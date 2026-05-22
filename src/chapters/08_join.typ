#import "@preview/bookly:3.1.0": *

#let abs = [
  The join is the most expensive and most consequential operation in relational
  query processing. A single wrong choice of join algorithm or join order can
  make the difference between a query that completes in seconds and one that
  runs for hours. This chapter develops the family of physical join algorithms
  available to a database optimizer, from the naive nested loop that serves as a
  theoretical baseline to the index nested loop, merge join, and hash join that
  are used in practice. For each algorithm the chapter establishes its cost, its
  memory requirements, the conditions under which it applies, and the ordering
  properties of its output. It then examines how each algorithm adapts to outer
  joins and full outer joins, and closes with the set operators—union,
  intersect, and except—which reduce to variants of join and can be implemented
  by the same algorithms. Throughout, the guiding principle is the same one that
  governs all disk-based computation: the unit of cost is the page, and any
  algorithm whose cost grows with the number of records rather than the number
  of pages should be avoided whenever the data is not highly filtered.
]

#chapter(title: "Physical Operators II", abstract: abs, toc: true)[

  == The Nested Loop Family

  The simplest conceivable join algorithm is the `NestedLoop`. For every record
  in the outer relation, scan the entire inner relation and emit every pair that
  satisfies the join condition. Its cost is

  $ C(O_E, O_I) = C(O_E) + E_"REC" (O_E) times C(O_I) $

  where $O_E$ is the outer operator and $O_I$ is the inner operator. If both are
  table scans, this is $N_"PAG" (R) + N_"REC" (R) times N_"PAG" (S)$—quadratic
  in the number of records. This cost is unacceptable for any table of
  non-trivial size and the nested loop is never used in practice. It serves only
  as a theoretical baseline and as the only algorithm capable of handling
  arbitrary join conditions, including disequalities and non-equijoins.

  The `PageNestedLoop` improves on the nested loop by loading one page of the
  outer relation at a time rather than one record. For every page of the outer,
  the entire inner is scanned. The cost becomes
  $N_"PAG" (R) + N_"PAG" (R) times N_"PAG" (S)$—still quadratic in pages but a
  factor of $B_"records/page"$ better than the basic nested loop. Still
  unacceptable in general.

  The `BlockNestedLoop` extends this further by loading $B$ pages of the outer
  relation at a time. For every block of $B$ outer pages, the entire inner is
  scanned once. The cost becomes
  $N_"PAG" (R) + ceil((N_"PAG" (R)) / B) times N_"PAG" (S)$. When the outer
  relation fits entirely in memory—that is, $N_"PAG" (R) <= B$—this collapses to
  the optimal $N_"PAG" (R) + N_"PAG" (S)$: load the outer once, stream the inner
  once.

  This special case of `BlockNestedLoop` is the right choice whenever one of the
  two relations is small enough to fit in memory. In that case the cost is
  simply the sum of the two table scans, which is optimal. The outer relation
  must be the smaller one; the inner relation may be arbitrarily large, because
  it is streamed one page at a time.

  None of the nested loop variants—except the special case where one table fits
  in memory—are used in practice. They are presented here to establish the
  baseline against which realistic algorithms are measured.

  == Index Nested Loop

  The `IndexNestedLoop` is the algorithm of choice when the outer relation is
  small— either because the table itself is small, or because a selective
  predicate has been applied upstream that reduces the number of records flowing
  into the join. For every record arriving from the outer operator, the
  algorithm uses an index on the inner relation's join attribute to retrieve
  directly the matching records, without scanning the entire inner relation.

  The cost is:

  $ C(O_E, O_I) = C(O_E) + E_"REC" (O_E) times (C_I + C_D) $

  where $C_I + C_D$ is the cost of one index lookup on the inner relation. When
  the join attribute is a primary key of the inner relation, $C_I + C_D = 2$
  (one leaf page of the index, one data page). When the join is on a non-unique
  attribute with on average $k$ matching records per outer record, $C_I + C_D$
  grows but remains a small constant for reasonable fan-outs.

  The critical factor is $E_"REC" (O_E)$: the expected number of records
  produced by the outer operator. When this is large—approaching
  $N_"REC" (R)$—the cost is $O(N_"REC" times (C_I + C_D))$, which is far worse
  than a merge join or hash join whose cost is $O(N_"PAG")$. Index nested loop
  is therefore appropriate only when the outer relation is genuinely small: when
  a highly selective predicate has been applied upstream, when the outer table
  is inherently tiny, or when the query requests a specific record by primary
  key.

  This is directly analogous to the `IndexFilter` versus `TableScan` decision.
  Just as an `IndexFilter` is better than a `TableScan` only when the
  selectivity factor is below roughly $1/B$ (where $B$ is the number of records
  per page), an `IndexNestedLoop` is better than `MergeJoin` or `HashJoin` only
  when $E_"REC" (O_E)$ is small relative to $N_"PAG" (S)$. When the outer
  relation is large and unfiltered, `MergeJoin` or `HashJoin` should always be
  preferred.

  === Structural Constraint: The Right Child Must Be IndexFilter

  `IndexNestedLoop` is not a single operator but a coordinated pair: the
  `IndexNestedLoop` operator on top and an `IndexFilter` operator as its _right
  child_. The `IndexNestedLoop` operator, for each record received from its left
  child, extracts the current value of the join attribute, and uses that value
  to _reopen_ the right child's `IndexFilter` with new bounds. The `IndexFilter`
  then produces all inner records matching that value.

  This coordination imposes a strict structural rule: the right child of an
  `IndexNestedLoop` must always be an `IndexFilter` (or a `Filter` placed
  immediately above an `IndexFilter`, since `Filter` passes the open signal
  through to its child). No other operator can appear as the right child,
  because the `IndexNestedLoop` reopens its right child once per outer record,
  and only `IndexFilter` supports being reopened with a new key value. The left
  child can be any operator whatsoever.

  #figure(image("../figures/chapter8/inl_1.pdf"), caption: [
    Two physical plans for an index nested loop join. In both plans, the outer
    table `R` scan drives the inner index `Idx(S)` probe via parameter passing
    (dashed arrow). The right plan additionally pushes a filter below the index
    lookup to reduce the number of probes.
  ])

  For a join of three tables $R, S, T$ where $R join_(R.a = S.A) S$ and
  $S join_(S.b = T.b) T$, a valid `IndexNestedLoop` plan is the one shown in
  @inl_2[Figure].

  #figure(image("../figures/chapter8/inl_2.pdf"), caption: [
    A pipelined plan for $R join S join T$. The first index nested loop joins
    $R$ and $S$ on $R.a = S.a$ using an index on $S.a$; its output is consumed
    directly by a second index nested loop that joins with $T$ on $S.b = T.b$
    using an index on $T.b$. Both joins use parameter passing from the outer to
    the inner side.
  ]) <inl_2>

  === Output Ordering

  The output of an IndexNestedLoop is ordered by the outer relation's sort
  order, if any. If the outer relation is unsorted, the output is unsorted.
  Because the inner relation is accessed record by record through index lookups
  rather than scanned sequentially, its contribution to the output carries no
  ordering guarantee.

  == Merge Join

  The _merge join_ (also called sort-merge join) is the algorithm of choice when
  neither relation is small and no useful filtering has been applied. It
  requires both inputs to arrive sorted on the join attribute, and then merges
  them in a single sequential pass, exactly as the merge phase of external sort
  merges sorted runs.

  When the join attribute is a key in the outer relation, the algorithm is
  straightforward. Two cursors advance through the sorted outer and sorted inner
  relations. When the current outer value is strictly less than the current
  inner value, the outer cursor advances. When the current inner value is
  strictly less than the current outer value, the inner cursor advances. When
  the values are equal, a joined record is emitted and the inner cursor advances
  (since the outer attribute is a key, no further outer records can match the
  current inner value). This scan of both relations is linear and requires no
  intermediate storage.

  When the join attribute is not a key in either relation, a small block of
  memory is needed. Whenever the outer cursor encounters a new value $v$ for the
  join attribute, all outer records with value $v$ are loaded into a memory
  block. The inner relation is then scanned until the join attribute exceeds
  $v$, and for each inner record with value $v$, it is joined with every record
  in the memory block. This requires that all outer records with any given join
  attribute value fit in memory—a condition that holds whenever the join
  attribute is reasonably selective in the outer relation.

  The incremental cost of the merge join operator itself is zero: it consumes
  its inputs through the iterator interface and produces output through the same
  interface, with no intermediate disk writes. The total cost is therefore the
  cost of producing the two sorted inputs. If both inputs arrive pre-sorted—from
  indexes, from earlier sorts, or from upstream operations—the merge join is
  entirely free. If sorting is required, the cost of each sort is added:

  $ C(O_E, O_I) = C(O_E) + C(O_I) + C_"sort" (O_E) + C_"sort" (O_I) $

  where $C_"sort"$ is the incremental sort cost ($2 times N_"PAG"$ in the
  standard two-phase case, zero if the input fits in memory after projection).

  === Output Ordering

  The output of a `MergeJoin` is sorted on the join attribute. This is a
  valuable property: a subsequent `GroupBy` on the join attribute, or a
  subsequent `MergeJoin` on the same attribute, requires no additional sort.
  When a query chains two merge joins on the same attribute—for example, joining
  $R$, $S$, and $T$ all on attribute $A$—the output of the first merge join is
  already sorted on $A$ and can feed directly into the second without
  re-sorting. This sort-preservation is a significant advantage of merge join
  over hash join, which produces unsorted output.

  == Hash Join

  The _hash join_ is an alternative to merge join for the case where both
  relations are large and unsorted. Rather than sorting the data to align
  matching records, it uses a hash function to partition both relations so that
  all records that could possibly join land in the same partition. The join is
  then computed partition by partition, with each partition of the smaller
  relation loaded entirely into memory.

  The algorithm assumes that at least one of the two relations—call it $R$, the
  smaller—satisfies $N_"PAG" (R) <= B^2$, where $B$ is the available buffer
  space. When this holds, a single partitioning phase suffices.

  In the _partitioning phase_, the operator applies a hash function $h_1$ on the
  join attribute to both $R$ and $S$, distributing records into $B$ partitions
  each. Records of $R$ with the same hash value and records of $S$ with the same
  hash value land in the same numbered partition. Each of the $B$ partitions of
  $R$ contains on average $(N_"PAG" (R)) / B$ pages, which by assumption is at
  most $B$ pages and therefore fits in memory.

  In the _probing phase_, for each partition $i$, the operator loads partition
  $i$ of $R$ entirely into memory (using a second hash function $h_2$ orthogonal
  to $h_1$ to build an in-memory hash table), then streams partition $i$ of $S$
  one page at a time, probing the in-memory hash table for each $S$ record and
  emitting matches.

  Because the operator works within a pipeline, the initial read of both
  relations is attributed to the child operators and the final output is
  streamed to the parent without being written to disk. The incremental cost is:

  $ C(O_E, O_I) = C(O_E) + C(O_I) + 2 times (N_"PAG" (O_E) + N_"PAG" (O_I)) $

  one write and one read per page for each of the two relations during
  partitioning and probing. This is the same structure as the merge join cost
  when both relations require a two-phase sort:

  $
    C(O_E, O_I) = C(O_E) + C(O_I) + 2 times N_"PAG" (O_E) + 2 times N_"PAG" (O_I)
  $

  The two algorithms have identical cost in the standard case. The difference
  emerges when the relations have very different sizes. If $R$ has $B^2$ pages
  and $S$ has $B^3$ pages, merge join requires a two-phase sort of $R$ and a
  three-phase sort of $S$, costing $2 N_"PAG" (R) + 4 N_"PAG" (S)$. Hash join
  requires only two phases (one to reduce $R$ to partitions of size $B$,
  regardless of $S$'s size), costing $2 times (N_"PAG" (R) +
    N_"PAG" (S))$—potentially much cheaper. When both relations are in the same
  size class, the costs are equal.

  #info-box()[
    === Choosing Between Index Nested Loop, Merge Join, and Hash Join

    The choice among the three practical join algorithms reduces to a single
    question: how many records does the outer operator produce?

    When $E_"REC" (O_E)$ is small—because a highly selective predicate has been
    applied upstream—index nested loop is best. Its cost scales with the number
    of outer records, and each index lookup costs only a few I/Os.

    When $E_"REC" (O_E)$ is large—approaching the full table size—merge join or
    hash join is best. Their costs scale with the number of pages, not records,
    and are therefore one to two orders of magnitude cheaper for large
    unrestricted tables.

    Between merge join and hash join, prefer merge join when the output needs to
    be sorted (merge join produces sorted output; hash join does not), when
    chaining multiple joins on the same attribute (sort-preservation eliminates
    re-sorting), or when the two relations are of similar size. Prefer hash join
    when one relation is much smaller than the other and the size difference
    spans hash-phase boundaries.

    The cost of projecting before sorting or hashing deserves emphasis. The cost
    of sort and hash join is proportional to $N_"PAG" (O)$—the pages of the
    operator's input, not the pages of the raw table. A projection that reduces
    the record from 20 attributes to 2 reduces the page count by roughly a
    factor of 10, and the sort or hash cost falls by the same factor. Always
    project to the minimal required attribute set before any blocking operator.
  ]

  === Output Ordering

  Hash join produces unsorted output. Records are emitted in partition order,
  which corresponds to no meaningful attribute order. If a subsequent operator
  requires sorted input—a GroupBy, a merge join, or a user-requested ORDER BY—a
  sort must be added after the hash join. This is in contrast to merge join,
  whose output is sorted on the join attribute.

  == Output Size Estimation for Joins

  The expected number of records produced by a join is:

  $ E_"REC" (R join S) = N_"REC" (R) times N_"REC" (S) times s_f (phi) $

  where $phi$ is the join predicate. For an equijoin $R.A = S.B$, the
  selectivity factor is $1 / max(N_"KEY" (R.A), N_"KEY" (S.B))$ as established
  in the previous chapter. For a three-way join of $R$, $S$, and $T$ with
  conditions $R.A = S.A$ and $S.A = T.A$, the combined estimate multiplies all
  three record counts and both selectivity factors in a single expression:

  $
    E_"REC" = N_"REC" (R) times N_"REC" (S) times N_"REC" (T) times s_f (R.A = S.A) times s_f (S.A = T.A)
  $

  A subtlety arises when the join involves a filtering condition that restricts
  the range of values for the join attribute. If $T.A$ has only 500 distinct
  values while $R.A$ and $S.A$ each have 10,000, then the join result is
  filtered to the 500 values present in $T$. The number of distinct groups in a
  subsequent GroupBy on $R.A$ is therefore at most 500, not 10,000: the join has
  implicitly reduced the range of $R.A$ to the values that appear in $T.A$. More
  generally, the number of distinct values of the join attribute in the result
  is the minimum of the distinct value counts across all joined tables.

  The number of output pages is computed from the record count and the output
  record size after projection:

  $
    E_"PAG" = ceil(E_"REC" times |"output attributes"| times L_"attr" / B_"page")
  $

  This page count, not the raw record count, determines the cost of any
  subsequent blocking operator such as Sort or HashGroupBy.

  == Outer Joins

  An _outer join_ between $R$ and $S$ returns all records that an inner join
  would return, plus, for every record of $R$ (the preserved relation) that has
  no matching record in $S$, one additional record with the $R$ fields filled
  and the $S$ fields set to null. A _left outer join_ preserves $R$; a _right
  outer join_ preserves $S$; a _full outer join_ preserves both.

  All five practical join algorithms adapt to left outer join by a uniform
  modification: maintain one bit per record of the outer relation, initialized
  to zero. Whenever an outer record matches an inner record and a joined tuple
  is emitted, set its bit to one. After the inner relation is exhausted, emit a
  null-padded tuple for every outer record whose bit remains zero.

  For _nested loop_ and _page nested loop_, the bit is naturally reset for each
  outer record or outer page respectively as the inner scan restarts. For _index
  nested loop_, the bit is set whenever the index returns at least one matching
  record. For _merge join_, the bit can be maintained while scanning the outer
  relation sequentially. For _hash join_, the bit is maintained during the
  probing phase: after streaming all of partition $i$ of $S$, the operator
  inspects the in-memory partition $i$ of $R$ and emits null-padded tuples for
  any $R$ records not yet matched.

  _Full outer join_ requires symmetry: unmatched records from both $R$ and $S$
  must be detected and emitted. This is straightforward for merge join, which
  scans both relations simultaneously and can track unmatched records from
  either side. Hash join supports full outer join when both relations'
  partitions fit in memory together, allowing both sides to be inspected after
  probing. Index nested loop and block nested loop do not naturally support full
  outer join because tracking unmatched inner records requires additional
  bookkeeping proportional to the size of the inner relation. In practice, full
  outer join is most naturally expressed as a merge join or, when partitions are
  small enough, a hash join.

  == Set Operators

  The set operators—Union, Intersect, and Except—operate on two relations with
  identical schemas and return their set union, set intersection, or set
  difference respectively, with duplicate elimination. The multiset variant
  UnionAll returns all records from both relations without duplicate
  elimination.

  _UnionAll_ is trivial: it streams all records from the first input until
  exhaustion, then all records from the second input. Its incremental cost is
  zero.

  _Union_, _Intersect_, and _Except_ each require that duplicate elimination be
  performed. The standard approach is to sort both inputs on all attributes in
  the same order, eliminating duplicates within each input, then merge the two
  sorted streams. During the merge:

  - Union emits a record whenever it appears in either input, but emits it only
    once when it appears in both.
  - Intersect emits a record only when it appears in both inputs simultaneously.
  - Except emits a record from the first input only when no corresponding record
    appears in the second input.

  All three operations therefore reduce to a merge join on all attributes, with
  different emission rules. The sort requirement is the same: both inputs must
  be sorted on a super-key for the relation—enough attributes to determine all
  others, typically either the primary key or all attributes—in the same order.
  Because Union and its variants are symmetric with respect to the schema, the
  sort order for attributes within the key may be chosen freely (ascending or
  descending on each attribute, in any permutation) as long as both inputs use
  the same order.

  The incremental cost of Union, Intersect, and Except is zero once the inputs
  are sorted; the cost of the sort operators placed on each input follows the
  standard formula. Hash variants exist for all three and have the same cost
  structure as hash join: one partitioning pass and one probing pass, at
  $2 times (N_"PAG" (O_E) + N_"PAG" (O_I))$ incremental I/Os.

  As a design observation, intersection is exactly a natural join on all
  attributes. Except is a left outer join on all attributes where the right-hand
  fields are null—which expresses the condition that no matching right record
  was found. Union is a full outer join on all attributes. This connection
  explains why the same algorithms that implement join also implement set
  operators: structurally they are the same computation.

  == Join Order and the Optimizer

  The optimizer's most consequential decision is _join order_: when a query
  joins $n$ tables, in what sequence should the joins be performed? With $n$
  tables there are $n!$ orderings, and for each ordering there are multiple
  algorithm choices. The space is too large to search exhaustively for realistic
  queries, and optimizers use heuristics and dynamic programming to prune it.

  The guiding principle is to begin from the most selective condition. The
  relation produced by the most selective operation is the smallest, and
  starting from the smallest intermediate result minimizes the cost of every
  subsequent operation. In a join of students, exams, and courses, if the query
  specifies a particular course title that matches one row, starting from the
  course table produces a tiny intermediate result that propagates cheaply
  through the remaining joins. Starting from the students table, which may have
  thousands of rows, produces a large intermediate result that is expensive to
  join with anything.

  When both a selection condition on one table and a join condition link that
  table to another, the optimizer should start from the table with the most
  selective combined condition. The selectivity of the combined condition is the
  product of the selectivity factors of all predicates applied to that table, as
  established in the selectivity estimation framework of the previous chapter.

  A secondary principle governs the choice between index nested loop and
  merge/hash join for each pair of tables in the chosen order: use index nested
  loop when the outer relation (the one already accumulated from previous joins)
  is small; use merge or hash join when it is large. As the join accumulates
  more tables, the intermediate result typically grows, shifting the preference
  from index nested loop toward merge or hash join as the plan tree is ascended.

  === Sort Preservation and Its Value

  A plan that uses merge join throughout produces a final result that is sorted
  on the last join attribute. If a subsequent GroupBy or ORDER BY requires
  sorting on that attribute, no additional sort is needed. This
  sort-preservation can eliminate one or more sort operations from the plan,
  each costing $2 times N_"PAG"$ incremental I/Os. When planning a query with
  both a join and a GroupBy on the same attribute, strongly prefer merge join
  over hash join so that the sort required for merge join also satisfies the
  GroupBy grouping requirement.

  More subtly, if two consecutive merge joins use the same join attribute—for
  example, joining $R$, $S$, and $T$ all on attribute $A$—the output of the
  first merge join is already sorted on $A$ and can be fed directly into the
  second merge join without re-sorting. A chain of merge joins on the same
  attribute has the same total cost as a single sort of the largest input. A
  chain of hash joins on the same attribute offers no such saving: each hash
  join partitions its input afresh, and the output of each is unsorted.

  This is the principal reason why practitioners sometimes prefer merge join
  even when hash join has equal or slightly lower raw I/O cost: the
  sort-preservation property compounds across multiple operations, while hash
  join's unsorted output requires paying for a new sort at each stage.

]
