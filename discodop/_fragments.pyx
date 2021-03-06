"""Fragment extraction with tree kernels.

Implements:

- Sangati et al. (2010), Efficiently extract recurring tree fragments from
  large treebanks.
- Moschitti (2006): Making Tree Kernels practical for Natural Language Learning
"""

from __future__ import print_function
import re
import codecs
from collections import defaultdict, Counter as multiset
from functools import partial
from itertools import islice
from array import array
from discodop.tree import Tree
from discodop.grammar import lcfrsproductions
from discodop.treetransforms import binarize

from libc.stdlib cimport malloc, realloc, free
from libc.string cimport memset, memcpy
from libc.stdint cimport uint8_t, uint32_t, uint64_t
from cpython.array cimport array, clone
from discodop.containers cimport Node, NodeArray, Ctrees, yieldranges
from discodop.bit cimport iteratesetbits, abitcount, subset, setunioninplace

cdef extern from "macros.h":
	int BITNSLOTS(int nb)
	void SETBIT(uint64_t a[], int b)
	void CLEARBIT(uint64_t a[], int b)
	uint64_t TESTBIT(uint64_t a[], int b)
	int IDX(int i, int j, int jmax, int kmax)

cdef array uintarray = array('I', ())  # template to create arrays of this type

# NB: (?: ) is a non-grouping operator; the second ':' is part of what we match
FRONTIERORTERMRE = re.compile(br' ([0-9]+)(?::[0-9]+)?\b')  # all leaf nodes
TERMINDICESRE = re.compile(br'\([^(]+ ([0-9]+)\)')  # leaf nodes w/term.indices
FRONTIERRE = re.compile(br' ([0-9]+):([0-9]+)\b')  # non-terminal frontiers
LABEL = re.compile(br' *\( *([^ ()]+) *')


# bitsets representing fragments are uint64_t arrays with the number of
# elements determined by SLOTS. While SLOTS is not a constant nor a global,
# it is set just once for a treebank to fit its largest tree.
# After SLOTS elements, this struct follows:
cdef packed struct BitsetTail:
	uint32_t id  # tree no. of which this fragment was extracted
	short root  # index of the root of the fragment in the NodeArray


# we wrap bitsets in bytes objects, because these can be (1) used in
# dictionaries and (2) passed between processes.
# we leave one byte for NUL-termination:
# data (SLOTS * 8), id (4), root (2), NUL (1)
cdef inline bytes wrap(uint64_t *data, short SLOTS):
	"""Wrap bitset in bytes object for handling in Python space."""
	return (<char *>data)[:SLOTS * sizeof(uint64_t) + sizeof(BitsetTail)]


# use getters & setters because a cdef class would incur overhead & indirection
# of a python object, and with a struct the root & id fields must be in front
# which seems to lead to bad hashing behavior (?)
cdef inline uint64_t *getpointer(object wrapper):
	"""Get pointer to bitset from wrapper."""
	return <uint64_t *><char *><bytes>wrapper


cdef inline uint32_t getid(uint64_t *data, short SLOTS):
	"""Get id of fragment in a bitset."""
	return (<BitsetTail *>&data[SLOTS]).id


cdef inline short getroot(uint64_t *data, short SLOTS):
	"""Get root of fragment in a bitset."""
	return (<BitsetTail *>&data[SLOTS]).root


cdef inline void setrootid(uint64_t *data, short root, uint32_t id,
		short SLOTS):
	"""Set root and id of fragment in a bitset."""
	cdef BitsetTail *tail = <BitsetTail *>&data[SLOTS]
	tail.id = id
	tail.root = root


cdef set twoterminals(NodeArray a, Node *anodes,
		Ctrees trees2, set contentwordprods, set lexicalprods):
	"""Produce tree pairs that share at least two words.

	Specifically, tree pairs sharing one content word and one additional word,
	where content words are recognized by a POS tag from the Penn treebank tag
	set.

	if trees2 is None, pairs (n, m) are such that n < m."""
	cdef int i, j
	cdef set tmp, candidates = set()
	# select candidates from 'trees2' that share productions with tree 'a'
	# want to select at least 1 content POS tag, 1 other lexical prod
	for i in range(a.len):
		if anodes[i].left >= 0 or anodes[i].prod not in contentwordprods:
			continue
		tmp = <set>(trees2.treeswithprod[anodes[i].prod])
		for j in range(a.len):
			if (i != j and anodes[j].left < 0 and
					anodes[j].prod in lexicalprods):
				candidates |= tmp & <set>(trees2.treeswithprod[anodes[j].prod])
	return candidates


