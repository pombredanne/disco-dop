""" Data types for grammars, chart items, &c. """
from math import exp as pyexp, log as pylog
import re
import logging
import numpy as np
cimport cython
from libc.math cimport log, exp
from tree import Tree

DEF SLOTS = 3
maxbitveclen = SLOTS * sizeof(ULong) * 8
# This regex should match exactly the set of valid yield functions,
# i.e., comma-separated strings of alternating occurrences from the set {0,1},
YFBINARY = re.compile(
		br'^(?:0|1|1?(?:01)+|0?(?:10)+)(?:,(?:0|1|1?(?:01)+|0?(?:10)+))*$')
YFUNARYRE = re.compile(br'^0(?:,0)*$')
# Match when non-integral weights are present
LCFRS_NONINT = re.compile(b"\t[0-9]+[./][0-9]+\n")
BITPAR_NONINT = re.compile(b"(?:^|\n)[0-9]+\.[0-9]+[ \t]")
LEXICON_NONINT = re.compile("[ \t][0-9]+[./][0-9]+[ \t\n]")

# comparison functions for sorting rules on LHS/RHS labels.
cdef int cmp0(const void *p1, const void *p2) nogil:
	cdef Rule *a = <Rule *>p1, *b = <Rule *>p2
	return (a.lhs > b.lhs) - (a.lhs < b.lhs)
cdef int cmp1(const void *p1, const void *p2) nogil:
	cdef Rule *a = <Rule *>p1, *b = <Rule *>p2
	return (a.rhs1 > b.rhs1) - (a.rhs1 < b.rhs1)
cdef int cmp2(const void *p1, const void *p2) nogil:
	cdef Rule *a = <Rule *>p1, *b = <Rule *>p2
	return (a.rhs2 > b.rhs2) - (a.rhs2 < b.rhs2)


