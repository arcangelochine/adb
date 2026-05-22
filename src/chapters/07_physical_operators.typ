#import "@preview/bookly:3.1.0": *

#let abs = [
  A SQL query does not execute itself. Before any record moves from disk to
  screen, the database system translates the query into a tree of physical
  operators, each of which implements one relational operation using a specific
  algorithm, and then orchestrates the execution of that tree with minimal
  memory and minimal disk access. The previous chapter developed the iterator
  model, the access method interface, and the optimizer's role in constructing
  physical plans. This chapter builds directly on that foundation. It examines
  each unary physical operator in turn: table and index scans, projection,
  duplicate elimination, sorting, and grouping. For each operator the chapter
  establishes its cost, its memory requirements, its blocking behavior, and the
  conditions under which the output is guaranteed to be sorted or
  grouped—properties that propagate upward through the tree and determine
  whether subsequent operators must pay for an explicit sort. The chapter closes
  with the problem of estimating the size of an operator's output, which is the
  prerequisite to every cost comparison the optimizer must make.
]

#chapter(
  title: "Physical Operators I",
  abstract: abs,
  toc: true,
)[
  
  == From SQL to a Physical Plan
  
  The previous chapter described the four transformations that carry a SQL
  statement from text to an executable physical plan: parsing, logical planning,
  logical optimization, and physical planning. Physical plans are represented as
  trees rather than linear expressions, because linear notation becomes
  unreadable as soon as binary operators such as join appear. In the tree
  representation, leaves are operators that read data from disk—table scans,
  index filters—and internal nodes are operators that transform data received
  from their children. Data flows upward from leaves to root; control flows
  downward from root to leaves through requests for the next record. This
  asymmetry is the foundation of the iterator model.
  
  == The Iterator Model
  
  The iterator model and its memory advantages were established in the previous
  chapter. To briefly recap the terms used throughout this chapter: every
  physical operator implements `open`, `next`, and `close`; only leaf operators
  read from disk; all others receive records one at a time from their children
  and pass results upward. Non-blocking operators hold at most one record in
  memory at a time. Blocking operators—those that must consume their entire
  input before producing any output—are the exception and are identified
  explicitly below.
  
  === The Access Method Interface
  
  The cursor abstraction through which operators request records regardless of
  the underlying data structure—heap file, B+-tree, hash table—was developed in
  the previous chapter, along with the $C_I + C_D$ cost model for two-level
  index access. These are assumed throughout what follows.
  
  == Scan Operators
  
  The `TableScan` operator opens a heap file and streams every record from first
  page to last. It is the baseline against which all other access strategies are
  compared. Its cost is $N_"PAG"$ disk reads, its output is unsorted, and it
  works on any primary organization—heap, sequential, hash, or B+-tree—because
  every organization supports a sequential scan. Unless otherwise specified, all
  tables in cost analyses are assumed to be stored as heap files.
  
  The `IndexScan` operator opens an index with bounds of minus infinity and plus
  infinity, and for every entry in the index retrieves the corresponding record
  from the data file. Its output arrives sorted on the indexed attribute.
  However, its cost is $O(N_"REC")$ rather than $O(N_"PAG")$, because each RID
  lookup may access a different page. Compared to a `TableScan` followed by an
  external sort—which costs $N_"PAG" + 2 times N_"PAG"$ in the standard
  two-phase case—`IndexScan` is _rarely competitive_. The one exception is when
  the index is clustered, in which case the RIDs are already in page order and
  the effective cost is $N_"PAG"$ with the data arriving pre-sorted. Outside of
  this case, `IndexScan` is not used.
  
  The `IndexFilter` operator is the standard tool for selective access. It takes
  a table, an index on that table, and an interval predicate $[v_1, v_2]$ on the
  indexed attribute. It opens the index cursor at $v_1$, scans to $v_2$, and for
  each RID retrieves the corresponding record from the heap file. Its cost is
  $C_I + C_D$ as developed in the previous chapter. Critically, `IndexFilter` is
  always a _leaf_ in the plan tree: it has no child operator and accepts no
  input from above. It reads its data exclusively from disk. Placing any
  operator below an `IndexFilter`, or placing an `IndexFilter` above another
  `IndexFilter`, is a structural error: the lower operator's output would never
  be consumed.
  
  The `IndexOnlyFilter` operator is a variant that reads _only the index_, never
  the data file. It can be used whenever the set of attributes required by the
  query is a subset of the attributes stored in the index—which is always true
  for a single-attribute index when only that attribute is needed, and may be
  true for a combined index when all required attributes appear together. Its
  cost is only $C_I = ceil(s_f times N_"LEAF")$ disk reads. Whenever
  `IndexOnlyFilter` is applicable it is dramatically cheaper than `IndexFilter`,
  and it should always be preferred.
  
  The `AndIndexFilter` operator handles conjunctive predicates using two or more
  indexes. For each index, it loads the RID list for the relevant portion into
  memory. It intersects all RID lists in memory, sorts the surviving RIDs, and
  then accesses the data file once per surviving record—or more precisely, once
  per page containing at least one surviving record, as estimated by the
  Cardenas formula applied to the combined selectivity. Its cost is the sum of
  the $C_I$ terms for each index plus the Cardenas data access cost using the
  combined selectivity factor. The amount of memory required is the size of the
  smallest index portion, since the smallest can be loaded fully into memory and
  the others scanned page by page to compute the intersection.
  
  #info-box()[
    === Operator Classification
    
    Physical operators divide into three categories by their position in the
    plan tree.
    
    _Zero-ary_ operators read data from disk and produce records from scratch.
    They are always leaves: `TableScan`, `IndexFilter`, `IndexOnlyFilter`,
    `AndIndexFilter`. They have no child operators and no input from above.
    
    _Unary_ operators transform a single input stream. They are always internal
    nodes: `Project`, `Filter`, `Sort`, `Distinct`, `GroupBy`, and their
    hash-based variants. They have exactly one child.
    
    _Binary_ operators combine two input streams. They are always internal nodes
    with exactly two children: all join operators, `Union`, `Intersect`,
    `Except`.
    
    Confusing zero-ary with unary operators produces structurally invalid plans.
    An `IndexFilter` with a child, or a `Filter` without a child, cannot be
    executed.
  ]
  
  == Projection
  
  The `Project` operator removes attributes from the record stream produced by
  its child. It is entirely non-blocking and requires no disk access: for each
  record received from its child it drops the unwanted fields and passes the
  reduced record upward. Its _incremental cost_ is zero; the total cost of a
  plan ending in `Project` is equal to the cost of the subplan below it.
  
  Projection is most valuable not as a logical operation but as a tool for
  reducing the size of data before expensive operations. Sort and hash-based
  operators have costs proportional to $N_"PAG"$, the number of pages of their
  input. A projection applied before a sort reduces the number of pages and
  therefore the sort cost. If a table has twenty attributes but the query
  requires only two, a projection reduces the page count by roughly a factor of
  ten, and the sort cost falls by the same factor. This optimization—project
  early, before sorting or hashing—is one of the most reliably beneficial
  transformations available to the optimizer.
  
  The output of `Project` has the same number of records as its input and the
  same ordering, but a different record size. The number of output pages is:
  
  $
    E_"PAG" = ceil(N_"REC" times (|"attributes kept"| times L_"attr") / B_"page")
  $
  
  where $L_"attr"$ is the byte length of each attribute and $B_"page"$ is the
  page size.
  
  == Duplicate Elimination
  
  The `Distinct` operator eliminates consecutive duplicate records from its
  input stream. It is non-blocking, requires no disk access, and has incremental
  cost zero: for each record received, it compares the record to the last one
  emitted. If they differ, it emits the new record and remembers it; if they are
  equal, it discards it and requests the next. The total cost of a plan ending
  in `Distinct` is equal to the cost of the subplan below it.
  
  The requirement that duplicates be _consecutive_ means that the input must be
  _grouped_ on the attributes being deduplicated. An input is grouped on a set
  of attributes $A$ if, whenever a particular combination of values for $A$
  appears, all records with that combination form a _contiguous block_ in the
  stream: once a combination disappears, it never reappears. Grouping is weaker
  than sorting. Sorted implies grouped, but grouped does not imply sorted: a
  stream may be grouped without being in any particular linear order. In
  practice, the only reliable way to ensure grouping is to sort.
  
  === Sorted vs Grouped: A Subtle but Important Distinction
  
  Sorting on a set of attributes $A_1, ..., A_k$ produces a stream that is also
  grouped on any prefix of that list, and on any reordering of the full list,
  because the grouping property is insensitive to the order of attributes—what
  matters is that equal combinations appear consecutively, not in which order
  the attributes are compared. This means that data sorted on
  `(name, surname, age)` is grouped on `(name, surname)`, on `(surname, name)`,
  on `(age, name, surname)`, and on every other permutation. However, it is only
  grouped on `(name, age)` if `name` functionally determines `age`—that is, if
  every pair of records with the same `name` also has the same `age`. If no such
  functional dependency holds, then inserting `surname` between `name` and `age`
  in the sort key _breaks the grouping property_ for `(name, age)`, because
  records with the same `name` but different `surnames` will appear interleaved,
  and records with the same `(name, age)` may be separated by records with a
  different `surname`.
  
  The practical rule is: when matching a sort property to a grouping
  requirement, the grouping requirement may be freely reordered, but the sort
  property may not. A stream sorted on `(name, surname, age)` satisfies the
  grouping requirement for `(surname, name)` because one can verify that the
  sort implies this grouping. It does not satisfy the grouping requirement for
  `(name, age)` unless the functional dependency `name -> age` holds. Functional
  dependencies that go _forward_—where an earlier key attribute determines a
  later one—allow attributes to be freely inserted or removed from the sort key
  without affecting the grouping guarantee. Functional dependencies that go
  _backward_ have no such effect.
  
  === Hash Distinct
  
  When the input stream is not sorted and sorting it would be too expensive, the
  `HashDistinct` operator provides an alternative. `HashDistinct` partitions all
  records into groups using a hash function on the deduplication attributes,
  ensures that all records with the same attribute values land in the same
  partition, and then eliminates duplicates within each partition in memory. It
  does not require its input to be sorted.
  
  The algorithm operates in two phases when the input is larger than the
  available buffer space $B$ but smaller than $B^2$. In the _partitioning
  phase_, the operator reads all input records one by one—receiving them from
  its child through the iterator interface—applies a hash function $h_1$ to the
  deduplication attributes, and writes each record to one of $B$ output
  partitions on disk. Each partition receives on average $N_"PAG" / B$ pages. In
  the _probing phase_, the operator reads each partition entirely into memory,
  applies a second hash function $h_2$ orthogonal to $h_1$ to build an in-memory
  hash table, and emits one record per distinct value.
  
  Because the operator operates within a pipeline, it does not pay for reading
  its input (that cost is attributed to the child operator) and does not pay for
  writing its final output (that is streamed directly to the parent). The
  incremental cost is therefore:
  
  $ C(O) = C(O) + 2 times N_"PAG" (O) $
  
  one write per page during partitioning, and one read per page during probing.
  When the input fits entirely in memory, the cost is $C(O) + 0$: all processing
  happens in memory with no intermediate disk writes.
  
  If the input exceeds $B^2$ pages, additional partitioning phases are needed.
  Each phase divides the data by a further factor of $B$, using a new orthogonal
  hash function. The number of phases is $ceil(log_B N_"PAG") - 1$, and each
  additional phase adds $2 times N_"PAG"$ to the cost. The same structure
  governs sorting and all hash-based operators, as discussed below.
  
  == Sorting
  
  The `Sort` operator produces its entire input in sorted order. It is
  _blocking_: the first call to next exhausts the entire input before returning
  a single record. This is unavoidable—the smallest record in the input may be
  the last one read—and it means that `Sort` imposes a latency equal to its full
  execution time before any result is visible to the parent operator. `Sort`
  also reserves $B$ buffer pages for the duration of its execution, from `open`
  until the final `next` returns end-of-file (`EOF`).
  
  The cost of `Sort` depends on the number of phases required, which in turn
  depends on the ratio of input pages to available buffer space.
  
  When $N_"PAG" (O) <= B$, the entire input fits in memory. `Sort` loads all
  records, sorts them in memory, and streams the result. The incremental disk
  cost is zero:
  
  $ C(O) = C(O) $
  
  When $N_"PAG" (O) > B$ but $N_"PAG" (O) <= B^2$, a two-phase external sort
  suffices. In the first phase, the input is divided into runs of $B$ pages
  each, which are sorted in memory and written to disk. In the second phase, all
  runs are merged using $B$ input buffers. Because the operator works within a
  pipeline, the initial read of the input is attributed to the child, and the
  final write of the output is streamed to the parent without being written to
  disk. The incremental cost is one write and one read per page:
  
  $ C(O) = C(O) + 2 times N_"PAG" (O) $
  
  In the general case, the number of phases is $ceil(log_B N_"PAG" (O))$, and
  the incremental cost is:
  
  $ C(O) = C(O) + (ceil(log_B N_"PAG" (O)) - 1) times 2 times N_"PAG" (O) $
  
  The subtraction of one reflects the fact that the final write and the initial
  read are eliminated by streaming. For the standard two-phase case, this
  formula gives $(2 - 1) times 2 = 2$ times $N_"PAG"$, consistent with the
  formula above.
  
  #figure(image("../figures/chapter7/sort_vs_hash.drawio.pdf"), caption: [
    Two dual strategies for grouping by key. External sort (left) merges runs
    bottom-up; hash partitioning (right) splits buckets top-down. Both complete
    in the same number of passes, with external sort additionally producing
    sorted output.
  ])
  
  === Sort vs HashDistinct: A Symmetric Structure
  
  External sort and hash-based partitioning are structurally dual. Sorting
  begins with completely unordered data and builds progressively larger sorted
  runs, merging them in each pass until a single sorted run covers the entire
  input. Hashing begins with a single equivalence class covering all records and
  splits it into progressively finer classes, applying a new hash function in
  each pass until each class fits in memory. Both require the same number of
  passes—$ceil(log_B N_"PAG")$—for the same input size, and both have the same
  incremental cost of $2 times N_"PAG"$ in the standard two-phase case. The
  choice between `Sort` and `HashDistinct` is therefore a matter of
  implementation preference and secondary factors such as whether the output
  needs to be sorted (`Sort` produces a sorted stream; `HashDistinct` does not)
  rather than a cost difference.
  
  == Group-By and Aggregation
  
  The `GroupBy` operator partitions records into groups sharing the same values
  for a set of _dimension_ attributes (or _grouping attributes_), and for each
  group computes one or more _aggregate functions_ such as `COUNT`, `SUM`,
  `MIN`, `MAX`, or `AVG`. Like `Distinct`, `GroupBy` requires its input to be
  grouped on the dimension attributes—once a particular combination of dimension
  values disappears from the stream, it must never reappear. `Distinct` is in
  fact a special case of `GroupBy` where no aggregate functions are computed.
  
  When the input is grouped, `GroupBy` accumulates aggregate state record by
  record. For most aggregates this state is a single value: a running count for
  `COUNT`, a running sum for `SUM`, a running minimum for `MIN`, a running
  maximum for `MAX`. Each new record updates the state in constant time and
  constant memory. The one exception is `AVG`, which cannot be accumulated
  directly: adding the new value to a running average weights the new record
  equally against all previous records. The correct approach maintains a running
  `SUM` and a running `COUNT`, computing their ratio only when the group ends.
  `GroupBy` therefore requires one or two memory locations per active group—a
  negligible amount—and its incremental cost is zero.
  
  $ C(O) = C(O) $
  
  When the input is not grouped, the same two strategies available for
  `Distinct` apply. A `Sort` operator placed before `GroupBy` guarantees
  grouping at the cost of the sort. The `HashGroupBy` operator works exactly
  like `HashDistinct` but accumulates aggregate state within each partition and
  within each in-memory hash table slot, rather than simply flagging duplicates.
  Its cost is identical to `HashDistinct`: $C(O) + 2 times N_"PAG" (O)$ in the
  two-phase case, or $C(O)$ when the input fits in memory.
  
  The choice between `Sort` + `GroupBy` and `HashGroupBy` mirrors the choice
  between `Sort` and `HashDistinct`. When the data arrives pre-sorted—because it
  came from an index, from an earlier sort, or from a join that preserves
  order—`GroupBy` is free. When the data is unsorted, `Sort` + `GroupBy` and
  `HashGroupBy` have equal cost, but `Sort` + `GroupBy` produces a sorted output
  that may benefit subsequent operators, while `HashGroupBy` does not.
  
  === Output Size Estimation for Distinct and GroupBy
  
  Estimating how many records a `Distinct` or `GroupBy` operation will produce
  requires knowing how many distinct combinations of the grouped attributes
  exist in the data. For a single attribute $A$, the answer is simply
  $N_"KEY" (A)$: one output record per distinct value.
  
  For two or more attributes $A_1, ..., A_k$, the estimate depends on whether
  the data is _dense_ or _sparse_ in the combination space. Dense data has a
  record for most combinations of values: if the table records exam results over
  many sessions, probably every `(course, grade)` pair that is possible has
  occurred at least once. In this case the product
  $N_"KEY" (A_1) times ... times N_"KEY" (A_k)$ is a reasonable estimate. Sparse
  data has records for only a small fraction of combinations: a table of
  students with attributes `(name, surname)` will not contain a record for every
  possible `(name, surname)` pair, since names and surnames are paired by the
  students who actually exist, not by Cartesian product. In this case the
  product massively overestimates.
  
  Since the optimizer cannot in general determine whether data is dense or
  sparse, the standard formula is:
  
  $
    E_"REC" = min(N_"KEY" (A_1) times ... times N_"KEY" (A_k), N_"REC" / 2)
  $
  
  The product is used when it is smaller than half the input size, reflecting
  the optimistic case where data is dense enough for the product to be
  meaningful. When the product exceeds half the input size, the estimate falls
  back to $N_"REC" / 2$, acknowledging that at least some duplicate elimination
  must occur—otherwise the user would not have written `Distinct`—while avoiding
  the absurdity of estimating more output records than input records. The factor
  of two is an empirical convention rather than a derived quantity: it encodes
  the belief that a `Distinct` operation eliminates at least half the records.
  
  This formula works well only for a _single attribute_, where the product is
  just $N_"KEY"$ and the estimate is exact under the assumption of uniform
  distribution. For two attributes it is already unreliable. For three or more
  attributes it should be treated as a rough order-of-magnitude guess rather
  than a serious estimate. The same formula applies to `GroupBy`, since the
  number of groups is exactly the number of distinct combinations of dimension
  attributes.
  
  == The Filter Operator
  
  The `Filter` operator applies a predicate to its input stream and discards
  records that do not satisfy it. It is non-blocking, requires no disk access,
  and has incremental cost zero. Its output has $E_"REC" = s_f times N_"REC"$
  records and $E_"PAG" = s_f times N_"PAG"^"in"$ pages, where $s_f$ is the
  selectivity factor of the predicate as defined in the previous chapter. The
  output preserves the order and grouping of the input.
  
  `Filter` is always an internal node and always has a child. Its most common
  use is to apply a predicate on an attribute not covered by any index, after a
  scan or index lookup has retrieved the candidate records. A filter that
  applies an equality or range predicate on an indexed attribute is often
  replaceable by an `IndexFilter`, which is more efficient because it avoids
  loading non-qualifying records from disk entirely.
  
  == Access Plan Costing: A Worked Illustration
  
  The principles above combine into a systematic procedure for evaluating access
  plan cost. For each node in the plan tree, proceeding from leaves to root, one
  computes: the cost of the operator (disk I/Os), the expected number of output
  records ($E_"REC"$), and the expected number of output pages ($E_"PAG"$). The
  cost of any operator is the cost of its children plus its own incremental
  cost. The total plan cost equals the cost at the root.
  
  To illustrate, consider a query selecting records from a heap table $R$ with
  $N_"PAG" = 10.000$ pages and $N_"REC" = 1.000.000$ records, under a
  conjunctive predicate with overall selectivity $s_f = 1/1000$, projecting the
  result onto two attributes each of 4 bytes, with a page size of 4 kilobytes
  and a buffer of 100 pages.
  
  A plan using `TableScan` followed by `Filter` and `Project` costs $10.000$
  I/Os (the table scan; Filter and Project are free). The expected output has
  $E_"REC" = 1.000$ records and $E_"PAG" = ceil((1000 times 8) / 4000) = 2$
  pages.
  
  A plan using `IndexFilter` on a B+-tree index with $N_"LEAF" = 2.000$ leaves
  and $N_"KEY" = 1.000$ distinct values has
  $C_I = ceil(s_f times N_"LEAF") = 10$ and
  $C_D = Phi(N_"REC" / N_"KEY", N_"PAG") = Phi(1000, 10000) approx 1.000$. The
  total plan cost is approximately $1.010$ I/Os—better than table scan precisely
  because the selectivity factor is $0.1%$, below the crossover point of roughly
  $1%$ at which table scan becomes competitive.
  
  If a sort on the output is subsequently required, its cost depends on whether
  $E_"PAG"$ exceeds $B$. Here $E_"PAG" = 2 < B = 100$, so the sort fits in
  memory and its incremental cost is zero: the sort is free. Had the selectivity
  been $10%$, the `IndexFilter` would have produced $100.000$ records in
  approximately $2.500$ pages, costing far more than the table scan and
  requiring a two-phase sort at an additional $2 times 2.500 = 5.000$ I/Os.
  
  These numbers illustrate the central insight that runs through all access plan
  analysis: the cost of index-based access scales with the number of records,
  while the cost of scan-based access scales with the number of pages. For
  selective predicates, records are far fewer than pages and indexes win. For
  non-selective predicates, records approach pages and table scan wins. The
  crossover occurs at a selectivity of approximately $1 / B$, where $B$ is the
  number of records per page.

]