cpdef extractfragments(Ctrees trees1, list sents1, int offset, int end,
		list labels, Ctrees trees2=None, list sents2=None, bint approx=True,
		bint debug=False, bint discontinuous=False, bint complement=False,
		bint twoterms=False, bint adjacent=False):
	"""Find the largest fragments in treebank(s) with the fast tree kernel.

	- scenario 1: recurring fragments in single treebank, use:
		``extractfragments(trees1, sents1, offset, end, labels)``
	- scenario 2: common fragments in two treebanks:
		``extractfragments(trees1, sents1, offset, end, labels, trees2, sents2)``

	``offset`` and ``end`` can be used to divide the work over multiple
	processes; they are indices of ``trees1`` to work on (default is all);
	when ``debug`` is enabled a table of common productions is shown for each
	pair of trees; when ``complement`` is true, the complement of the recurring
	fragments in each pair of trees is extracted as well."""
	cdef:
		int n, m, start = 0, end2
		short minterms = 2 if twoterms else 0
		short SLOTS  # the number of uint32_ts needed to cover the largest tree
		uint64_t *matrix = NULL  # bit matrix of common productions in tree pair
		uint64_t *scratch
		NodeArray a
		NodeArray *ctrees1
		Node *anodes
		list asent
		dict fragments = {}
		set inter = set(), contentwordprods = None, lexicalprods = None
		bytearray tmp = bytearray()
	if twoterms:
		contentword = re.compile(
				br'^(?:NN(?:[PS]|PS)?|(?:JJ|RB)[RS]?|VB[DGNPZ])$')
		contentwordprods = {n for n, label in enumerate(labels)
				if contentword.match(label)}
		lexical = re.compile(br'^[A-Z]+$')
		lexicalprods = {n for n, label in enumerate(labels)
				if lexical.match(label)}
	if approx:
		fragments = <dict>defaultdict(int)
	if trees2 is None:
		trees2 = trees1
	ctrees1 = trees1.trees
	SLOTS = BITNSLOTS(max(trees1.maxnodes, trees2.maxnodes) + 1)
	matrix = <uint64_t *>malloc(trees2.maxnodes * SLOTS * sizeof(uint64_t))
	scratch = <uint64_t *>malloc((SLOTS + 2) * sizeof(uint64_t))
	if matrix is NULL or scratch is NULL:
		raise MemoryError('allocation error')
	end2 = trees2.len
	# loop over tree pairs to extract fragments from
	for n in range(offset, min(end or trees1.len, trees1.len)):
		a = ctrees1[n]
		asent = <list>(sents1[n])
		anodes = &trees1.nodes[a.offset]
		if adjacent:
			m = n + 1
			if m < trees2.len:
				extractfrompair(a, anodes, trees2, n, m,
						complement, debug, asent, sents2 or sents1,
						labels, inter, minterms, matrix, scratch, SLOTS)
		elif twoterms:
			for m in twoterminals(a, anodes, trees2,
					contentwordprods, lexicalprods):
				if sents2 is None and m <= n:
					continue
				elif m < 0 or m >= trees2.len:
					raise ValueError('illegal index %d' % m)
				extractfrompair(a, anodes, trees2, n, m,
						complement, debug, asent, sents2 or sents1,
						labels, inter, minterms, matrix, scratch, SLOTS)
		else:  # all pairs
			if sents2 is None:
				start = n + 1
			for m in range(start, end2):
				extractfrompair(a, anodes, trees2, n, m,
						complement, debug, asent, sents2 or sents1,
						labels, inter, minterms, matrix, scratch, SLOTS)
		collectfragments(fragments, inter, anodes, asent, labels,
				discontinuous, approx, tmp, SLOTS)
	free(matrix)
	free(scratch)
	return fragments


cdef inline extractfrompair(NodeArray a, Node *anodes, Ctrees trees2,
		int n, int m, bint complement, bint debug, list asent, list sents,
		list labels, set inter, short minterms, uint64_t *matrix, uint64_t *scratch,
		short SLOTS):
	"""Extract the bitsets of maximal overlapping fragments for a tree pair."""
	cdef NodeArray b = trees2.trees[m]
	cdef Node *bnodes = &trees2.nodes[b.offset]
	# initialize table
	memset(<void *>matrix, 0, b.len * SLOTS * sizeof(uint64_t))
	# fill table
	fasttreekernel(anodes, bnodes, a.len, b.len, matrix, SLOTS)
	# dump table
	if debug:
		print(n, m)
		dumpmatrix(matrix, a, b, anodes, bnodes, asent, sents[m], labels,
				scratch, SLOTS)
	# extract results
	extractbitsets(matrix, anodes, bnodes, b.root, n,
			inter, minterms, scratch, SLOTS)
	# extract complementary fragments?
	if complement:
		# combine bitsets of inter together with bitwise or
		memset(<void *>scratch, 0, SLOTS * sizeof(uint64_t))
		for wrapper in inter:
			setunioninplace(scratch, getpointer(wrapper), SLOTS)
		# extract bitsets in A from result, without regard for B
		extractcompbitsets(scratch, anodes, a.root, n, inter,
				SLOTS, NULL)