cdef class Grammar:
	"""
	A grammar object which stores rules compactly, indexed in various ways.
	Parameters:

	- rule_tuples_or_bytes: either a sequence of tuples containing both
		phrasal & lexical rules, or a bytes string containing the phrasal
		rules in text format; in the latter case lexicon should be given.
		The text format allows for more efficient loading and is used
		internally.
	- start: a string identifying the unique start symbol of this grammar,
		which will be used by default when parsing with this grammar
	- bitpar: whether to expect and use the bitpar grammar format

	By default the grammar is in logprob mode;
	invoke grammar.switch('default', logprob=False) to switch.
	If the grammar only contains integral weights (frequencies), they will
	be normalized into relative frequencies; if the grammar contains any
	non-integral weights, weights will be left unchanged. """
	def __cinit__(self):
		self.fanout = self.unary = self.mapping = self.splitmapping = NULL

	def __init__(self, rule_tuples_or_bytes, lexicon=None, start=b'ROOT',
			bitpar=False):
		cdef LexicalRule lexrule
		cdef double [:] tmp
		cdef int n
		self.mapping = self.splitmapping = self.bylhs = NULL
		if not isinstance(start, bytes):
			start = start.encode('ascii')
		self.start = start
		self.bitpar = bitpar
		self.numunary = self.numbinary = self.currentmodel = 0
		self.modelnames = [u'default']
		self.logprob = False

		if isinstance(rule_tuples_or_bytes, bytes):
			assert isinstance(lexicon, unicode), "expected lexicon"
			self.origrules = rule_tuples_or_bytes
			self.origlexicon = lexicon
		elif isinstance(rule_tuples_or_bytes[0], tuple):
			# convert tuples to strings with text format
			from grammar import write_lcfrs_grammar
			self.origrules, self.origlexicon = write_lcfrs_grammar(
					rule_tuples_or_bytes, bitpar=bitpar)
		else:
			raise ValueError("expected sequence of tuples or bytes string.")

		# collect non-terminal labels; count number of rules in each category
		# for allocation purposes.
		rulelines = self.origrules.splitlines()
		fanoutdict = self._countrules(rulelines)
		self._allocate()
		# convert phrasal & lexical rules
		self._convertlexicon(fanoutdict)
		self._convertrules(rulelines)
		for n in range(self.nonterminals):
			self.fanout[n] = fanoutdict[self.tolabel[n]]
		del rulelines, fanoutdict
		# store 'default' weights
		self.models = np.empty((1, self.numrules + len(self.lexical)), dtype='d')
		tmp = self.models[0]
		for n in range(self.numrules):
			tmp[self.bylhs[0][n].no] = self.bylhs[0][n].prob
		for n, lexrule in enumerate(self.lexical, self.numrules):
			tmp[n] = lexrule.prob
		# index & filter phrasal rules in different ways
		self._indexrules(self.bylhs, 0, 0)
		# if the grammar only contains integral values (frequencies),
		# normalize them into relative frequencies.
		nonint = BITPAR_NONINT if self.bitpar else LCFRS_NONINT
		if not (nonint.search(self.origrules)
				or LEXICON_NONINT.search(self.origlexicon)):
			self._normalize()
		self._indexrules(self.unary, 1, 2)
		self._indexrules(self.lbinary, 1, 3)
		self._indexrules(self.rbinary, 2, 3)
		self.switch('default', True)  # enable log probabilities

	@cython.wraparound(True)
	def _countrules(self, list rulelines):
		""" Count unary & binary rules; make a canonical list of all
		non-terminal labels and assign them unique IDs """
		Epsilon = b'Epsilon'
		# Epsilon and the start symbol get IDs 0 and 1 respectively.
		self.toid = {Epsilon: 0}
		count = 2  # used to assign IDs to non-terminal labels
		fanoutdict = {Epsilon: 0}  # temporary mapping of labels to fan-outs
		for line in rulelines:
			if not line:
				continue
			fields = line.split()
			if self.bitpar:
				rule = fields[1:]
				yf = b'0' if len(rule) == 2 else b'01'
			else:
				rule = fields[:-2]
				yf = fields[-2]
			assert Epsilon not in rule, ("Epsilon symbol is only used "
						"to introduce terminal symbols in lexical rules.")
			assert self.start not in rule[1:], (
					"Start symbol should only occur on LHS.")
			if len(rule) == 2:
				assert YFUNARYRE.match(yf), ("yield function refers to "
						"non-existent second non-terminal: %r\t%r" % (rule, yf))
				self.numunary += 1
			elif len(rule) == 3:
				assert YFBINARY.match(yf), "illegal yield function: %s" % yf
				assert b'0' in yf and b'1' in yf, ("mismatch between "
						"non-terminals and yield function: %r\t%r" % (rule, yf))
				self.numbinary += 1
			else:
				raise ValueError("grammar not binarized:\n%s" % line)
			for n, nt in enumerate(rule):
				fanout = yf.count(b',01'[n:n + 1]) + (n == 0)
				if nt in self.toid:
					assert fanoutdict[nt] == fanout, (
							"conflicting fanouts for symbol '%s'.\n"
							"previous: %d; this non-terminal: %d.\nrule: %r" % (
							nt, fanoutdict[nt], fanout, rule))
				else:
					if nt == self.start:
						self.toid[nt] = 1
					else:
						self.toid[nt] = count
						count += 1
					fanoutdict[nt] = fanout
					if fanoutdict[nt] > self.maxfanout:
						self.maxfanout = fanoutdict[nt]

		assert self.start in self.toid, ("Start symbol %r not in set of "
				"non-terminal labels extracted from grammar rules." % self.start)
		self.numrules = self.numunary + self.numbinary
		assert self.numrules, "no rules found"
		self.tolabel = sorted(self.toid, key=self.toid.get)
		self.nonterminals = len(self.toid)
		return fanoutdict

	def _allocate(self):
		""" Allocate memory to store rules. """
		# store all non-lexical rules in a contiguous array
		# the other arrays will contain pointers to relevant parts thereof
		# (indexed on lhs, rhs1, and rhs2 of rules)
		self.bylhs = <Rule **>malloc(sizeof(Rule *) * self.nonterminals * 4)
		assert self.bylhs is not NULL
		self.bylhs[0] = NULL
		self.unary = &(self.bylhs[1 * self.nonterminals])
		self.lbinary = &(self.bylhs[2 * self.nonterminals])
		self.rbinary = &(self.bylhs[3 * self.nonterminals])
		# allocate the actual contiguous array that will contain the rules
		# (plus sentinels)
		self.bylhs[0] = <Rule *>malloc(sizeof(Rule) *
			(self.numrules + (2 * self.numbinary) + self.numunary + 4))
		assert self.bylhs[0] is not NULL
		self.unary[0] = &(self.bylhs[0][self.numrules + 1])
		self.lbinary[0] = &(self.unary[0][self.numunary + 1])
		self.rbinary[0] = &(self.lbinary[0][self.numbinary + 1])
		self.fanout = <UChar *>malloc(sizeof(UChar) * self.nonterminals)
		assert self.fanout is not NULL

	@cython.wraparound(True)
	cdef _convertrules(Grammar self, list rulelines):
		""" Auxiliary function to create Grammar objects. Copies grammar
		rules from a text file to a contiguous array of structs. """
		cdef UInt n = 0, m, prev = self.nonterminals
		cdef Rule *cur
		self.rulenos = {}
		for line in rulelines:
			if not line:
				continue
			fields = line.split()
			if self.bitpar:
				rule = fields[1:]
				yf = b'0' if len(rule) == 2 else b'01'
				w = fields[0]
			else:
				rule = fields[:-2]
				yf = fields[-2]
				w = fields[-1]
			# convert fraction to float
			x = w.find(b'/')
			w = float(w[:x]) / float(w[x + 1:]) if x > 0 else float(w)
			assert w > 0, "weights should be positive and non-zero:\n%r" % line
			# n is the rule index in the array, and will be the ID for the rule
			cur = &(self.bylhs[0][n])
			cur.no = n
			cur.lhs = self.toid[rule[0]]
			cur.rhs1 = self.toid[rule[1]]
			cur.rhs2 = self.toid[rule[2]] if len(rule) == 3 else 0
			cur.prob = w
			cur.lengths = cur.args = m = 0
			for a in yf.decode('ascii'):
				if a == ',':
					cur.lengths |= 1 << (m - 1)
					continue
				elif a == '1':
					cur.args += 1 << m
				elif a != '0':
					raise ValueError('expected: %r; got: %r' % ('0', a))
				m += 1
			cur.lengths |= 1 << (m - 1)
			assert m < (8 * sizeof(cur.args)), (m, (8 * sizeof(cur.args)))
			self.rulenos[tuple(rule)] = n
			n += 1
		assert n == self.numrules, (n, self.numrules)

	def _convertlexicon(self, fanoutdict):
		""" Make objects for lexical rules. """
		cdef int n, x
		self.lexical = []
		self.lexicalbyword = {}
		self.lexicalbylhs = {}
		for line in self.origlexicon.splitlines():
			if not line:
				continue
			x = line.index('\t')
			word = line[:x]
			fields = line[x + 1:].encode('ascii').split()
			assert word not in self.lexicalbyword, (
					"word %r appears more than once in lexicon file" % word)
			self.lexicalbyword[word] = []
			for tag, w in zip(fields[::2], fields[1::2]):
				if tag not in self.toid:
					logging.warning("POS tag %r for word %r "
							"not used in any phrasal rule", tag, word)
					continue
				if tag not in fanoutdict:
					fanoutdict[tag] = 1
				assert fanoutdict[tag] == 1, (
						"POS tag %r does not have fan-out 1." % tag)
				# convert fraction to float
				x = w.find(b'/')
				w = float(w[:x]) / float(w[x + 1:]) if x > 0 else float(w)
				assert w > 0, (
						"weights should be positive and non-zero:\n%r" % line)
				lexrule = LexicalRule(self.toid[tag], word, w)
				if lexrule.lhs not in self.lexicalbylhs:
					self.lexicalbylhs[lexrule.lhs] = {}
				self.lexical.append(lexrule)
				self.lexicalbyword[word].append(lexrule)
				self.lexicalbylhs[lexrule.lhs][word] = lexrule
			assert self.lexical and self.lexicalbyword and self.lexicalbylhs, (
					"no lexical rules found.")

	def _normalize(self):
		""" Optionally normalize frequencies to relative frequencies.
		Should be run during initialization. """
		cdef double mass = 0
		cdef UInt n = 0, lhs
		cdef LexicalRule lexrule
		for lhs in range(self.nonterminals):
			mass = 0
			n = 0
			while self.bylhs[lhs][n].lhs == lhs:
				mass += self.bylhs[lhs][n].prob
				n += 1
			for lexrule in self.lexicalbylhs.get(lhs, {}).values():
				mass += lexrule.prob
			n = 0
			while self.bylhs[lhs][n].lhs == lhs:
				self.bylhs[lhs][n].prob /= mass
				n += 1
			for lexrule in self.lexicalbylhs.get(lhs, {}).values():
				lexrule.prob /= mass

	cdef _indexrules(Grammar self, Rule **dest, int idx, int filterlen):
		""" Auxiliary function to create Grammar objects. Copies certain
		grammar rules and sorts them on the given index.
		Resulting array is ordered by lhs, rhs1, or rhs2 depending on the value
		of `idx` (0, 1, or 2); filterlen can be 0, 2, or 3 to get all, only
		unary, or only binary rules, respectively.
		A separate array has a pointer for each non-terminal into this array;
		e.g.: dest[NP][0] == the first rule with an NP in the idx position. """
		cdef UInt prev = self.nonterminals, idxlabel = 0, n, m = 0
		cdef Rule *cur
		#need to set dest even when there are no rules for that idx
		for n in range(self.nonterminals):
			dest[n] = dest[0]
		if dest is self.bylhs:
			m = self.numrules
		else:
			for n in range(self.numrules):
				if (filterlen == 2) == (self.bylhs[0][n].rhs2 == 0):
					# copy this rule
					dest[0][m] = self.bylhs[0][n]
					assert dest[0][m].no < self.numrules
					m += 1
		if filterlen == 2:
			assert m == self.numunary, (m, self.numunary)
		elif filterlen == 3:
			assert m == self.numbinary, (m, self.numbinary)
		# sort rules by idx
		if idx == 0:
			qsort(dest[0], m, sizeof(Rule), &cmp0)
		elif idx == 1:
			qsort(dest[0], m, sizeof(Rule), &cmp1)
		elif idx == 2:
			qsort(dest[0], m, sizeof(Rule), &cmp2)
		# make index: dest[NP] points to first rule with NP in index position
		for n in range(m):
			cur = &(dest[0][n])
			if idx == 0:
				idxlabel = cur.lhs
			elif idx == 1:
				idxlabel = cur.rhs1
			elif idx == 2:
				idxlabel = cur.rhs2
			if idxlabel != prev:
				dest[idxlabel] = cur
			prev = idxlabel
			assert cur.no < self.numrules
		# sentinel rule
		dest[0][m].lhs = dest[0][m].rhs1 = dest[0][m].rhs2 = self.nonterminals

	def register(self, unicode name, weights):
		""" Register a probabilistic model given a name, and sequences of
		weights 'weights', where weights are in the same order as that of
		self.origrules and self.origlexicon (which is an arbitrary order
		except that words appear sorted). """
		cdef int n, m = len(self.modelnames)
		cdef double [:] tmp
		assert name not in self.modelnames, 'model %r already exists' % name
		assert len(self.modelnames) <= 255, (
				'256 probabilistic models should be enough for anyone.')
		assert len(weights) == self.numrules + len(self.lexical), (
				'length mismatch: %d grammar rules, %d weights given.' % (
					self.numrules + len(self.lexical), len(weights)))
		self.models.resize(m + 1, self.numrules + len(self.lexical))
		self.modelnames.append(name)
		tmp = self.models[m]
		for n in range(self.numrules):
			tmp[self.bylhs[0][n].no] = weights[n]
		for n, lexrule in enumerate(self.lexical, self.numrules):
			tmp[n] = weights[n]

	def switch(self, name, bint logprob=True):
		""" Switch to a different probabilistic model;
		use 'default' to swith back to model given during initialization. """
		cdef int n, m = self.modelnames.index(name)
		cdef double [:] tmp
		cdef LexicalRule lexrule
		if self.currentmodel == m and self.logprob == logprob:
			return
		tmp = -np.log(self.models[m]) if logprob else self.models[m]
		for n in range(self.numrules):
			self.bylhs[0][n].prob = tmp[self.bylhs[0][n].no]
		for n in range(self.numbinary):
			self.lbinary[0][n].prob = tmp[self.lbinary[0][n].no]
			self.rbinary[0][n].prob = tmp[self.rbinary[0][n].no]
		for n in range(self.numunary):
			self.unary[0][n].prob = tmp[self.unary[0][n].no]
		for n, lexrule in enumerate(self.lexical, self.numrules):
			lexrule.prob = tmp[n]
		self.logprob = logprob
		self.currentmodel = m

	def buildchainvec(self):
		""" Build a boolean matrix representing the unary (chain) rules. """
		cdef UInt n
		cdef Rule *rule
		self.chainvec = <ULong *>calloc(self.nonterminals
				* BITNSLOTS(self.nonterminals), sizeof(ULong))
		assert self.chainvec is not NULL
		for n in range(self.numunary):
			rule = self.unary[n]
			SETBIT(self.chainvec, rule.rhs1 * self.nonterminals + rule.lhs)

	def testgrammar(self, epsilon=0):
		""" Report whether all left-hand sides sum to 1 +/-epsilon. """
		#We could be strict about separating POS tags and phrasal categories,
		#but Negra contains at least one tag (--) used for both.
		cdef Rule *rule
		cdef LexicalRule lexrule
		cdef UInt n
		cdef dict sums = {n: [] for n in range(1, self.nonterminals)}
		for n in range(self.numrules):
			rule = &(self.bylhs[0][n])
			sums[rule.lhs].append(rule.prob)
		for n in self.lexicalbylhs:
			for lexrule in self.lexicalbylhs[n].values():
				sums[lexrule.lhs].append(lexrule.prob)
		for lhs, probs in sums.items():
			mass = logprobsum(probs) if self.logprob else sum(probs)
			if 1 - epsilon < mass < 1 + epsilon:
				logging.error("Does not sum to 1 +/- %g: %s; sums to %s",
						epsilon, lhs, mass)
				return False
		logging.info("All left hand sides sum to 1")
		return True

	def getmapping(Grammar self, Grammar coarse, striplabelre=None,
			neverblockre=None, bint splitprune=False, bint markorigin=False):
		""" Construct a mapping of fine non-terminal IDs to coarse non-terminal
		IDS, by applying the regex striplabelre to the labels, used for
		coarse-to-fine pruning. A secondary regex neverblockre is for items
		that should never be pruned.
		The regexes should be compiled objects, i.e., re.compile(regex),
		or None to leave labels unchanged.

        - use "|<" to ignore nodes introduced by binarization;
            useful if coarse and fine stages employ different kinds of
            markovization; e.g., NP and VP may be blocked, but not NP|<DT-NN>.
        - "_[0-9]+" to ignore discontinuous nodes X_n where X is a label
			and n is a fanout. """
		cdef int n, m, components = 0
		if coarse is None:
			coarse = self
		if self.mapping is not NULL:
			free(self.mapping)
		self.mapping = <UInt *>malloc(sizeof(UInt) * self.nonterminals)
		if splitprune and markorigin:
			if self.splitmapping is not NULL:
				if self.splitmapping[0] is not NULL:
					free(self.splitmapping[0])
				free(self.splitmapping)
			self.splitmapping = <UInt **>malloc(sizeof(UInt *)
					* self.nonterminals)
			for n in range(self.nonterminals):
				self.splitmapping[n] = NULL
			self.splitmapping[0] = <UInt *>malloc(sizeof(UInt) *
				sum([self.fanout[n] for n in range(self.nonterminals)
					if self.fanout[n] > 1]))
		seen = {0}
		for n in range(self.nonterminals):
			if not neverblockre or neverblockre.search(self.tolabel[n]) is None:
				strlabel = self.tolabel[n]
				if striplabelre is not None:
					strlabel = striplabelre.sub(b'', strlabel, 1)
				if self.fanout[n] == 1 or not splitprune:
					self.mapping[n] = coarse.toid[strlabel]
					seen.add(self.mapping[n])
				else:
					strlabel += b'*'
					if markorigin:
						self.mapping[n] = self.nonterminals  # sentinel value
						self.splitmapping[n] = &(
								self.splitmapping[0][components])
						components += self.fanout[n]
						for m in range(self.fanout[n]):
							self.splitmapping[n][m] = coarse.toid[
								strlabel + str(m).encode('ascii')]
							seen.add(self.splitmapping[n][m])
					else:
						self.mapping[n] = coarse.toid[strlabel]
						seen.add(self.mapping[n])
			else:
				self.mapping[n] = 0
		if seen == set(range(coarse.nonterminals)):
			msg = 'label sets are equal'
		else:
			l = sorted([coarse.tolabel[a].decode('ascii') for a in
						set(coarse.toid.values()) - seen])
			diff1 = ", ".join(l[:10]) + (', ...' if len(l) > 10 else '')
			l = [coarse.tolabel[a].decode('ascii') for a in seen -
					set(range(coarse.nonterminals))]
			diff2 = ", ".join(l[:10]) + (', ...' if len(l) > 10 else '')
			if coarse.nonterminals > self.nonterminals:
				msg = ('grammar is not a superset of coarse grammar:\n'
						'only in coarse: {%s}\nonly in fine: {%s}' % (
						diff1, diff2))
			elif coarse.nonterminals < self.nonterminals:
				msg = ('grammar is a proper superset of coarse grammar:\n'
						'only in fine: {%s}' % diff2)
			elif diff1 or diff2:
				msg = ('equal number of nodes, but not equivalent:\n'
						'only in coarse: {%s}\nonly in fine: {%s}' % (
						diff1, diff2))
			else:
				msg = ''  # should not happen?
		return msg

	cdef rulestr(self, Rule rule):
		left = "%.2f %s => %s%s" % (
			exp(-rule.prob) if self.logprob else rule.prob,
			self.tolabel[rule.lhs].decode('ascii'),
			self.tolabel[rule.rhs1].decode('ascii'),
			"  %s" % self.tolabel[rule.rhs2].decode('ascii')
				if rule.rhs2 else '')
		return left.ljust(40) + self.yfstr(rule)

	cdef yfstr(self, Rule rule):
		cdef int n, m = 0
		cdef result = ''
		for n in range(8 * sizeof(rule.args)):
			result += "1" if (rule.args >> n) & 1 else "0"
			if (rule.lengths >> n) & 1:
				m += 1
				if m == self.fanout[rule.lhs]:
					return result
				else:
					result += ","
		raise ValueError("expected %d components for %s -> %s %s\n"
				"args: %s; lengths: %s" % (self.fanout[rule.lhs],
				self.tolabel[rule.lhs], self.tolabel[rule.rhs1],
				self.tolabel[rule.rhs2],
				bin(rule.args), bin(rule.lengths)))

	def rulesstr(self, lhs):
		cdef int n = 0
		result = []
		while self.bylhs[lhs][n].lhs == lhs:
			result.append(self.rulestr(self.bylhs[lhs][n]))
			n += 1
		return "\n".join(result)

	def __str__(self):
		cdef LexicalRule lexrule
		rules = "\n".join(filter(None,
			[self.rulesstr(lhs) for lhs in range(1, self.nonterminals)]))
		lexical = "\n".join(["%.2f %s => %s" % (
				exp(-lexrule.prob) if self.logprob else lexrule.prob,
				self.tolabel[lexrule.lhs].decode('ascii'),
				lexrule.word.encode('unicode-escape').decode('ascii'))
			for word in sorted(self.lexicalbyword)
			for lexrule in sorted(self.lexicalbyword[word],
			key=lambda lexrule: (<LexicalRule>lexrule).lhs)])
		labels = ", ".join("%s=%d" % (a.decode('ascii'), b)
				for a, b in sorted(self.toid.items()))
		return "rules:\n%s\nlexicon:\n%s\nlabels:\n%s" % (
				rules, lexical, labels)

	def __repr__(self):
		return "%s(\n%s,\n%s\n)" % (self.__class__.__name__,
				self.origrules, self.origlexicon)

	def __reduce__(self):
		""" Helper function for pickling. """
		return (Grammar, (self.origrules, self.origlexicon,
				self.start, self.logprob, self.bitpar))

	def __dealloc__(self):
		if self.bylhs is NULL:
			return
		if self.bylhs[0] is not NULL:
			free(self.bylhs[0])
			self.bylhs[0] = NULL
		free(self.bylhs)
		self.bylhs = NULL
		if self.fanout is not NULL:
			free(self.fanout)
			self.fanout = NULL
		if self.chainvec is not NULL:
			free(self.chainvec)
			self.chainvec = NULL
		if self.mapping is not NULL:
			free(self.mapping)
			self.mapping = NULL
		if self.splitmapping is not NULL:
			free(self.splitmapping[0])
			free(self.splitmapping)
			self.splitmapping = NULL


