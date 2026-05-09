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

  private

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
