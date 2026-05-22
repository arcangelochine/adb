#import "@preview/bookly:3.1.0": *

#let abs = [
  The four primary organizations studied so far—heap, sequential, hash, and
  B+-tree—each optimize a table's physical layout for one dominant access
  pattern, on one specific attribute. The B+-tree, when used as a _primary_
  organization, provides the data file itself in sorted order. But real
  workloads rarely concentrate all their queries on a single attribute. A table
  may be organized by family name yet queried constantly by age, by city, by
  salary, or by combinations of all four. The answer to this mismatch is the
  _secondary index_: an auxiliary data structure that accelerates access on an
  attribute without disturbing the primary layout. This chapter begins by
  clarifying the critical distinction between B+-trees used as primary
  organizations versus secondary indexes, then develops the full cost model for
  secondary indexes, distinguishing carefully between clustered and unclustered
  configurations and between unique and non-unique attributes. It introduces
  inverted lists for non-unique keys and the Cardenas formula for estimating
  page accesses. The chapter then extends the framework to conjunctive
  queries—queries that impose conditions on two or more attributes
  simultaneously—showing when two separate single-attribute indexes can be
  combined to answer such queries, and when a _multi-attribute index_ is
  preferable. The chapter closes with the problem of two-dimensional spatial
  data, where even the best multi-attribute index breaks down, and introduces
  the G-tree as a structure that preserves two-dimensional proximity under a
  one-dimensional ordering.
]