cdef inline collectfragments(dict fragments, set inter, Node *anodes,
		list asent, list labels, bint discontinuous, bint approx,
		bytearray tmp, short SLOTS):
	"""Collect string representations of fragments given as bitsets."""
	cdef uint64_t *bitset
	for wrapper in inter:
		bitset = getpointer(wrapper)
		getsubtree(tmp, anodes, bitset, labels,
				<list>(None if discontinuous else asent),
				getroot(bitset, SLOTS))
		frag = getsent(bytes(tmp), asent) if discontinuous else bytes(tmp)
		del tmp[:]
		if approx:
			fragments[frag] += 1
		elif frag not in fragments:  # FIXME: is this condition useful?
			fragments[frag] = wrapper
	inter.clear()


cdef inline void fasttreekernel(Node *a, Node *b, int alen, int blen,
		uint64_t *matrix, short SLOTS):
	"""Fast Tree Kernel (average case linear time).

	Expects trees to be sorted according to their productions (in descending
	order, with terminals as -1). This algorithm is from the pseudocode in
	Moschitti (2006): Making Tree Kernels practical for Natural Language
	Learning."""
	# i is an index to a, j to b, and ii is a temp index starting at i.
	cdef int i = 0, j = 0, ii = 0
	while True:
		if a[i].prod < b[j].prod:
			i += 1
			if i >= alen:
				return
		elif a[i].prod > b[j].prod:
			j += 1
			if j >= blen:
				return
		else:
			while a[i].prod == b[j].prod:
				ii = i
				while a[ii].prod == b[j].prod:
					SETBIT(&matrix[j * SLOTS], ii)
					ii += 1
					if ii >= alen:
						break
				j += 1
				if j >= blen:
					return


cdef inline extractbitsets(uint64_t *matrix, Node *a, Node *b, short j, int n,
		set results, int minterms, uint64_t *scratch, short SLOTS):
	"""Visit nodes of ``b`` top-down and store bitsets of common nodes.

	Stores bitsets of connected subsets of ``a`` as they are encountered,
	following the common nodes specified in bit matrix. ``j`` is the node in
	``b`` to start with, which changes with each recursive step. ``n`` is the
	identifier of this tree which is stored with extracted fragments."""
	cdef uint64_t *bitset = &matrix[j * SLOTS]
	cdef uint64_t cur = bitset[0]
	cdef int idx = 0, terms
	cdef int i = iteratesetbits(bitset, SLOTS, &cur, &idx)
	while i != -1:
		memset(<void *>scratch, 0, SLOTS * sizeof(uint64_t))
		terms = extractat(matrix, scratch, a, b, i, j, SLOTS)
		if terms >= minterms:
			setrootid(scratch, i, n, SLOTS)
			results.add(wrap(scratch, SLOTS))
		i = iteratesetbits(bitset, SLOTS, &cur, &idx)
	if b[j].left >= 0:
		extractbitsets(matrix, a, b, b[j].left, n,
				results, minterms, scratch, SLOTS)
		if b[j].right >= 0:
			extractbitsets(matrix, a, b, b[j].right, n,
					results, minterms, scratch, SLOTS)


cdef inline int extractat(uint64_t *matrix, uint64_t *result, Node *a, Node *b,
		short i, short j, short SLOTS):
	"""Traverse tree `a` and `b` in parallel to extract a connected subset."""
	cdef int terms = 0
	SETBIT(result, i)
	CLEARBIT(&matrix[j * SLOTS], i)
	if a[i].left < 0:
		return 1
	elif TESTBIT(&matrix[b[j].left * SLOTS], a[i].left):
		terms += extractat(matrix, result, a, b, a[i].left, b[j].left, SLOTS)
	if a[i].right < 0:
		return 0
	elif TESTBIT(&matrix[b[j].right * SLOTS], a[i].right):
		terms += extractat(matrix, result, a, b, a[i].right, b[j].right, SLOTS)
	return terms