cdef class SmallChartItem:
	""" Item with word sized bitvector """
	def __init__(SmallChartItem self, label, vec):
		self.label = label
		self.vec = vec

	def __hash__(SmallChartItem self):
		""" juxtapose bits of label and vec, rotating vec if > 33 words:
		64              32            0
		|               ..........label
		|vec[0] 1st half
		|               vec[0] 2nd half
		------------------------------- XOR """
		return (self.label ^ (self.vec << (sizeof(self.vec) / 2 - 1))
				^ (self.vec >> (sizeof(self.vec) / 2 - 1)))

	def __richcmp__(SmallChartItem self, SmallChartItem ob, int op):
		if op == 2:
			return self.label == ob.label and self.vec == ob.vec
		elif op == 3:
			return self.label != ob.label or self.vec != ob.vec
		elif op == 5:
			return self.label >= ob.label or self.vec >= ob.vec
		elif op == 1:
			return self.label <= ob.label or self.vec <= ob.vec
		elif op == 0:
			return self.label < ob.label or self.vec < ob.vec
		elif op == 4:
			return self.label > ob.label or self.vec > ob.vec

	def __nonzero__(SmallChartItem self):
		return self.label != 0 and self.vec != 0

	def __repr__(self):
		return "%s(%d, %s)" % (self.__class__.__name__,
				self.label, self.binrepr())

	def lexidx(self):
		assert self.label == 0
		return self.vec

	def copy(SmallChartItem self):
		return SmallChartItem(self.label, self.vec)

	def binrepr(SmallChartItem self, int lensent=0):
		return bin(self.vec)[2:].zfill(lensent)[::-1]


