#import "@preview/bookly:3.1.0": *

#let abs = [
  The examination of heap files and sequential organizations reveals a persistent and seemingly irreconcilable tension. The heap achieves insertion costs approaching zero and perfect space efficiency, but at the price of search performance so catastrophic that it requires secondary indexes for any selective access. The sequential organization delivers logarithmic search and clustered range scans, but its insertion cost, in its pure form, is linear in the file size—a penalty so severe that it can only be mitigated through deliberate underpopulation of pages or periodic, system-stopping reorganizations. The question that naturally arises is whether a structure exists that transcends this dichotomy: a dynamic organization that maintains sorted order, supports both equality and range queries with logarithmic cost, and absorbs arbitrary sequences of insertions and deletions without ever requiring global reorganization. The _B-tree_ family, and its most practically significant variant the _B+-tree_, constitutes precisely such a structure. This chapter develops a rigorous cost-model analysis of these trees, examines their structural properties and behavioral guarantees, and situates them within the broader landscape of primary and secondary organizational strategies.
]

#chapter(title: "Tree Organization", abstract: abs, toc: true)[

  == Complementary Organizational Strategies

  The study of database systems reveals a fundamental truth about data organization on disk: _no single approach dominates all scenarios_. Instead, four primary organizational strategies—heap organizations, sequential files, hash-based structures, and tree-based structures—each occupy distinct niches characterized by their particular strengths and limitations. This chapter examines the fourth of these approaches, with particular attention to B-trees and their most practically significant variant, the B+-tree, while situating them within the broader context of data organization alternatives.

  The argument that unfolds throughout this analysis is that B-trees and B+-trees represent a sophisticated engineering compromise that achieves near-optimal performance across multiple dimensions simultaneously. Unlike hash-based organizations, which excel at equality searches but fail at range queries, or sequential files, which optimize range queries at the cost of expensive updates, tree-based structures provide efficient support for both access patterns while remaining highly dynamic and resistant to performance degradation over time. This combination of properties explains why B+-trees have become the dominant indexing structure in virtually all modern database systems.

  It is essential to recognize that these four organizational approaches _do not form a hierarchy_ from worst to best. Rather, each method possesses situations in which it excels and situations in which it performs poorly. The selection of an appropriate organization depends critically on the expected workload patterns—the types of queries most frequently executed, the frequency and pattern of insertions and deletions, and the relative importance of different performance metrics such as search time, update cost, and storage efficiency.

  // #figure(
  //   table(
  //     columns: (auto, 1fr, 1fr, 1fr, 1fr),
  //     align: center,
  //     fill: (x, y) => if y == 0 { rgb("2E75B6") } else if calc.odd(y) { rgb("EBF3FB") } else { white },
  //     table.header(
  //       text(fill: white, weight: "bold")[Organization],
  //       text(fill: white, weight: "bold")[Equality Search],
  //       text(fill: white, weight: "bold")[Range Search],
  //       text(fill: white, weight: "bold")[Insert],
  //       text(fill: white, weight: "bold")[Table Scan],
  //     ),
  //     [Heap], [$N_"PAG"$], [$N_"PAG"$], [$2$], [$N_"PAG"$],
  //     [Sequential], [$log_2 N_"PAG"$], [$log_2 N_"PAG" + s_f dot N_"PAG"$], [$N_"PAG"$], [$N_"PAG"$],
  //     [Hash], [$1$], [Not supported], [$1$–$2$], [$N_"PAG"$],
  //     [B+-tree], [$1$], [$1 + s_f dot N_"LEAF"$], [$h + 1$], [$N_"LEAF"$],
  //   ),
  //   caption: [Cost comparison of the four primary organizational strategies. Costs are expressed in disk I/Os. For the B+-tree, $N_"LEAF"$ denotes the number of leaf pages and $s_f$ the selectivity factor of the range predicate. The B+-tree table scan cost $N_"LEAF" > N_"PAG"$ for a heap, because leaf pages are only 75-83% full.],
  // )

  == The B-Tree

  // === Fundamental Properties and Definitions

  A B-tree of order $m$ constitutes a _search tree_ in which every node contains at most $m$ pointers to child nodes and, consequently, at most $m-1$ key-record pairs. The defining characteristic of this structure is its _maintenance of sorted order_ throughout the tree. Within any node, the keys appear in ascending order. Moreover, for any key $k$ in a given node, all keys in the left subtree are less than $k$, and all keys in the right subtree are greater than $k$. This recursive ordering property ensures that an inorder traversal of the tree yields all records in sorted order, a capability that proves essential for efficient range queries.

  Perhaps the most critical structural property of B-trees is that they remain _perfectly balanced by design_. All leaf nodes reside at exactly the same depth, meaning that the path length from the root to any leaf is constant for a given tree. This balance is not coincidental but is enforced through the splitting and merging algorithms that maintain every node at between 50% and 100% capacity, with the sole exception of the root, which may have as few as two children. More precisely, every node except the root contains at least $ceil(m/2)-1$ keys and at most $m-1$ keys.

  The concept of fan-out—the number of children per node—determines the tree's height and, consequently, its search performance. The number of pointers per node is bounded by $m$, and in practice, $m$ is chosen to match the page size of the storage system. With a fan-out of, say, 100, the tree's capacity grows exponentially with each level. A single node at the root level holds at most 99 records. Adding one level of intermediate nodes yields up to $100 times 99$ records at the second level, assuming each intermediate node has the maximum number of children. Adding a third level produces $100^2 times 99$ records, and so forth. This exponential growth means that even with modest fan-outs, B-trees become extremely shallow. The height $h$ of a B-tree is approximately logarithmic in the number of records, specifically $log_(m/2) N$ in the pessimistic case (when nodes are half full) or $log_m N$ in the optimistic case (when nodes are full).

  This logarithmic height directly translates into search efficiency. To locate a specific record, the search algorithm traverses from root to leaf, reading exactly one node per level. With a fan-out of 100, a tree containing one million records would have only three levels: a root node, one level of intermediate nodes, and the leaf level. In such a configuration, the vast majority of records—99% in this example—reside in the leaves. The cost of a typical equality search is therefore approximately $h$ disk accesses, where $h$ is the height of the tree.

  #figure(image("../figures/chapter4/btree_1.pdf"), caption: [
    B-tree of order $m = 5$. Each node represents a page containing between $ceil(m/2)-1 = 2$ and $m-1=4$ records together with $m=5$ pointers to child nodes. Leaf nodes have no children. Records were inserted by key in the following order: 1, 3, 5, 6, 7, 8, 9, 11, 13, 16, 18, 21, 22, 24, 25, 37, 42, 51. An asterisk beside a key denotes the record associated with that key. Mind that the root node is the only one with less than $2$ keys (records).
  ])

  === The Insertion Algorithm and Dynamic Growth

  The insertion algorithm reveals how B-trees maintain their balance _dynamically_ without requiring periodic reorganization. When inserting a _new_ record, the search procedure always terminates at a leaf node; there is no ambiguity about where the record belongs, as the sorted order uniquely determines its position. If the target leaf has available space, the record is inserted there with minimal overhead—essentially the cost of reading the leaf and writing it back.

  However, when the target leaf is already full, a _split_ operation occurs. Consider a leaf containing keys 3, 5, and 7, into which a new record with key 6 must be inserted. The node first collects all keys including the new one: 3, 5, 6, 7. It then splits this collection into two approximately equal halves, producing one leaf containing keys 3 and 5, and another containing keys 6 and 7. The median value, 5, is promoted to the parent node, along with a pointer to the newly created leaf.

  #figure(image("../figures/chapter4/btree_2.pdf"), caption: [
    The insertion of key 6 (underlined) caused the leftmost leaf to split; the median key, 5, was promoted to become the parent node.
  ])

  This promotion may _cascade_ upward. If the parent node has available space, the promoted key is inserted there, and the operation completes. If the parent is also full, it too must be split, with its median key promoted further upward. This cascade can continue all the way to the root. If the root itself must be split, a new root is created with a single key and two children, increasing the tree's height by one.

  The worst-case cost for an insertion is $h$ reads (to traverse the tree and find the insertion point) and $2h + 1$ writes (to write the modified nodes along the path, plus the new node created by each split). However, this worst case occurs extremely rarely. The expensive cascade of splits happens only when the tree transitions from one height to the next, which occurs after hundreds or thousands of insertions under normal circumstances. In the typical case, an insertion requires only $h$ reads to locate the leaf and a single write to update that leaf. This infrequency of expensive operations represents a significant advantage over hash-based structures, where reorganization may require rebuilding the entire table.

  #info-box([
    === How likely is the worst case?

    A B-tree of order $m$ grows in height only when the root splits. This happens via a cascade: if an insertion overflows a leaf (pushing it past $m-1$ keys), it splits and propagates a key upward; if that parent is also full, it splits too, and so on. The height increases only when this cascade reaches and splits the root.

    For this to happen, _every_ node on the path from root to leaf must already be full at the time of insertion. A node can legally hold anywhere from $ceil(m/2)-1$ to $m-1$ keys, giving $ceil(m/2)$ possible fill levels, of which only one is full. Assuming fill levels are roughly uniform, each node on the path is full with probability $approx 1 \/ ceil(m/2)$, and since all $h$ nodes must be full simultaneously:

    $ P("height increase") approx (1 / ceil(m/2))^h $

    For example, a B-tree of order $m = 100$ at height $h = 2$ gives:

    $ P approx (1/50)^2 = 0.0004 $

    So fewer than 1 in 2000 insertions would cause the tree to grow—and this probability shrinks exponentially as the tree gets taller.
  ])

  === Deletion and Rebalancing

  The deletion algorithm follows a logic symmetric to insertion. A crucial observation is that even when deleting a key from an internal node, the key's immediate successor exists in the leaf level. Therefore, deleting a key from an internal node requires _finding its successor_ in the leaf level, removing it, and promoting it to the internal position. Ultimately, all deletions actually occur at the leaf level.

  #figure(image("../figures/chapter4/btree_3.pdf"), caption: [
    Deletion of key 5 (underlined) from an internal node: key 5 is replaced by its inorder successor, key 6, which is promoted from the leaf.
  ])

  Once a leaf drops below the minimum occupancy threshold of 50%, _rebalancing_ becomes necessary. The standard approach is to merge the underfull leaf with a sibling. If the sibling has sufficient records, the two leaves are combined and their contents redistributed, potentially causing a deletion cascade upward as the separator key in the parent becomes unnecessary. Alternatively, if a sibling has records to spare, a _rotation_ operation may be performed: an element is moved from the sibling to the underfull leaf, avoiding the need for a merge. Rotation is generally preferred when possible, as it maintains higher page occupancy and delays future rebalancing operations.

  #figure(image("../figures/chapter4/btree_4.pdf"), caption: [
    Deletion of key 3 (underlined) from a leaf causing a merge: the leaf underflows and merges with its right sibling. The parent's separator key (the immediate successor of 3) is demoted into the merged leaf.
  ])

  The key insight is that B-trees are _self-organizing_. Extensive sequences of insertions and deletions can be performed—causing the file to grow and shrink repeatedly—without ever requiring a full reorganization of the structure. This stands in stark contrast to static hash tables or static sequential files, which require periodic reorganization to maintain acceptable performance as the data evolves.

  #figure(image("../figures/chapter4/btree_5.pdf"), caption: [
    Deletion of key 3 (underlined) from a leaf causing a rotation: the leaf borrows a key from its right sibling, which has spare capacity. The parent's separator key moves down into the leaf, and the smallest key of the right sibling is promoted to the parent.
  ])

  == The B+-Tree

  === Structural Distinctions

  The B+-tree represents a variation of the basic B-tree that has become the most commonly used implementation in practice. The fundamental change is that _all actual data records reside exclusively in the leaf nodes_. Internal nodes contain only keys and pointers—not full records. This separation has profound implications for both performance and storage efficiency.

  A useful way to conceptualize the B+-tree is as two distinct components. The leaf level forms a _dynamic sequential file_: a sorted collection of data pages linked together through pointers, enabling efficient sequential scans. The upper portion—all internal nodes—constitutes a _sparse index_ over these leaf pages. Each internal node entry contains a key and a pointer to a child node, with the implicit understanding that all records in the child's subtree have keys less than or equal to that key.

  The advantages of this design are substantial. Because internal nodes contain only keys and pointers, rather than full records with multiple attributes and potentially large variable-length fields, they are significantly more compact. A typical internal node entry might consist of a 4-byte integer key and a 4-byte page pointer, totaling 8 bytes. Given a page size of 4 kilobytes, a single page can contain approximately 500 such entries, yielding a fan-out of 500.

  This compactness produces remarkably flat trees. With a fan-out of 500, a B+-tree with just two levels (root and leaves) can index up to 500 pages of data. A three-level tree (root, one intermediate level, leaves) can index 250,000 pages. Assuming pages of 4 kilobytes, this corresponds to 1 gigabyte of data. A four-level tree can index 125 million pages, or 500 gigabytes. Thus, with only three or four levels, B+-trees can index databases of substantial size.

  The practical implication is that for all but the largest databases, the internal nodes of a B+-tree can be kept _entirely in main memory_. The typical cost for an equality search then reduces to a single disk access: reading the leaf page that contains the desired record. This performance matches that of hash-based organizations, but with the crucial additional capability of efficient range queries.

  #figure(image("../figures/chapter4/bptree_1.pdf"), caption: [
    B+-tree of order $m = 5$. Above the dashed line is the sparse index, a B-tree on the keys. Below the dashed line lies the sequential file, where the actual data records reside, grouped into pages. Records were inserted by key in the following order: 1, 3, 5, 6, 7, 8, 9, 11, 13, 16, 18, 21, 22, 24, 25, 37, 42, 51. Mind that the root node is the only one with less than $ceil(m/2)-1 = 2$ keys (not records).
  ])

  === Performance Characteristics and Trade-offs

  The cost of range queries in a B+-tree deserves careful examination. To retrieve all records with keys between a lower bound $L$ and an upper bound $U$, the algorithm first searches for $L$ in the index, locating the appropriate leaf page. It then follows the sibling pointers to read subsequent leaf pages until encountering a key greater than $U$. The total cost is the cost of the initial search (typically one disk access if the upper levels are in memory) plus the number of leaf pages that contain records in the desired range.

  This structure makes the B+-tree particularly well-suited for range queries. The cost grows linearly with the number of qualifying pages, not with the number of qualifying records. For large ranges, this is far more efficient than hash-based approaches, which would require probing each potential key individually.

  #info-box()[
    === Range Query Cost

    Given a query applying a range predicate $phi = [a_1, a_2]$ on the _sorting attribute_ $A$ used to build the B+-tree on table $T$, its cost is given by:

    $ 1 + s_f (phi) times N_"PAG" "I/Os" $
  ]

  It is important to note that this efficiency applies only when the B+-tree is used as the _primary_ organization—that is, when the data itself is physically sorted on the indexed attribute. In this case, even a range predicate selecting 50% of the records costs just 50% of the leaf pages. This is a much stronger guarantee than what secondary indexes can offer, as discussed in the following section.

  === Storage Efficiency and the Page Occupancy Trade-off

  The B+-tree introduces a trade-off regarding storage efficiency that follows directly from its splitting policy. When a page fills to 100% capacity and receives a new record, it splits into two pages each at 50% occupancy. The page then fills gradually back toward 100% before splitting again. Averaged over this cycle, the expected occupancy of any given page is $(50\% + 100\%) / 2 = 75\%$, meaning roughly one quarter of every page is wasted space, making the leaf file larger than an equivalent heap or static sequential file.

  A practical optimization known as _rotation_ can raise the minimum occupancy and therefore the average. When a page would split, the system first attempts to redistribute records with a neighboring sibling. Only if the sibling is also full does a true split occur, at which point three pages are produced from the two full ones, each at approximately 66% occupancy. With this policy, no page ever drops below 66%, giving an average of $(66\% + 100\%) / 2 approx 83\%$—substantially better than 75%, though still below the density of a static file.

  #warning-box()[
    B+-trees typically achieve only $~83%$ average page occupancy. A full table scan on a non-sorting attribute therefore reads more pages than the equivalent heap file would require for the same data, since roughly 17% of every leaf page is unused space. This overhead is acceptable only when queries on the indexed attribute are sufficiently selective to justify the organization.
  ]

  The consequence for query planning is significant. A table scan on a B+-tree organized file reads $N_"LEAF"$ pages, which exceeds the $N_"PAG"$ pages a compact heap file would require for the same data. This is the price paid for fast equality and range access on the primary attribute. When table scans on arbitrary attributes are frequent and important, a heap organization may be preferable—augmented by secondary indexes for the attributes that require fast lookup.

  == Primary vs. Secondary Organization: A Critical Distinction

  A recurring source of confusion is the conflation of two very different uses of a B+-tree: as a _primary_ organization, where the data file itself is the B+-tree leaf level, versus as a _secondary_ organization, where the B+-tree is an index structure sitting beside a separately organized data file. The distinction matters enormously for query cost.

  When a B+-tree is the primary organization, the data is physically sorted on the indexed attribute. Range queries on that attribute are therefore cheap at any selectivity—reading 50% of the records requires reading 50% of the leaf pages, just as with a sequential file. This is the best possible behavior for range queries on one specific attribute, and it holds regardless of how large the selected range is.

  When a B+-tree index is used as a secondary organization over a heap file, the data is physically unsorted. The index can still narrow down which records match a predicate, but retrieving those records requires random page accesses into the heap file. For range queries, this becomes expensive quickly: as the selectivity factor grows beyond roughly $1 / B$—where $B$ is the number of records per page—the cost of chasing individual RIDs through the heap exceeds the cost of a plain table scan. For a typical page holding 100 records, this threshold sits near 1%. Range queries selecting more than 1% of records should generally not use an unclustered secondary index.

  #warning-box()[
    Do not confuse a B+-tree used as a _primary_ organization with a B+-tree used as a _secondary_ organization. In the primary case, data is physically sorted and range queries are efficient at any selectivity. In the secondary case, data is typically unsorted, and range queries become more expensive than a table scan once the selectivity factor exceeds a small threshold.
  ]

  Given this tension, a natural question arises: which primary organization should be chosen when queries span multiple attributes with no single dominant access pattern? The answer, in the vast majority of practical systems, is the heap file augmented with secondary indexes. The reasoning is straightforward. A primary B+-tree organization optimizes equality and range queries on one attribute but makes table scans more expensive, because the leaf file carries the overhead of 75–83% occupancy. A heap file optimizes table scans—it is the most compact possible organization—but provides no fast access on any attribute. By pairing a heap file with one or more secondary indexes, a system gains optimal table scan performance on any attribute alongside fast equality search on indexed attributes, at a cost of two I/Os rather than one: one for the index leaf and one for the data page. This modest increase from one to two I/Os for equality search is almost always an acceptable trade-off given the gains in flexibility, which is why heap-plus-index is the default design in virtually every relational database system.

  == Indexes as Secondary Organizational Structures

  === Definition and Purpose

  An index constitutes a secondary organizational structure designed to _accelerate searches on specific attributes_. Formally, an index is a set of pairs $(k_i, r_i)$, where $k_i$ represents the value of the indexed attribute in record $r_i$, and $r_i$ is a record identifier (RID) that uniquely locates the record within the primary data file. An index provides a mapping from attribute values to the locations of records containing those values.

  The fundamental design decision in creating an index concerns which data structure to employ. Since indexes exist solely to speed up searches, neither heap nor sequential organization is appropriate. The choice reduces to hash-based structures versus tree-based structures, specifically B+-trees. The selection depends on workload characteristics. If range queries are never required and the data is highly static, a hash table may suffice. In practice, however, B+-trees are overwhelmingly preferred because they offer comparable equality search performance—particularly when the index fits in main memory—while also supporting range queries.

  === Clustered Versus Unclustered Indexes

  The distinction between _clustered_ and _unclustered_ indexes is critical for query cost estimation. An index is clustered when the primary data file is sorted according to the indexed attribute, or nearly so. It is unclustered when the data bears no particular ordering relative to the index attribute.

  For equality searches, the difference between clustered and unclustered indexes is modest. Using an index to find a single record requires accessing the index leaf (typically one disk access, assuming upper levels are in memory) plus one access to the data page. This yields a total cost of two disk accesses, compared to one for a primary B+-tree organization. This cost is generally acceptable, which explains why heap organization plus secondary indexes remains a common design pattern.

  Range searches reveal a dramatic difference between clustered and unclustered indexes. With a clustered index, retrieving a fraction of the records, say 1%, typically requires reading approximately 1% of the data pages, because records with consecutive key values tend to reside on the same pages. This efficiency arises from the sorted arrangement of the data. With an unclustered index, however, records are scattered throughout the file. Each record may reside on a different page, so retrieving $k$ records may require $k$ separate page accesses, even if the total number of qualifying records is modest.

  The clustered case is relatively _rare_ in practice. The typical scenario for creating an index is precisely that the _data is not sorted_ on the indexed attribute. If the data were already sorted, a primary B+-tree would likely be used instead. Consequently, most indexes are unclustered, and their performance for range queries can be substantially worse than for clustered indexes.

  #info-box()[
    === Index Access Cost Model

    An index search costs $C = C_I + C_D$, where:
    - $C_I$: index traversal cost,
    - $C_D$: data access cost.

    *Equality search.* Both $C_I$ and $C_D$ are 1, since at most one record matches.

    *Range search.* For a predicate $phi$ with selectivity factor $s_f (phi)$:

    - *Clustered index:* Leaf pages are scanned, then the matching data pages (which are physically contiguous) are read.

    $ C_"clustered" = s_f (phi) dot N_"LEAF" + s_f (phi) dot N_"PAG" $

    - *Unclustered index:* Each matching record likely resides on a different page, so the data access cost explodes.

    $ C_"unclustered" = s_f (phi) dot N_"LEAF" + s_f (phi) dot N_"REC" $
  ]

  For unclustered range queries, this formula implies a crossover point around $s_f approx 1 / B$ where $B$ is the number of records per page. Beyond this selectivity threshold, a full table scan on the heap file is cheaper than using the index. For a typical page holding 100 records, this threshold is approximately 1%. Range queries selecting more than 1% of records should generally not use an unclustered index.

  === Indexes on Non-Unique Attributes: Inverted Lists

  The preceding discussion assumed that the indexed attribute is unique, so each index entry maps to exactly one record identifier. In practice, indexes are often built on attributes that are not unique—a city of birth, an exam grade, a department code—where each distinct value corresponds to a potentially long list of records.

  A note on terminology is warranted here. In the database implementation literature, the term _primary key_ refers to any unique attribute, and _secondary key_ to any non-unique attribute over which searches are performed. This usage is entirely independent of the relational notion of primary key as the target of foreign keys, and can be a persistent source of confusion. Throughout this section, "secondary key" simply means a non-unique search attribute.

  The standard data structure for indexing a secondary key is the _inverted list_, sometimes called an inverted index. The name reflects the direction of the mapping: ordinarily, given a record identifier one retrieves attribute values; an inverted list reverses this direction, mapping each distinct attribute value to the set of record identifiers of all records that carry it. For a `city` attribute, the structure might associate Florence with the single record $r_1$, Milan with the pair $r_3, r_5$, and Pisa with $r_2, r_4, r_6$. Each entry stores the attribute value once, followed by its list of RIDs, typically represented as a length-prefixed array with no separator between identifiers.

  The total space occupied by the inverted list has two components. The first is proportional to the number of distinct values: each value is stored exactly once, contributing $N_"KEY" times L_A$ bytes, where $N_"KEY"$ is the count of distinct values and $L_A$ is the byte length of the attribute. The second component is proportional to the total number of records: since every record contributes exactly one RID to some list, the aggregate RID storage is $N_"REC" times L_"RID"$ bytes. The number of leaf pages in the index is therefore

  $ N_"LEAF" = ceil((N_"KEY" times L_A + N_"REC" times L_"RID") / (B_"page" times rho)) $

  where $rho$ is the average page fill factor. Since $N_"REC"$ typically dominates $N_"KEY"$, the index size is driven primarily by the total record count rather than the number of distinct values.

  For an equality predicate on the indexed attribute the selectivity factor is $1 / N_"KEY"$, and the expected number of matching records is $N_"REC" / N_"KEY"$. The cost of reaching the correct entry in the index is one leaf page, assuming the upper levels are in memory. What happens next depends on whether the index is clustered and whether the RID list is sorted. In the clustered case, all matching records are physically adjacent, so the data access cost is $s_f times N_"PAG"$ pages—optimal. In the unclustered case with an unsorted RID list, each matching record may reside on a distinct page, giving a worst-case data access cost of $s_f times N_"REC"$ page reads. The practically important intermediate case is an unclustered index whose RID lists are kept sorted: because the identifiers are ordered, the system never fetches the same page twice, and the actual cost is the number of distinct pages containing at least one matching record. This quantity is estimated by the Cardenas formula introduced in the following section.

  == Estimating Page Accesses for Range Queries

  === The Cardenas Formula

  When retrieving multiple records through an unclustered index, the number of page accesses depends on the distribution of qualifying records across pages. If the record identifiers (RIDs) are sorted before fetching—a common optimization—the access pattern becomes: read a page if and only if it contains at least one qualifying record. This differs fundamentally from the unsorted case, where each record retrieval might read a page already accessed for a previous record.

  The _Cardenas formula_ provides an estimate of the number of distinct pages containing at least one qualifying record when retrieving $k$ records from a file of $n$ pages, assuming random distribution. The probability that a given page contains no qualifying records is the probability that all $k$ records land on other pages. For randomly distributed records, this probability is $p_0 = (1 - 1/n)^k$. The probability that a given page contains at least one qualifying record is therefore $1 - p_0$. The expected number of pages with at least one qualifying record is $ n times (1 - p_0) = n times (1 - (1 - 1/n)^k) $.

  This formula has two natural upper bounds: $k$, because one cannot read more pages than records, and $n$, because one cannot read more pages than exist in the file. The expected number is always less than or equal to the minimum of these two bounds.

  === Practical Approximations

  While the Cardenas formula provides an exact expectation under the random distribution assumption, a simpler approximation suffices for practical cost estimation. When the number of qualifying records $k$ is small relative to the number of pages $n$, the expected number of pages approximates $k$, because each record is likely to reside on a distinct page. When $k$ is large relative to $n$, the expected number of pages approximates $n$, because most pages will contain at least one qualifying record. Between these extremes, the Cardenas formula provides a smooth transition.

  For practical query optimization, the approximation $min(k, n)$ serves adequately. This approximation captures the essential behavior: when few records are retrieved, the cost scales with the number of records; when many records are retrieved, the cost scales with the number of pages. The exact formula, while interesting from a theoretical perspective, adds little to practical decision-making.

  #figure(image("../figures/chapter4/cardenas.pdf", width: 50%), caption: [
    Cardenas formula and its upper bound $min(k, n)$ for $n = 1000$ pages.
  ])

  == Broader Implications and Conceptual Lessons

  The study of B-trees and B+-trees reveals several fundamental principles that inform database design more broadly. First, no organizational structure dominates all scenarios. Each approach—heap, sequential, hash, and tree-based—possesses distinctive strengths and weaknesses that make it suitable for particular workloads. The designer's task is to match the structure to the expected access patterns.

  Second, trade-offs are inherent in database design. Storage efficiency, query performance, and update performance cannot all be optimized simultaneously. The B+-tree sacrifices storage density for dynamic flexibility and fast searches, a trade-off that proves beneficial for many applications but would be inappropriate in contexts where storage is the primary constraint.

  Third, practical cost estimation requires understanding the shape of cost functions rather than memorizing exact formulas. The approximation of the Cardenas formula by the minimum of $k$ and $n$ captures the essential behavior while remaining simple enough for practical use.

  Fourth, awareness of the memory hierarchy is crucial. The observation that upper levels of a B+-tree typically fit in main memory transforms the performance analysis, making equality searches cost approximately one disk access regardless of tree height. This insight depends on understanding both the structure's fan-out and the realistic size of main memory in contemporary systems.

  Finally, probabilistic thinking informs cost estimation. Query costs are inherently probabilistic, requiring understanding of expected values and distributions rather than deterministic guarantees. The Cardenas formula exemplifies this probabilistic approach, modeling the expected number of page accesses under assumptions about record distribution.

  The B+-tree's dominance in practice stems from its successful navigation of these trade-offs. By providing near-optimal performance for both equality and range queries, remaining highly dynamic without requiring reorganization, and achieving sufficient storage efficiency for most applications, the B+-tree has earned its position as the default indexing structure in virtually all modern database systems.

]
