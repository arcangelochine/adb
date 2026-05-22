#import "@preview/bookly:3.1.0": *

#let abs = [
  The _Buffer Manager_ is a core component of a Database Management System
  (DBMS) responsible for efficiently managing the movement of data between disk
  storage and main memory. This chapter examines the role of the Buffer Manager
  in _minimizing disk I/O_, which is one of the primary performance bottlenecks
  in database systems. It introduces the concept of the buffer pool, where pages
  are temporarily stored in memory, and discusses key mechanisms such as page
  replacement policies, pinning and unpinning of pages, and dirty page handling.
  The chapter also explores common strategies like Least Recently Used (LRU) and
  Clock replacement, highlighting their trade-offs in terms of performance and
  implementation complexity. Additionally, it addresses concurrency
  considerations and coordination with other DBMS components such as the
  transaction manager and recovery system. By understanding how the Buffer
  Manager operates, readers gain insight into how modern DBMSs achieve efficient
  data access and maintain consistency under heavy workloads.
]

#chapter(title: "Buffer Manager", abstract: abs, toc: true)[

  == Persistent Storage

  To understand the critical role of the Buffer Manager, we must first
  appreciate the fundamental characteristics of the storage landscape it
  navigates. A computer system presents its processor with a stark dichotomy: a
  fast, expensive, and _volatile_ main memory, and a slow, cheap, and
  _persistent_ storage layer. The processor can only operate on data that
  resides in the main memory; data lying dormant on persistent storage is, from
  the perspective of computation, inert and inaccessible until it is first
  copied into memory. This constraint, when combined with the economic reality
  that the vast majority of an organization's data must be housed on the cheaper
  persistent medium, gives rise to the central organizing principle of any
  data-intensive system. You constantly shuttle the small, currently needed
  pieces of data from the slow, persistent world into the fast, volatile one.

  This memory hierarchy is not a simple two-tier structure but a spectrum of
  technologies, each with different physical properties that dictate how a DBMS
  must interact with them.

  === Memory Formats

  The traditional, and still economically vital, form of persistent storage is
  the magnetic _hard disk drive_ (HDD). Its defining characteristic is its
  mechanical nature. Data is stored on spinning platters and accessed by a
  physical arm that must swing into position. This mechanical reality imposes an
  access latency measured in milliseconds, a truly immense duration for a
  processor that can execute millions of operations in the same interval.
  Because the cost of positioning the arm and waiting for the platter to rotate
  is so high, it would be ruinously inefficient to read or write just a few
  bytes at a time. Instead, once the mechanism is in the right place, the system
  reads a substantial, fixed-size block of data, which we universally term a
  _page_ (or sometimes a block). The page thus becomes the atomic unit of
  transfer to and from a disk. A direct consequence of this design is a crucial
  principle of physical database organization: data items that applications
  frequently access together should be stored together within the same page to
  amortize the enormous seek and rotational delays.

  A more modern entry in the storage hierarchy is _flash memory_, which forms
  the basis of _Solid-State Drives_ (SSDs). This technology is purely
  electronic, based on "solid-state physics" with no mechanical parts. By
  eliminating mechanical delays, SSDs offer speeds and costs that place them in
  a logarithmic sense midway between traditional RAM and magnetic disks.
  Notably, they are still persistent storage. Despite this fundamentally
  different physical nature, for technical reasons outside our immediate
  scope—having to do with wear-leveling algorithms that map virtual to physical
  addresses to prevent memory cells from burning out—flash memory is also
  architected to be read and written one page at a time. This convergence on a
  page-based software interface, whether for a spinning disk or a solid-state
  drive, allows the higher levels of the DBMS to manage them with a unified
  abstraction. In modern data centers, a storage hierarchy often includes a mix
  of SSDs for more frequently accessed "hot" data and larger pools of
  traditional HDDs for less-used "cold" data. For the remainder of this
  discussion, any reference to a "disk" should be understood as a convenient
  shorthand for this generic, page-based, persistent storage layer.

  == The Buffer

  The DBMS component designed to manage the constant, page-level shuttling of
  data between the fast main memory and the slow disk is the Buffer Manager. Its
  fundamental purpose is to create the illusion that all the necessary data is
  readily available in memory while using only a small, allocated portion of
  main memory called the _buffer pool_ to cache a subset of the much larger
  database on disk. It achieves this by maintaining a mapping between pages on
  disk, identified by a _Page ID_, and frames in the buffer pool, identified by
  a _Frame ID_. When a client module, such as the Storage Manager or Access
  Method Manager, needs to operate on a disk page, it engages the Buffer Manager
  with a "_get and pin_" request. If the requested page is already present in a
  buffer frame, the manager simply increments a counter associated with that
  frame and returns its memory address. If not, it must find a suitable
  frame—perhaps by reclaiming one that is no longer in active use—read the
  requested page from disk into that frame, record the new mapping, and then
  return the address.

  === Pinning

  The "get and pin" protocol is the core contract between the Buffer Manager and
  its clients. The act of pinning a page serves as a guarantee: as long as a
  client holds a pin on a page, it can be absolutely certain that the page will
  not be evicted from its memory frame. The client is free to read and
  manipulate the data at the given memory address without fear of it
  disappearing. The protocol is implemented as a simple _pin count_. The first
  client to request a page causes it to be loaded and its pin count set to 1. If
  a second, concurrent client requests the same page, the Buffer Manager, seeing
  the page is already resident, merely increments the pin count to 2 and returns
  the same frame address to the second client. This mechanism elegantly handles
  shared access without redundant I/O. The client's reciprocal obligation is to
  release the page when it is finished, a process called _unpinning_, which
  decrements the counter. A page is only ever a candidate for eviction when its
  pin count falls back to 0. The general rule for a well-behaved client is to
  never hold a pin for longer than absolutely necessary: pin the page, perform
  the immediate operation, and then unpin it immediately.

  === Dirty Bit

  The complexity of buffer management increases significantly when we move
  beyond read-only access. If a client modifies a page while it is pinned in
  memory, the version of the page in the buffer pool becomes different from the
  version on disk. The responsibility for signaling this divergence falls on the
  client. Before unpinning a page it has modified, the client must call a "_set
  dirty_" function. This call sets a _dirty bit_ on the frame, a flag that tells
  the Buffer Manager, "This page is now different from its on-disk counterpart."

  This flag fundamentally changes the eviction calculus. When a clean page is
  evicted, its frame can simply be overwritten with new data from disk. However,
  if the Buffer Manager chooses a frame with its dirty bit set for eviction, it
  cannot simply discard the contents. It must first copy, or flush, the modified
  page back to its original location on disk to make the modification
  persistent. Only after this flush operation is complete can the frame's dirty
  bit be reset to zero and the frame safely reused for another page. The
  management of this dirty state creates a critical tension, leading to the
  different replacement and writing policies that distinguish the performance
  and reliability characteristics of a DBMS.

  == Replacement Policies

  When a new page must be brought into the buffer pool and all frames are
  occupied, the Buffer Manager must decide which resident page to _evict_. This
  decision is governed by a _replacement policy_. The selection is always
  restricted to frames with a pin count of zero, as evicting a pinned page would
  break the contract with its client. Among the unpinned, clean pages, or dirty
  pages that have been flushed, the choice of which to victimize is a strategic
  one that can dramatically affect performance.

  The canonical policy in general operating systems is _Least Recently Used_
  (_LRU_). It operates on the temporal locality principle: the page that has
  gone unused for the longest time is the one least likely to be needed again
  soon. While effective in many scenarios, a DBMS has deep knowledge of its own
  data access patterns and can do better. For instance, a sequential scan of a
  large table will read every page exactly once. Using LRU during such a scan is
  catastrophic, as it would evict the actively used pages of other queries to
  make room for pages the scan will never revisit. The perfect policy for this
  operation is the opposite one, _Most Recently Used_ (_MRU_) , which corrals
  the scan into a single frame, repeatedly replacing the just-read page with the
  next one. This example illustrates that DBMS buffer managers often use
  dynamically chosen or hint-guided policies rather than relying on a
  one-size-fits-all approach.

  The decision of when to write a dirty page to disk is equally critical and is
  managed by a _write policy_, creating a trade-off between system throughput
  and data durability. Two extremes define the spectrum.

  === Eager Policy (Write-Through)

  The most eager approach is the _write-through_ policy. Here, every time a
  client modifies a page in the buffer and sets the dirty bit, the Buffer
  Manager immediately schedules a synchronous write to disk. This guarantees an
  exact mirror of the modified data on persistent storage at all times. In the
  event of a system crash, no committed work is lost from the buffer. The
  reliability is maximal, but the performance cost is severe. The disk is
  subjected to a continuous, high-volume write load, forcing the system to
  constantly wait on the slowest component and thereby dramatically reducing
  overall throughput.

  === Lazy Policy (Write-Back)

  At the opposite extreme is an extremely lazy, or _write-back_, policy. The
  system delays writing a dirty page to disk for as long as physically possible.
  A modified page may remain in the buffer pool, accumulating numerous logical
  changes, while its on-disk counterpart grows increasingly stale. This approach
  maximizes throughput by collapsing many updates into a single eventual
  physical write and allows the disk to be used more efficiently. The
  corresponding risk, however, is catastrophic: if the system crashes, a massive
  amount of buffered work is lost, and the disk image is left in an inconsistent
  state, requiring a long and complex recovery process.

  === Other Policies

  Between the extremes of eager and lazy, a host of _hybrid policies_ exist. A
  _timeout policy_ might decide that if a certain amount of time, say a few
  seconds, has passed since the last update to a dirty page, it is a sign that
  the burst of activity on that page is over and it should be flushed. A
  _checkpoint policy_ imposes a global rhythm on flushing. Periodically, perhaps
  every five minutes, the system declares a checkpoint, taking a snapshot of the
  active transaction state and forcing all dirty pages in the buffer pool to be
  written to disk. This limits the amount of work that could be lost in a crash
  to the transactions active since the last checkpoint, creating a controlled
  interval of vulnerability in exchange for much higher average throughput. The
  choice among these policies represents a fundamental business and engineering
  decision, balancing the need for speed against the tolerance for risk and
  recovery time.

  == Bypass OS

  A final, often-surprising complication in DBMS buffer management is the
  operating system itself. When a DBMS reads a page from a file on disk, the
  operating system's own file system _buffer cache_ will likely retain a copy of
  that page. Then, the DBMS copies the data into its own buffer pool. The data
  exists twice in memory, and a write operation by the DBMS may be intercepted
  and delayed by the OS's own lazy writing policies, creating a dangerous false
  sense of security if the DBMS's buffers have been flushed but the OS's have
  not. The two levels of caching and scheduling can interfere, with the DBMS's
  carefully chosen LRU/MRU policy undermined by the unpredictable behavior of
  the OS cache. To achieve full control and maximum performance, many production
  DBMSs offer the option to use a raw disk interface, bypassing the OS file
  system and its buffer cache entirely to manage the disk directly. While this
  solution sacrifices some portability and administrative simplicity, it is
  often the only way to eliminate the inefficiencies of double-buffering and
  truly guarantee the I/O behavior the DBMS is designed to achieve.

  #info-box([
    === `open()` Flags

    Databases like MySQL (InnoDB) support opening table and index files with the
    `O_DIRECT` flag on Linux. When this flag is used, subsequent `read()` and
    `write()` calls bypass the kernel's page cache, allowing the storage engine
    to manage caching directly through its buffer pool.
  ])
]