cpdef exactcounts(Ctrees trees1, Ctrees trees2, list bitsets,
		bint indices=False):
	"""Get exact counts or indices of occurrence for fragments.

	Given a set of fragments from ``trees1`` as bitsets, find all occurrences
	of those fragments in ``trees2`` (which may be equal to ``trees1``).

	By default, exact counts are collected. When ``indices`` is ``True``, a
	multiset of indices is returned for each fragment; the indices point to the
	trees where the fragments (described by the bitsets) occur. This is useful
	to look up the contexts of fragments, or when the order of sentences has
	significance which makes it possible to interpret the set of indices as
	time-series data. The reason we need to do this separately from extracting
	maximal fragments is that a fragment can occur in other trees where it was
	not a maximal."""
	cdef:
		array counts = None
		list theindices = None
		object matches = None  # multiset()
		set candidates
		short i, j, SLOTS = BITNSLOTS(max(trees1.maxnodes, trees2.maxnodes) + 1)
		uint32_t n, m
		uint32_t *countsp = NULL
		NodeArray a, b
		Node *anodes
		Node *bnodes
		uint64_t cur
		uint64_t *bitset
		int idx
	if indices:
		theindices = [multiset() for _ in bitsets]
	else:
		counts = clone(uintarray, len(bitsets), True)
		countsp = counts.data.as_uints
	# compare one bitset to each tree for each unique fragment.
	for n, wrapper in enumerate(bitsets):
		bitset = getpointer(wrapper)
		a = trees1.trees[getid(bitset, SLOTS)]  # fragment came from this tree
		anodes = &trees1.nodes[a.offset]
		cur, idx = bitset[0], 0
		i = iteratesetbits(bitset, SLOTS, &cur, &idx)
		assert i != -1
		candidates = <set>(trees2.treeswithprod[anodes[i].prod]).copy()
		while True:
			i = iteratesetbits(bitset, SLOTS, &cur, &idx)
			if i == -1 or i >= a.len:  # FIXME. why is 2nd condition necessary?
				break
			candidates &= <set>(trees2.treeswithprod[anodes[i].prod])
		i = getroot(bitset, SLOTS)  # root of fragment in tree 'a'
		if indices:
			matches = theindices[n]
		for m in candidates:
			b = trees2.trees[m]
			bnodes = &trees2.nodes[b.offset]
			for j in range(b.len):
				if anodes[i].prod == bnodes[j].prod:
					if containsbitset(anodes, bnodes, bitset, i, j):
						if indices:
							matches[m] += 1
						else:
							countsp[n] += 1
				elif anodes[i].prod < bnodes[j].prod:
					break
	return theindices if indices else counts


cdef inline int containsbitset(Node *a, Node *b, uint64_t *bitset,
		short i, short j):
	"""Test whether the fragment ``bitset`` at ``a[i]`` occurs at ``b[j]``."""
	if a[i].prod != b[j].prod:
		return 0
	elif a[i].left < 0:
		return 1
	elif TESTBIT(bitset, a[i].left):
		if not containsbitset(a, b, bitset, a[i].left, b[j].left):
			return 0
	if a[i].right < 0:
		return 1
	elif TESTBIT(bitset, a[i].right):
		return containsbitset(a, b, bitset, a[i].right, b[j].right)
	return 1


cpdef dict coverbitsets(Ctrees trees, list sents, list labels,
		short maxnodes, bint discontinuous):
	"""Utility function to generate one bitset for each type of production.

	Important: if multiple treebanks are used, maxnodes should equal
	``max(trees1.maxnodes, trees2.maxnodes)``"""
	cdef:
		dict result = {}
		int p, i, n = -1
		short SLOTS = BITNSLOTS(maxnodes + 1)
		uint64_t *scratch = <uint64_t *>malloc((SLOTS + 2) * sizeof(uint64_t))
		Node *nodes
		bytearray tmp = bytearray()
	if scratch is NULL:
		raise MemoryError('allocation error')
	assert SLOTS, SLOTS
	for p, treeindices in enumerate(trees.treeswithprod):
		try:  # slightly convoluted way of getting an arbitrary set member:
			n = next(iter(treeindices))
		except StopIteration:
			# when using multiple treebanks, there may be a production which
			# doesn't occur in this treebank
			continue
		nodes = &trees.nodes[trees.trees[n].offset]
		memset(<void *>scratch, 0, SLOTS * sizeof(uint64_t))
		for i in range(trees.trees[n].len):
			if nodes[i].prod == p:
				SETBIT(scratch, i)
				setrootid(scratch, i, n, SLOTS)
				break
		else:
			raise ValueError('production not found. wrong index?')
		getsubtree(tmp, nodes, scratch, labels,
				None if discontinuous else sents[n], i)
		frag = getsent(bytes(tmp), sents[n]) if discontinuous else bytes(tmp)
		del tmp[:]
		result[frag] = wrap(scratch, SLOTS)
	return result


