"""Data types for chart items, edges, &c."""
from __future__ import print_function
from math import exp, log, fsum
from libc.math cimport log, exp
from discodop.tree import Tree
from discodop.bit cimport nextset, nextunset, anextset, anextunset
cimport cython
include "constants.pxi"

maxbitveclen = SLOTS * sizeof(uint64_t) * 8
cdef double INFINITY = float('infinity')

include "_grammar.pxi"


@cython.final
cdef class LexicalRule:
	"""A weighted rule of the form 'non-terminal --> word'."""
	def __init__(self, uint32_t lhs, unicode word, double prob):
		self.lhs = lhs
		self.word = word
		self.prob = prob

	def __repr__(self):
		return "%s%r" % (self.__class__.__name__,
				(self.lhs, self.word, self.prob))


@cython.final
cdef class SmallChartItem:
	"""Item with word sized bitvector."""
	def __init__(self, label, vec):
		self.label = label
		self.vec = vec

	def __hash__(self):
		"""Juxtapose bits of label and vec, rotating vec if > 33 words.

		64              32            0
		|               ..........label
		|vec[0] 1st half
		|               vec[0] 2nd half
		------------------------------- XOR"""
		return (self.label ^ (self.vec << (sizeof(self.vec) / 2 - 1))
				^ (self.vec >> (sizeof(self.vec) / 2 - 1)))

	def __richcmp__(self, other, int op):
		cdef SmallChartItem me = <SmallChartItem>self
		cdef SmallChartItem ob = <SmallChartItem>other
		if op == 2:
			return me.label == ob.label and me.vec == ob.vec
		elif op == 3:
			return me.label != ob.label or me.vec != ob.vec
		elif op == 5:
			return me.label >= ob.label or me.vec >= ob.vec
		elif op == 1:
			return me.label <= ob.label or me.vec <= ob.vec
		elif op == 0:
			return me.label < ob.label or me.vec < ob.vec
		elif op == 4:
			return me.label > ob.label or me.vec > ob.vec

	def __nonzero__(self):
		return self.label != 0 and self.vec != 0

	def __repr__(self):
		return "%s(%d, %s)" % (self.__class__.__name__,
				self.label, self.binrepr())

	def lexidx(self):
		assert self.label == 0
		return self.vec

	cdef copy(self):
		return new_SmallChartItem(self.label, self.vec)

	def binrepr(self, int lensent=0):
		return bin(self.vec)[2:].zfill(lensent)[::-1]


@cython.final
cdef class FatChartItem:
	"""Item where bitvector is a fixed-width static array."""
	def __hash__(self):
		cdef long n, _hash
		"""Juxtapose bits of label and vec.

		64              32            0
		|               ..........label
		|vec[0] 1st half
		|               vec[0] 2nd half
		|........ rest of vec .........
		------------------------------- XOR"""
		_hash = (self.label ^ self.vec[0] << (8 * sizeof(self.vec[0]) / 2 - 1)
				^ self.vec[0] >> (8 * sizeof(self.vec[0]) / 2 - 1))
		# add remaining bits
		for n in range(sizeof(self.vec[0]), sizeof(self.vec)):
			_hash *= 33 ^ (<uint8_t *>self.vec)[n]
		return _hash

	def __richcmp__(self, other, int op):
		cdef FatChartItem me = <FatChartItem>self
		cdef FatChartItem ob = <FatChartItem>other
		cdef int cmp = 0
		cdef bint labelmatch = me.label == ob.label
		cmp = memcmp(<uint8_t *>ob.vec, <uint8_t *>me.vec, sizeof(me.vec))
		if op == 2:
			return labelmatch and cmp == 0
		elif op == 3:
			return not labelmatch or cmp != 0
		# NB: for a proper ordering, need to reverse memcmp
		elif op == 5:
			return me.label >= ob.label or (labelmatch and cmp >= 0)
		elif op == 1:
			return me.label <= ob.label or (labelmatch and cmp <= 0)
		elif op == 0:
			return me.label < ob.label or (labelmatch and cmp < 0)
		elif op == 4:
			return me.label > ob.label or (labelmatch and cmp > 0)

	def __nonzero__(self):
		cdef int n
		if self.label:
			for n in range(SLOTS):
				if self.vec[n]:
					return True
		return False

	def __repr__(self):
		return "%s(%d, %s)" % (self.__class__.__name__,
			self.label, self.binrepr())

	def lexidx(self):
		assert self.label == 0
		return self.vec[0]

	cdef copy(self):
		cdef int n
		cdef FatChartItem a = new_FatChartItem(self.label)
		for n in range(SLOTS):
			a.vec[n] = self.vec[n]
		return a

	def binrepr(self, lensent=0):
		cdef int n
		cdef str result = ''
		for n in range(SLOTS):
			result += bin(self.vec[n])[2:].zfill(BITSIZE)[::-1]
		return result[:lensent] if lensent else result.rstrip('0')


