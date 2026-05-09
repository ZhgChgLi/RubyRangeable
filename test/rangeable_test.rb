# frozen_string_literal: true

require_relative 'test_helper'

# 23-case normative test contract from RFC.md §10. Each test name embeds the
# RFC test number for direct cross-reference.
class RangeableTest < Minitest::Test
  using Rangeable::Refinements

  def setup
    @r = Rangeable.new
  end

  # --- Test #1 — Empty -------------------------------------------------------

  def test_01_empty
    assert_equal [], @r[0].objs
    assert_equal [], Fixtures.strong.get_range(from: @r)
    assert_equal 0, @r.count
    assert @r.empty?
  end

  # --- Test #2 — Single insert ----------------------------------------------

  def test_02_single_insert
    @r.insert(Fixtures.strong, start: 2, end: 5)
    assert_equal [Fixtures.strong], @r[2].objs
    assert_equal [Fixtures.strong], @r[5].objs
    assert_equal [], @r[6].objs
    assert_equal [], @r[1].objs
  end

  # --- Test #3 — Inclusive end ----------------------------------------------

  def test_03_inclusive_end
    @r.insert(Fixtures.strong, start: 3, end: 8)
    assert_equal [Fixtures.strong], @r[8].objs
    assert_equal [], @r[9].objs
  end

  # --- Test #4 — Single-point ----------------------------------------------

  def test_04_single_point
    @r.insert(Fixtures.strong, start: 4, end: 4)
    assert_equal [], @r[3].objs
    assert_equal [Fixtures.strong], @r[4].objs
    assert_equal [], @r[5].objs
  end

  # --- Test #5 — Same-element overlap merge ----------------------------------

  def test_05_same_element_overlap_merge
    @r.insert(Fixtures.strong, start: 2, end: 5)
    @r.insert(Fixtures.strong, start: 3, end: 7)
    assert_equal [[2, 7]], Fixtures.strong.get_range(from: @r)
  end

  # --- Test #6 — Same-element adjacency merge -------------------------------

  def test_06_same_element_adjacency_merge
    @r.insert(Fixtures.strong, start: 2, end: 4)
    @r.insert(Fixtures.strong, start: 5, end: 7)
    assert_equal [[2, 7]], Fixtures.strong.get_range(from: @r)
  end

  # --- Test #7 — Same-element non-adjacent disjoint -------------------------

  def test_07_same_element_non_adjacent_disjoint
    @r.insert(Fixtures.strong, start: 2, end: 4)
    @r.insert(Fixtures.strong, start: 6, end: 7)
    assert_equal [[2, 4], [6, 7]], Fixtures.strong.get_range(from: @r)
  end

  # --- Test #8 — Same-element nested ----------------------------------------

  def test_08_same_element_nested
    @r.insert(Fixtures.strong, start: 2, end: 10)
    @r.insert(Fixtures.strong, start: 4, end: 6)
    assert_equal [[2, 10]], Fixtures.strong.get_range(from: @r)
  end

  # --- Test #9 — Idempotent insert ------------------------------------------

  def test_09_idempotent_insert
    @r.insert(Fixtures.strong, start: 2, end: 5)
    v1 = @r.version
    @r.insert(Fixtures.strong, start: 2, end: 5)
    v2 = @r.version
    assert_equal [[2, 5]], Fixtures.strong.get_range(from: @r)
    assert_equal v1, v2, 'idempotent insert MUST NOT bump version'
  end

  # --- Test #10 — Different elements coexist --------------------------------

  def test_10_different_elements_coexist
    @r.insert(Fixtures.strong, start: 2, end: 5)
    @r.insert(Fixtures.italic, start: 3, end: 7)
    assert_equal [Fixtures.strong, Fixtures.italic], @r[3].objs
    assert_equal [Fixtures.italic], @r[6].objs
    assert_equal [[2, 5]], Fixtures.strong.get_range(from: @r)
    assert_equal [[3, 7]], Fixtures.italic.get_range(from: @r)
  end

  # --- Test #11 — Equal-by-equality elements merge --------------------------

  def test_11_equal_by_equality_elements_merge
    @r.insert(Fixtures.link('a'), start: 2, end: 5)
    @r.insert(Fixtures.link('a'), start: 4, end: 8)
    @r.insert(Fixtures.link('b'), start: 6, end: 9)
    assert_equal [[2, 8]], Fixtures.link('a').get_range(from: @r)
    assert_equal [[6, 9]], Fixtures.link('b').get_range(from: @r)
  end

  # --- Test #12 — First-insert order at point -------------------------------

  def test_12_first_insert_order_at_point
    @r.insert(Fixtures.strong, start: 1, end: 10)
    @r.insert(Fixtures.italic, start: 1, end: 10)
    @r.insert(Fixtures.code, start: 1, end: 10)
    assert_equal [Fixtures.strong, Fixtures.italic, Fixtures.code], @r[5].objs
  end

  # --- Test #13 — Order preserved through merge -----------------------------

  def test_13_order_preserved_through_merge
    @r.insert(Fixtures.strong, start: 1, end: 5)
    @r.insert(Fixtures.italic, start: 3, end: 7)
    @r.insert(Fixtures.strong, start: 4, end: 8)
    assert_equal [Fixtures.strong, Fixtures.italic], @r[6].objs
    assert_equal [[1, 8]], Fixtures.strong.get_range(from: @r)
  end

  # --- Test #14 — Transitions over a range ----------------------------------

  def test_14_transitions_over_a_range
    @r.insert(Fixtures.strong, start: 2, end: 5)
    @r.insert(Fixtures.italic, start: 3, end: 7)
    events = @r.transitions(over: 0..10).map { |e| [e.coordinate, e.kind, e.element] }
    assert_equal [
      [2, :open,  Fixtures.strong],
      [3, :open,  Fixtures.italic],
      [6, :close, Fixtures.strong],
      [8, :close, Fixtures.italic],
    ], events
  end

  # --- Test #15 — Transitions same-start ------------------------------------

  def test_15_transitions_same_start
    @r.insert(Fixtures.strong, start: 3, end: 5)
    @r.insert(Fixtures.italic, start: 3, end: 7)
    events = @r.transitions(over: 0..10).map { |e| [e.coordinate, e.kind, e.element] }
    assert_equal [
      [3, :open,  Fixtures.strong],
      [3, :open,  Fixtures.italic],
      [6, :close, Fixtures.strong],
      [8, :close, Fixtures.italic],
    ], events
  end

  # --- Test #16 — Transitions same-end (LIFO) -------------------------------

  def test_16_transitions_same_end_lifo
    @r.insert(Fixtures.strong, start: 3, end: 5)
    @r.insert(Fixtures.italic, start: 3, end: 5)
    events = @r.transitions(over: 0..10).map { |e| [e.coordinate, e.kind, e.element] }
    assert_equal [
      [3, :open,  Fixtures.strong],
      [3, :open,  Fixtures.italic],
      [6, :close, Fixtures.italic],
      [6, :close, Fixtures.strong],
    ], events
  end

  # --- Test #17 — start > end raises ---------------------------------------

  def test_17_start_gt_end_raises
    assert_raises(Rangeable::InvalidIntervalError) do
      @r.insert(Fixtures.strong, start: 5, end: 2)
    end
    assert @r.empty?, 'failed insert MUST leave container unchanged'
    assert_equal 0, @r.version
  end

  # --- Test #18 — Negative start ------------------------------------------

  def test_18_negative_start
    @r.insert(Fixtures.strong, start: -2, end: 3)
    assert_equal [Fixtures.strong], @r[-1].objs
    assert_equal [Fixtures.strong], @r[0].objs
    assert_equal [Fixtures.strong], @r[3].objs
    assert_equal [], @r[4].objs
  end

  # --- Test #19 — Insert/read interleave (rebuild correctness) --------------

  def test_19_insert_read_interleave_rebuild
    @r.insert(Fixtures.strong, start: 1, end: 3)
    read1 = @r[2].objs
    @r.insert(Fixtures.strong, start: 5, end: 7)
    read2 = @r[6].objs
    assert_equal [Fixtures.strong], read1
    assert_equal [Fixtures.strong], read2
    assert_equal [[1, 3], [5, 7]], Fixtures.strong.get_range(from: @r)
  end

  # --- Test #20 — Property test (stress) -----------------------------------
  # The full property suite lives in property_test.rb; we keep a small
  # deterministic fixture here to keep the §10 numbered file complete.

  def test_20_property_smoke_against_brute_force
    rng = Random.new(42)
    elements = [Fixtures.strong, Fixtures.italic, Fixtures.code, Fixtures.link('x'), Fixtures.link('y')]
    triples = Array.new(50) do
      lo = rng.rand(-50..50)
      hi = lo + rng.rand(0..20)
      [elements.sample(random: rng), lo, hi]
    end

    triples.each { |e, lo, hi| @r.insert(e, start: lo, end: hi) }

    coords = (-60..60).to_a
    coords.each do |i|
      assert_equal brute_force_active(triples, i), @r[i].objs, "mismatch at i=#{i}"
    end
  end

  # --- Test #21 — Idempotent insert does NOT bump version -------------------

  def test_21_idempotent_insert_no_version_bump
    @r.insert(Fixtures.strong, start: 2, end: 5)
    v1 = @r.version
    @r.insert(Fixtures.strong, start: 2, end: 5)
    v2 = @r.version
    assert_equal v1, v2
  end

  # --- Test #21.A — Idempotent insert with strict containment ---------------

  def test_21A_idempotent_insert_strict_containment
    @r.insert(Fixtures.strong, start: 2, end: 10)
    v1 = @r.version
    @r.insert(Fixtures.strong, start: 4, end: 6)
    v2 = @r.version
    assert_equal [[2, 10]], Fixtures.strong.get_range(from: @r)
    assert_equal v1, v2, 'strict-containment fast-path MUST NOT bump version'
  end

  # --- Test #22 — transitions with lo > hi raises --------------------------

  def test_22_transitions_lo_gt_hi_raises
    @r.insert(Fixtures.strong, start: 2, end: 5)
    err = assert_raises(Rangeable::InvalidIntervalError) do
      @r.transitions(over: 5..2)
    end
    refute_nil err.message
  end

  # --- Test #23 — Int.min as lo of insert ----------------------------------

  def test_23_int_min_as_lo
    int_min = -(2**62)
    @r.insert(Fixtures.strong, start: int_min, end: int_min + 5)
    assert_equal [Fixtures.strong], @r[int_min].objs
    assert_equal [Fixtures.strong], @r[int_min + 5].objs
    assert_equal [], @r[int_min + 6].objs
    assert_equal [[int_min, int_min + 5]], Fixtures.strong.get_range(from: @r)
  end

  # --- Test #23.A — Int.max as hi of insert (sentinel via empty hi) --------
  # Ruby has unbounded Integer; we instead simulate the cross-language
  # contract by feeding a very large hi (representing Int.max in the Swift
  # twin) and checking that the close coordinate is `hi + 1` and that no
  # arithmetic blow-up occurs. The cross-language byte-identical contract
  # is exercised in the property_test fixture compare and the eventual
  # SwiftRangeable parity check.

  def test_23A_int_max_as_hi
    int_max = (2**62) - 1
    @r.insert(Fixtures.strong, start: 100, end: int_max)
    events = @r.transitions(over: 50..int_max).map { |ev| [ev.coordinate, ev.kind] }
    assert_equal [[100, :open], [int_max + 1, :close]], events
  end

  private

  # Brute-force oracle for property test: walk the raw triple list, group
  # by first occurrence in `insertion_order`, return the elements whose
  # any interval covers `i`.
  def brute_force_active(triples, i)
    seen = {}
    insertion_order = []
    triples.each do |e, _lo, _hi|
      next if seen.key?(e)

      seen[e] = true
      insertion_order << e
    end
    by_element = Hash.new { |h, k| h[k] = [] }
    triples.each { |e, lo, hi| by_element[e] << [lo, hi] }
    insertion_order.select do |e|
      by_element[e].any? { |lo, hi| lo <= i && i <= hi }
    end
  end
end