cpdef dict completebitsets(Ctrees trees, list sents, list labels,
		short maxnodes, bint discontinuous=False):
	"""Generate bitsets corresponding to whole trees in the input.

	Important: if multiple treebanks are used, maxnodes should equal
	``max(trees1.maxnodes, trees2.maxnodes)``"""
	cdef:
		dict result = {}
		list sent
		int n, i
		short SLOTS = BITNSLOTS(maxnodes + 1)
		uint64_t *scratch = <uint64_t *>malloc((SLOTS + 2) * sizeof(uint64_t))
		Node *nodes
		bytearray tmp = bytearray()
	for n in range(trees.len):
		memset(<void *>scratch, 0, SLOTS * sizeof(uint64_t))
		nodes = &trees.nodes[trees.trees[n].offset]
		sent = sents[n]
		for i in range(trees.trees[n].len):
			if nodes[i].left >= 0 or sent[termidx(nodes[i].left)] is not None:
				SETBIT(scratch, i)
		setrootid(scratch, trees.trees[n].root, n, SLOTS)
		getsubtree(tmp, nodes, scratch, labels,
				None if discontinuous else sent, trees.trees[n].root)
		frag = (bytes(tmp), tuple(sent)) if discontinuous else bytes(tmp)
		del tmp[:]
		result[frag] = wrap(scratch, SLOTS)
	return result


cdef extractcompbitsets(uint64_t *bitset, Node *a,
		int i, int n, set results, short SLOTS, uint64_t *scratch):
	"""Like ``extractbitsets()`` but following complement of ``bitset``."""
	cdef bint start = scratch is NULL and not TESTBIT(bitset, i)
	if start:  # start extracting a fragment
		# need to create a new array because further down in the recursion
		# other fragments may be encountered which should not overwrite
		# this one
		scratch = <uint64_t *>malloc((SLOTS + 2) * sizeof(uint64_t))
		if scratch is NULL:
			raise MemoryError('allocation error')
		setrootid(scratch, i, n, SLOTS)
	elif TESTBIT(bitset, i):  # stop extracting for this fragment
		scratch = NULL
	if scratch is not NULL:
		SETBIT(scratch, i)
	if a[i].left >= 0:
		extractcompbitsets(bitset, a, a[i].left, n, results, SLOTS, scratch)
		if a[i].right >= 0:
			extractcompbitsets(bitset, a, a[i].right, n, results, SLOTS, scratch)
	if start:  # store fragment
		results.add(wrap(scratch, SLOTS))
		free(scratch)


cdef inline short termidx(short x):
	"""Translate representation for terminal indices."""
	return -x - 1


cdef inline getsubtree(bytearray result, Node *tree, uint64_t *bitset,
		list labels, list sent, int i):
	"""Get string of tree fragment denoted by bitset; indices as terminals.

	:param result: provide an empty ``bytearray()`` for the initial call."""
	result.append(b'(')
	result += labels[tree[i].prod]
	result.append(b' ')
	if TESTBIT(bitset, i):
		if tree[i].left >= 0:
			getsubtree(result, tree, bitset, labels, sent, tree[i].left)
			if tree[i].right >= 0:
				result.append(b' ')
				getsubtree(result, tree, bitset, labels, sent, tree[i].right)
		elif sent is None:
			result += str(termidx(tree[i].left)).encode('ascii')
		else:
			result += sent[termidx(tree[i].left)].encode('utf-8')
	elif sent is None:  # node not in bitset, frontier non-terminal
		result += yieldranges(sorted(getyield(tree, i))).encode('ascii')
	result.append(b')')


cdef inline list getyield(Node *tree, int i):
	"""Recursively collect indices of terminals under a node."""
	if tree[i].left < 0:
		return [termidx(tree[i].left)]
	elif tree[i].right < 0:
		return getyield(tree, tree[i].left)
	return getyield(tree, tree[i].left) + getyield(tree, tree[i].right)


def repl(d):
	"""A function for use with re.sub that looks up numeric IDs in a dict.
	"""
	def f(x):
		return d[int(x.group(1))]
	return f


def pygetsent(bytes frag, list sent):
	"""Wrapper of ``getsent()`` to make doctests possible.

	>>> pygetsent(b'(S (NP 2) (VP 4))',
	... ['The', 'tall', 'man', 'there', 'walks'])
	('(S (NP 0) (VP 2))', ('man', None, 'walks'))
	>>> pygetsent(b'(VP (VB 0) (PRT 3))', ['Wake', 'your', 'friend', 'up'])
	('(VP (VB 0) (PRT 2))', ('Wake', None, 'up'))
	>>> pygetsent(b'(S (NP 2:2 4:4) (VP 1:1 3:3))',
	... ['Walks','the','quickly','man'])
	('(S (NP 1 3) (VP 0 2))', (None, None, None, None))
	>>> pygetsent(b'(ROOT (S 0:2) ($. 3))', ['Foo', 'bar', 'zed', '.'])
	('(ROOT (S 0) ($. 1))', (None, '.'))
	>>> pygetsent(b'(ROOT (S 0) ($. 3))', ['Foo', 'bar', 'zed','.'])
	('(ROOT (S 0) ($. 2))', ('Foo', None, '.'))
	>>> pygetsent(b'(S|<VP>_2 (VP_3 0:1 3:3 16:16) (VAFIN 2))', '''In Japan
	...  wird offenbar die Fusion der Geldkonzerne Daiwa und Sumitomo zur
	...  gr\\xf6\\xdften Bank der Welt vorbereitet .'''.split())
	('(S|<VP>_2 (VP_3 0 2 4) (VAFIN 1))', (None, 'wird', None, None, None))"""
	try:
		a, b = getsent(frag, sent)
		return str(a.decode('ascii')), b
	except:
		print(frag)
		raise


