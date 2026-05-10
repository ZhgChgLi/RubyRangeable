# frozen_string_literal: true

require_relative 'test_helper'

# v2 normative test contract per RFC §10.B–§10.G (#21–#80) plus Ruby-idiom
# ergonomic extensions (operator alias parity, bang-form chaining, dup
# isolation). Every test name embeds the RFC test number for direct
# cross-reference. Test names that DO NOT embed an RFC number are
# Ruby-specific consistency checks (e.g. operator aliasing, sym-diff
# associativity beyond Test #70's single-key case).
#
# `Markup` element fixtures (`A, B, C, D, E`) below are bare frozen Symbol
# values; we use Symbols rather than Structs because they are already
# Hashable+frozen and let us read tests at a glance ("element A inserts
# into r1 then we intersect with r2"). The v1 test suite's `Strong`,
# `Italic`, `Code`, `Link` Structs are reused where the same fixture as
# the RFC narrative is desired.
#
# All assertions on `r.version` use the public `r.version` reader; we do
# NOT reach into ivars. The semantic contract is "no-bump iff truly no
# mutation" per §3.2 + §4.10 (N3); reaching into ivars would not test
# any extra contract.
class V2OperationsTest < Minitest::Test
  using Rangeable::Refinements

  # Bare-element fixtures. Symbols are frozen, immutable, Hashable —
  # ideal as test markups in cross-element scenarios.
  A = :a
  B = :b
  C = :c
  D = :d
  E = :e

  def setup
    @r = Rangeable.new
  end

  # ===========================================================================
  # §10.B — Removal Tests (#21–#43)
  # ===========================================================================

  # --- #21 — `remove(e, start, end)` no overlap (no-op, no version bump) ---
  def test_b21_remove_no_overlap_no_bump
    @r.insert(Fixtures.strong, start: 10, end: 20)
    v0 = @r.version
    @r.remove(Fixtures.strong, start: 0, end: 5)
    assert_equal [[10, 20]], Fixtures.strong.get_range(from: @r)
    assert_equal v0, @r.version, 'no-overlap remove MUST NOT bump version'
    assert_equal 1, @r.count
  end

  # --- #22 — `remove(e, start, end)` exact match consumes one entry ----------
  def test_b22_remove_exact_match
    @r.insert(Fixtures.strong, start: 10, end: 20)
    @r.remove(Fixtures.strong, start: 10, end: 20)
    assert_equal 0, @r.count
    assert @r.empty?
    assert_equal [], Fixtures.strong.get_range(from: @r)
  end

  # --- #23 — `remove` leaves left residual only ------------------------------
  def test_b23_remove_left_residual
    @r.insert(Fixtures.strong, start: 0, end: 10)
    @r.remove(Fixtures.strong, start: 5, end: 100)
    assert_equal [[0, 4]], Fixtures.strong.get_range(from: @r)
  end

  # --- #24 — `remove` leaves right residual only -----------------------------
  def test_b24_remove_right_residual
    @r.insert(Fixtures.strong, start: 0, end: 10)
    @r.remove(Fixtures.strong, start: -100, end: 5)
    assert_equal [[6, 10]], Fixtures.strong.get_range(from: @r)
  end

  # --- #25 — `remove` splits one entry into two ------------------------------
  def test_b25_remove_split
    @r.insert(Fixtures.strong, start: 0, end: 10)
    @r.remove(Fixtures.strong, start: 3, end: 6)
    assert_equal [[0, 2], [7, 10]], Fixtures.strong.get_range(from: @r)
  end

  # --- #26 — `remove` spans multiple entries ---------------------------------
  def test_b26_remove_spans_multiple_entries
    @r.insert(Fixtures.strong, start: 0,  end: 5)
    @r.insert(Fixtures.strong, start: 10, end: 15)
    @r.insert(Fixtures.strong, start: 20, end: 25)
    @r.remove(Fixtures.strong, start: 3, end: 22)
    assert_equal [[0, 2], [23, 25]], Fixtures.strong.get_range(from: @r)
  end

  # --- #27 — `remove` spans entire R(e), prunes element ----------------------
  def test_b27_remove_full_prune_renumbers_ord
    @r.insert(Fixtures.strong, start: 0,  end: 5)
    @r.insert(Fixtures.strong, start: 10, end: 15)
    @r.insert(Fixtures.italic, start: 7,  end: 8)
    v0 = @r.version
    @r.remove(Fixtures.strong, start: -100, end: 100)
    assert_equal 1, @r.count
    assert_equal [Fixtures.italic], @r.map { |e, _| e }
    # Italic was inserted second (ord=2); after Strong is pruned, its ord
    # MUST be renumbered to 1 (§4.10 N1 dense renumber).
    @r.each { |e, ranges| assert_equal Fixtures.italic, e; assert_equal [[7, 8]], ranges }
    assert_equal v0 + 1, @r.version
  end

  # --- #28 — `remove` no-op MUST NOT bump version ---------------------------
  def test_b28_remove_no_op_no_bump
    @r.insert(Fixtures.strong, start: 10, end: 20)
    v0 = @r.version
    @r.remove(Fixtures.strong, start: 30, end: 40)  # no overlap.
    @r.remove(Fixtures.italic, start: 0,  end: 5)   # element absent.
    assert_equal v0, @r.version, 'two consecutive no-op removes MUST keep version'
  end

  # --- #29 — `remove` with `start > end` raises -----------------------------
  def test_b29_remove_start_gt_end_raises
    @r.insert(Fixtures.strong, start: 0, end: 10)
    assert_raises(Rangeable::InvalidIntervalError) do
      @r.remove(Fixtures.strong, start: 7, end: 3)
    end
    assert_equal [[0, 10]], Fixtures.strong.get_range(from: @r), 'failed remove leaves r unchanged'
  end

  # --- #30 — `remove` with `start == Int.min` (underflow safe) --------------
  def test_b30_remove_start_at_int_min_underflow_safe
    int_min = -(2**62)
    @r.insert(Fixtures.strong, start: int_min, end: int_min + 100)
    @r.remove(Fixtures.strong, start: int_min, end: int_min + 50)
    # Left residual NOT created (iv.lo == start), so `start - 1` is never computed.
    assert_equal [[int_min + 51, int_min + 100]], Fixtures.strong.get_range(from: @r)
  end

  # --- #31 — `remove` with `end == Int.max` (overflow safe) -----------------
  def test_b31_remove_end_at_int_max_overflow_safe
    int_max = (2**62) - 1
    @r.insert(Fixtures.strong, start: 0, end: int_max)
    @r.remove(Fixtures.strong, start: 1000, end: int_max)
    # Right residual NOT created (iv.hi == end), so `end + 1` is never computed.
    assert_equal [[0, 999]], Fixtures.strong.get_range(from: @r)
  end

  # --- #32 — `remove(e)` excises element + dense renumber -------------------
  def test_b32_remove_element_renumbers
    @r.insert(Fixtures.strong, start: 0, end: 5)
    @r.insert(Fixtures.italic, start: 7, end: 12)
    @r.insert(Fixtures.code,   start: 15, end: 20)
    v0 = @r.version
    @r.remove_element(Fixtures.italic)
    assert_equal 2, @r.count
    keys = @r.map { |e, _| e }
    assert_equal [Fixtures.strong, Fixtures.code], keys
    # First-insert ord(Strong) = 1; after Italic excision, ord(Code) MUST be 2.
    # We can verify dense renumbering indirectly by re-inserting a NEW element
    # and checking its assigned position is 3 (count + 1).
    @r.insert(Fixtures.link('z'), start: 100, end: 200)
    keys2 = @r.map { |e, _| e }
    assert_equal [Fixtures.strong, Fixtures.code, Fixtures.link('z')], keys2
    assert_equal v0 + 1 + 1, @r.version  # one for remove, one for new insert.
  end

  # --- #33 — `remove(e)` on never-inserted element MUST NOT bump version ---
  def test_b33_remove_element_absent_no_bump
    @r.insert(Fixtures.strong, start: 0, end: 5)
    v0 = @r.version
    @r.remove_element(Fixtures.italic)
    assert_equal 1, @r.count
    assert_equal v0, @r.version, 'remove of absent element MUST NOT bump version'
  end

  # --- #34 — `remove(e)` on element with single interval --------------------
  def test_b34_remove_element_single_interval
    @r.insert(Fixtures.strong, start: 5, end: 10)
    @r.remove_element(Fixtures.strong)
    assert @r.empty?
    assert_equal 0, @r.count
  end

  # --- #35 — `remove(e)` on element with many intervals ---------------------
  def test_b35_remove_element_many_intervals
    @r.insert(Fixtures.strong, start: 0,  end: 5)
    @r.insert(Fixtures.strong, start: 10, end: 15)
    @r.insert(Fixtures.strong, start: 20, end: 25)
    @r.remove_element(Fixtures.strong)
    assert @r.empty?
    assert_equal [], Fixtures.strong.get_range(from: @r)
  end

  # --- #36 — `clear` on non-empty container ---------------------------------
  def test_b36_clear_non_empty
    @r.insert(Fixtures.strong, start: 0, end: 5)
    @r.insert(Fixtures.italic, start: 7, end: 12)
    v0 = @r.version
    @r.clear
    assert @r.empty?
    assert_equal 0, @r.count
    assert_equal [], Fixtures.strong.get_range(from: @r)
    assert_equal [], Fixtures.italic.get_range(from: @r)
    assert_equal v0 + 1, @r.version
  end

  # --- #37 — `clear` on empty container MUST NOT bump version --------------
  def test_b37_clear_empty_no_bump
    v0 = @r.version
    @r.clear
    assert @r.empty?
    assert_equal v0, @r.version
  end

  # --- #38 — Post-clear `r.empty? == true` ----------------------------------
  def test_b38_post_clear_empty_predicate
    @r.insert(Fixtures.strong, start: 0, end: 5)
    @r.clear
    assert @r.empty?
    assert_equal [], @r[3].objs
    assert_equal [], @r.transitions(over: 0..10)
  end

  # --- #39 — Post-clear `r.count == 0` -------------------------------------
  def test_b39_post_clear_count_zero
    @r.insert(Fixtures.strong, start: 0, end: 5)
    @r.insert(Fixtures.italic, start: 7, end: 12)
    @r.clear
    assert_equal 0, @r.count
    seen = []
    @r.each { |e, _| seen << e }
    assert_empty seen
  end

  # --- #40 — Insert after clear assigns ord = 1 -----------------------------
  def test_b40_insert_after_clear_resets_ord
    @r.insert(Fixtures.strong, start: 0, end: 5)
    @r.insert(Fixtures.italic, start: 7, end: 12)
    @r.clear
    @r.insert(Fixtures.code, start: 100, end: 110)
    assert_equal 1, @r.count
    # First-insert ordinal of Code MUST be 1 (not 3).
    keys = @r.map { |e, _| e }
    assert_equal [Fixtures.code], keys
  end

  # --- #41 — `remove_ranges` hits multiple elements (single bump) ----------
  def test_b41_remove_ranges_multi_element_single_bump
    @r.insert(Fixtures.strong, start: 0,   end: 10)
    @r.insert(Fixtures.italic, start: 5,   end: 15)
    @r.insert(Fixtures.code,   start: 100, end: 110)
    v0 = @r.version
    @r.remove_ranges(start: 3, end: 8)
    assert_equal [[0, 2], [9, 10]],  Fixtures.strong.get_range(from: @r)
    assert_equal [[9, 15]],          Fixtures.italic.get_range(from: @r)
    assert_equal [[100, 110]],       Fixtures.code.get_range(from: @r)
    assert_equal v0 + 1, @r.version, 'remove_ranges MUST bump version exactly once'
  end

  # --- #42 — `remove_ranges` no overlap MUST NOT bump version --------------
  def test_b42_remove_ranges_no_overlap_no_bump
    @r.insert(Fixtures.strong, start: 0,  end: 10)
    @r.insert(Fixtures.italic, start: 50, end: 60)
    v0 = @r.version
    @r.remove_ranges(start: 20, end: 30)
    assert_equal [[0, 10]],   Fixtures.strong.get_range(from: @r)
    assert_equal [[50, 60]],  Fixtures.italic.get_range(from: @r)
    assert_equal v0, @r.version
  end

  # --- #43 — `remove_ranges` mixed prune + retain --------------------------
  def test_b43_remove_ranges_mixed_prune_retain
    @r.insert(Fixtures.strong, start: 0,  end: 5)
    @r.insert(Fixtures.italic, start: 10, end: 20)
    @r.insert(Fixtures.code,   start: 25, end: 30)
    v0 = @r.version
    @r.remove_ranges(start: 8, end: 22)
    assert_equal [[0, 5]],    Fixtures.strong.get_range(from: @r)
    assert_equal [],          Fixtures.italic.get_range(from: @r)  # fully pruned.
    assert_equal [[25, 30]],  Fixtures.code.get_range(from: @r)
    assert_equal 2, @r.count
    keys = @r.map { |e, _| e }
    assert_equal [Fixtures.strong, Fixtures.code], keys
    assert_equal v0 + 1, @r.version
  end

  # --- #43-variant — `remove_ranges` covers everything ---------------------
  def test_b43v_remove_ranges_covers_all
    @r.insert(Fixtures.strong, start: 0,  end: 5)
    @r.insert(Fixtures.italic, start: 10, end: 20)
    @r.insert(Fixtures.code,   start: 25, end: 30)
    v0 = @r.version
    @r.remove_ranges(start: 0, end: 30)
    assert @r.empty?
    assert_equal v0 + 1, @r.version
  end

  # --- pre-condition raise on `remove_ranges` (Edge #33) -------------------
  def test_b_remove_ranges_start_gt_end_raises
    @r.insert(Fixtures.strong, start: 0, end: 10)
    assert_raises(Rangeable::InvalidIntervalError) do
      @r.remove_ranges(start: 5, end: 2)
    end
    assert_equal [[0, 10]], Fixtures.strong.get_range(from: @r)
  end

  # --- Insert-after-remove ord reassignment (#78 / R14) --------------------
  def test_b_insert_after_full_remove_reassigns_ord
    @r.insert(A, start: 0, end: 5)
    @r.insert(B, start: 10, end: 15)
    @r.remove_element(A)
    keys_after_remove = @r.map { |e, _| e }
    assert_equal [B], keys_after_remove
    @r.insert(A, start: 100, end: 110)
    keys_final = @r.map { |e, _| e }
    assert_equal [B, A], keys_final, 'A is a NEW first-insert at the tail'
  end

  # ===========================================================================
  # §10.C — Union Tests (#44–#50)
  # ===========================================================================

  # --- #44 — union with disjoint elements ----------------------------------
  def test_c44_union_disjoint_elements
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0, end: 5) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.italic, start: 10, end: 15) }
    v1_before = r1.version
    v2_before = r2.version
    r3 = r1.union(r2)
    assert_equal 2, r3.count
    assert_equal [Fixtures.strong, Fixtures.italic], r3.map { |e, _| e }
    assert_equal [[0, 5]],   Fixtures.strong.get_range(from: r3)
    assert_equal [[10, 15]], Fixtures.italic.get_range(from: r3)
    assert_equal 0, r3.version
    assert_equal v1_before, r1.version, 'source r1.version unchanged'
    assert_equal v2_before, r2.version, 'source r2.version unchanged'
  end

  # --- #45 — union same element, overlapping intervals ---------------------
  def test_c45_union_same_element_overlap
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 5, end: 15) }
    r3 = r1.union(r2)
    assert_equal [[0, 15]], Fixtures.strong.get_range(from: r3)
    assert_equal 1, r3.count
  end

  # --- #46 — union adjacency-merge -----------------------------------------
  def test_c46_union_adjacency_merge
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0, end: 5) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 6, end: 10) }
    r3 = r1.union(r2)
    assert_equal [[0, 10]], Fixtures.strong.get_range(from: r3),
                 'integer-adjacency: 5 + 1 == 6 ⇒ merge'
  end

  # --- #47 — union! with idempotent subset MUST NOT bump version ----------
  def test_c47_union_bang_idempotent_subset_no_bump
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0,  end: 10)
    r1.insert(Fixtures.italic, start: 20, end: 30)
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 3, end: 7) }
    v0 = r1.version
    r1.union!(r2)
    assert_equal [[0, 10]],  Fixtures.strong.get_range(from: r1)
    assert_equal [[20, 30]], Fixtures.italic.get_range(from: r1)
    assert_equal v0, r1.version, 'idempotent union! MUST NOT bump version'
  end

  # --- #48 — union of two empties ------------------------------------------
  def test_c48_union_of_two_empties
    r3 = Rangeable.new.union(Rangeable.new)
    assert r3.empty?
    assert_equal 0, r3.count
    assert_equal 0, r3.version
  end

  # --- #49 — union with self ------------------------------------------------
  def test_c49_union_with_self
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0, end: 5)
    r1.insert(Fixtures.italic, start: 10, end: 15)
    v0 = r1.version
    r2 = r1.union(r1)
    assert_equal r1.map { |e, ranges| [e, ranges] }, r2.map { |e, ranges| [e, ranges] }
    assert_equal 0, r2.version
    assert_equal v0, r1.version
  end

  def test_c49_union_bang_self_no_bump
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0, end: 5)
    v0 = r1.version
    r1.union!(r1)
    assert_equal v0, r1.version, 'union!(self) MUST NOT bump version'
  end

  # --- #50 — union insertion-order tail-append -----------------------------
  def test_c50_union_insertion_order_tail_append
    r1 = Rangeable.new
    r1.insert(A, start: 0, end: 1)
    r1.insert(B, start: 2, end: 3)
    r2 = Rangeable.new
    r2.insert(C, start: 4,  end: 5)
    r2.insert(B, start: 10, end: 11)
    r2.insert(D, start: 12, end: 13)
    r3 = r1.union(r2)
    keys = r3.map { |e, _| e }
    assert_equal [A, B, C, D], keys, 'self-order then other-only-keys-in-other-order'
  end

  # --- Operator alias parity for union -------------------------------------
  def test_c_union_operator_alias
    r1 = Rangeable.new.tap { |r| r.insert(A, start: 0, end: 5) }
    r2 = Rangeable.new.tap { |r| r.insert(B, start: 10, end: 15) }
    via_method = r1.union(r2)
    via_op     = r1 | r2
    assert_equal via_method.map { |e, rg| [e, rg] }, via_op.map { |e, rg| [e, rg] }
  end

  # ===========================================================================
  # §10.D — Intersect Tests (#51–#57)
  # ===========================================================================

  # --- #51 — intersect with no shared elements -----------------------------
  def test_d51_intersect_no_shared_elements
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.italic, start: 5, end: 15) }
    r3 = r1.intersect(r2)
    assert r3.empty?
    assert_equal 0, r3.count
  end

  # --- #52 — intersect shared elements, overlapping intervals --------------
  def test_d52_intersect_shared_overlap
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 5, end: 15) }
    r3 = r1.intersect(r2)
    assert_equal [[5, 10]], Fixtures.strong.get_range(from: r3)
    assert_equal 1, r3.count
  end

  # --- #53 — intersect shared elements, disjoint intervals → eager prune --
  def test_d53_intersect_disjoint_eager_prune
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0,   end: 5) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 100, end: 200) }
    r3 = r1.intersect(r2)
    assert r3.empty?
    assert_equal [], Fixtures.strong.get_range(from: r3)
  end

  # --- #54 — intersect with self -------------------------------------------
  def test_d54_intersect_with_self
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0, end: 5)
    r1.insert(Fixtures.italic, start: 10, end: 15)
    v0 = r1.version
    r2 = r1.intersect(r1)
    assert_equal r1.map { |e, rg| [e, rg] }, r2.map { |e, rg| [e, rg] }
    assert_equal 0, r2.version
    assert_equal v0, r1.version
  end

  # --- #55 — intersect with empty ------------------------------------------
  def test_d55_intersect_with_empty
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0, end: 5)
    r1.insert(Fixtures.italic, start: 10, end: 15)
    r3 = r1.intersect(Rangeable.new)
    assert r3.empty?
  end

  # --- #56 — intersect produces multiple sub-intervals per element ---------
  def test_d56_intersect_multiple_sub_intervals
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0,  end: 5)
    r1.insert(Fixtures.strong, start: 10, end: 15)
    r1.insert(Fixtures.strong, start: 20, end: 25)
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 3, end: 22) }
    r3 = r1.intersect(r2)
    assert_equal [[3, 5], [10, 15], [20, 22]], Fixtures.strong.get_range(from: r3)
  end

  # --- #57 — intersect insertion-order preservation + dense ord -----------
  def test_d57_intersect_insertion_order_dense_ord
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r1.insert(C, start: 20, end: 25)
    r1.insert(D, start: 30, end: 35)
    r2 = Rangeable.new
    r2.insert(A, start: 0,   end: 5)
    r2.insert(C, start: 21,  end: 24)
    r2.insert(E, start: 100, end: 200)
    r3 = r1.intersect(r2)
    keys = r3.map { |e, _| e }
    assert_equal [A, C], keys
    assert_equal [[0,  5]],  r3.get_range(A)
    assert_equal [[21, 24]], r3.get_range(C)
  end

  # --- Operator alias parity for intersect ---------------------------------
  def test_d_intersect_operator_alias
    r1 = Rangeable.new.tap { |r| r.insert(A, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(A, start: 5, end: 15) }
    via_method = r1.intersect(r2)
    via_op     = r1 & r2
    assert_equal via_method.get_range(A), via_op.get_range(A)
  end

  def test_d_intersection_alias
    r1 = Rangeable.new.tap { |r| r.insert(A, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(A, start: 5, end: 15) }
    assert_equal r1.intersect(r2).get_range(A), r1.intersection(r2).get_range(A)
  end

  # ===========================================================================
  # §10.E — Difference Tests (#58–#65)
  # ===========================================================================

  # --- #58 — difference with disjoint elements (returns self structurally) -
  def test_e58_difference_disjoint_elements
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.italic, start: 5, end: 15) }
    r3 = r1.difference(r2)
    assert_equal [[0, 10]], Fixtures.strong.get_range(from: r3)
    assert_equal 1, r3.count
    assert_equal 0, r3.version
  end

  # --- #59 — difference with self = empty -----------------------------------
  def test_e59_difference_with_self_empty
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0,  end: 10)
    r1.insert(Fixtures.italic, start: 20, end: 30)
    r2 = r1.difference(r1)
    assert r2.empty?
    assert_equal 0, r2.count
  end

  # --- #60 — difference creates left residuals ------------------------------
  def test_e60_difference_left_residuals
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 5, end: 100) }
    r3 = r1.difference(r2)
    assert_equal [[0, 4]], Fixtures.strong.get_range(from: r3)
  end

  # --- #61 — difference creates right residuals ----------------------------
  def test_e61_difference_right_residuals
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0,    end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: -100, end: 5) }
    r3 = r1.difference(r2)
    assert_equal [[6, 10]], Fixtures.strong.get_range(from: r3)
  end

  # --- #62 — difference creates both residuals (split) ---------------------
  def test_e62_difference_split
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 3, end: 6) }
    r3 = r1.difference(r2)
    assert_equal [[0, 2], [7, 10]], Fixtures.strong.get_range(from: r3)
  end

  # --- #63 — difference spans multiple L_a entries -------------------------
  def test_e63_difference_multi_la_span
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0,  end: 5)
    r1.insert(Fixtures.strong, start: 10, end: 15)
    r1.insert(Fixtures.strong, start: 20, end: 25)
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 3, end: 22) }
    r3 = r1.difference(r2)
    assert_equal [[0, 2], [23, 25]], Fixtures.strong.get_range(from: r3)
  end

  # --- #64 — difference insertion-order preservation -----------------------
  def test_e64_difference_insertion_order_preservation
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r1.insert(C, start: 20, end: 25)
    r1.insert(D, start: 30, end: 35)
    r2 = Rangeable.new
    r2.insert(B, start: 9,   end: 16)
    r2.insert(E, start: 100, end: 200)
    r3 = r1.difference(r2)
    keys = r3.map { |e, _| e }
    assert_equal [A, C, D], keys, 'B fully consumed and pruned; E ignored (not in r1)'
  end

  # --- #65 — difference ≡ remove_ranges-loop equivalence ------------------
  # NOTE on the fixture choice: the RFC §10.E #65 verbatim fixture uses
  # `r2.insert(Strong, 3, 6); r2.insert(Italic, 12, 18)`, but the
  # `remove_ranges`-loop equivalence quoted in §6.12 is "flatten ALL of
  # r2's intervals" then loop. That cross-applies Strong's (3, 6) to
  # Italic and vice versa, which `difference` does NOT (difference is
  # per-element). So the verbatim RFC fixture would intentionally diverge.
  # We instead use a single-element fixture (only Strong is touched on
  # both sides) so the cross-pollution issue does not arise; this still
  # exercises the structural equivalence intent of #65 and matches the
  # RFC's normative invariant for the single-key case (Edge #36).
  def test_e65_difference_eq_remove_ranges_loop
    # Place Italic far away (50-60) so r2's cut range (3, 6) does NOT
    # cross-pollute it via remove_ranges.
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0,  end: 10)
    r1.insert(Fixtures.italic, start: 50, end: 60)
    r2 = Rangeable.new
    r2.insert(Fixtures.strong, start: 3, end: 6)

    r3 = r1.difference(r2)

    r4 = r1.copy
    r2.each do |_e, ranges|
      ranges.each { |lo, hi| r4.remove_ranges(start: lo, end: hi) }
    end

    assert_equal r3.map { |e, _| e },                  r4.map { |e, _| e }
    assert_equal Fixtures.strong.get_range(from: r3),  Fixtures.strong.get_range(from: r4)
    assert_equal Fixtures.italic.get_range(from: r3),  Fixtures.italic.get_range(from: r4)
  end

  # --- Operator alias parity for difference --------------------------------
  def test_e_difference_operator_alias
    r1 = Rangeable.new.tap { |r| r.insert(A, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(A, start: 3, end: 6) }
    via_method = r1.difference(r2)
    via_op     = r1 - r2
    assert_equal via_method.get_range(A), via_op.get_range(A)
  end

  def test_e_subtract_alias
    r1 = Rangeable.new.tap { |r| r.insert(A, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(A, start: 3, end: 6) }
    assert_equal r1.difference(r2).get_range(A), r1.subtract(r2).get_range(A)
  end

  # ===========================================================================
  # §10.F — Symmetric Difference Tests (#66–#71)
  # ===========================================================================

  # --- #66 — sym-diff with empty = self structurally ----------------------
  def test_f66_sym_diff_with_empty_eq_self
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0,  end: 5)
    r1.insert(Fixtures.italic, start: 10, end: 15)
    r3 = r1.symmetric_difference(Rangeable.new)
    assert_equal [Fixtures.strong, Fixtures.italic], r3.map { |e, _| e }
    assert_equal [[0, 5]],   Fixtures.strong.get_range(from: r3)
    assert_equal [[10, 15]], Fixtures.italic.get_range(from: r3)
    assert_equal 0, r3.version
  end

  # --- #67 — sym-diff with self = empty -----------------------------------
  def test_f67_sym_diff_with_self_eq_empty
    r1 = Rangeable.new
    r1.insert(Fixtures.strong, start: 0,  end: 5)
    r1.insert(Fixtures.italic, start: 10, end: 15)
    r2 = r1.symmetric_difference(r1)
    assert r2.empty?
    assert_equal 0, r2.count
  end

  # --- #68 — sym-diff per-element residuals from both sides ---------------
  def test_f68_sym_diff_per_element_residuals
    r1 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(Fixtures.strong, start: 5, end: 15) }
    r3 = r1.symmetric_difference(r2)
    assert_equal [[0, 4], [11, 15]], Fixtures.strong.get_range(from: r3)
  end

  # --- #69 — sym-diff commutativity (modulo insertion_order) --------------
  def test_f69_sym_diff_commutativity_modulo_insertion_order
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r2 = Rangeable.new
    r2.insert(B, start: 12, end: 17)
    r2.insert(C, start: 20, end: 25)
    r3 = r1.symmetric_difference(r2)
    r4 = r2.symmetric_difference(r1)
    # Per-element R(e) is identical.
    assert_equal r3.get_range(A), r4.get_range(A)
    assert_equal r3.get_range(B), r4.get_range(B)
    assert_equal r3.get_range(C), r4.get_range(C)
    assert_equal [[0,  5]],            r3.get_range(A)
    assert_equal [[10, 11], [16, 17]], r3.get_range(B)
    assert_equal [[20, 25]],           r3.get_range(C)
    # insertion_order is NOT commutative (self-primary rule).
    assert_equal [A, B, C], r3.map { |e, _| e }, 'r3.insertion_order is r1-primary'
    assert_equal [B, C, A], r4.map { |e, _| e }, 'r4.insertion_order is r2-primary'
  end

  # --- #70 — sym-diff associativity (RFC §10.F worked derivation) ---------
  # `(r1 △ r2) △ r3 == r1 △ (r2 △ r3) == [(0,4), (10,10), (16,20)]`
  # for `r1=[A:0..10], r2=[A:5..15], r3=[A:10..20]`.
  def test_f70_sym_diff_associativity_single_key
    r1 = Rangeable.new.tap { |r| r.insert(A, start: 0,  end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(A, start: 5,  end: 15) }
    r3 = Rangeable.new.tap { |r| r.insert(A, start: 10, end: 20) }
    left  = r1.symmetric_difference(r2).symmetric_difference(r3)
    right = r1.symmetric_difference(r2.symmetric_difference(r3))
    expected_a = [[0, 4], [10, 10], [16, 20]]
    assert_equal expected_a, left.get_range(A)
    assert_equal expected_a, right.get_range(A)
    assert_equal [A], left.map { |e, _| e }
    assert_equal [A], right.map { |e, _| e }
  end

  # --- #71 — sym-diff insertion_order tail-append for keys ∈ other ∖ self -
  def test_f71_sym_diff_tail_append
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r2 = Rangeable.new
    r2.insert(C, start: 20, end: 25)
    r2.insert(D, start: 30, end: 35)
    r3 = r1.symmetric_difference(r2)
    assert_equal [A, B, C, D], r3.map { |e, _| e }
  end

  # --- Adjacency-collapse worked example (#34 / RFC §6.13) ---------------
  def test_f_sym_diff_adjacency_collapse
    r1 = Rangeable.new.tap { |r| r.insert(A, start: 0, end: 5) }
    r2 = Rangeable.new.tap { |r| r.insert(A, start: 6, end: 10) }
    r3 = r1.symmetric_difference(r2)
    # a = [(0,5)], b = [(6,10)], adjacent at 5+1==6 ⇒ merge to [(0,10)].
    assert_equal [[0, 10]], r3.get_range(A)
  end

  # --- Operator alias parity for sym-diff --------------------------------
  def test_f_sym_diff_operator_alias
    r1 = Rangeable.new.tap { |r| r.insert(A, start: 0, end: 10) }
    r2 = Rangeable.new.tap { |r| r.insert(A, start: 5, end: 15) }
    via_method = r1.symmetric_difference(r2)
    via_op     = r1 ^ r2
    assert_equal via_method.get_range(A), via_op.get_range(A)
  end

  # ===========================================================================
  # §10.G — Set-op Insertion-order Stress Tests (#72–#80)
  # ===========================================================================

  # --- #72 — Dense ord renumber after multi-element prune ----------------
  def test_g72_dense_ord_after_multi_element_prune
    r1 = Rangeable.new
    [A, B, C, D, E].each_with_index do |e, k|
      r1.insert(e, start: k * 2, end: k * 2 + 1)
    end
    r2 = Rangeable.new
    r2.insert(B, start: 100, end: 200)
    r2.insert(D, start: 100, end: 200)
    r3 = r1.intersect(r2)
    assert r3.empty?
    assert_equal 0, r3.count
  end

  # --- #73 — union then intersect preserves insertion_order --------------
  def test_g73_union_then_intersect_chain
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r2 = Rangeable.new
    r2.insert(C, start: 20, end: 25)
    r2.insert(B, start: 12, end: 17)
    r3 = Rangeable.new
    r3.insert(B, start: 0, end: 100)
    r3.insert(C, start: 0, end: 100)

    r_union = r1.union(r2)
    assert_equal [A, B, C], r_union.map { |e, _| e }

    r_chain = r_union.intersect(r3)
    assert_equal [B, C], r_chain.map { |e, _| e }, 'A dropped (not in r3.keys)'
  end

  # --- #74 — Set-op ord ignores pre-prune ord of input ------------------
  def test_g74_set_op_ord_uses_post_prune_input
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r1.insert(C, start: 20, end: 25)
    r1.remove_element(B)  # r1.insertion_order == [A, C], dense ord A=1, C=2.
    r2 = r1.union(Rangeable.new)
    assert_equal [A, C], r2.map { |e, _| e }, 'walks current insertion_order'
  end

  # --- #75 — difference then union recovers insertion_order ------------
  def test_g75_difference_then_union_recovers_order
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 10)
    r1.insert(B, start: 20, end: 30)
    r1.insert(C, start: 40, end: 50)
    r2 = Rangeable.new.tap { |r| r.insert(B, start: 0, end: 100) }
    r3 = r1.difference(r2).union(r1)
    # difference(r2) ⇒ [A, C] (B pruned). union(r1) ⇒ [A, C, B] (B re-tail-appended).
    assert_equal [A, C, B], r3.map { |e, _| e }
  end

  # --- #76 — Union of three with overlapping keys ----------------------
  def test_g76_union_of_three
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r2 = Rangeable.new
    r2.insert(B, start: 20, end: 25)
    r2.insert(C, start: 30, end: 35)
    r3 = Rangeable.new
    r3.insert(C, start: 40, end: 45)
    r3.insert(D, start: 50, end: 55)

    r_chain = r1.union(r2).union(r3)
    assert_equal [A, B, C, D],        r_chain.map { |e, _| e }
    assert_equal [[0, 5]],            r_chain.get_range(A)
    assert_equal [[10, 15], [20, 25]], r_chain.get_range(B)
    assert_equal [[30, 35], [40, 45]], r_chain.get_range(C)
    assert_equal [[50, 55]],          r_chain.get_range(D)
  end

  # --- #77 — sym-diff two algebraic-form equivalence (per-element) -----
  def test_g77_sym_diff_two_form_equivalence
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 10)
    r1.insert(B, start: 20, end: 30)
    r2 = Rangeable.new
    r2.insert(A, start: 5,  end: 15)
    r2.insert(C, start: 40, end: 50)

    form1 = r1.symmetric_difference(r2)
    form2 = r1.union(r2).difference(r1.intersect(r2))

    # Per-element identity (insertion_order MAY differ; we test per-element
    # range identity for each surviving key).
    keys = (form1.map { |e, _| e } | form2.map { |e, _| e }).uniq
    keys.each do |e|
      assert_equal form1.get_range(e), form2.get_range(e), "mismatch for #{e}"
    end
  end

  # --- #78 — Insert-after-remove ord reassignment (R14, also #b above) ---
  def test_g78_insert_after_remove_ord_reassignment
    r = Rangeable.new
    r.insert(A, start: 0,  end: 5)
    r.insert(B, start: 10, end: 15)
    r.remove_element(A)
    r.insert(A, start: 100, end: 110)
    assert_equal [B, A], r.map { |e, _| e }
  end

  # --- #79 — Cross-op ord consistency (intersect after union) ----------
  def test_g79_intersect_after_union_ord_consistency
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r1.insert(C, start: 20, end: 25)
    r2 = Rangeable.new
    r2.insert(B, start: 12, end: 17)
    r2.insert(D, start: 30, end: 35)
    r_union = r1.union(r2)
    assert_equal [A, B, C, D], r_union.map { |e, _| e }

    r3 = Rangeable.new
    r3.insert(B, start: 0, end: 100)
    r3.insert(D, start: 0, end: 100)
    r3.insert(A, start: 0, end: 100)
    r_intersect = r_union.intersect(r3)
    assert_equal [A, B, D], r_intersect.map { |e, _| e }, 'C dropped, dense renumber'
  end

  # --- #80 — Empty result eager prune across set-op chain --------------
  def test_g80_empty_result_eager_prune_chain
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r2 = Rangeable.new
    r2.insert(A, start: 100, end: 200)
    r2.insert(B, start: 100, end: 200)
    r3 = r1.intersect(r2)
    assert r3.empty?, 'both A and B intersect to empty'

    r4 = r3.union(r1)
    # r3 has no keys; union step 2 re-introduces A, B from r1 in its order.
    assert_equal [A, B], r4.map { |e, _| e }
  end

  # ===========================================================================
  # Bang-form (mutating) tests — Ruby idiom-specific
  # ===========================================================================

  def test_bang_union_returns_self_and_chains
    r = Rangeable.new
    r.insert(A, start: 0, end: 5)
    other = Rangeable.new.tap { |x| x.insert(B, start: 10, end: 15) }
    result = r.union!(other)
    assert_same r, result, 'bang form MUST return self'
    assert_equal [A, B], r.map { |e, _| e }
  end

  def test_bang_intersect_returns_self
    r = Rangeable.new
    r.insert(A, start: 0, end: 10)
    r.insert(B, start: 20, end: 30)
    other = Rangeable.new.tap { |x| x.insert(A, start: 5, end: 15) }
    result = r.intersect!(other)
    assert_same r, result
    assert_equal [A], r.map { |e, _| e }, 'B pruned (not in other)'
    assert_equal [[5, 10]], r.get_range(A)
  end

  def test_bang_difference_returns_self
    r = Rangeable.new
    r.insert(A, start: 0, end: 10)
    other = Rangeable.new.tap { |x| x.insert(A, start: 3, end: 6) }
    result = r.difference!(other)
    assert_same r, result
    assert_equal [[0, 2], [7, 10]], r.get_range(A)
  end

  def test_bang_sym_diff_returns_self
    r = Rangeable.new
    r.insert(A, start: 0, end: 10)
    other = Rangeable.new.tap { |x| x.insert(A, start: 5, end: 15) }
    result = r.symmetric_difference!(other)
    assert_same r, result
    assert_equal [[0, 4], [11, 15]], r.get_range(A)
  end

  def test_bang_intersect_self_no_bump
    r = Rangeable.new
    r.insert(A, start: 0, end: 10)
    v0 = r.version
    r.intersect!(r)
    assert_equal v0, r.version, 'intersect!(self) MUST NOT bump version'
  end

  def test_bang_difference_self_empties_with_bump
    r = Rangeable.new
    r.insert(A, start: 0, end: 10)
    r.insert(B, start: 20, end: 30)
    v0 = r.version
    r.difference!(r)
    assert r.empty?, 'difference!(self) ⇒ empty'
    assert_equal v0 + 1, r.version, 'structural change ⇒ one bump'
  end

  def test_bang_sym_diff_self_empties_with_bump
    r = Rangeable.new
    r.insert(A, start: 0, end: 10)
    v0 = r.version
    r.symmetric_difference!(r)
    assert r.empty?, 'symmetric_difference!(self) ⇒ empty'
    assert_equal v0 + 1, r.version, 'structural change ⇒ one bump'
  end

  def test_bang_union_self_no_bump
    r = Rangeable.new
    r.insert(A, start: 0, end: 10)
    r.insert(B, start: 20, end: 30)
    v0 = r.version
    r.union!(r)
    assert_equal v0, r.version, 'union!(self) MUST NOT bump version'
    assert_equal [A, B], r.map { |e, _| e }
  end

  def test_bang_union_chains
    r1 = Rangeable.new.tap { |r| r.insert(A, start: 0, end: 5) }
    r2 = Rangeable.new.tap { |r| r.insert(B, start: 10, end: 15) }
    r3 = Rangeable.new.tap { |r| r.insert(C, start: 20, end: 25) }
    r1.union!(r2).union!(r3)
    assert_equal [A, B, C], r1.map { |e, _| e }
  end

  # ===========================================================================
  # COW-style isolation: dup-then-mutation MUST NOT affect original
  # ===========================================================================

  def test_dup_after_remove_isolation
    r = Rangeable.new
    r.insert(A, start: 0,  end: 10)
    r.insert(B, start: 20, end: 30)
    r2 = r.dup
    r2.remove(A, start: 5, end: 100)
    # Original r unchanged.
    assert_equal [[0, 10]], r.get_range(A)
    assert_equal [[20, 30]], r.get_range(B)
    # Copy reflects the cut.
    assert_equal [[0, 4]],   r2.get_range(A)
    assert_equal [[20, 30]], r2.get_range(B)
  end

  def test_dup_after_remove_element_isolation
    r = Rangeable.new
    r.insert(A, start: 0,  end: 10)
    r.insert(B, start: 20, end: 30)
    r2 = r.dup
    r2.remove_element(A)
    assert_equal [[0, 10]], r.get_range(A), 'original unaffected'
    assert_equal [],        r2.get_range(A), 'copy excised A'
    assert_equal [B], r2.map { |e, _| e }
  end

  def test_dup_after_clear_isolation
    r = Rangeable.new
    r.insert(A, start: 0, end: 10)
    r2 = r.dup
    r2.clear
    refute r.empty?, 'original NOT cleared'
    assert r2.empty?, 'copy cleared'
  end

  def test_dup_after_set_op_bang_isolation
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 10)
    r1.insert(B, start: 20, end: 30)
    r2 = r1.dup
    other = Rangeable.new.tap { |x| x.insert(A, start: 5, end: 100) }
    r2.difference!(other)
    # r1 unchanged.
    assert_equal [[0, 10]],  r1.get_range(A)
    assert_equal [[20, 30]], r1.get_range(B)
    # r2 reflects difference.
    assert_equal [[0, 4]],   r2.get_range(A)
    assert_equal [[20, 30]], r2.get_range(B)
  end

  # ===========================================================================
  # Sym-diff associativity over multi-key sets (extends Test #70)
  # ===========================================================================

  def test_f_sym_diff_associativity_multi_key
    r1 = Rangeable.new
    r1.insert(A, start: 0,  end: 5)
    r1.insert(B, start: 10, end: 15)
    r2 = Rangeable.new
    r2.insert(B, start: 12, end: 17)
    r2.insert(C, start: 20, end: 25)
    r3 = Rangeable.new
    r3.insert(A, start: 3,  end: 7)
    r3.insert(C, start: 22, end: 28)

    left  = r1.symmetric_difference(r2).symmetric_difference(r3)
    right = r1.symmetric_difference(r2.symmetric_difference(r3))
    keys = (left.map { |e, _| e } | right.map { |e, _| e }).uniq
    keys.each do |e|
      assert_equal left.get_range(e), right.get_range(e), "key #{e} mismatch"
    end
  end

  # ===========================================================================
  # Idempotence assertions (cross-cutting; touches §3.2 dual)
  # ===========================================================================

  def test_remove_then_insert_same_range_no_state_drift
    @r.insert(A, start: 0, end: 10)
    v0 = @r.version
    @r.remove(A, start: 3, end: 6)
    @r.insert(A, start: 3, end: 6)
    v_final = @r.version
    assert_equal v0 + 2, v_final, 'one bump for remove (split), one for insert (merge back)'
    assert_equal [[0, 10]], @r.get_range(A)
  end

  def test_clear_after_clear_no_double_bump
    @r.insert(A, start: 0, end: 5)
    @r.clear
    v0 = @r.version
    @r.clear  # idempotent.
    assert_equal v0, @r.version
  end

  def test_remove_ranges_idempotent_after_first_call
    @r.insert(A, start: 0, end: 10)
    @r.remove_ranges(start: 3, end: 6)
    v0 = @r.version
    @r.remove_ranges(start: 3, end: 6)  # already cut; sweep finds no overlap.
    assert_equal v0, @r.version
    assert_equal [[0, 2], [7, 10]], @r.get_range(A)
  end
end
