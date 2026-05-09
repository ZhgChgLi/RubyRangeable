# frozen_string_literal: true

class Rangeable
  # Lazy boundary-event index per RFC §5.2 / §6.3.
  #
  # Built from a snapshot of the per-element interval map plus the
  # insertion-order map `ord`. Carries:
  #
  #   * `events`   — sorted Array of TransitionEvent under §4.5 ordering.
  #   * `segments` — sorted, disjoint Array of (seg_lo, seg_hi, frozen active)
  #                  triples covering every coordinate at which the active
  #                  set is non-empty. Active sets are frozen and sorted by
  #                  `ord(e)` ascending.
  #   * `version`  — snapshot of Rangeable.version at build time. The owner
  #                  Rangeable invalidates the index by setting it to nil
  #                  on any mutation; reads compare versions to decide
  #                  whether to rebuild (T3 mutex pattern, §11).
  #
  # `nil` close coordinates encode +∞ for hi == Integer::MAX boundaries
  # (§4.7 C4). Comparison against `nil` always treats it as greater than
  # any finite Integer; we centralise that logic in `coord_lt?` /
  # `coord_le?`.
  class BoundaryIndex
    # Public TransitionEvent type returned by `Rangeable#transitions`.
    # `coordinate` is normally an Integer; it is `nil` for close events
    # whose underlying interval ends at the implementation's +∞ sentinel
    # (i.e. `hi` was the maximum representable boundary in the cross-language
    # contract). `kind` is `:open` or `:close`.
    TransitionEvent = Struct.new(:coordinate, :kind, :element, :ord) do
      def open?
        kind == :open
      end

      def close?
        kind == :close
      end

      def to_h
        { coordinate: coordinate, kind: kind, element: element }
      end
    end

    # Sentinel: callers may pass `Integer.MAX` semantics by passing the
    # special value below as `hi`. We default to no upper bound so close
    # coords are always `hi + 1` finite Integer except when the caller
    # explicitly opts into the +∞ sentinel via `Rangeable::INT_MAX`.
    #
    # Ruby has unbounded Integer, so this sentinel only matters for
    # cross-language byte-identical fixtures that need to round-trip
    # Swift's `Int.max` boundary (Test #23.A).

    Segment = Struct.new(:lo, :hi, :active)

    attr_reader :events, :segments, :version

    def initialize(events, segments, version)
      @events   = events.freeze
      @segments = segments.freeze
      @version  = version
      freeze
    end

    # Find the segment containing `coord`, or nil if none. O(log |segments|).
    # `coord` must be a finite Integer.
    def segment_at(coord)
      idx = @segments.bsearch_index { |seg| seg.hi >= coord }
      return nil unless idx

      seg = @segments[idx]
      return nil unless seg.lo <= coord
      seg
    end

    # Returns the events whose coordinate falls in `[lo, succ(hi)]` per
    # RFC §6.4. `lo` is a finite Integer; `upper_coord` may be `nil` to
    # mean "include all events through +∞".
    def events_in_range(lo, upper_coord)
      i_start = @events.bsearch_index { |ev| coord_ge?(ev.coordinate, lo) } || @events.size
      result = []
      i = i_start
      while i < @events.size && coord_le?(@events[i].coordinate, upper_coord)
        result << @events[i]
        i += 1
      end
      result
    end

    # Build a fresh index from the per-element interval map and the
    # insertion-order map `ord`. `int_max_sentinel` (default nil) lets the
    # caller opt into "treat hi == sentinel as +∞" semantics for cross-
    # language fixture parity; if it is nil we never coerce close coords
    # to nil (Ruby's unbounded Integer makes that unnecessary).
    def self.build(intervals, ord, snapshot_version, int_max_sentinel: nil)
      events = []
      intervals.each do |element, set|
        element_ord = ord[element]
        set.each do |interval|
          events << TransitionEvent.new(interval.lo, :open, element, element_ord)
          close_coord =
            if !int_max_sentinel.nil? && interval.hi == int_max_sentinel
              nil
            else
              interval.hi + 1
            end
          events << TransitionEvent.new(close_coord, :close, element, element_ord)
        end
      end

      events.sort! do |a, b|
        cmp = compare_coord(a.coordinate, b.coordinate)
        next cmp unless cmp.zero?

        # Same coord: opens before closes.
        cmp = (a.kind == :open ? 0 : 1) <=> (b.kind == :open ? 0 : 1)
        next cmp unless cmp.zero?

        # Same coord + same kind: open ascending by ord, close descending.
        if a.kind == :open
          a.ord <=> b.ord
        else
          b.ord <=> a.ord
        end
      end

      segments = materialise_segments(events)
      new(events, segments, snapshot_version)
    end

    # Sweep events linearly, materialising a Segment for every maximal run
    # of integers over which the active set is constant. Per RFC §6.3 we
    # do not emit a segment whose active set is empty (no phantom
    # `(-inf, first_open - 1)` segment).
    def self.materialise_segments(events)
      segments = []
      active_by_ord = {} # ord => element (treated as a sorted set keyed by ord)
      prev_coord = nil
      i = 0
      while i < events.size
        # Group events at the same coord; we apply all of them before
        # snapshotting the active set so that segment boundaries land on
        # transitions, not in the middle of a same-coord burst.
        ev = events[i]
        coord = ev.coordinate

        if !prev_coord.nil? && !active_by_ord.empty?
          segments << Segment.new(prev_coord, coord - 1, snapshot_active(active_by_ord))
        end

        # Apply every event at this coord.
        while i < events.size && events[i].coordinate == coord
          ev_i = events[i]
          if ev_i.open?
            active_by_ord[ev_i.ord] = ev_i.element
          else
            active_by_ord.delete(ev_i.ord)
          end
          i += 1
        end

        prev_coord = coord
      end
      segments
    end

    # Snapshot the active set as a frozen Array sorted by ord ascending.
    # The Hash insertion order is not guaranteed to match ord ascending
    # (we add/remove arbitrarily), so we sort explicitly.
    def self.snapshot_active(active_by_ord)
      active_by_ord.keys.sort.map { |o| active_by_ord[o] }.freeze
    end

    # Total order over coordinates: nil (== +∞) is greater than any finite.
    # Returns -1 / 0 / +1.
    def self.compare_coord(a, b)
      return 0 if a.nil? && b.nil?
      return 1 if a.nil?
      return -1 if b.nil?

      a <=> b
    end

    private

    def coord_ge?(coord, threshold)
      self.class.compare_coord(coord, threshold) >= 0
    end

    def coord_le?(coord, upper)
      self.class.compare_coord(coord, upper) <= 0
    end
  end
end