cdef getsent(bytes frag, list sent):
	"""Renumber indices in fragment and select terminals it contains.

	Returns a transformed copy of fragment and sentence. Replace words that do
	not occur in the fragment with None and renumber terminals in fragment such
	that the first index is 0 and any gaps have a width of 1. Expects a tree as
	string where frontier nodes are marked with intervals."""
	cdef:
		int n, m = 0, maxl
		list newsent = []
		dict leafmap = {}
		dict spans = {int(start): int(end) + 1
				for start, end in FRONTIERRE.findall(frag)}
		list leaves = list(map(int, TERMINDICESRE.findall(frag)))
	for n in leaves:
		spans[n] = n + 1
	maxl = max(spans)
	for n in sorted(spans):
		newsent.append(sent[n] if n in leaves else None)
		leafmap[n] = (' %d' % m).encode('ascii')
		m += 1
		if spans[n] not in spans and n != maxl:  # a gap
			newsent.append(None)
			m += 1
	frag = FRONTIERORTERMRE.sub(repl(leafmap), frag)
	return frag, tuple(newsent)


cdef dumpmatrix(uint64_t *matrix, NodeArray a, NodeArray b, Node *anodes,
		Node *bnodes, list asent, list bsent, list labels, uint64_t *scratch,
		short SLOTS):
	"""Dump a table of the common productions of a tree pair."""
	dumptree(a, anodes, asent, labels, scratch)
	dumptree(b, bnodes, bsent, labels, scratch)
	print('\t'.join([''] + ['%2d' % x for x in range(b.len)
		if bnodes[x].prod != -1]))
	for m in range(b.len):
		print('\t', labels[(<Node>bnodes[m]).prod][:3], end='')
	for n in range(a.len):
		print('\n%2d' % n, labels[(<Node>anodes[n]).prod][:3], end='')
		for m in range(b.len):
			print('\t', end='')
			print('1' if TESTBIT(&matrix[m * SLOTS], n) else ' ', end='')
	print('\ncommon productions:', end=' ')
	print(len({anodes[n].prod for n in range(a.len)} &
			{bnodes[n].prod for n in range(b.len)}))
	print('found:', end=' ')
	print('horz', sum([abitcount(&matrix[n * SLOTS], SLOTS) > 0
			for n in range(b.len)]),
		'vert', sum([any([TESTBIT(&matrix[n * SLOTS], m)
			for n in range(b.len)]) for m in range(a.len)]),
		'both', abitcount(matrix, b.len * SLOTS))


cdef dumptree(NodeArray a, Node *anodes, list asent, list labels,
		uint64_t *scratch):
	"""Print debug information of a given tree."""
	for n in range(a.len):
		print('idx=%2d\tleft=%2d\tright=%2d\tprod=%2d\tlabel=%s' % (n,
				termidx(anodes[n].left) if anodes[n].left < 0
				else anodes[n].left,
				anodes[n].right, anodes[n].prod, labels[anodes[n].prod]),
				end='')
		if anodes[n].left < 0:
			if asent[termidx(anodes[n].left)]:
				print('\t%s=%s' % ('terminal', asent[termidx(anodes[n].left)]))
			else:
				print('\tfrontier non-terminal')
		else:
			print()
	tmp = bytearray()
	memset(<void *>scratch, 255, BITNSLOTS(a.len) * sizeof(uint64_t))
	getsubtree(tmp, anodes, scratch, labels, None, a.root)
	print(tmp.decode('utf-8'), '\n', asent, '\n')


def addprods(tree, sent, disc=True):
	"""Set ``.prod`` attribute on nodes of tree to their LCFRS productions.

	:param disc: pass disc=False to get CFG productions instead."""
	if disc:
		for a, b in zip(tree.subtrees(),
				lcfrsproductions(tree, sent, frontiers=True)):
			a.prod = b
	else:
		for a in tree.subtrees():
			if len(a) == 0:
				a.prod = (a.label, )
			elif len(a) == 1:
				a.prod = (a.label,
						a[0].label if isinstance(a[0], Tree)
						else sent[a[0]])
			elif len(a) == 2:
				a.prod = (a.label, a[0].label, a[1].label)
			else:
				raise ValueError('tree not binarized.')
	return tree