cdef class FatChartItem:
	""" Item with fixed-with bitvector. """
	def __hash__(self):
		cdef long n, _hash
		""" juxtapose bits of label and vec:
		64              32            0
		|               ..........label
		|vec[0] 1st half
		|               vec[0] 2nd half
		|........ rest of vec .........
		------------------------------- XOR """
		_hash = (self.label ^ self.vec[0] << (8 * sizeof(self.vec[0]) / 2 - 1)
				^ self.vec[0] >> (8 * sizeof(self.vec[0]) / 2 - 1))
		# add remaining bits
		for n in range(sizeof(self.vec[0]), sizeof(self.vec)):
			_hash *= 33 ^ (<UChar *>self.vec)[n]
		return _hash

	def __richcmp__(FatChartItem self, FatChartItem ob, int op):
		cdef int cmp = memcmp(<UChar *>self.vec, <UChar *>ob.vec,
			sizeof(self.vec))
		cdef bint labelmatch = self.label == ob.label
		if op == 2:
			return labelmatch and cmp == 0
		elif op == 3:
			return not labelmatch or cmp != 0
		elif op == 5:
			return self.label >= ob.label or (labelmatch and cmp >= 0)
		elif op == 1:
			return self.label <= ob.label or (labelmatch and cmp <= 0)
		elif op == 0:
			return self.label < ob.label or (labelmatch and cmp < 0)
		elif op == 4:
			return self.label > ob.label or (labelmatch and cmp > 0)

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

	def copy(FatChartItem self):
		cdef FatChartItem a = FatChartItem(self.label)
		for n in range(SLOTS):
			a.vec[n] = self.vec[n]
		return a

	def binrepr(FatChartItem self, lensent=0):
		cdef int m, n = SLOTS - 1
		cdef str result
		while n and self.vec[n] == 0:
			n -= 1
		result = bin(self.vec[n])
		for m in range(n - 1, -1, -1):
			result += bin(self.vec[m])[2:].zfill(BITSIZE)
		return result.zfill(lensent)[::-1]