cdef SmallChartItem CFGtoSmallChartItem(uint32_t label, Idx start, Idx end):
	return new_SmallChartItem(label, (1UL << end) - (1UL << start))


cdef FatChartItem CFGtoFatChartItem(uint32_t label, Idx start, Idx end):
	cdef FatChartItem fci = new_FatChartItem(label)
	cdef short n
	if BITSLOT(start) == BITSLOT(end):
		fci.vec[BITSLOT(start)] = (1UL << end) - (1UL << start)
	else:
		fci.vec[BITSLOT(start)] = ~0UL << (start % BITSIZE)
		for n in range(BITSLOT(start) + 1, BITSLOT(end)):
			fci.vec[n] = ~0UL
		fci.vec[BITSLOT(end)] = BITMASK(end) - 1
	return fci


@cython.final
cdef class Edges:
	"""A static array with a fixed number of Edge structs."""
	def __cinit__(self):
		self.len = 0

	def __repr__(self):
		return '<%d edges>' % self.len


@cython.final
cdef class RankedEdge:
	"""A derivation with backpointers.

	Denotes a *k*-best derivation defined by an edge, including the chart
	item (head) to which it points, along with ranks for its children."""
	def __hash__(self):
		cdef long _hash = 0x345678UL
		_hash = (1000003UL * _hash) ^ hash(self.head)
		_hash = (1000003UL * _hash) ^ (-1 if self.edge.rule is NULL
				else self.edge.rule.no)
		_hash = (1000003UL * _hash) ^ self.edge.pos.lvec
		_hash = (1000003UL * _hash) ^ self.left
		_hash = (1000003UL * _hash) ^ self.right
		return _hash

	def __richcmp__(RankedEdge self, RankedEdge ob, int op):
		if op == 2 or op == 3:  # '==' or '!='
			return (op == 2) == (self.left == ob.left and self.right
					== ob.right and self.head == ob.head
					and memcmp(<uint8_t *>self.edge, <uint8_t *>ob.edge,
						sizeof(ob.edge)) == 0)
		return NotImplemented

	def __repr__(self):
		return "%s(%r, %d, %d)" % (self.__class__.__name__,
			self.head, self.left, self.right)