def getlabelsprods(trees, labels, prods):
	"""Collect ``label``, ``prod`` attributes from ``trees`` and index them."""
	pnum = len(prods)
	for tree in trees:
		for st in tree:
			if st.prod not in prods:
				labels.append(st.label.encode('ascii'))  # LHS label of prod
				prods[st.prod] = pnum
				pnum += 1


def nonfrontier(sent):
	def nonfrontierfun(x):
		return isinstance(x[0], Tree) or sent[x[0]] is not None
	return nonfrontierfun


def tolist(tree, sent):
	"""Convert Tree object to list of non-terminal nodes in preorder traversal.

	Also adds indices to nodes reflecting their position in the list;
	i.e., ``tolist(tree, sent)[n].idx == n``"""
	result = list(tree.subtrees(nonfrontier(sent)))
	for n in reversed(range(len(result))):
		a = result[n]
		a.idx = n
		if not a.label:
			raise ValueError('labels should be non-empty. tree: '
				'%s\nsubtree: %s\nindex %d, label %r' % (tree, a, n, a.label))
	result[0].rootidx = 0
	return result


def getprodid(prods, node):
	return prods.get(node.prod, -1)


def getctrees(trees, sents, disc=True, trees2=None, sents2=None):
	""":returns: Ctrees object for disc. binary trees and sentences."""
	# make deep copies to avoid side effects.
	trees12 = trees = [tolist(addprods(Tree.convert(a), b, disc), b)
			for a, b in zip(trees, sents)]
	if trees2:
		trees2 = [tolist(addprods(Tree.convert(a), b, disc), b)
					for a, b in zip(trees2, sents2)]
		trees12 = trees + trees2
	labels = []
	prods = {}
	getlabelsprods(trees12, labels, prods)
	for tree in trees12:
		root = tree[0]
		tree.sort(key=partial(getprodid, prods))
		for n, a in enumerate(tree):
			a.idx = n
		tree[0].rootidx = root.idx
	trees = Ctrees(trees, prods)
	trees.indextrees(prods)
	if trees2:
		trees2 = Ctrees(trees2, prods)
		trees2.indextrees(prods)
	return dict(trees1=trees, sents1=sents, trees2=trees2, sents2=sents2,
			prods=prods, labels=labels)


cdef readnode(bytes label, bytes line, char *cline, short start, short end,
		list labels, dict prods, Node *result, size_t *idx, list sent,
		bytes binlabel):
	"""Parse tree in bracket format into pre-allocated array of Node structs.

	:param idx: a counter to keep track of the number of Node structs used.
	:param sent: collects the terminals encountered.
	:param binlabel: used for on-the-fly binarization, pass None initially."""
	cdef:
		short n, parens = 0, left = -1, right = -1
		short startchild1 = 0, startchild2 = 0, endchild1 = 0, endchild2 = 0
		list childlabels = None
		bytes labelchild1 = None, labelchild2 = None
	# walk through the string and find the first two children
	for n in range(start, end):
		if cline[n] == '(':
			if parens == 0:
				start = n
			parens += 1
		elif cline[n] == ')':
			parens -= 1
			if parens == -1:
				if startchild1 == 0:
					startchild1, endchild1 = start, n
			elif parens == 0:
				if startchild1 == 0:
					startchild1, endchild1 = start, n + 1
				elif startchild2 == 0:
					startchild2, endchild2 = start, n + 1
				else:  # will do on the fly binarization
					childlabels = []
					break
	# get left child label
	match1 = LABEL.match(line, startchild1)
	if match1 is not None:  # non-terminal label
		labelchild1 = match1.group(1)
		startchild1 = match1.end()
	elif startchild2 != 0:  # insert preterminal
		labelchild1 = b'/'.join((label, line[startchild1:endchild1]))
	else:  # terminal following pre-terminal; store terminal
		# leading space distinguishes terminal from non-terminal
		labelchild1 = b' ' + line[startchild1:endchild1]
		left = termidx(len(sent))
		sent.append(line[startchild1:endchild1].decode('utf-8')
				if startchild1 < endchild1 else None)
	# if there were more children, collect labels for a binarized constituent
	if childlabels is not None:
		for n in range(startchild2, end):
			if cline[n] == '(':
				if parens == 0:
					start = n
				parens += 1
			elif cline[n] == ')':
				parens -= 1
				if parens == 0:
					match = LABEL.match(line, start)
					if match is None:  # introduce preterminal
						childlabels.append(
								b'/'.join((label, line[start:n + 1])))
					else:
						childlabels.append(match.group(1))
		if not binlabel:
			binlabel = label + b'|<' + labelchild1
			labelchild2 = binlabel + b'.' + b','.join(childlabels) + b'>'
		else:
			binlabel += b',' + labelchild1
			labelchild2 = binlabel + b'.' + b','.join(childlabels) + b'>'
		endchild2 = end
	if parens != -1:
		raise ValueError('unbalanced parentheses: %d\n%r' % (parens, line))
	if startchild2 == 0:
		prod = (label, labelchild1) if startchild1 else (label, )
	else:
		if labelchild2 is None:
			match = LABEL.match(line, startchild2)
			if match is not None:
				labelchild2 = match.group(1)
				startchild2 = match.end()
			else:  # insert preterminal
				labelchild2 = b'/'.join((label, line[startchild2:endchild2]))
		prod = (label, labelchild1, labelchild2)
	if prod not in prods:  # assign new ID?
		prods[prod] = len(prods)
		labels.append(label)
	n = idx[0]
	idx[0] += 1
	if match1 is not None or startchild2 != 0:
		left = idx[0]
		readnode(labelchild1, line, cline, startchild1, endchild1, labels,
				prods, result, idx, sent, None)
		if startchild2 != 0:
			right = idx[0]
			readnode(labelchild2, line, cline, startchild2, endchild2, labels,
					prods, result, idx, sent, childlabels and binlabel)
	# store node
	result[n].prod = prods[prod]
	result[n].left = left
	result[n].right = right