cdef class CFGChartItem:
	""" Item for CFG parsing; span is denoted with start and end indices. """
	def __init__(self, label, start, end):
		self.label = label
		self.start = start
		self.end = end

	def __hash__(self):
		""" juxtapose bits of label and indices of span:
		|....end...start...label
		64    40      32       0 """
		return (self.label ^ <ULong>self.start << (8 * sizeof(long) / 2)
				^ <ULong>self.end << (8 * sizeof(long) / 2 + 8))

	def __richcmp__(CFGChartItem self, CFGChartItem ob, int op):
		cdef bint labelmatch = self.label == ob.label
		cdef bint startmatch = self.start == ob.start
		if op == 2:
			return labelmatch and startmatch and self.end == ob.end
		elif op == 3:
			return not labelmatch or not startmatch or self.end != ob.end
		elif op == 5:
			return self.label >= ob.label or (labelmatch and (self.start
					>= ob.start or startmatch and self.end >= ob.end))
		elif op == 1:
			return self.label <= ob.label or (labelmatch and (self.start
					<= ob.start or (startmatch and self.end <= ob.end)))
		elif op == 0:
			return self.label < ob.label or (labelmatch and (self.start
					< ob.start or (startmatch and self.end < ob.end)))
		elif op == 4:
			return self.label > ob.label or (labelmatch and (self.start
					> ob.start or (startmatch and self.end > ob.end)))

	def __nonzero__(self):
		return self.label and self.end

	def __repr__(self):
		return "%s(%d, %d, %d)" % (self.__class__.__name__,
				self.label, self.start, self.end)

	def lexidx(self):
		assert self.label == 0
		return self.start

	def copy(CFGChartItem self):
		return new_CFGChartItem(self.label, self.start, self.end)


