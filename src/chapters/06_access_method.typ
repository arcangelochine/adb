#import "@preview/bookly:3.1.0": *

#let abs = [
  Choosing the right data organization and the right set of indexes is only half
  the problem of efficient query processing. The other half is deciding, at
  query time, how to use those structures. A database system does not execute a
  SQL statement directly: it translates the statement into a tree of physical
  operators, each of which implements one relational operation using a specific
  algorithm, and then executes that tree in a way that minimizes the total
  number of disk accesses. This chapter develops the machinery behind that
  process from the ground up. It begins with the iterator model, the execution
  protocol that allows an entire operator tree to run with minimal memory by
  producing one record at a time. It then examines how an optimizer constructs
  and evaluates candidate access plans, focusing on the two decisions that
  dominate plan quality: join order and the choice between table scan and index
  access. Both decisions hinge on accurate estimates of selectivity factors—the
  fraction of records a predicate is expected to select—and the chapter closes
  with a rigorous treatment of selectivity estimation: the standard formulas,
  their systematic failures, and the histogram-based techniques that modern
  systems use to correct those failures.
]

#chapter(title: "Access Methods", abstract: abs, toc: true)[

  == From SQL to Physical Execution

  When a relational database system receives a SQL statement, it does not
  interpret the statement directly. Instead it passes the statement through a
  pipeline of transformations that ends in a _physical access plan_: a tree of
  concrete algorithms, each of which implements one logical relational
  operation. Understanding this pipeline is a prerequisite to understanding why
  query performance varies so dramatically across different plans that compute
  the same result.

  The first transformation is _parsing and type checking_: the SQL text is
  converted into an internal representation and the system verifies that every
  table and attribute mentioned exists and that the types are compatible. The
  second transformation produces a _logical plan_, an algebraic expression in
  the relational algebra that is semantically equivalent to the SQL statement.
  The translation is largely mechanical: a `FROM` clause becomes a sequence of
  joins, a `WHERE` clause becomes a selection, a `SELECT` clause becomes a
  projection. The third transformation is _logical optimization_, where the
  system applies algebraic equivalences to improve the plan without yet
  committing to any specific algorithm. The most important such transformation
  is pushing selections as close as possible to the leaf nodes of the tree, so
  that each join operates on the smallest possible intermediate result.

  The fourth and final transformation produces the _physical plan_, in which
  every logical operator is replaced by a physical one. A logical join becomes
  one of several concrete join algorithms—nested loop, index nested loop,
  sort-merge, or hash join. A logical selection becomes either a table scan
  followed by an in-memory filter, or a direct index lookup. The component
  responsible for this fourth transformation is the _Optimizer_, and it is
  arguably the most important component in any relational database system: the
  difference between a good and a bad physical plan for the same query can be
  several orders of magnitude in execution time.

  == The Iterator Execution Model

  Once a physical plan is constructed, it must be executed. The naive approach
  is _operator-at-a-time_ execution: evaluate the leftmost leaf operation
  completely, store its result on disk, evaluate the next operation on that
  stored result, store again, and so on until the root of the tree is reached.
  The result at each step is a complete intermediate relation that must be
  written to disk and read back by the next operator. With five operators in the
  tree, five intermediate relations are materialized, each requiring a full
  write and a full read of potentially millions of records. This is precisely
  the pattern that database design works hardest to avoid.

  The alternative, used by virtually every production database system, is
  _iterator_ or _tuple-at-a-time_ execution. Each physical operator implements
  three methods: `open`, which initializes the operator and opens its children;
  `next`, which produces the next output record or signals end of file; and
  `close`, which releases all resources. When the root of the plan tree is asked
  for its next record, it asks its children for their next records, each of
  which asks its own children, and so on down to the leaf operators. The leaf
  operators—table scans and index scans—are the only operators that actually
  read from disk. Every other operator receives records from its children one at
  a time, applies its logic, and immediately passes the result upward.

  The memory advantage of this model is striking. A filter operator, for
  instance, never holds more than one record in memory at a time: it asks its
  child for a record, tests the predicate, and either passes the record up or
  discards it and asks for the next one. A projection operator similarly holds
  one record. A nested-loop join holds one record from its outer input and one
  from its inner input simultaneously. The total memory consumed by all non-leaf
  operators in the tree is bounded by the number of operators multiplied by the
  size of one record—a quantity that is negligible compared to the size of the
  data.

  There are exceptions. Sorting requires seeing all records before producing any
  output. Hashing-based operations—hash join and hash-based grouping—must build
  an in-memory hash table before the probe phase can begin. These operators do
  access disk for intermediate storage, and they are the reason why memory
  allocation matters for query performance even in the iterator model. But they
  are the exception, not the rule, and the iterator model confines their disk
  footprint to what is strictly necessary.

  The cost of the iterator model is implementation complexity. Each operator
  must maintain its own state across successive calls to next, remembering where
  it was in its input when it last produced a record. A nested-loop join, for
  example, must remember which record it currently holds from the outer relation
  and where it is in the scan of the inner relation. This bookkeeping is
  straightforward but requires care. It is also the reason why the tree of open
  operators consumes a small but nonzero amount of memory for each active node,
  even before any data is read. In practice this cost is entirely negligible
  compared to the data volume, but it is worth being aware of.

  === The Access Method Interface

  The iterator model depends on a uniform interface through which physical
  operators request records from their inputs, regardless of the underlying data
  structure. This interface is provided by the _Access Method Layer_, which
  wraps every data structure—heap file, B+-tree index, hash table—behind a
  common cursor abstraction.

  A _file scan cursor_ on a heap file supports `open`, which positions the
  cursor before the first record; `isDone`, which returns true when no more
  records remain; `getCurrent`, which returns the record at the current
  position; and `next`, which advances the cursor. An _index scan cursor_
  extends this with a `range`: when opened, it is given a first key and a last
  key, and it scans only the portion of the index between those bounds. Equality
  search is the special case where first key equals last key. A full index scan
  is the case where first key is $-infinity$ and last key is $+infinity$.

  This uniform interface means that a filter operator written against the cursor
  abstraction works identically whether its input is a heap file or a B+-tree
  index. The decision of which data structure to use is made once, at plan
  construction time, by the optimizer. At execution time, the operators simply
  call `open`, `isDone`, `getCurrent`, and `next` without knowing or caring what
  lies beneath.

  When an index is used to find records in a heap file, two cursors are active
  simultaneously: one on the index, which produces RIDs, and one on the heap
  file, which maps each RID to a physical page and record. The index cursor
  produces a RID; the heap cursor uses that RID to fetch the record. This
  two-level access is the standard cost of secondary index lookup, and it
  corresponds directly to the $C_I + C_D$ cost model developed in the previous
  chapter.

  == The Optimizer and Plan Selection

  The optimizer's task is to search the space of physical plans for the one with
  the lowest estimated execution cost. In principle this space is enormous: for
  a query joining $n$ tables there are $n!$ orderings of the joins, and for each
  ordering there are multiple algorithm choices for each join and multiple
  access method choices for each table. In practice, the space is pruned
  aggressively, but even after pruning the optimizer must evaluate many
  candidate plans, and the quality of its choice depends entirely on the quality
  of its cost estimates.

  The two decisions that dominate plan quality are _join order_ and _access
  method selection_. Join order determines the size of intermediate results. If
  a query joins students, exams, and courses with a highly selective condition
  on the course title, the right plan begins by selecting the matching
  courses—perhaps just one row—and then joins that tiny intermediate result
  against exams and then students. Beginning instead from students, which may
  number in the thousands, produces a large intermediate result that propagates
  expensively through the rest of the tree. The general principle is to begin
  from the most selective condition, because the most selective condition
  produces the smallest intermediate result, which minimizes the cost of every
  subsequent operation.

  Access method selection determines how each table is accessed. For each table
  in the query, the optimizer decides whether to use a table scan or one of the
  available indexes, and if an index, which one. This decision depends on the
  selectivity factor of the predicate applied to that table: when the
  selectivity factor is very low—below roughly 0.1%—an index access is faster
  than a table scan; when it is high—above roughly 1%—the table scan is faster.
  At intermediate selectivities the choice is less clear and the cost model must
  be consulted directly.

  The asymmetry of error deserves emphasis. An optimizer that overestimates
  selectivity—believing a predicate is more selective than it is—will prefer
  index access where a table scan would have been better. In the worst case, an
  unclustered index access on a non-selective predicate costs $O(N_"REC")$ page
  accesses, which is far worse than the $O(N_"PAG")$ cost of a table scan. An
  optimizer that underestimates selectivity will prefer table scans where an
  index would have been better, losing performance but not catastrophically.
  This asymmetry explains why optimizers are deliberately calibrated to be
  pessimistic: when uncertain, assume a larger selectivity factor and lean
  toward table scans, which have bounded and predictable cost.

  == Selectivity Estimation

  Every cost estimate in the optimizer depends on estimates of selectivity
  factors. A _selectivity factor_ $s_f (phi)$ for a predicate $phi$ is the
  fraction of records in a table that are expected to satisfy $phi$. It ranges
  from 0 to 1, and the expected number of qualifying records is
  $E_"REC" = s_f times N_"REC"$.

  For an equality predicate $phi equiv (A = v)$ on an attribute $A$ with
  $N_"KEY"$ distinct values, the standard estimate assumes a uniform
  distribution of values and gives

  $ s_f (A = v) = 1 / (N_"KEY" (A)) $

  For a range predicate $phi equiv (v_1 <= A <= v_2)$ on an attribute whose
  minimum and maximum values are known, the standard estimate assumes uniform
  distribution over the domain and gives

  $ s_f (v_1 <= A <= v_2) = (v_2 - v_1) / (max(A) - min(A)) $

  For a conjunction of two independent predicates $phi_1$ and $phi_2$, the
  selectivity factor of the conjunction is the product of the individual
  selectivity factors:

  $ s_f (phi_1 and phi_2) = s_f (phi_1) times s_f (phi_2) $

  This follows from treating satisfaction of each predicate as an independent
  event and applying the multiplicative rule for independent probabilities. For
  a disjunction, the inclusion-exclusion principle gives

  $
    s_f (phi_1 or phi_2) = s_f (phi_1) + s_f (phi_2) - s_f (phi_1) times s_f (phi_2)
  $

  though in practice disjunctions appear far less often than conjunctions in
  real workloads.

  For a join predicate of the form $A = B$ where $A$ and $B$ are attributes of
  two different tables, the standard estimate is

  $ s_f (A = B) = 1 / (max(N_"KEY" (A), N_"KEY" (B))) $

  This formula is motivated by the case where one attribute is a foreign key and
  the other is the corresponding primary key. If $A$ takes values from a set
  that is a subset of the values taken by $B$—as is guaranteed by referential
  integrity—then for any value extracted from $A$, the probability that a
  randomly chosen value of $B$ matches it is $1 / (N_"KEY" (B))$. Taking the
  maximum in the denominator handles the general case where it is not known
  which attribute is the subset. The formula gives a result that is either
  correct or a slight overestimate, which, as noted above, is the safer
  direction of error.

  When no statistical information is available for an attribute, optimizers fall
  back on magic constants: $1/10$ for equality on an unknown attribute, $1/3$ or
  $1/4$ for a range predicate. These numbers are not derived from any data
  property; they are deliberately conservative defaults that bias the optimizer
  toward table scans and away from the potentially catastrophic cost of an
  unclustered index access on a non-selective predicate.

  == Failures of the Standard Formulas

  The standard formulas are universally used, and universally imperfect.
  Understanding precisely how and why they fail is essential for anyone who
  works with query optimization, whether as a database designer, an application
  developer, or a systems engineer.

  === The Uniform Distribution Assumption

  The equality formula $1 / N_"KEY"$ and the range formula
  $(v_2 - v_1) / (max - min)$ are both exact only under a uniform distribution
  of values across the attribute's domain. Real data distributions are almost
  never uniform. Exam grades cluster around passing values. Salaries follow a
  right-skewed distribution with a long tail. Family names are distributed
  according to cultural and geographic patterns that no formula can capture.

  For the range formula, the consequences are systematic and severe. Most data
  follows a bell-shaped distribution concentrated near the mean. A query for
  values near the mean selects far more records than the formula predicts,
  because the formula divides the query range by the full domain range and knows
  nothing about the concentration of records in the center. A query for values
  in the tails of the distribution selects far fewer records than the formula
  predicts, because the formula overestimates the density in the tails. The
  formula gives a reasonable estimate only for a query whose range is positioned
  such that the actual density happens to equal the average density—a rare
  coincidence in practice.

  === Sensitivity to Outliers

  The range formula has an additional and especially damaging failure mode:
  sensitivity to outliers. The formula depends on $max(A) - min(A)$, the total
  range of the attribute. A single data entry error—one salary recorded as
  10,000,000 instead of 10,000, one temperature recorded in Kelvin instead of
  Celsius—inflates the denominator by orders of magnitude. Every range query on
  that attribute then receives a selectivity estimate that is orders of
  magnitude smaller than reality, causing the optimizer to believe all range
  predicates are extremely selective. The consequence is systematic overuse of
  index access, and an unclustered index access on a non-selective predicate can
  cost $N_"REC"$ page reads—potentially a thousand times more than a table scan.
  Worse, the error is invisible from the query itself: the optimizer is applying
  the correct formula to corrupted statistics, and the resulting plan appears
  reasonable until execution reveals its cost.

  === Correlation Between Attributes

  The conjunction formula
  $s_f (phi_1 and phi_2) = s_f (phi_1) times s_f (phi_2)$ assumes that the two
  predicates are statistically independent—that knowing a record satisfies
  $phi_1$ gives no information about whether it satisfies $phi_2$. This
  assumption fails whenever the two attributes are correlated, which in practice
  is more often the rule than the exception.

  Negative correlation produces massive overestimation. Suppose that a
  university database is queried for exams passed by students enrolled in
  anthropology for the course "Advanced Databases". If no anthropology student
  has ever taken the databases course, the true selectivity of the conjunction
  is zero. But if databases exams account for 10% of all exams and anthropology
  students account for 10% of all students, the formula estimates the
  conjunction at 1%—infinitely larger than the truth. The optimizer, believing
  1% of records qualify, may choose a table scan; an optimizer that knew the
  true selectivity was zero would produce a trivially fast plan.

  Positive correlation produces the opposite error: underestimation. The
  databases course is taken almost exclusively by students in the data science
  program. Knowing that an exam record is for the databases course makes it
  near-certain that the student is from data science. The true selectivity of
  the conjunction `(databases course) AND (data science student)` is
  approximately equal to the selectivity of `(databases course)` alone. But if
  each condition has selectivity 10%, the formula estimates 1%, underestimating
  by an order of magnitude. The optimizer, believing only 1% of records qualify,
  may use an index when a table scan would have been faster, or may choose a
  join order that starts from the wrong table.

  No formula based only on per-attribute statistics can detect inter-attribute
  correlation. The correlation is an inherently multivariate property of the
  data, and capturing it requires multivariate statistics—which, as discussed
  below, are expensive to maintain.

  == Histograms

  The failures of the standard formulas motivate a richer representation of the
  data distribution. A _histogram_ is a compressed summary of the distribution
  of values for one attribute, stored in the system _Catalog_ and used by the
  optimizer to estimate selectivity more accurately than the min-max-$N_"KEY"$
  triple allows.

  The basic idea is to divide the domain of the attribute into contiguous
  intervals called _buckets_ and record, for each bucket, the number of records
  whose attribute value falls in that bucket. Given this summary, a range query
  $v_1 <= A <= v_2$ is answered by summing the record counts of all buckets
  fully inside the range, plus a proportional fraction of the counts of the two
  boundary buckets whose edges partially overlap the range. The estimate is
  exact when every bucket is internally uniform—when all values within a bucket
  occur with equal frequency—and the approximation error is smaller when more
  buckets are used.

  #figure(image("../figures/chapter6/histograms.pdf"), caption: [
    Comparison of equi-width and equi-height histograms. The equi-width
    histogram divides the attribute domain into intervals of equal size (width =
    4), while the equi-height histogram partitions the data so that each bucket
    contains approximately the same number of records (height = 10).
  ])

  === Equi-Width and Equi-Height Buckets

  The simplest histogram design uses _equi-width_ buckets: the domain is divided
  into intervals of equal length, and the record count for each interval is
  stored. With 30 distinct possible values and 10 buckets, each bucket covers
  exactly 3 values. The advantage is simplicity: bucket boundaries are computed
  from the domain range and need not be stored explicitly. The disadvantage is
  that equi-width buckets allocate the same representational resolution to every
  part of the domain, including the tails where records are sparse and where
  precise estimation matters less.

  A better design uses _equi-height_ buckets, sometimes called equi-depth
  buckets. Here the bucket boundaries are chosen so that every bucket contains
  approximately the same number of records. If the table has 100,000 records and
  100 buckets are allocated, each bucket contains approximately 1,000 records.
  In a right-skewed salary distribution, the buckets near the median are
  narrow—covering a small salary range that contains many records—while the
  buckets in the high-salary tail are wide—covering a large range that contains
  few records. This allocation matches representational resolution to data
  density: the parts of the domain where most queries fall are represented most
  precisely.

  For an equi-width histogram, the stored information is the height of each
  bucket—the record count—because the boundaries are implicit. For an
  equi-height histogram, the stored information is the boundary of each
  bucket—where each bucket begins and ends—because the heights are approximately
  equal and known. In either case the total storage is proportional to the
  number of buckets, which can be chosen to fit in a single page of main memory,
  ensuring that the histogram is available to the optimizer without any disk
  access.

  === Maintenance and Practical Considerations

  Histograms must be kept reasonably up to date to be useful, but updating them
  after every single insertion or deletion would be prohibitively expensive:
  counting distinct values requires either an index scan or a full table scan,
  neither of which should occur on every write. The standard practice is to
  update histograms periodically—typically at scheduled maintenance windows when
  the system load is low—or to expose an explicit command such as
  `UPDATE STATISTICS` that the database administrator can invoke after bulk
  loads or other operations that significantly change the data distribution.

  The choice of which attributes to maintain histograms for is itself a design
  decision. Maintaining histograms for every attribute of every table is
  expensive in storage and maintenance cost. The practical approach is to
  maintain histograms for all indexed attributes, since these are the attributes
  most likely to appear in selective predicates that drive the optimizer's
  access method decisions.

  === The Limits of Univariate Histograms

  Histograms correct the single most important failure of the standard formulas:
  the uniform distribution assumption for individual attributes. They do not
  correct the correlation problem. A histogram is a univariate structure,
  describing the distribution of one attribute independently of all others.
  Estimating the selectivity of a conjunction using two histograms still
  requires multiplying the individual estimates, which still assumes
  independence.

  The natural extension is a _joint histogram_: a two-dimensional data structure
  recording the distribution of pairs of attribute values. For two attributes
  each with 100 distinct values, a joint histogram with 100 buckets per
  dimension requires storing 10,000 values. For ten attributes, maintaining a
  joint histogram for every pair requires $binom(10, 2) = 45$ joint histograms,
  each with 10,000 entries—a total of 450,000 values, which begins to strain the
  requirement that statistics fit in main memory and be inexpensive to maintain.
  For triples of attributes the situation is worse still, and in general
  capturing $k$-way correlations requires a $k$-dimensional histogram whose size
  grows exponentially in $k$.

  In practice, no production system maintains joint histograms for arbitrary
  attribute pairs. The standard approach remains independent per-attribute
  histograms, and the conjunction formula remains a product of individual
  selectivity estimates. The optimizer therefore operates with a structural bias
  toward treating attributes as independent, and query plans generated under
  this assumption will occasionally be poor when significant correlation exists
  between the attributes in a conjunctive predicate. This is a known and
  accepted limitation of the current state of the art, not a problem that has
  been solved and merely awaits deployment.

]