cdef class Chart:
	"""Base class for charts. Provides methods available on all charts.

	The subclass hierarchy for charts has three levels:

		(0) base class, methods for chart traversal.
		(1) formalism, methods specific to CFG vs. LCFRS parsers.
		(2) data structures optimized for short/long sentences, small/large
			grammars.

	Level 1/2 defines a type for labeled spans referred to as ``item``."""
	def root(self):
		"""Return item with root label spanning the whole sentence."""
		raise NotImplementedError

	cdef _left(self, item, Edge *edge):
		"""Return the left item that edge points to."""
		raise NotImplementedError

	cdef _right(self, item, Edge *edge):
		"""Return the right item that edge points to."""
		raise NotImplementedError

	cdef double subtreeprob(self, item):
		"""Return probability of subtree headed by item."""
		raise NotImplementedError

	cdef left(self, RankedEdge rankededge):
		"""Given a ranked edge, return the left item it points to."""
		return self._left(rankededge.head, rankededge.edge)

	cdef right(self, RankedEdge rankededge):
		"""Given a ranked edge, return the right item it points to."""
		return self._right(rankededge.head, rankededge.edge)

	cdef copy(self, item):
		return item

	def indices(self, item):
		"""Return a list of indices dominated by ``item``."""
		raise NotImplementedError

	cdef lexidx(self, Edge *edge):
		"""Return sentence index of the terminal child given a lexical edge."""
		cdef short result = edge.pos.mid - 1
		assert 0 <= result < self.lensent, (result, self.lensent)
		return result

	cdef edgestr(self, item, Edge *edge):
		"""Return string representation of item and edge belonging to it."""
		if edge.rule is NULL:
			return self.sent[self.lexidx(edge)]
		else:
			return ('%g %s %s' % (
					exp(-edge.rule.prob) if self.grammar.logprob
					else edge.rule.prob,
					self.itemstr(self._left(item, edge)),
					self.itemstr(self._right(item, edge))
						if edge.rule.rhs2 else ''))

	cdef ChartItem asChartItem(self, item):
		"""Convert/copy item to ChartItem instance."""
		cdef size_t itemx
		if isinstance(item, SmallChartItem):
			return (<SmallChartItem>item).copy()
		elif isinstance(item, FatChartItem):
			return (<FatChartItem>item).copy()
		itemx = <size_t>item
		label = self.label(itemx)
		itemx //= self.grammar.nonterminals
		start = itemx // self.lensent
		end = itemx % self.lensent + 1
		if self.lensent < 8 * sizeof(uint64_t):
			return CFGtoSmallChartItem(label, start, end)
		return CFGtoFatChartItem(label, start, end)

	cdef size_t asCFGspan(self, item, size_t nonterminals):
		"""Convert item for chart with different number of non-terminals."""
		cdef size_t itemx
		if isinstance(item, SmallChartItem):
			start = nextset((<SmallChartItem>item).vec, 0)
			end = nextunset((<SmallChartItem>item).vec, start)
			assert nextset((<SmallChartItem>item).vec, end) == -1
		elif isinstance(item, FatChartItem):
			start = anextset((<FatChartItem>item).vec, 0, SLOTS)
			end = anextunset((<FatChartItem>item).vec, start, SLOTS)
			assert anextset((<FatChartItem>item).vec, end, SLOTS) == -1
		else:
			itemx = <size_t>item
			itemx //= self.grammar.nonterminals
			start = itemx // self.lensent
			end = itemx % self.lensent + 1
		return cellidx(start, end, self.lensent, nonterminals)

	def __str__(self):
		"""Pretty-print chart and *k*-best derivations."""
		cdef Edges edges
		cdef RankedEdge rankededge
		result = []
		for item in sorted(self.getitems()):
			result.append(' '.join((
					self.itemstr(item).ljust(20),
					('vitprob=%g' % (
						exp(-self.subtreeprob(item)) if self.logprob
						else self.subtreeprob(item))).ljust(17),
					((' ins=%g' % self.inside[item]).ljust(14)
						if self.inside else ''),
					((' out=%g' % self.outside[item]).ljust(14)
						if self.outside else ''))))
			for edges in self.parseforest[item]:
				for n in range(edges.len):
					result.append('\t=> %s'
							% self.edgestr(item, &(edges.data[n])))
			result.append('')
		if self.rankededges:
			result.append('ranked edges:')
			for item in sorted(self.rankededges):
				result.append(self.itemstr(item))
				for n, entry in enumerate(self.rankededges[item]):
					rankededge = entry.key
					result.append('%d: %10g => %s %d %d' % (n,
							exp(-entry.value) if self.logprob else entry.value,
							self.edgestr(item, rankededge.edge),
							rankededge.left, rankededge.right))
				result.append('')
		return '\n'.join(result)

	def __nonzero__(self):
		"""Return true when the root item is in the chart.

		i.e., test whether sentence has been parsed successfully."""
		return self.root() in self.parseforest

	cdef getitems(self):
		return self.parseforest

	cdef list getedges(self, item):
		"""Get edges for item."""
		return self.parseforest[item] if item in self.parseforest else []

	def filter(self):
		"""Drop entries not part of a derivation headed by root of chart."""
		items = set()
		_filtersubtree(self, self.root(), items)
		if isinstance(self.parseforest, dict):
			for item in set(self.getitems()) - items:
				del self.parseforest[item]
		elif isinstance(self.parseforest, list):
			for item in set(self.getitems()) - items:
				self.parseforest[item] = None
		else:
			raise ValueError('parseforest: expected list or dict')

	def stats(self):
		"""Return a short string with counts of items, edges."""
		if isinstance(self.parseforest, dict):
			alledges = self.parseforest.values()
		elif isinstance(self.parseforest, list):
			alledges = filter(None, self.parseforest)
		else:
			raise ValueError('parseforest: expected list or dict')
		return 'items %d, edges %d' % (
				len(self.getitems()),
				sum(map(numedges, alledges)))
		# more stats:
		# labels: len({self.label(item) for item in self.getitems()}),
		# spans: ...