cdef SmallChartItem CFGtoSmallChartItem(UInt label, UChar start, UChar end):
	return new_ChartItem(label, (1ULL << end) - (1ULL << start))


cdef FatChartItem CFGtoFatChartItem(UInt label, UChar start, UChar end):
	cdef FatChartItem fci = new_FatChartItem(label)
	if BITSLOT(start) == BITSLOT(end):
		fci.vec[BITSLOT(start)] = (1ULL << end) - (1ULL << start)
	else:
		fci.vec[BITSLOT(start)] = ~0UL << (start % BITSIZE)
		for n in range(BITSLOT(start) + 1, BITSLOT(end)):
			fci.vec[n] = ~0UL
		fci.vec[BITSLOT(end)] = BITMASK(end) - 1
	return fci


cdef class LCFRSEdge:
	""" NB: hash / (in)equality considers all elements except inside score,
	order is determined by inside score only. """
	def __hash__(LCFRSEdge self):
		cdef long _hash = 0x345678UL
		# this condition could be avoided by using a dedicated sentinel Rule
		if self.rule is not NULL:
			_hash = (1000003UL * _hash) ^ <long>self.rule.no
		# we only look at the left item, because this edge will only be
		# compared to other edges for the same parent item
		# FIXME: we cannot compute hash directly here, because
		# left can be of different subtypes.
		_hash = (1000003UL * _hash) ^ <long>self.left.__hash__()
		return _hash

	def __richcmp__(LCFRSEdge self, LCFRSEdge ob, int op):
		if op == 0:
			return self.score < ob.score
		elif op == 1:
			return self.score <= ob.score
		elif op == 2 or op == 3:
			# right matches iff left matches, so skip that check
			return (op == 2) == (self.rule is ob.rule and self.left == ob.left)
		elif op == 4:
			return self.score > ob.score
		elif op == 5:
			return self.score >= ob.score
		elif op == 1:
			return self.score <= ob.score
		elif op == 0:
			return self.score < ob.score

	def __repr__(self):
		return "%s(%g, %g, Rule(%g, 0x%x, 0x%x, %d, %d, %d, %d), %r, %r)" % (
				self.__class__.__name__, self.score, self.inside,
				self.rule.prob, self.rule.args, self.rule.lengths,
				self.rule.lhs, self.rule.rhs1, self.rule.rhs2, self.rule.no,
				self.left, self.right)

	def copy(self):
		return new_LCFRSEdge(self.score, self.inside, self.rule,
				self.left.copy(), self.right.copy())