def readtreebank(treebankfile, list labels, dict prods,
		fmt='bracket', limit=None, encoding='utf-8'):
	"""Read a treebank from a given filename.

	labels and prods should be re-used when reading multiple treebanks."""
	cdef size_t cnt, n
	cdef Node *scratch
	cdef Ctrees ctrees
	if treebankfile is None:
		return None, None
	if fmt != 'bracket':
		from discodop.treebank import READERS
		from discodop.treetransforms import canonicalize
		corpus = READERS[fmt](treebankfile, encoding=encoding)
		ctrees = Ctrees()
		ctrees.alloc(512, 512 * 512)  # dummy values, array will be realloc'd
		sents = []
		for _, (tree, sent) in corpus.itertrees(0, limit):
			tree = tolist(addprods(
					canonicalize(binarize(tree, dot=True)), sent), sent)
			for st in tree:
				if st.prod not in prods:
					labels.append(st.label.encode('ascii'))
					prods[st.prod] = len(prods)
			root = tree[0]
			tree.sort(key=partial(getprodid, prods))
			for n, a in enumerate(tree):
				a.idx = n
			tree[0].rootidx = root.idx
			ctrees.add(tree, prods)
			sents.append(sent)
	else:  # do incremental reading of bracket trees
		# could use BracketCorpusReader or expect trees/sents as input, but
		# incremental reading reduces memory requirements.
		sents = []
		maxnodes = 512
		ctrees = Ctrees()
		ctrees.alloc(512, 512 * 512)  # dummy values, array will be realloc'd
		binfactor = 2  # conservative estimate to accommodate binarization
		scratch = <Node *>malloc(maxnodes * binfactor * sizeof(Node))
		if scratch is NULL:
			raise MemoryError('allocation error')
		if encoding.lower() in ('utf8', 'utf-8'):
			data = open(treebankfile)
		else:  # a kludge; better use UTF-8!
			data = codecs.iterencode(codecs.open(treebankfile,
					encoding=encoding), 'utf-8')
		for n, line in enumerate(islice(data, limit), 1):
			if line.count(b'(') > maxnodes:
				maxnodes = 2 * line.count(b'(')
				scratch = <Node *>realloc(scratch,
						maxnodes * binfactor * sizeof(Node))
				if scratch is NULL:
					raise MemoryError('allocation error')
			cnt = 0
			sent = []
			match = LABEL.match(line)
			if match is None:
				raise ValueError('malformed tree in %r line %d:\n%r' % (
						treebankfile, n, line))
			readnode(match.group(1), line, line, match.end(), len(line),
					labels, prods, scratch, &cnt, sent, None)
			ctrees.addnodes(scratch, cnt, 0)
			sents.append(sent)
		if not sents:
			raise ValueError('%r appears to be empty' % treebankfile)
		free(scratch)
	return ctrees, sents


__all__ = ['addprods', 'completebitsets', 'coverbitsets', 'exactcounts',
		'extractfragments', 'getctrees', 'getlabelsprods', 'getprodid',
		'nonfrontier', 'pygetsent', 'readtreebank', 'repl', 'tolist']
