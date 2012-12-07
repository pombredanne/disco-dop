from array import array
from cpython.array cimport array
from libc.stdlib cimport malloc, realloc, free
from libc.string cimport memcmp, memset
cimport cython

ctypedef unsigned long long ULLong
ctypedef unsigned long ULong
ctypedef unsigned int UInt
ctypedef unsigned char UChar

cdef extern:
	int __builtin_ffsll (ULLong)
	int __builtin_ctzll (ULLong)
	int __builtin_clzll (ULLong)
	int __builtin_ctzl (ULong)
	int __builtin_popcountl (ULong)
	int __builtin_popcountll (ULLong)

cdef extern from "macros.h":
	int BITSIZE
	int BITSLOT(int b)
	ULong BITMASK(int b)
	int BITNSLOTS(int nb)
	void SETBIT(ULong a[], int b)
	ULong TESTBIT(ULong a[], int b)
	#int SLOTS # doesn't work
#cdef extern from "arrayarray.h": pass

# FIXME: find a way to make this a constant, yet shared across modules.
DEF SLOTS = 2

@cython.final
cdef class Grammar:
	cdef Rule **unary, **lbinary, **rbinary, **bylhs
	cdef UChar *fanout
	cdef UInt *mapping, **splitmapping
	cdef size_t nonterminals, numrules, numunary, numbinary
	cdef public dict lexical, lexicalbylhs, toid, tolabel, rulenos
	cdef frozenset origrules
	cdef copyrules(Grammar self, Rule **dest, idx, filterlen)
	cpdef getmapping(Grammar self, Grammar coarse, striplabelre=*,
			neverblockre=*, bint splitprune=*, bint markorigin=*, bint debug=*)
	cdef str rulerepr(self, Rule rule)
	cdef str yfrepr(self, Rule rule)

cdef struct Rule:
	double prob # 8 bytes
	UInt args # 4 bytes => 32 max vars per rule
	UInt lengths # 4 bytes => same
	UInt lhs # 4 bytes
	UInt rhs1 # 4 bytes
	UInt rhs2 # 4 bytes
	UInt no # 4 bytes
	# total: 32 bytes.

@cython.final
cdef class LexicalRule:
	cdef UInt lhs
	cdef UInt rhs1
	cdef UInt rhs2
	cdef unicode word
	cdef double prob

cdef class ChartItem:
	cdef UInt label
@cython.final
cdef class SmallChartItem(ChartItem):
	cdef ULLong vec
@cython.final
cdef class FatChartItem(ChartItem):
	cdef ULong vec[SLOTS]
@cython.final
cdef class CFGChartItem(ChartItem):
	cdef UChar start, end

cdef SmallChartItem CFGtoSmallChartItem(UInt label, UChar start, UChar end)
cdef FatChartItem CFGtoFatChartItem(UInt label, UChar start, UChar end)

cdef class Edge:
	cdef double inside
	cdef Rule *rule
@cython.final
cdef class LCFRSEdge(Edge):
	cdef double score # inside probability + estimate score
	cdef ChartItem left
	cdef ChartItem right
	cdef long _hash
@cython.final
cdef class CFGEdge(Edge):
	cdef UChar mid

@cython.final
cdef class RankedEdge:
	cdef ChartItem head
	cdef LCFRSEdge edge
	cdef int left
	cdef int right
	cdef long _hash

@cython.final
cdef class RankedCFGEdge:
	cdef UInt label
	cdef UChar start, end
	cdef CFGEdge edge
	cdef int left
	cdef int right
	cdef long _hash


# start fragments stuff

cdef struct Node:
	int label, prod
	short left, right

cdef struct NodeArray:
	Node *nodes
	short len, root

@cython.final
cdef class Ctrees:
	cpdef alloc(self, int numtrees, long numnodes)
	cdef realloc(self, int len)
	cpdef add(self, list tree, dict labels, dict prods)
	cdef NodeArray *data
	cdef long nodesleft
	cdef public long nodes
	cdef public int maxnodes
	cdef int len, max

@cython.final
cdef class CBitset:
	cdef int bitcount(self)
	cdef int nextset(self, UInt pos)
	cdef int nextunset(self, UInt pos)
	cdef void setunion(self, CBitset src)
	cdef bint superset(self, CBitset op)
	cdef bint subset(self, CBitset op)
	cdef bint disjunct(self, CBitset op)
	cdef char *data
	cdef UChar slots

@cython.final
cdef class FrozenArray:
	cdef array obj

# end fragments stuff


@cython.final
cdef class MemoryPool:
	cdef void reset(MemoryPool self)
	cdef void *malloc(self, int size)
	cdef void **pool
	cdef void *cur
	cdef int poolsize, limit, n, leftinpool

cdef binrepr(ULong *vec)

# to avoid overhead of __init__ and __cinit__ constructors
cdef inline FrozenArray new_FrozenArray(array data):
	cdef FrozenArray item = FrozenArray.__new__(FrozenArray)
	item.obj = data
	return item

cdef inline FatChartItem new_FatChartItem(UInt label):
	cdef FatChartItem item = FatChartItem.__new__(FatChartItem)
	item.label = label
	return item

cdef inline SmallChartItem new_ChartItem(UInt label, ULLong vec):
	cdef SmallChartItem item = SmallChartItem.__new__(SmallChartItem)
	item.label = label
	item.vec = vec
	return item

cdef inline CFGChartItem new_CFGChartItem(UInt label, UChar start, UChar end):
	cdef CFGChartItem item = CFGChartItem.__new__(CFGChartItem)
	item.label = label
	item.start = start
	item.end = end
	return item

cdef inline LCFRSEdge new_LCFRSEdge(double score, double inside, Rule *rule,
		ChartItem left, ChartItem right):
	cdef LCFRSEdge edge = LCFRSEdge.__new__(LCFRSEdge)
	cdef long h = 0x345678UL
	edge.score = score
	edge.inside = inside
	edge.rule = rule
	edge.left = left
	edge.right = right
	#self._hash = hash((prob, left, right))
	# this is the hash function used for tuples, apparently
	h = (1000003UL * h) ^ <long>rule
	h = (1000003UL * h) ^ <long>left.__hash__()
	# if it weren't for this call to left.__hash__(), the hash would better
	# be computed on the fly.
	edge._hash = h
	return edge

cdef inline CFGEdge new_CFGEdge(double inside, Rule *rule, UChar mid):
	cdef CFGEdge edge = CFGEdge.__new__(CFGEdge)
	edge.inside = inside
	edge.rule = rule
	edge.mid = mid
	return edge