cdef class CFGEdge:
	""" NB: hash / (in)equality considers all elements except inside score,
	order is determined by inside score only. """
	def __hash__(CFGEdge self):
		cdef long _hash = 0x345678UL
		_hash = (1000003UL * _hash) ^ <long>self.rule
		_hash = (1000003UL * _hash) ^ <long>self.mid
		return _hash

	def __richcmp__(CFGEdge self, CFGEdge ob, int op):
		if op == 0:
			return self.inside < ob.inside
		elif op == 1:
			return self.inside <= ob.inside
		elif op == 2 or op == 3:
			return (op == 2) == (self.rule is ob.rule and self.mid == ob.mid)
		elif op == 4:
			return self.inside > ob.inside
		elif op == 5:
			return self.inside >= ob.inside
		elif op == 1:
			return self.inside <= ob.inside
		elif op == 0:
			return self.inside < ob.inside

	def __repr__(self):
		return "%s(%g, Rule(%g, 0x%x, 0x%x, %d, %d, %d, %d), %r)" % (
			self.__class__.__name__, self.inside, self.rule.prob,
			self.rule.args, self.rule.lengths, self.rule.lhs, self.rule.rhs1,
			self.rule.rhs2, self.rule.no, self.mid)


cdef class RankedEdge:
	""" An edge, including the ChartItem to which it points, along with
	ranks for its children, to denote a k-best derivation. """
	def __cinit__(self, ChartItem head, LCFRSEdge edge, int j1, int j2):
		self.head = head
		self.edge = edge
		self.left = j1
		self.right = j2

	def __hash__(self):
		cdef long _hash = 0x345678UL
		_hash = (1000003UL * _hash) ^ hash(self.head)
		_hash = (1000003UL * _hash) ^ hash(self.edge)
		_hash = (1000003UL * _hash) ^ self.left
		_hash = (1000003UL * _hash) ^ self.right
		return _hash

	def __richcmp__(RankedEdge self, RankedEdge ob, int op):
		if op == 2 or op == 3:
			return (op == 2) == (self.left == ob.left and self.right ==
					ob.right and self.head == ob.head and self.edge == ob.edge)
		return NotImplemented

	def __repr__(self):
		return "%s(%r, %r, %d, %d)" % (self.__class__.__name__,
			self.head, self.edge, self.left, self.right)


