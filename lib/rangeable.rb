# frozen_string_literal: true

require_relative 'rangeable/version'
require_relative 'rangeable/interval'
require_relative 'rangeable/slot'
require_relative 'rangeable/disjoint_set'
require_relative 'rangeable/boundary_index'

# `Rangeable` is the language-neutral, generic, integer-coordinate closed-
# interval set container described in `RFC.md`. It pairs hashable elements
# with their merged disjoint integer ranges and supports three query
# families: by-element (`get_range`), by-position (`r[i]`) and by-range
# (`transitions`). See RFC §3 for the API surface.
class Rangeable
  # Raised when an interval is malformed (start > end). Subclassing
  # `ArgumentError` keeps it `rescue`able alongside other invalid-arg
  # mistakes per RFC §3.7.
  class InvalidIntervalError < ArgumentError; end

  # `Rangeable::TransitionEvent` is the public alias for the Struct defined
  # inside the index. Re-exposed here so callers don't need to reach through
  # `BoundaryIndex` to reference its type.
  TransitionEvent = ::Rangeable::BoundaryIndex::TransitionEvent unless const_defined?(:TransitionEvent, false)

  # Frozen empty Array we hand back from `[]` when the coordinate is
  # outside every segment. Avoids re-allocating an empty Array per query.
  EMPTY_ACTIVE = [].freeze unless const_defined?(:EMPTY_ACTIVE, false)

  attr_reader :version

  # Build a fresh empty container. RFC §3.1.
  def initialize
    @intervals       = {}     # element => DisjointSet
    @insertion_order = []     # Array<element> in first-insert order
    @ord             = {}     # element => Integer (1-based)
    @version         = 0
    @event_index     = nil    # BoundaryIndex or nil (lazy)
  end

  # Sugar: `Rangeable.empty` matches the RFC §3.1 alias.
  def self.empty
    new
  end

  # Insert `element` covering `[start, end_]` (closed interval). Idempotent
  # by RFC §3.2: re-inserting a sub-range that is already fully contained
  # leaves the container unchanged and does NOT bump version.
  #
  # The RFC reference uses the keyword `end:`, but Ruby treats `end` inside
  # method headers as a soft-keyword that is fine in keyword-arg position.
  # We accept it that way to match the RFC API exactly.
  def insert(element, start:, end:)
    end_ = binding.local_variable_get(:end)
    raise InvalidIntervalError, "start (#{start}) > end (#{end_})" if start > end_

    e = freeze_for_insert(element)

    set = @intervals[e]
    if set.nil?
      set = DisjointSet.new
      @intervals[e] = set
      @insertion_order << e
      @ord[e] = @insertion_order.length
    end

    result = set.insert(start, end_)
    if result == DisjointSet::MUTATED
      @version += 1
      @event_index = nil
    end
    self
  end

  # Active-element list at `i`. RFC §3.3.
  # O(log |segments| + r) once the index is built.
  #
  # Hot path: we inline the segment bsearch here (instead of going through
  # a private helper or method dispatch into BoundaryIndex#segment_at) so
  # `r[i]` stays allocation-free apart from the unavoidable `Slot`
  # envelope. The cached active array on the segment is already frozen,
  # so `Slot.new` does not duplicate it (see `Slot#initialize`).
  def [](i)
    ensure_event_index_fresh
    segs = @event_index.segments
    idx = segs.bsearch_index { |seg| seg.hi >= i }
    if idx
      seg = segs[idx]
      if seg.lo <= i
        Slot.new(seg.active)
      else
        Slot.new(EMPTY_ACTIVE)
      end
    else
      Slot.new(EMPTY_ACTIVE)
    end
  end
  alias active_at_index []

  # Same as `[]` but spelled out to match RFC §3.3.
  def active_at(index:)
    self[index]
  end

  # Merged ranges for `element` as `[[lo, hi], ...]`. RFC §3.4. Returns an
  # empty Array when the element has never been inserted.
  def get_range(element)
    set = @intervals[element]
    return [] unless set

    set.to_pairs
  end
  alias range_of get_range
  alias get_range_of get_range

  # Transitions (open / close events) within an inclusive coordinate range.
  # Accepts a Ruby `Range` (inclusive or exclusive). RFC §3.5.
  def transitions(over:)
    raise InvalidIntervalError, "transitions range must be a Range" unless over.is_a?(Range)

    lo = over.begin
    hi = over.end
    raise InvalidIntervalError, "open-ended begin not supported" if lo.nil?

    # Normalise exclusive end (`a...b` ⇒ inclusive end `b - 1`).
    hi = hi - 1 if !hi.nil? && over.exclude_end?

    # Open-ended top (`a..nil`) means +∞ ⇒ include all events.
    if hi.nil?
      raise InvalidIntervalError, "lo (#{lo}) > hi (nil)" if lo.nil?
    else
      raise InvalidIntervalError, "lo (#{lo}) > hi (#{hi})" if lo > hi
    end

    ensure_event_index_fresh
    upper = hi.nil? ? nil : hi + 1
    @event_index.events_in_range(lo, upper).map do |ev|
      TransitionEvent.new(ev.coordinate, ev.kind, ev.element, ev.ord)
    end
  end

  # Number of distinct equivalence-class elements ever inserted. RFC §3.5.1.
  def count
    @insertion_order.length
  end
  alias size count
  alias length count

  # `count == 0`. RFC §3.5.1.
  def empty?
    @insertion_order.empty?
  end

  # Iterate `(element, ranges)` pairs in insertion-order ascending. RFC §3.5.1.
  def each(&block)
    return enum_for(:each) unless block_given?

    @insertion_order.each do |element|
      yield element, @intervals[element].to_pairs
    end
    self
  end
  include Enumerable

  # Deep copy of the entire container per RFC §3.5.1. Mutation on the copy
  # MUST NOT affect this instance and vice versa.
  def copy
    dup_instance = self.class.new
    @insertion_order.each do |element|
      dup_instance.send(:replant, element, @intervals[element], @ord[element])
    end
    dup_instance.send(:set_version_after_copy, @version)
    dup_instance
  end
  alias dup copy
  alias clone copy

  # Sugar form: `Rangeable.range_of(element, from: r)`. RFC §3.4.
  def self.range_of(element, from:)
    from.get_range(element)
  end

  # Refinement-only sugar so `element.get_range(from: r)` works without
  # polluting the global Object namespace. Caller does `using Rangeable::Refinements`.
  module Refinements
    refine Object do
      def get_range(from:)
        from.get_range(self)
      end
    end
  end

  # ===========================================================================
  # v2 Removal API (RFC §6.6–§6.9, §4.10 eager-pruning)
  # ===========================================================================

  # Remove the closed interval `[start_, end_]` from `R(element)`. RFC §6.6.
  # Splits an entry if the cut lies strictly inside it. Idempotent (no-op,
  # no version bump) when `element` is absent or no entry overlaps the cut
  # window. Eagerly prunes `element` if its `R(e)` becomes empty (§4.10 N1).
  def remove(element, start:, end:)
    end_ = binding.local_variable_get(:end)
    raise InvalidIntervalError, "start (#{start}) > end (#{end_})" if start > end_

    set = @intervals[element]
    return self if set.nil?  # §4.10 (N3): no R(e) ⇒ no-op, no bump.

    result = set.remove_subrange(start, end_)
    return self if result == DisjointSet::IDEMPOTENT

    # Eager pruning (§4.10 N1) when R(e) is now ∅.
    excise_element(element) if set.empty?

    @version += 1
    @event_index = nil
    self
  end

  # Fully remove `element` from the container. RFC §6.7. Idempotent on a
  # never-inserted element. Eagerly excises and densely renumbers `ord`.
  def remove_element(element)
    # Hash#delete returns the deleted value or nil. nil ⇒ key absent ⇒
    # no-op per §4.10 (N3); MUST NOT bump version.
    return self unless @intervals.delete(element)

    idx = @insertion_order.index(element)
    @insertion_order.delete_at(idx)
    @ord.delete(element)
    # Renumber ord densely for elements that moved up by one position.
    (idx...@insertion_order.length).each do |k|
      @ord[@insertion_order[k]] = k + 1
    end

    @version += 1
    @event_index = nil
    self
  end
  alias delete remove_element

  # Reset the container to its empty state. RFC §6.8. Idempotent on an
  # already-empty container (no version bump).
  def clear
    return self if @insertion_order.empty?  # §4.10 (N3) idempotence.

    @intervals       = {}
    @insertion_order = []
    @ord             = {}
    @version += 1
    @event_index = nil
    self
  end
  alias remove_all clear

  # Subtract `[start_, end_]` from every element's `R(e)`. RFC §6.9.
  # Atomic: at most one version bump for the entire op. Eagerly prunes
  # any element whose `R(e)` becomes empty. No-op (no bump) if no element
  # overlaps the cut window.
  def remove_ranges(start:, end:)
    end_ = binding.local_variable_get(:end)
    raise InvalidIntervalError, "start (#{start}) > end (#{end_})" if start > end_

    any_change = false
    # Iterate a snapshot of @insertion_order: we may delete from @intervals
    # mid-loop. We do NOT mutate @insertion_order in this loop — the §6.9
    # pseudocode defers the rebuild to step 4 to avoid O(E²) delete_at cost.
    @insertion_order.each do |element|
      set = @intervals[element]
      result = set.remove_subrange(start, end_)
      next if result == DisjointSet::IDEMPOTENT

      any_change = true
      @intervals.delete(element) if set.empty?
    end

    return self unless any_change  # §4.10 (N3) no-op.

    # Step 4: single-pass rebuild of insertion_order and dense ord.
    @insertion_order = @insertion_order.select { |e| @intervals.key?(e) }
    @ord = {}
    @insertion_order.each_with_index { |e, k| @ord[e] = k + 1 }

    @version += 1
    @event_index = nil
    self
  end

  # ===========================================================================
  # v2 Set Operations API (RFC §6.10–§6.13)
  # ===========================================================================

  # Per-element `R_self(e) ∪ R_other(e)`. Returns a fresh `Rangeable` with
  # `version == 0`. Insertion-order rule: preserve `self`'s, tail-append
  # keys ∈ `other` ∖ `self` in `other`'s insertion-order order. RFC §6.10.
  def union(other)
    raise ArgumentError, "expected Rangeable, got #{other.class}" unless other.is_a?(Rangeable)

    out = self.class.new

    # Step 1: walk self's insertion_order; merge with other if shared key.
    @insertion_order.each do |element|
      list_self  = @intervals[element].entries
      other_set  = other.send(:intervals_internal)[element]
      list_other = other_set ? other_set.entries : EMPTY_ACTIVE
      merged = DisjointSet.merge_disjoint_lists(list_self, list_other)
      # length(merged) > 0 is guaranteed because list_self is non-empty (I1.4).
      out.send(:install_element, element, DisjointSet.from_entries(merged))
    end

    # Step 2: tail-append keys ∈ other ∖ self in other's insertion order.
    other.send(:insertion_order_internal).each do |element|
      next if @intervals.key?(element)

      other_entries = other.send(:intervals_internal)[element].entries
      out.send(:install_element, element, DisjointSet.from_entries(other_entries.dup))
    end

    out
  end
  alias_method :|, :union

  # Per-element `R_self(e) ∩ R_other(e)` for keys in both. Empty results
  # are eagerly pruned (§4.10). Insertion-order: preserve self's order over
  # surviving keys. RFC §6.11.
  def intersect(other)
    raise ArgumentError, "expected Rangeable, got #{other.class}" unless other.is_a?(Rangeable)

    out = self.class.new

    @insertion_order.each do |element|
      other_set = other.send(:intervals_internal)[element]
      next unless other_set  # not in other ⇒ drop.

      list_self  = @intervals[element].entries
      list_other = other_set.entries
      intersected = DisjointSet.intersect_disjoint_lists(list_self, list_other)
      next if intersected.empty?  # eager prune.

      out.send(:install_element, element, DisjointSet.from_entries(intersected))
    end

    out
  end
  alias_method :&, :intersect
  alias intersection intersect

  # Per-element `R_self(e) ∖ R_other(e)`. Empty results eagerly pruned.
  # Insertion-order: preserve self's order over surviving keys. RFC §6.12.
  def difference(other)
    raise ArgumentError, "expected Rangeable, got #{other.class}" unless other.is_a?(Rangeable)

    out = self.class.new

    @insertion_order.each do |element|
      list_self = @intervals[element].entries
      other_set = other.send(:intervals_internal)[element]
      remaining =
        if other_set.nil? || other_set.empty?
          list_self.dup
        else
          DisjointSet.subtract_disjoint_lists(list_self, other_set.entries)
        end
      next if remaining.empty?  # eager prune.

      out.send(:install_element, element, DisjointSet.from_entries(remaining))
    end

    out
  end
  alias_method :-, :difference
  alias subtract difference

  # Per-element `R_self(e) △ R_other(e) = (self∖other) ∪ (other∖self)`.
  # Empty results eagerly pruned. Insertion-order: preserve self's order
  # for `e ∈ keys(self)`; tail-append `e ∈ keys(other) ∖ keys(self)` in
  # other's order. RFC §6.13.
  #
  # `merge_disjoint_lists` (NOT sorted concat) is required because the two
  # one-sided residuals can be integer-adjacent (RFC §10.B Test #34 worked
  # example: `R_self=[(0,5)], R_other=[(6,10)]` ⇒ a=[(0,5)], b=[(6,10)],
  # adjacent at 5+1==6, must collapse to [(0,10)]).
  def symmetric_difference(other)
    raise ArgumentError, "expected Rangeable, got #{other.class}" unless other.is_a?(Rangeable)

    out = self.class.new

    # Step 1: self-primary keys.
    @insertion_order.each do |element|
      list_self  = @intervals[element].entries
      other_set  = other.send(:intervals_internal)[element]
      list_other = other_set ? other_set.entries : EMPTY_ACTIVE
      a = DisjointSet.subtract_disjoint_lists(list_self,  list_other)
      b = DisjointSet.subtract_disjoint_lists(list_other, list_self)
      sym = DisjointSet.merge_disjoint_lists(a, b)
      next if sym.empty?  # eager prune.

      out.send(:install_element, element, DisjointSet.from_entries(sym))
    end

    # Step 2: other-only keys.
    other.send(:insertion_order_internal).each do |element|
      next if @intervals.key?(element)

      other_entries = other.send(:intervals_internal)[element].entries
      next if other_entries.empty?  # defensive; (I1.4) makes this unreachable.

      out.send(:install_element, element, DisjointSet.from_entries(other_entries.dup))
    end

    out
  end
  alias_method :^, :symmetric_difference

  # ---------------------------------------------------------------------------
  # Mutating set ops (Ruby `!` convention). All four ALWAYS return self for
  # chain-friendliness. Each bumps `version` exactly once iff the result
  # differs structurally from `self` (per §6.10–§6.13 idempotence dual).
  # Implementation strategy: build the new container via the non-mutating
  # form (copy-then-swap), then compare to self. If structurally identical,
  # discard and skip the bump.
  # ---------------------------------------------------------------------------

  def union!(other)
    swap_with(union(other))
  end

  def intersect!(other)
    swap_with(intersect(other))
  end
  alias intersection! intersect!

  def difference!(other)
    swap_with(difference(other))
  end
  alias subtract! difference!

  def symmetric_difference!(other)
    swap_with(symmetric_difference(other))
  end

  private

  # Internal accessor for set-op fast paths — exposed via `send` so the
  # public surface stays clean. Returns the live @intervals Hash.
  def intervals_internal
    @intervals
  end

  def insertion_order_internal
    @insertion_order
  end

  # Splice an already-canonical DisjointSet into this container under
  # `element`. Used by set-op result construction. Caller MUST guarantee
  # the element is not already a key (we tail-append to insertion_order).
  def install_element(element, set)
    @intervals[element]   = set
    @insertion_order      << element
    @ord[element]         = @insertion_order.length
  end

  # Excise an element from all three element-keyed structures and densely
  # renumber `ord` for the survivors at positions ≥ idx. Used by §6.6
  # eager-prune path.
  def excise_element(element)
    @intervals.delete(element)
    idx = @insertion_order.index(element)
    @insertion_order.delete_at(idx)
    @ord.delete(element)
    (idx...@insertion_order.length).each do |k|
      @ord[@insertion_order[k]] = k + 1
    end
  end

  # In-place swap helper for the mutating set-op variants. Compares the
  # candidate result `other` to `self` structurally; if equal, no-op (no
  # version bump). Otherwise replaces all element-keyed state with `other`'s
  # contents and bumps version exactly once. Always returns self.
  def swap_with(other)
    return self if structurally_equal?(other)

    @intervals       = other.send(:intervals_internal)
    @insertion_order = other.send(:insertion_order_internal)
    @ord             = other.send(:ord_internal)
    @version += 1
    @event_index = nil
    self
  end

  # Internal accessor so `swap_with` can read the candidate's ord map.
  def ord_internal
    @ord
  end

  # Structural-equality test for the swap fast-path: same insertion order
  # AND per-element same canonical entries. Used by mutating set ops to
  # honor the §3.2 idempotence dual ("no bump if result == self").
  def structurally_equal?(other)
    return false unless @insertion_order == other.send(:insertion_order_internal)

    other_intervals = other.send(:intervals_internal)
    @insertion_order.all? do |e|
      a = @intervals[e].entries
      b = other_intervals[e].entries
      a.size == b.size && a.zip(b).all? { |x, y| x.lo == y.lo && x.hi == y.hi }
    end
  end

  # RFC §4.6 (M2): freeze on insert as cheap defence against caller-side
  # mutation of hash-affecting state. We try to dup-then-freeze; if `dup`
  # is not supported (some Symbol-like cases) we fall back to the original.
  def freeze_for_insert(element)
    return element if element.frozen?

    begin
      element.dup.freeze
    rescue TypeError
      element
    end
  end

  def ensure_event_index_fresh
    return if @event_index && @event_index.version == @version

    # Snapshot the version at the start of the build. After build, recheck
    # against `@version` (T3 mutex pattern, §11). In Ruby's GVL world this
    # is mostly a no-op, but the comment exists to flag the contract for
    # any future Ractor port.
    v_start = @version
    rebuilt = BoundaryIndex.build(@intervals, @ord, v_start)
    @event_index = rebuilt if @version == v_start
  end

  # Public-ish helper kept available for direct callers. The hot path in
  # `[]` inlines this for one less method dispatch per query.
  def active_at_coord(coord)
    ensure_event_index_fresh
    seg = @event_index.segment_at(coord)
    seg ? seg.active : EMPTY_ACTIVE
  end

  # Used by `copy` to clone an element's interval set with its ord intact.
  # Lives here as a private setter so the public surface stays clean.
  def replant(element, source_set, source_ord)
    new_set = DisjointSet.new
    source_set.each do |iv|
      # MUTATED is the only outcome for sequential insertions of disjoint,
      # ordered intervals into an empty set; we don't need to inspect the
      # return value but we still call insert to keep all invariants in
      # one place.
      new_set.insert(iv.lo, iv.hi)
    end
    @intervals[element] = new_set
    @insertion_order << element
    @ord[element] = source_ord
  end

  def set_version_after_copy(v)
    @version = v
  end
end