#chapter(title: "Indexes", abstract: abs, toc: true)[

  == Primary and Secondary Indexes

  A recurring source of confusion is the conflation of two very different uses
  of a B+-tree: as a _primary_ organization, where the data file itself is the
  B+-tree leaf level, versus as a _secondary_ organization, where the B+-tree is
  an index structure sitting beside a separately organized data file. The
  distinction matters enormously for query cost.

  When a B+-tree is the primary organization, the data is physically sorted on
  the indexed attribute. Range queries on that attribute are therefore cheap at
  any selectivity—reading 50% of the records requires reading 50% of the leaf
  pages, just as with a sequential file. This is the best possible behavior for
  range queries on one specific attribute, and it holds regardless of how large
  the selected range is.

  When a B+-tree index is used as a secondary organization over a heap file, the
  data is physically unsorted. The index can still narrow down which records
  match a predicate, but retrieving those records requires _random page
  accesses_ into the heap file. For range queries, this becomes expensive
  quickly: as the selectivity factor grows beyond roughly $1 / B$—where $B$ is
  the number of records per page—the cost of chasing individual RIDs through the
  heap exceeds the cost of a plain table scan. For a typical page holding 100
  records, this threshold sits near 1%. Range queries selecting more than 1% of
  records should generally not use an unclustered secondary index.

  #warning-box()[
    Do not confuse a B+-tree used as a _primary_ organization with a B+-tree
    used as a _secondary_ organization. In the primary case, data is physically
    sorted and range queries are efficient at any selectivity. In the secondary
    case, data is typically unsorted, and range queries become more expensive
    than a table scan once the selectivity factor exceeds a small threshold.
  ]

  Given this tension, a natural question arises: which primary organization
  should be chosen when queries span multiple attributes with no single dominant
  access pattern? The answer, in the vast majority of practical systems, is the
  heap file augmented with secondary indexes. The reasoning is straightforward.
  A primary B+-tree organization optimizes equality and range queries on one
  attribute but makes table scans more expensive, because the leaf file carries
  the overhead of 75-83% occupancy (hence pages contain 17-25% garbage). A heap
  file optimizes table scans—it is the most compact possible organization—but
  provides no fast access on any attribute. By pairing a heap file with one or
  more secondary indexes, a system gains _optimal table scan performance_ on any
  attribute alongside fast equality search on indexed attributes, at a cost of 2
  I/Os rather than 1: one for the index leaf and one for the data page. This
  modest increase from one to two I/Os for equality search is almost always an
  acceptable trade-off given the gains in flexibility, which is why
  heap-plus-index is the default design in virtually every relational database
  system.

  == Secondary Index Structures

  === Definition and Purpose

  An index constitutes a secondary organizational structure designed to
  _accelerate searches on specific attributes_. Formally, an index is a set of
  pairs $(k_i, r_i)$, where $k_i$ represents the value of the indexed attribute
  in record $r_i$, and $r_i$ is a record identifier (RID) that uniquely locates
  the record within the primary data file. An index provides a mapping from
  attribute values to the locations of records containing those values.

  The fundamental design decision in creating an index concerns which data
  structure to employ. Since indexes exist solely to speed up searches, neither
  heap nor sequential organization is appropriate. The choice reduces to
  hash-based structures versus tree-based structures, specifically B+-trees. The
  selection depends on workload characteristics. If range queries are never
  required and the data is highly static, a hash table may suffice. In practice,
  however, B+-trees are overwhelmingly preferred because they offer comparable
  equality search performance—particularly when the index fits in main
  memory—while also supporting range queries.

  === Clustered Versus Unclustered Indexes

  The distinction between _clustered_ and _unclustered_ indexes is critical for
  query cost estimation. An index is clustered when the primary data file is
  sorted according to the indexed attribute, or _nearly_ so (e.g. differential
  file). It is unclustered when the data bears no particular ordering relative
  to the index attribute (e.g. heap file).

  For equality searches, the difference between clustered and unclustered
  indexes is modest. Using an index to find a single record requires accessing
  the index leaf (typically one disk access, assuming upper levels are in
  memory) plus one access to the data page. This yields a total cost of two disk
  accesses, compared to one for a primary B+-tree organization. This cost is
  generally acceptable, which explains why heap organization plus secondary
  indexes remains a common design pattern.

  Range searches reveal a dramatic difference between clustered and unclustered
  indexes. With a clustered index, retrieving a fraction of the records, say 1%,
  typically requires reading approximately 1% of the data pages, because records
  with consecutive key values tend to reside on the same pages. This efficiency
  arises from the sorted arrangement of the data. With an unclustered index,
  however, records are scattered throughout the file. Each record may reside on
  a different page, so retrieving $k$ records may require $k$ separate page
  accesses, even if the total number of qualifying records is modest.

  The clustered case is relatively _rare_ in practice. The typical scenario for
  creating an index is precisely that the _data is not sorted_ on the indexed
  attribute. If the data were already sorted, a primary B+-tree would likely be
  used instead. Consequently, most indexes are unclustered, and their
  performance for range queries can be substantially worse than for clustered
  indexes.

  #info-box()[
    === Index Access Cost Model

    An index search costs $C = C_I + C_D$, where:
    - $C_I$: index traversal cost,
    - $C_D$: data access cost.

    _Equality search._ Both $C_I$ and $C_D$ are 1, since at most one record
    matches.

    _Range search._ For a predicate $phi$ with selectivity factor $s_f (phi)$:

    - _Clustered index:_ Leaf pages are scanned, then the matching data pages
      (which are physically contiguous) are read.

    $ C_"clustered" = s_f (phi) dot N_"LEAF" + s_f (phi) dot N_"PAG" $

    - _Unclustered index:_ Each matching record likely resides on a different
      page, so the data access cost explodes.

    $ C_"unclustered" = s_f (phi) dot N_"LEAF" + s_f (phi) dot N_"REC" $
  ]

  For unclustered range queries, this formula implies a crossover point around
  $s_f approx 1 / B$ where $B$ is the number of records per page. Beyond this
  selectivity threshold, a full table scan on the heap file is cheaper than
  using the index. For a typical page holding 100 records, this threshold is
  approximately 1%. Range queries selecting more than 1% of records should
  generally not use an unclustered index.

  === Indexes on Non-Unique Attributes: Inverted Lists

  The preceding discussion assumed that the indexed attribute is unique, so each
  index entry maps to exactly one record identifier. In practice, indexes are
  often built on attributes that are _not unique_—a city of birth, an exam
  grade, a department code—where each distinct value corresponds to a
  potentially long list of records.

  A note on terminology is warranted here. In the database implementation
  literature, the term _primary key_ refers to any unique attribute, and
  _secondary key_ to any non-unique attribute over which searches are performed.
  This usage is entirely independent of the relational notion of primary key as
  the target of foreign keys, and can be a persistent source of confusion.
  Throughout this section, "secondary key" simply means a non-unique search
  attribute.

  The standard data structure for indexing a secondary key is the _inverted
  list_, sometimes called an _inverted index_. The name reflects the direction
  of the mapping: ordinarily, given a record identifier one retrieves attribute
  values; an inverted list reverses this direction, mapping each distinct
  attribute value to the set of record identifiers of all records that carry it.
  For a `city` attribute, the structure might associate Florence with the single
  record $r_1$, Milan with the pair $r_3, r_5, r_6$, and Pisa with $r_2, r_4$.
  Each entry stores the attribute value once, followed by its list of RIDs,
  typically represented as a length-prefixed array with no separator between
  identifiers.

  #figure(image("../figures/chapter5/index_1.pdf"), caption: [
    Inverted list on the city attribute.
  ])

  The total space occupied by the inverted list has two components. The first is
  proportional to the number of distinct values: each value is stored exactly
  once, contributing $N_"KEY" times L_A$ bytes, where $N_"KEY"$ is the count of
  distinct values and $L_A$ is the byte length of the attribute. The second
  component is proportional to the total number of records: since every record
  contributes exactly one RID to some list, the aggregate RID storage is
  $N_"REC" times L_"RID"$ bytes. The number of leaf pages in the index is
  therefore

  $
    N_"LEAF" = ceil((N_"KEY" times L_A + N_"REC" times L_"RID") / (B_"page" times rho))
  $

  where $rho$ is the average page fill factor. Since $N_"REC"$ typically
  dominates $N_"KEY"$, the index size is driven primarily by the total record
  count rather than the number of distinct values.

  For an equality predicate on the indexed attribute the selectivity factor is
  $s_f = 1 / N_"KEY"$, and the expected number of matching records is
  $E_"REC" = N_"REC" / N_"KEY"$. The cost of reaching the correct entry in the
  index is one leaf page, assuming the upper levels are in memory. What happens
  next depends on whether the index is clustered and whether the RID list is
  sorted. In the clustered case, all matching records are physically adjacent,
  so the data access cost is $s_f times N_"PAG"$ pages—optimal. In the
  unclustered case with an unsorted RID list, each matching record may reside on
  a distinct page, giving a worst-case data access cost of $s_f times N_"REC"$
  page reads. The practically important intermediate case is an unclustered
  index whose RID lists are kept sorted: because the identifiers are ordered,
  the system never fetches the same page twice, and the actual cost is the
  number of distinct pages containing at least one matching record. This
  quantity is estimated by the Cardenas formula introduced in the following
  section.

  == Range Query Cost Estimation

  === The Cardenas Formula

  When retrieving multiple records through an unclustered index, the number of
  page accesses depends on the distribution of qualifying records across pages.
  If the record identifiers (RIDs) are sorted before fetching—a common
  optimization—the access pattern becomes: read a page if and only if it
  contains at least one qualifying record. This differs fundamentally from the
  unsorted case, where each record retrieval might read a page already accessed
  for a previous record.

  The _Cardenas formula_ provides an estimate of the number of distinct pages
  containing at least one qualifying record when retrieving $k$ records from a
  file of $n$ pages, assuming random distribution. The probability that a given
  page contains no qualifying records is the probability that all $k$ records
  land on other pages. For randomly distributed records, this probability is
  $p_0 = (1 - 1/n)^k$. The probability that a given page contains at least one
  qualifying record is therefore $1 - p_0$. The expected number of pages with at
  least one qualifying record is
  $ n times (1 - p_0) = n times (1 - (1 - 1/n)^k) $.

  This formula has two natural upper bounds: $k$, because one cannot read more
  pages than records, and $n$, because one cannot read more pages than exist in
  the file. The expected number is always less than or equal to the minimum of
  these two bounds.

  === Practical Approximations

  While the Cardenas formula provides an exact expectation under the random
  distribution assumption, a simpler approximation suffices for practical cost
  estimation. When the number of qualifying records $k$ is small relative to the
  number of pages $n$, the expected number of pages approximates $k$, because
  each record is likely to reside on a distinct page. When $k$ is large relative
  to $n$, the expected number of pages approximates $n$, because most pages will
  contain at least one qualifying record. Between these extremes, the Cardenas
  formula provides a smooth transition.

  For practical query optimization, the approximation $min(k, n)$ serves
  adequately. This approximation captures the essential behavior: when few
  records are retrieved, the cost scales with the number of records; when many
  records are retrieved, the cost scales with the number of pages. The exact
  formula, while interesting from a theoretical perspective, adds little to
  practical decision-making.

  #figure(image("../figures/chapter4/cardenas.pdf", width: 50%), caption: [
    Cardenas formula and its upper bound $min(k, n)$ for $n = 1000$ pages.
  ])

  == Non-Unique Index Cost Models

  The discussion of indexes in the previous chapter established the basic
  two-component cost model $C = C_I + C_D$, where $C_I$ is the cost of
  traversing the index itself and $C_D$ is the cost of fetching the matching
  records from the data file. For equality predicates on unique attributes this
  decomposition is trivial: at most one record matches, so both components are
  one page access each. The interesting and practically important case is range
  search on a non-unique attribute, where the number of matching records can be
  large and the interaction between the index structure and the data layout
  determines the cost.

  === Index Traversal Cost

  For any predicate $phi$, the cost of scanning the relevant portion of the
  index is

  $ C_I = ceil(s_f (phi) times N_"LEAF") $

  where $N_"LEAF"$ is the number of leaf pages in the index and $s_f (phi)$ is
  the selectivity factor of the predicate. Because the index is sorted on the
  indexed attribute, the qualifying entries occupy a contiguous segment of the
  leaf level, and that segment contains exactly $s_f times N_"LEAF"$ pages. The
  ceiling arises because even a very small selectivity factor requires reading
  at least one leaf page to determine that no records qualify.

  === Data Access Cost for Range Queries

  The number of key values that fall within a range predicate
  $phi = (v_1 <= A <= v_2)$ is

  $ E_"KEY" = ceil(s_f (phi) times N_"KEY") $

  where $N_"KEY"$ is the total number of distinct values stored in the index.
  For each such key value, the index supplies a RID list, and the cost of
  fetching the corresponding data pages depends on whether the index is
  clustered and whether the RID lists are sorted.

  When the index is _clustered_ and RID lists are sorted, all records sharing
  the same key value reside on the same contiguous region of the data file. The
  number of data pages that must be read for each key value is therefore at most

  $ C_D = ceil((N_"PAG" (R)) / N_"KEY") $

  that is, the total number of data pages divided evenly among the distinct key
  values. The total data access cost is then the product of the number of
  qualifying key values and the pages per key value, which simplifies to
  $s_f times N_"PAG"$—the same formula as for a primary B+-tree.

  When the index is _unclustered_ with sorted RID lists, records with the same
  key value are scattered across the data file. The number of pages that must be
  read to retrieve all records for one key value is estimated by the Cardenas
  formula applied to $(N_"REC" )(R) / N_"KEY"$ records distributed across
  $N_"PAG" (R)$ pages:

  $ C_D = ceil(Phi((N_"REC" (R)) / N_"KEY", N_"PAG" (R))) $

  where $Phi(k, n) = n (1 - (1 - 1/n)^k)$ is the expected number of distinct
  pages hit when drawing $k$ records uniformly at random from a file of $n$
  pages. Because the RID list is sorted, each page is read at most once even if
  it contains multiple qualifying records.

  When the index is unclustered with _unsorted_ RID lists, there is no such
  guarantee, and in the worst case each qualifying record requires a separate
  page read. The data access cost per key value becomes simply
  $C_D = ceil((N_"REC" (R)) / N_"KEY")$, and the total cost grows linearly with
  the number of qualifying records.

  #info-box()[
    === Range Query Cost Summary

    For a range predicate $phi = (v_1 <= A <= v_2)$ on attribute $A$ with
    selectivity factor $s_f$, the total cost of using a secondary index is
    $C_I + C_D$ where:

    $ C_I = ceil(s_f times N_"LEAF") $

    $
      C_D = ceil(s_f times N_"KEY") times cases(
        ceil(N_"PAG" / N_"KEY") & "clustered, sorted RIDs",
        ceil(Phi(N_"REC" / N_"KEY", N_"PAG")) & "unclustered, sorted RIDs",
        ceil(N_"REC" / N_"KEY") & "unclustered, unsorted RIDs"
      )
    $
  ]

  == Conjunctive Queries

  A conjunctive query imposes conditions on two or more attributes
  simultaneously, for example retrieving all employees whose age is between 30
  and 40 and whose salary exceeds 50,000. When separate indexes exist on each
  attribute, a natural approach is to use them in combination. The most
  selective index is consulted first: its RID list is loaded into main memory,
  sorted, and then used as a filter against which the second index's RID list is
  intersected. Only the RIDs that survive the intersection are then used to
  fetch actual records from the data file.

  This two-index strategy works well when the selectivity factors of the two
  conditions are very different. If one condition selects 0.1% of records and
  the other selects 40%, the first index reduces the candidate set to a tiny
  fraction before the second is applied. The dominant cost is determined by the
  more selective condition, and the less selective condition imposes only a
  cheap in-memory filtering step.

  The strategy degrades, however, at both extremes of the selectivity balance.
  When neither condition is particularly selective—say both select 30% of
  records—loading all the RIDs for either condition fills main memory with a
  large set that must then be intersected with another large set. The cost
  approaches that of a table scan, defeating the purpose of the indexes.
  Equally, when both conditions are extremely selective—each selecting one
  record in ten thousand—the situation is paradoxical: each individual RID list
  is tiny, but using only one of them to find the data and then filtering in
  memory with the other means reading ten thousand times more data pages than
  the final result actually requires. What is needed is a way to exploit both
  conditions simultaneously during the index lookup, so that only the records
  satisfying both predicates are ever retrieved from disk.

  === Update, Insert, and Delete Through an Index

  Before examining multi-attribute indexes, it is worth noting the cost of write
  operations when secondary indexes are present. Insertion requires writing the
  new record to the data file and inserting one entry into each index maintained
  on the table. If there are $k$ indexes, the total cost is one data write plus
  $k$ index updates, each costing approximately $h + 1$ I/Os for a B+-tree index
  of height $h$. Deletion requires locating the record—either through an index
  or by scan—removing it from the data file, and removing its entry from every
  index. Update is equivalent to a deletion followed by an insertion whenever
  the updated attribute is an indexed one. The practical implication is that
  maintaining many indexes on a frequently written table incurs a significant
  ongoing write overhead, and the decision to add an index must always weigh its
  read benefits against this write cost.

  The standard strategy for operations with a conjunction of conditions is to
  apply predicates in order of increasing selectivity factor: the most selective
  condition is evaluated first, and each subsequent condition filters a
  progressively smaller candidate set. This principle minimizes both the number
  of disk accesses and the volume of in-memory work, and it applies regardless
  of whether the predicates are served by indexes or evaluated directly against
  the data.

  == Multi-Attribute Indexes

  A _multi-attribute index_, sometimes called a combined index, is an index
  built on an ordered tuple of attributes rather than a single one. The entries
  in the index are sorted lexicographically on the tuple: first on the first
  attribute, and among entries with equal first attribute values, on the second
  attribute, and so on. This lexicographic ordering has profound consequences
  for which query shapes the index can serve efficiently.

  Consider a combined index on (age, salary). The leaf level of this index
  stores one entry for each distinct (age, salary) pair observed in the data,
  with the pairs arranged in ascending order of age and, within each age, in
  ascending order of salary. The RID list attached to each entry contains the
  identifiers of all records with that exact combination of age and salary.

  #figure(image("../figures/chapter5/index_2.pdf"), caption: [
    Multi-attribute index sorted on `age` and `salary`, RID-lists are not shown.
    Equality queries on `age` yield contiguous entries at the index leaf level,
    while equality queries on `salary` may not.
  ])

  === Query Shapes and Index Efficiency

  The utility of a combined index on $(A_1, A_2)$ depends critically on the
  shape of the query. When the predicate specifies only $A_1$—whether as an
  equality or a range—the qualifying entries form a contiguous segment of the
  index leaf level, just as they would in a single-attribute index on $A_1$. The
  combined index therefore subsumes the single-attribute index on the first
  attribute: once the combined index exists, a separate index on $A_1$ alone is
  redundant.

  When the predicate specifies equality on $A_1$ and any condition on
  $A_2$—equality or range—the qualifying entries again form a contiguous
  segment, because all entries with the fixed value of $A_1$ are grouped
  together, and within that group the entries are sorted by $A_2$. The combined
  index handles this shape optimally.

  The situation reverses for predicates that specify a range on $A_1$ and any
  condition on $A_2$. Within the range of $A_1$ values, the entries for
  different $A_1$ values each carry their own sorted $A_2$ sub-sequence. A
  condition on $A_2$ within this range does not correspond to a contiguous
  region of the index: for each distinct $A_1$ value, the matching $A_2$ entries
  are a contiguous sub-run, but these sub-runs are separated by the $A_2$
  entries for other $A_1$ values. The index traversal therefore jumps across
  many non-qualifying entries, and the cost approaches that of reading a
  significant fraction of the entire index leaf level.

  Worst of all is a predicate on $A_2$ alone. The entries for a given value of
  $A_2$ are distributed uniformly across the entire leaf level, one for each
  distinct value of $A_1$. The combined index provides no benefit over a full
  index scan for such a query.

  #info-box()[
    === Effective Query Shapes for a Combined Index on $(A_1, A_2)$

    The index traversal cost $C_I = ceil(s_f times N_"LEAF")$ holds—meaning the
    index is genuinely useful—only for predicates where the qualifying entries
    are contiguous in the leaf level. This is the case precisely when the
    predicate has one of the following forms.

    The predicate may impose any condition—equality or range—on $A_1$ alone,
    with no constraint on $A_2$ `(*,)`. It may impose equality on $A_1$ together
    with any condition on $A_2$ `(=,*)`. And it may impose equality on both
    $A_1$ and $A_2$ `(=,=)`. All other combinations, including a range on $A_1$
    with any condition on $A_2$ `(<>,*)`, a condition on $A_2$ alone `(,*)`, or
    a range on both attributes `(<>,<>)`, produce non-contiguous qualifying
    entries and therefore a higher traversal cost.

    The practical design rule follows: place the attribute with equality
    conditions first. If a workload mixes equality-age/range-salary queries and
    range-age/equality-salary queries, and only one combined index can be
    maintained, the index on (age, salary) serves the first shape well and the
    second shape poorly, while the index on (salary, age) does the opposite.
  ]

  == Bitmap Indexes

  Where inverted lists store, for each distinct attribute value, a list of the
  RIDs of matching records, a _bitmap index_ stores, for each distinct value, a
  bit vector of length $N_"REC"$—one bit per record in the table, set to one if
  and only if that record carries the corresponding value. The two
  representations encode identical information and, when the bitmap is
  compressed, occupy nearly identical space. Their difference lies in how they
  support conjunctive and disjunctive queries.

  Given two bitmap indexes on attributes $A$ and $B$, the set of records
  satisfying $A = v_1 and B = v_2$ is the bitwise `AND` of the two corresponding
  bit vectors. The set of records satisfying $A = v_1 or B = v_2$ is their
  bitwise `OR`. Modern processor architectures can perform these bitwise
  operations on 64 bits—or, with SIMD instructions, on 256 or 512 bits—in a
  single cycle. For queries that combine many conditions, bitmap intersection
  can be faster by orders of magnitude than intersecting sorted RID lists,
  because no pointer chasing or comparison is required: the answer is a simple
  arithmetic operation over arrays.

  The space cost of a bitmap index is the product of the number of distinct key
  values and the number of records, measured in bits:
  $(N_"KEY" times N_"REC") / 8$ bytes. The space cost of an inverted list index
  is dominated by the total number of RID entries, which is exactly $N_"REC"$
  (one RID per record), each occupying $L_"RID"$ bytes. Setting these equal:

  $ (N_"KEY" times N_"REC") / 8 = N_"REC" times L_"RID" $

  $ N_"KEY" = 8 times L_"RID" $

  With a four-byte RID, the _crossover point_ is $N_"KEY" = 32$. When the
  indexed attribute takes fewer than 32 distinct values, the bitmap index is
  more compact; when it takes more than 32 distinct values, the inverted list is
  more compact, and the advantage grows linearly with $N_"KEY"$.

  This analysis points to the natural domain of bitmap indexes: attributes with
  low cardinality, meaning a small and stable set of distinct values. A city
  attribute in a university database, a department code, a Boolean flag, an exam
  grade—these are all good candidates. An attribute like a personal identifier,
  a timestamp, or a continuous measurement is a poor candidate: the number of
  distinct values grows with the table, and the bitmap index grows
  _quadratically_.

  === Compression and the Equivalence with Inverted Lists

  When $N_"KEY"$ is large—the regime where bitmap indexes are spacious—each
  individual bit vector is very sparse, because only one record in $N_"KEY"$
  carries any given value. The probability that a randomly chosen bit is set to
  one is $1 / N_"KEY"$. Sparse bit vectors compress well under _run-length
  encoding_, a scheme that replaces each maximal run of identical bits with a
  pair (value, length). Applied to a sparse bitmap, run-length encoding amounts
  to recording the positions of the ones and the gaps between them.

  This observation has a striking consequence. A run-length encoded bitmap for a
  given value $v$ contains exactly one number per record that carries value
  $v$—the gap before it—plus one additional number for the final gap. The total
  storage is therefore one number per matching record, precisely as in the
  inverted list. A compressed bitmap index and an inverted list index are
  therefore the same data structure viewed from two different angles: the former
  records gaps between matching records, the latter records the positions of
  matching records directly. The difference between them is a trivial encoding
  choice, not a structural one.

  The practical implication is that the choice between a bitmap index and an
  inverted list is not a choice about stored data but about the in-memory
  representation used at query time. When many conditions must be combined,
  decompressing the relevant entries into full bit vectors and applying bitwise
  operations is often faster than merging sorted RID lists. When the conditions
  are few and highly selective, working directly with RID lists avoids the
  overhead of constructing full bit vectors. A well-engineered system may
  support both representations and choose between them based on the query.

  == Multi-Dimensional Indexing

  All indexes discussed so far impose a total linear order on the indexed
  attribute values. For a single numerical or string attribute this is entirely
  natural. For two-dimensional spatial data—latitude and longitude, or any pair
  of Cartesian coordinates—a linear order is an imperfect fit, and the standard
  approaches fail in ways that are worth understanding precisely.

  === Why Separate Indexes and Combined Indexes Both Fail

  Consider a table of restaurants, each with coordinates $(x, y)$. A proximity
  query asks for all restaurants within a rectangle: $x_1 <= x <= x_2$ and
  $y_1 <= y <= y_2$. This is a range-range conjunction: both conditions are
  interval predicates, and neither alone is particularly selective if the
  rectangle is small relative to the total extent of the data.

  Using two separate indexes, one on $x$ and one on $y$, works well only when
  one of the two conditions is much more selective than the other. In the
  restaurant example, a small rectangle selects perhaps one in a million
  restaurants overall, but the horizontal stripe $x_1 <= x <= x_2$ and the
  vertical stripe $y_1 <= y <= y_2$ each select approximately one in a thousand
  restaurants independently. Loading all the RIDs for either stripe requires
  loading one thousand times more RIDs than the final answer contains. The
  in-memory intersection of two lists of one thousand entries each is cheap, but
  fetching those one thousand RIDs from disk is wasteful.

  Using a combined index on $(x, y)$ is worse. The lexicographic ordering sorts
  restaurants first by $x$-coordinate and, within each $x$ value, by
  $y$-coordinate. Restaurants at coordinates $(x, y_1)$ and $(x, y_2)$ for the
  same $x$ are adjacent in the index, but restaurants at $(x_1, y)$ and
  $(x_2, y)$ for the same $y$—which are nearby in two-dimensional space—may be
  separated by the entire range of $y$ values for all intermediate $x$ values.
  In terms of the index, two restaurants that are ten meters apart north-south
  but at slightly different east-west positions can be separated by the entire
  contents of a vertical strip spanning thousands of kilometers. A range on $y$
  within a range on $x$ touches a non-contiguous set of index entries, and the
  traversal cost approaches $N_"LEAF"$—the cost of reading the entire index.

  The fundamental obstacle is that no continuous injection from two-dimensional
  space into a line can preserve two-dimensional proximity. Any linearization
  must place some pairs of nearby points far apart in the linear order. Standard
  indexes impose a linearization through lexicographic order, and for spatial
  data this linearization is particularly bad: the axis privileged by the first
  attribute completely determines proximity in the index, and the orthogonal
  direction is ignored.

  == The G-Tree

  The G-tree, designed for geographic or more generally two-dimensional data,
  replaces the lexicographic linearization with one that alternates between the
  two coordinate axes and thereby treats both dimensions more evenly. It does so
  in two phases: first _partitioning_ the two-dimensional space into pages, and
  then _ordering_ those pages along a one-dimensional curve that respects
  two-dimensional proximity as well as any linear ordering can.

  === Space Partitioning

  The first phase divides the plane recursively. At each step, the algorithm
  selects one axis and splits the current region along that axis at its
  midpoint, producing two sub-regions. Splitting alternates between the
  horizontal and vertical axes. The process continues until each region contains
  at most one page worth of data points—at most $C$ restaurants for a page
  capacity of $C$. Regions that already contain few enough points are left
  undivided; regions that contain too many are split further.

  #figure(image("../figures/chapter5/gtree_1.pdf"), caption: [
    G-Tree partitioning with page capacity $C = 2$. Splitting alternates between
    axes at the midpoint until each region contains at most two points.
  ])

  The result is a set of non-overlapping regions, each roughly rectangular, that
  together tile the entire plane. Because splitting alternates axes, no region
  is ever more than twice as long in one direction as in the other: every page
  covers a patch of space that is at most a 2:1 rectangle. This bounded aspect
  ratio is the key to the G-tree's proximity guarantee: two points in the same
  region are within a bounded distance of each other in both directions
  simultaneously, unlike the unbounded strips produced by lexicographic
  ordering.

  === Path Encoding

  Once the space is partitioned, each region is assigned a binary string called
  its _path_, which encodes the sequence of decisions made to reach that region
  during partitioning. At the root, the first split is horizontal or vertical
  and divides the space into a left (or bottom) half, coded 0, and a right (or
  top) half, coded 1. Each subsequent split appends another bit: 0 for the left
  or lower sub-region and 1 for the right or upper sub-region. A region reached
  by the decision sequence left, up, left, up has path 0, 1, 0, 1.

  To find the path of an arbitrary point $(x, y)$, the algorithm proceeds level
  by level. At each level it determines, for the current axis and the current
  midpoint of the remaining region, whether the coordinate falls below (0) or
  above (1) the midpoint, and appends the corresponding bit. The number of bits
  generated is the depth of the partition tree at which the point's region was
  first identified as a leaf. In practice, all paths are padded to a uniform
  length equal to the depth of the deepest leaf in the partition tree, either
  with zeros or with a designated padding symbol. The choice of padding symbol
  does not affect correctness.

  #figure(image("../figures/chapter5/gtree_2.pdf"), caption: [
    Path encoding for point $(20, 4)$. Left: the G-Tree partitioning, with the
    point's region highlighted. Right: the corresponding decision tree, where
    each split compares the point's coordinate to the current midpoint.
  ])

  === The Hilbert Curve and Why This Works

  When regions are ordered by their paths—interpreted as binary numbers, or
  equivalently visited in the preorder (depth-first, left-before-right)
  traversal of the partition tree—the resulting linear order traces a path
  through the plane known as a _space-filling curve_, closely related to the
  Hilbert curve. The essential property of this curve is that most consecutive
  steps along it are geometrically local: neighboring positions in the linear
  order correspond to nearby regions in the plane.

  The alternating-axis construction is what produces this locality. At each
  level of the tree, the split alternates between the horizontal and vertical
  directions. This means that the linear order gives equal weight to both
  coordinate axes: proximity in $x$ and proximity in $y$ are treated
  symmetrically. The contrast with lexicographic order is stark: in
  lexicographic order, a difference of $epsilon$ in the $x$ coordinate can
  separate two points by arbitrarily many positions in the linear order, because
  all points with $x' < x$ for any $x' in [x-epsilon, x)$ intervene. Under the
  path encoding, a difference of $epsilon$ in either coordinate can separate two
  points by at most one level of the partition tree, which corresponds to a
  bounded number of positions in the linear order.

  #figure(image("../figures/chapter5/gtree_3.pdf"), caption: [
    Space-filling curve induced by path ordering. Left: binary path labels on a
    $4 times 4$ grid. Right: the linear visitation order, showing how
    geometrically adjacent cells tend to appear near each other in the sequence.
  ])

  === Storage and Queries

  The G-tree is stored as a standard B+-tree whose key is the path of each
  region. The leaf level of the B+-tree contains one entry per region, holding
  the region's path and the collection of records (restaurants) within it. The
  internal nodes form the usual sparse index over these paths. No auxiliary
  structure—no partition tree, no spatial index hierarchy—needs to be stored on
  disk. The partition tree is a mental model for understanding the path
  computation; the only physical structure is the B+-tree.

  A point query for coordinates $(x, y)$ proceeds by computing the path of the
  query point using the same level-by-level algorithm, then performing a
  standard B+-tree lookup for that path. The computation of the path requires
  knowing the depth of the deepest leaf, which is a small integer stored as
  metadata.

  A range query for all points in a rectangle $[x_1, x_2] times [y_1, y_2]$
  proceeds as follows. The lower-left corner $(x_1, y_1)$ and the upper-right
  corner $(x_2, y_2)$ of the rectangle are used to compute the paths of the
  regions that contain these two points. The B+-tree is then scanned from the
  path of the lower-left region to the path of the upper-right region. All
  regions whose path falls in this interval are read, and for each record
  retrieved, the coordinates are checked against the query rectangle to discard
  false positives—records that lie in a region intersecting the query range but
  not within the rectangle itself.

  #figure(image("../figures/chapter5/gtree_4.pdf"), caption: [
    Range query $10 <= x <= 22.5$, $0 <= y <= 30$. Highlighted regions are those
    whose paths fall between the paths of the lower-left and upper-right
    corners; retrieved records are then filtered to discard false positives
    outside the rectangle.
  ])

  The false positive rate depends on the geometry of the query rectangle
  relative to the partition boundaries. In the best case, the query rectangle
  aligns with the partition boundaries and no false positives occur. In the
  worst case, the rectangle straddles several partition boundaries and some
  extra regions must be read. In practice, the false positive overhead is
  modest: the path ordering ensures that regions that are spatially nearby are
  close in the linear order, so the scan between the two endpoints covers
  primarily the regions that genuinely intersect the query area.

  === Insertion and Deletion

  Insertion into a G-tree follows the same logic as insertion into a standard
  B+-tree. The path of the new point is computed, the appropriate leaf is
  located, and the record is inserted there. If the leaf overflows, it is
  split—but splitting a leaf in the G-tree corresponds to refining the spatial
  partition: the region associated with the full leaf is divided along the next
  axis, and its records are distributed between the two new regions. The maximum
  path length increases by one, reflecting the deeper partition. All subsequent
  path computations use the updated depth.

  Deletion is symmetric: the record is located by its path, removed from the
  leaf, and if the leaf becomes too sparse it may be merged with its sibling,
  coarsening the partition. In both cases, the operations are entirely local,
  involving only a bounded number of pages, exactly as in a standard B+-tree.

  == Index Selection Strategies

  The three approaches to conjunctive queries—separate single-attribute indexes
  with RID-list intersection, multi-attribute combined indexes, and spatial
  indexes such as the G-tree—are not interchangeable. Each is suited to a
  different query shape.

  Separate indexes with intersection work well when one condition is
  substantially more selective than the other. The more selective index does
  most of the filtering work, and the second index or the data file itself
  handles the remainder. When neither condition is highly selective, or when
  both are extremely selective simultaneously, this approach is inefficient.

  Combined indexes work well when the predicate on the first attribute is an
  equality condition. They also handle predicates on the first attribute alone,
  and are strictly better than a separate single-attribute index for those
  queries. They fail for range conditions on both attributes—the case where
  spatial indexes are designed to excel.

  Spatial indexes such as the G-tree are optimized for range-range conjunctions
  on two attributes that represent coordinates in a metric space. They are the
  right choice whenever proximity in two dimensions is the dominant query
  pattern, and whenever neither lexicographic ordering nor a combined index can
  efficiently exploit the two-dimensional structure of the data. They are not
  the right choice for queries on a single attribute or for equality-range
  conjunctions, where a combined index is simpler and equally efficient.

  The underlying lesson is one that recurs throughout database design: the
  structure of the index must reflect the structure of the queries it is meant
  to accelerate. An index imposes a particular order or partition on the data,
  and queries that align with that structure are cheap while queries that cut
  across it are expensive. Understanding which queries your workload
  contains—and in what proportions—is therefore the prerequisite to choosing the
  right index type.

]