cdef class RankedCFGEdge:
	""" An edge, including the ChartItem to which it points, along with
	ranks for its children, to denote a k-best derivation. """
	def __cinit__(self, UInt label, UChar start, UChar end, Edge edge,
			int j1, int j2):
		self.label = label
		self.start = start
		self.end = end
		self.edge = edge
		self.left = j1
		self.right = j2

	def __hash__(self):
		cdef long _hash = 0x345678UL
		_hash = (1000003UL * _hash) ^ hash(self.edge)
		_hash = (1000003UL * _hash) ^ self.label
		_hash = (1000003UL * _hash) ^ self.start
		_hash = (1000003UL * _hash) ^ self.end
		_hash = (1000003UL * _hash) ^ self.left
		_hash = (1000003UL * _hash) ^ self.right
		return _hash

	def __richcmp__(RankedCFGEdge self, RankedCFGEdge ob, int op):
		if op == 2 or op == 3:
			return (op == 2) == (self.left == ob.left and self.right ==
					ob.right and self.label == ob.label and self.start ==
					ob.start and self.end == ob.end and self.edge == ob.edge)
		return NotImplemented

	def __repr__(self):
		return "%s(%r, %r, %r, %r, %d, %d)" % (self.__class__.__name__,
			self.label, self.start, self.end, self.edge, self.left, self.right)


cdef class LexicalRule:
	""" A weighted rule of the form 'non-terminal --> word'. """
	def __init__(self, lhs, word, prob):
		self.lhs = lhs
		self.word = word
		self.prob = prob

	def __repr__(self):
		return "%s%r" % (self.__class__.__name__,
				(self.lhs, self.word, self.prob))


cdef class Ctrees:
	"""
	Auxiliary class to be able to pass around collections of NodeArrays
	in Python.

	When trees is given, prods should be given as well.
	When trees is not given, the alloc() method should be called and
	trees added one by one using the add() or addnodes() methods. """
	def __cinit__(self):
		self.trees = self.nodes = NULL

	def __init__(self, list trees=None, dict prods=None):
		self.len = self.max = 0
		self.numnodes = self.maxnodes = self.nodesleft = 0
		if trees is not None:
			assert prods is not None
			self.alloc(len(trees), sum(map(len, trees)))
			for tree in trees:
				self.add(tree, prods)

	cpdef alloc(self, int numtrees, long numnodes):
		""" Initialize an array of trees of nodes structs. """
		self.max = numtrees
		self.trees = <NodeArray *>malloc(numtrees * sizeof(NodeArray))
		self.nodes = <Node *>malloc(numnodes * sizeof(Node))
		assert self.trees is not NULL and self.nodes is not NULL
		self.nodesleft = numnodes

	cdef realloc(self, int len):
		""" Increase size of array (handy with incremental binarization) """
		self.nodesleft += len
		#estimate how many new nodes will be needed
		self.nodesleft += (self.max - self.len) * (self.numnodes / self.len)
		self.nodes = <Node *>realloc(self.nodes,
				(self.numnodes + self.nodesleft) * sizeof(Node))
		assert self.nodes is not NULL

	cpdef add(self, list tree, dict prods):
		""" Trees can be incrementally added to the node array; useful
		when dealing with large numbers of NLTK trees (say 100,000)."""
		assert self.len < self.max, ("either no space left (len >= max) or "
			"alloc() has not been called (max=0). max = %d" % self.max)
		if self.nodesleft < len(tree):
			self.realloc(len(tree))
		self.trees[self.len].len = len(tree)
		self.trees[self.len].offset = self.numnodes
		copynodes(tree, prods, &self.nodes[self.numnodes])
		self.trees[self.len].root = tree[0].rootidx
		self.len += 1
		self.nodesleft -= len(tree)
		self.numnodes += len(tree)
		self.maxnodes = max(self.maxnodes, len(tree))

	cdef addnodes(self, Node *source, int cnt, int root):
		""" Trees can be incrementally added to the node array; this version
		copies a tree that has already been converted to an array of nodes. """
		cdef dict prodsintree, sortidx
		cdef int n, m
		cdef Node *dest
		assert self.len < self.max, ("either no space left (len >= max) or "
				"alloc() has not been called (max=0).\n"
				"len = %d, max = %d" % (self.len, self.max))
		if self.nodesleft < cnt:
			self.realloc(cnt)
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
		""" Create an index from specific productions to trees containing that
		production. Productions are represented as integer IDs, trees are given
		as sets of integer indices. """
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

	def __dealloc__(Ctrees self):
		if self.nodes is not NULL:
			free(self.nodes)
			self.nodes = NULL
		if self.trees is not NULL:
			free(self.trees)
			self.trees = NULL

	def __len__(self):
		return self.len


cdef inline copynodes(tree, dict prods, Node *result):
	""" Convert NLTK tree to an array of Node structs. """
	cdef int n
	for n, a in enumerate(tree):
		assert isinstance(a, Tree), (
				'Expected Tree node, got %s\n%r' % (type(a), a))
		assert 1 <= len(a) <= 2, (
				"trees must be non-empty and binarized\n%s\n%s" % (a, tree[0]))
		result[n].prod = prods[a.prod]
		if isinstance(a[0], int):  # a terminal index
			result[n].left = -a[0] - 1
		else:
			result[n].left = a[0].idx
			if len(a) == 2:
				result[n].right = a[1].idx
			else:  # unary node
				result[n].right = -1