def numedges(list edgeslist):
	cdef Edges edges
	cdef size_t result = 0
	for edges in edgeslist:
		result += edges.len
	return result


cdef void _filtersubtree(Chart chart, item, set items):
	"""Recursively filter chart."""
	cdef Edge *edge
	cdef Edges edges
	items.add(item)
	for edges in chart.getedges(item):
		for n in range(edges.len):
			edge = &(edges.data[n])
			if edge.rule is NULL:
				continue
			leftitem = chart._left(item, edge)
			if leftitem not in items:
				_filtersubtree(chart, leftitem, items)
			if edge.rule.rhs2 == 0:
				continue
			rightitem = chart._right(item, edge)
			if rightitem not in items:
				_filtersubtree(chart, rightitem, items)


@cython.final
cdef class Ctrees:
	"""Auxiliary class to pass around collections of NodeArrays in Python.

	When trees is given, prods should be given as well.
	When trees is not given, the alloc() method should be called and
	trees added one by one using the add() or addnodes() methods."""
	def __cinit__(self):
		self.trees = self.nodes = NULL

	def __init__(self, list trees=None, dict prods=None):
		self.len = self.max = 0
		self.numnodes = self.maxnodes = self.nodesleft = 0
		if trees is not None:
			if prods is None:
				raise ValueError('when initialized with trees, prods argument '
						'is required.')
			self.alloc(len(trees), sum(map(len, trees)))
			for tree in trees:
				self.add(tree, prods)

	cpdef alloc(self, int numtrees, long numnodes):
		"""Initialize an array of trees of nodes structs."""
		self.max = numtrees
		self.trees = <NodeArray *>malloc(numtrees * sizeof(NodeArray))
		self.nodes = <Node *>malloc(numnodes * sizeof(Node))
		if self.trees is NULL or self.nodes is NULL:
			raise MemoryError('allocation error')
		self.nodesleft = numnodes

	cdef realloc(self, int numtrees, int extranodes):
		"""Increase size of array (handy with incremental binarization)."""
		# based on Python's listobject.c list_resize()
		cdef numnodes
		if numtrees > self.max:
			# overallocate to get linear-time amortized behavior
			numtrees += (numtrees >> 3) + (3 if numtrees < 9 else 6)
			self.trees = <NodeArray *>realloc(self.trees,
					numtrees * sizeof(NodeArray))
			if self.trees is NULL:
				raise MemoryError('allocation error')
			self.max = numtrees
		if extranodes > self.nodesleft:
			numnodes = self.numnodes + extranodes
			# estimate how many new nodes will be needed
			# self.nodesleft += (self.max - self.len) * (self.numnodes / self.len)
			# overallocate to get linear-time amortized behavior
			numnodes += (numnodes >> 3) + (3 if numnodes < 9 else 6)
			self.nodes = <Node *>realloc(self.nodes, numnodes * sizeof(Node))
			if self.nodes is NULL:
				raise MemoryError('allocation error')
			self.nodesleft = numnodes - self.numnodes

	cpdef add(self, list tree, dict prods):
		"""Incrementally add tree to the node array.

		Useful when dealing with large numbers of Tree objects (say 100,000).
		"""
		if not self.max:
			raise ValueError('alloc() has not been called (max=0).')
		if self.len >= self.max or self.nodesleft < len(tree):
			self.realloc(self.len + 1, len(tree))
		self.trees[self.len].len = len(tree)
		self.trees[self.len].offset = self.numnodes
		copynodes(tree, prods, &self.nodes[self.numnodes])
		self.trees[self.len].root = tree[0].rootidx
		self.len += 1
		self.nodesleft -= len(tree)
		self.numnodes += len(tree)
		self.maxnodes = max(self.maxnodes, len(tree))

	cdef addnodes(self, Node *source, int cnt, int root):
		"""Incrementally add tree to the node array.

		This version copies a tree that has already been converted to an array
		of nodes."""
		cdef dict prodsintree, sortidx
		cdef int n, m
		cdef Node *dest
		if not self.max:
			raise ValueError('alloc() has not been called (max=0).')
		if self.len >= self.max or self.nodesleft < cnt:
			self.realloc(self.len + 1, cnt)
		prodsintree = {n: source[n].prod for n in range(cnt)}
		sortidx = {m: n for n, m in enumerate(
				sorted(range(cnt), key=prodsintree.get))}
		# copy nodes to allocated array, while translating indices
		dest = &self.nodes[self.numnodes]
		for n, m in sortidx.iteritems():
			dest[m] = source[n]
			if dest[m].left >= 0:
				dest[m].left = sortidx[source[n].left]
				if dest[m].right >= 0:
					dest[m].right = sortidx[source[n].right]
		self.trees[self.len].offset = self.numnodes
		self.trees[self.len].root = sortidx[root]
		self.trees[self.len].len = cnt
		self.len += 1
		self.nodesleft -= cnt
		self.numnodes += cnt
		if cnt > self.maxnodes:
			self.maxnodes = cnt

	def indextrees(self, dict prods):
		"""Create index from productions to trees containing that production.

		Productions are represented as integer IDs, trees are given as sets of
		integer indices."""
		cdef:
			list result = [set() for _ in prods]
			NodeArray a
			Node *nodes
			int n, m
		for n in range(self.len):
			a = self.trees[n]
			nodes = &self.nodes[a.offset]
			for m in range(a.len):
				(<set>result[nodes[m].prod]).add(n)
		self.treeswithprod = result

	def __dealloc__(self):
		if self.nodes is not NULL:
			free(self.nodes)
			self.nodes = NULL
		if self.trees is not NULL:
			free(self.trees)
			self.trees = NULL

	def __len__(self):
		return self.len


cdef inline copynodes(tree, dict prods, Node *result):
	"""Convert NLTK tree to an array of Node structs."""
	cdef int n
	for n, a in enumerate(tree):
		if not isinstance(a, Tree):
			raise ValueError('Expected Tree node, got %s\n%r' % (type(a), a))
		if not 1 <= len(a) <= 2:
			raise ValueError('trees must be non-empty and binarized\n%s\n%s' %
					(a, tree[0]))
		result[n].prod = prods[a.prod]
		if isinstance(a[0], int):  # a terminal index
			result[n].left = -a[0] - 1
		else:
			result[n].left = a[0].idx
			if len(a) == 2:
				result[n].right = a[1].idx
			else:  # unary node
				result[n].right = -1

__all__ = ['Chart', 'Ctrees', 'Edges', 'FatChartItem', 'Grammar',
		'LexicalRule', 'RankedEdge', 'SmallChartItem', 'numedges']
