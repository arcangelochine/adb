#import "@preview/bookly:3.1.0": *

#let abs = [
  When the workload consists overwhelmingly of single-key lookups, hash-based primary organization offers the promise of constant-time access—one page read in the ideal case. This chapter explores both static and dynamic hash techniques. We begin by analysing classic static hashing: the choice of loading factor, the probabilistic relationship between page size and overflow, and the principles of hash-function design. The central cost of static hashing is the eventual need for full-file reorganization, and we develop a design principle that recurs throughout all of database engineering—pay per page, not per record—together with the sorting trick that makes reorganization tractable. The second half of the chapter surveys the major families of dynamic hashing: virtual, extendable, linear, and spiral. Each is evaluated honestly for its density and distribution properties, and the conclusion is sobering: no dynamic hash algorithm has entirely solved the challenge of maintaining both high occupancy and bounded overflow. The chapter closes by positioning hashing as a powerful but narrow tool, fatally weak for range queries, and setting the stage for B-trees, which reconcile the demands of both point and interval access.
]

#chapter(title: "Hash Organization", abstract: abs, toc: true)[

  == Static Hash Organization

  Where the sequential organization optimizes for range queries by sorting data on a chosen attribute, _hash organization_ optimizes exclusively for equality search. It abandons any notion of ordering and instead distributes records across pages using a hash function computed on a designated key attribute. The result is a structure that can locate any record with a single page read under ideal conditions, but that is entirely blind to the relative order of keys and therefore useless for interval queries.

  === Parameters and the Loading Factor

  Static hash organization is defined by three parameters: the total number of records $N_"REC"$, the capacity of each page $C$, and the number of pages $M$ allocated for the file. The designer fixes $M$ before the file is created. A natural target is for the total capacity $M times C$ to be slightly larger than $N_"REC"$, leaving a small amount of free space in each page. The ratio

  $ d = N_"REC" / (M times C) $

  is called the _loading factor_ or _density_ of the hash table. It measures how full the file is, on average. A loading factor of 0.9 means pages are 90% full; a loading factor of 1.2 means the file is overloaded and 20% of records have spilled into overflow pages.

  #figure(image("../figures/chapter3/hash_1.pdf"), caption: [
    An hash organization with $M = 5$ pages and 2 overflow buckets.
  ])

  The loading factor embodies a fundamental trade-off. If it is too small, significant empty space exists in every page, wasting storage and inflating the cost of table scans. If it is too high, overflow becomes frequent, degrading access performance. Neither extreme is acceptable, and the right choice depends on the interplay between page capacity and the statistical properties of the hash function—a relationship that turns out to be subtler than it first appears.

  === Page Size and the Probability of Overflow

  The relationship between page capacity and overflow probability reveals a deep principle. When pages are small, even a modest loading factor leads to significant overflow. Consider a page with capacity for only three records, filled to two. The loading factor is already 67%, and a single additional collision causes overflow. The probability of that collision occurring is not negligible. But when pages are large—with capacity for 200 or 300 records—the same 90% loading factor produces a very different picture. Arriving at 400 records in a page that holds 300 is a far more improbable event than arriving at four records in a page that holds three. The variance of the occupancy distribution shrinks as the page grows larger, because each additional record is spread across a much wider probability space.

  // FIGURE SUGGESTION:
  // This is precisely the graph the professor describes: overflow probability on the
  // y-axis, page capacity on the x-axis, with a fixed density of 90%. The curve drops
  // steeply from around 20% overflow at capacity 5 to around 3% at capacity 30.
  // This figure is the visual heart of the overflow section and should appear here.

  The practical consequence is that disk-based hash tables, whose pages naturally hold tens or hundreds of records, enjoy far lower overflow rates than their main-memory counterparts for the same loading factor. In a main-memory hash table, each bucket holds exactly one record, so any collision is an overflow. On disk, a page holding 30 records at 90% density has an overflow probability of only a few percent. This is the statistical buffer that disk pages provide, and it is the reason that hash organizations can be operated at high density without catastrophic performance degradation.

  === Hash Function Design

  The hash function transforms a key into a page number in the range $[0, M-1]$. The typical construction applies a general-purpose transformation to the key—extracting bits from different parts of the string or integer and combining them through multiplication—and then takes the result modulo $M$. The requirement is that the function distribute records as uniformly as possible across pages, because any systematic bias concentrates records and drives up overflow in certain pages.

  Common pitfalls deserve explicit mention. If most keys end with a run of zeros, using only the final bytes of the key will produce a severely skewed distribution. Conversely, if most keys share a common prefix, using only the leading bytes is equally dangerous. A well-designed function mixes bits from across the entire key. A subtler pitfall concerns the choice of $M$: if the hash function happens to produce even numbers more often than odd, and $M$ is even, then after taking modulo $M$, only even pages will ever be selected, leaving half the file permanently empty. For this reason, $M$ is often chosen to be prime, though with large page capacities the overflow buffer effect makes this less critical in practice.

  === Overflow Management

  When more records hash to the same page than the page can hold, overflow must be managed. The simplest policy, and the one adopted here for analysis, allocates exactly one overflow page per primary page. If a primary page fills, a single dedicated overflow page is attached to it. With this policy, every page is either unoverflowed or has exactly one extra page; chains of two or three overflow pages do not occur.

  The cost model is straightforward. With a 10% overflow probability, 90% of equality searches read one page and 10% read two. The average cost is therefore approximately 1.1 page accesses—effectively constant. Even in the worst case, when a single key is so common that it fills three or four pages (imagine an extremely frequent family name in a table of people), the cost to retrieve all matching records is proportional to the number of pages those records occupy, which is optimal.

  === The Fatal Weakness: Range Queries

  Despite its excellence for equality search, hash organization is entirely unsuitable for range queries. The mechanism that achieves constant-time point access—distributing logically adjacent keys to unrelated pages—simultaneously destroys any spatial locality. Records with keys 100.001 and 100.002, which are adjacent in value, may reside on pages 47 and 831 respectively. A query requesting all records with key between 100 and 101 must therefore perform a full table scan, reading every page in the file. There is no alternative: the hash function provides no information about where records with nearby keys are stored.

  This limitation is not a deficiency in any particular design but an inherent consequence of the hash principle. Any function that achieves uniform distribution must necessarily scatter nearby keys, and any function that preserves proximity cannot achieve uniformity. Hash organization is therefore the right choice only when equality search dominates and range queries are either absent or rare enough to be handled by a table scan at acceptable cost.

  == Reorganization: Paying the Price of Static Organization

  The central cost of static hash organization is not paid on any individual query but accumulated silently over time: as records are inserted, the loading factor rises. At 100% density the file is full, at 120% overflow is widespread, and beyond 150% or 200% performance degrades to the point where reorganization becomes unavoidable. The file must be halted, a new value of $M$ chosen, and every record reloaded into the new structure.

  === The Naive Approach and Why It Fails

  The naive reorganization algorithm is a loop: scan the old file, and for each record apply the new hash function and insert the record into the new file. The scan of the old file is linear in $N_"PAG"$ and is unproblematic. The problem is with writing the new file. Records destined for the same output page arrive throughout the input scan, interleaved with records for every other page. If the output file does not fit in memory—the typical case—each output page must be loaded from disk, updated, and flushed back for every record that hashes to it. If a page holds $C$ records, it is loaded and flushed $C$ times: the write cost is $O(N_"REC")$, not $O(N_"PAG")$. For a page capacity of 100, this is a hundredfold penalty.

  The principle at stake is worth stating explicitly: in disk-based systems, the unit of cost is the page, not the record. An algorithm that performs one I/O per record is a hundred times worse than one that performs one I/O per page, and this difference dwarfs any constant-factor optimization. The challenge is to reorganize the file while paying the per-page price.

  === The Sorting Trick

  The solution is a three-phase algorithm that uses sorting as its core tool. Database systems sort data constantly, because external sorting can be performed in $O(N_"PAG")$ I/Os, and sorted data can be processed with a single sequential scan.

  In the first phase, the old file is scanned sequentially. For each record, a new entry is written to a temporary file containing the record together with the value of the new hash function. This produces a sequential file of decorated records at a cost of $2 times N_"PAG"$ I/Os (one read, one write).

  In the second phase, the temporary file is sorted on the hash address field. After sorting, all records that belong to the same output page are grouped together. The cost of external sort is $4 times N_"PAG"$ I/Os.

  In the third phase, the sorted temporary file is scanned sequentially. Because records are now in destination order, each output page is filled completely before moving to the next. Every output page is written exactly once. The cost is $2 times N_"PAG"$ I/Os (one read, one write).

  The total is $8 times N_"PAG"$ I/Os, compared to $O(N_"REC"$) for the naive approach—a factor of $C$ improvement for a page capacity of $C$.

  // FIGURE SUGGESTION:
  // A three-row pipeline diagram illustrating the three phases would clarify this well:
  // Phase 1: old file -> sequential scan -> temporary file (records + hash value)
  // Phase 2: temporary file -> sort on hash address -> sorted temporary file
  // Phase 3: sorted temporary file -> sequential scan -> new hash file
  // Annotate each arrow with its I/O cost. This diagram would sit naturally here,
  // between the description of the algorithm and the streaming optimization below.

  === Streaming and the Full Optimization

  The three-phase algorithm can be further optimized to $4 times N_"PAG"$ through _streaming_, a principle that recurs throughout database engineering. The key observation is that an intermediate file is necessary only when its producer writes records in one order and its consumer needs them in a different order. Wherever the producer and consumer agree on order, the file can be eliminated and replaced by a direct pipeline.

  Consider the third phase. The sorted temporary file is read sequentially and the output pages are written sequentially. The consumer—the code that writes the new hash file—is perfectly happy to receive records one at a time in sorted order rather than reading them from disk. The final write of the temporary file in phase two and the read in phase three can be fused: merge sort, which produces records in order, streams its output directly into the new hash file. This eliminates one read and one write, saving $2 times N_"PAG"$ I/Os.

  The same logic applies between phases one and two. The first phase reads records in arbitrary order, decorates them with their hash address, and passes them on. The sorting algorithm is equally happy to receive records as a stream rather than from a file—it does not care about the order of its input, only the order of its output. The write in phase one and the read in phase two can be fused, saving another $2 times N_"PAG"$ I/Os.

  The one phase that cannot be streamed is the sort itself, because sorting receives records in one order and produces them in another. The disk is essential here: without it there is no way to rearrange the data. But this is the only unavoidable intermediate storage, and it is already accounted for in the $4 times N_"PAG"$ cost of external sort.

  The final cost of the streaming reorganization is therefore $4 times N_"PAG"$, achieved by reading and writing every page exactly twice. This is the minimum possible for any algorithm that must rearrange the contents of a file on disk.

  == Dynamic Hashing Organizations

  The reorganization problem motivates _dynamic hashing_: a family of techniques that expand the hash file incrementally, page by page, avoiding any global rebuild. Over the past five decades, hundreds of dynamic hash variants have been proposed. Four are representative of the design space: virtual hash, extendable hash, linear hash, and spiral hash. None is fully satisfactory, which is the honest reason why practitioners rarely use dynamic hashing and instead reach for B-trees when a dynamic organization is required.

  === Virtual Hash

  Virtual hash begins from a simple observation: when a file doubles in size, the redistribution of records is especially clean. A record that mapped to page $k$ under modulo $M$ will map to either page $k$ or page $k + M$ under modulo $2M$. This means that only the records in page $k$ need to be examined; all other pages are unaffected. Doubling therefore enables per-page splitting without global reorganization.

  Virtual hash applies this doubling idea selectively. Rather than doubling the entire file when density becomes too high, it doubles individual pages on demand. The file maintains a _bitmap_ in main memory, with one bit per virtual page address, indicating whether each page has been allocated. At the start, all primary pages are allocated and all their doubles are not. When page 5 overflows, it is split: its records are redistributed between page 5 and page 12 (assuming $M = 7$), and both bits are set to 1. All other pages remain at modulo 7.

  // FIGURE SUGGESTION:
  // Two side-by-side states of the virtual hash bitmap would illustrate the split
  // operation clearly. Left state: seven pages (0--6) allocated, all at modulo 7.
  // Right state: after splitting page 5, pages 0--4, 5, 6, and 12 allocated; page 5
  // and 12 both at modulo 14, all others still at modulo 7. This makes the selective
  // doubling concrete and easy to follow.

  Finding a record in this structure requires knowing whether the relevant page has been split. The search algorithm starts with the largest active exponent and computes the hash modulo the corresponding size. If the bitmap shows the resulting page as allocated, the search proceeds to disk. If not, the exponent is decremented and the computation repeated. Because this traversal happens entirely in main memory—the bitmap is small and cached—its cost is zero in terms of disk I/Os, even when several iterations are needed.

  Virtual hash has two serious problems. The first concerns density. Every page begins its life at 50% occupancy immediately after a split, then fills to 100% before splitting again. The average occupancy over this cycle is 75%, which is disappointing. The very property that makes virtual hash appealing at first glance—zero overflow—is what causes this problem. Without any overflow tolerated, pages must be split the instant they reach 100%, the post-split occupancy to 50%.

  The second problem concerns the bitmap. For small files, keeping the bitmap in main memory is trivial. For large files, the bitmap can grow unwieldy. If it must be paged to disk, the cost of each lookup increases: instead of a zero-cost in-memory scan, the search may require reading one or more bitmap pages before the actual data page, potentially tripling the cost of an equality search.

  #info-box([
    Virtual hashing eliminates overflow entirely—and this turns out to be its greatest weakness. Because every page is split the instant it reaches capacity, each page spends exactly half its life between 50% and 100% full, giving an average occupancy of 75%. Tolerating a small amount of overflow would raise occupancy substantially. The lesson is that overflow and occupancy are not independent problems: solving one too aggressively worsens the other.
  ])

  === Extendable Hash

  Extendable hash is a variation of virtual hash that replaces the bitmap with a directory table. Rather than a single bit per virtual page, the directory contains one pointer per hash prefix, mapping each prefix to the physical page that currently holds records with that prefix. When a page is split, the directory doubles in size, and the two halves of the new directory point to the two new pages respectively, while all other entries are copied unchanged.

  The structural difference from virtual hash is modest: the directory occupies somewhat more space than a compressed bitmap, but it makes the lookup marginally simpler. The fundamental properties—average density of 75%, need to keep the directory in main memory, zero overflow—are identical. Extendable hash is best understood as an engineering variant of virtual hash rather than a conceptually distinct approach.

  === Linear Hash

  Linear hash abandons the on-demand splitting of virtual and extendable hash and instead splits pages in a fixed round-robin order. A pointer $P$ marks the boundary between pages that have been split in the current round and pages that have not. Whatever lies before $P$ has been split; whatever lies after $P$ has not.

  When an overflow occurs anywhere in the file, the response is to split the page at $P$ and advance the pointer—regardless of which page actually overflowed. This decoupling of the overflow trigger from the split location eliminates the need for any directory or bitmap; the single pointer $P$ is the only auxiliary structure required.

  // FIGURE SUGGESTION:
  // A timeline diagram showing the pointer P advancing across pages as splits occur
  // would be useful. Show the file at three moments: initial state with P at page 0,
  // after a few splits with P at page 3 (pages 0--2 split, pages 3 onwards not),
  // and after a full round with P back at page 0 and all pages having been split once.
  // This illustrates the round-robin nature of the algorithm.

  The more important advantage of linear hash is that it gives the designer direct control over the target density. Rather than being forced to split every page that reaches 100%, the designer can choose any threshold—say 90%—and split whenever the global density exceeds it. This allows the average loading factor to be set explicitly, trading off between overflow probability and table scan cost.

  Linear hash has its own distribution problem, however. At any moment, the file contains two populations of pages: those that have been split in the current round, which are near 50% full, and those that have not yet been split, which are near 100% full. The ideal of all pages sitting near the target density is never achieved; instead the distribution is always bimodal, with roughly half the pages uncomfortably full and the other half uncomfortably empty.

  === Spiral Hash

  Spiral hash addresses the distribution problem by using an exponential distribution rather than a uniform one. The hash function is designed so that the first page is approximately twice as likely to receive a new record as the last page, with intermediate pages following an exponential curve between these extremes. When a page at the dense end of the distribution is split, the two resulting pages each sit at the corresponding point on the same exponential curve. The shape of the distribution is therefore preserved across splits: at any moment, the density of each page is roughly in proportion to its expected load under the exponential function.

  The consequence is that roughly half the pages at any time sit within a reasonable range of the target density—neither dangerously full nor wastefully empty. The remaining half are concentrated at the two extremes, but the extremes are at least predictable and bounded. Compared to linear hash, where every page is at one of two bad extremes, spiral hash achieves a meaningfully better distribution.

  Despite this improvement, spiral hash is not a complete solution. Even in the best case, the densest page in the file is approximately twice as full as the sparsest page. This two-to-one ratio is an inherent feature of the exponential construction, not an implementation deficiency.

  === Why Dynamic Hashing Remains Unsatisfying

  The four techniques described above represent the best that dynamic hashing has achieved, and the honest assessment is that none of them is fully satisfactory. Virtual and extendable hash guarantee zero overflow but pay a chronic 75% average density. Linear hash offers density control but produces a permanently bimodal distribution. Spiral hash improves the distribution but cannot close the two-to-one gap between its densest and sparsest pages.

  The root cause is an asymmetry in the splitting operation. When a page splits, two pages are created from one, each at approximately 50% occupancy. For the total occupancy to recover to the target level, both new pages must fill to near 100% before the next split. This fill-and-split cycle inevitably produces variance in occupancy. The dynamic sequential organization avoids this problem through a different trick: when two adjacent pages are both sparse, they are merged into one, and when one is full, it is split in coordination with its neighbor so that both emerge at 66% rather than 50%. This three-halves trick raises the minimum occupancy from 50% to 66%, giving an average of 83% instead of 75%. No dynamic hash technique has found an equivalent mechanism, because hash pages have no natural notion of adjacency that would make coordinated merging and splitting tractable.

  The practical conclusion is simple. Static hash is the right choice when the file is nearly stable and equality search dominates. Dynamic hash is theoretically attractive but in practice too complicated and too imperfect. When a truly dynamic organization is required that also supports range queries, the B-tree is the correct answer, and the following chapter is devoted entirely to it.

]
