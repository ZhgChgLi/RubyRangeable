# frozen_string_literal: true

require_relative 'interval'

class Rangeable
  # Sorted, disjoint, non-adjacent list of `Interval` for a single element.
  #
  # Maintains RFC §5.1 (I1) invariant:
  #   * sorted by lo strictly ascending
  #   * any two adjacent entries (lo1, hi1), (lo2, hi2) satisfy hi1 + 1 < lo2
  #     (no overlap, no integer adjacency)
  #   * lo <= hi for every entry
  #
  # `insert` follows RFC §6.1 cleaner variant (containment idempotent
  # fast-path) and signals to the caller whether the mutation actually
  # changed the canonical state.
  class DisjointSet
    # Result codes returned from `insert`. The caller (Rangeable) uses these
    # to decide whether to bump the container-level version counter.
    MUTATED    = :mutated
    IDEMPOTENT = :idempotent

    def initialize
      @entries = []
    end

    # Returns a frozen snapshot of the merged intervals as `[[lo, hi], ...]`.
    # The list satisfies RFC §5.1 (I1).
    def to_pairs
      @entries.map(&:to_a)
    end

    def each(&block)
      @entries.each(&block)
    end

    def empty?
      @entries.empty?
    end

    def size
      @entries.size
    end

    # Insert `[lo, hi]` into the set, performing union-with-merge per RFC §6.1.
    # Returns `MUTATED` if the canonical state changed (caller should bump
    # version), `IDEMPOTENT` if the insert was absorbed by an existing entry
    # (caller MUST NOT bump version, per Test #21 and Lemma 6.5.B).
    def insert(lo, hi)
      raise ArgumentError, "lo (#{lo}) > hi (#{hi})" if lo > hi

      # Step 4 of §6.1: bsearch for the leftmost touch candidate.
      # Predicate: `iv.hi + 1 >= lo`. We use `iv.hi + 1` (not `lo - 1`) to
      # avoid Integer underflow at lo == Int.min boundaries (§4.7 C5).
      i0 = @entries.bsearch_index { |iv| iv.hi + 1 >= lo } || @entries.size

      # Step 5: collect contiguous touch entries while `entries[i].lo <= hi + 1`.
      to_merge_end = i0
      while to_merge_end < @entries.size && @entries[to_merge_end].lo <= hi + 1
        to_merge_end += 1
      end
      merge_count = to_merge_end - i0

      # Step 6: containment idempotent fast-path. If we touch exactly one
      # existing entry that fully covers [lo, hi], this insert is a no-op.
      # MUST NOT mutate, MUST NOT bump version.
      if merge_count == 1
        existing = @entries[i0]
        if existing.lo <= lo && hi <= existing.hi
          return IDEMPOTENT
        end
      end

      # Step 7: real mutation path. Compute merged bounds, splice in.
      new_lo = lo
      new_hi = hi
      if merge_count.positive?
        first = @entries[i0]
        last  = @entries[to_merge_end - 1]
        new_lo = first.lo if first.lo < new_lo
        new_hi = last.hi  if last.hi  > new_hi
      end
      merged = Interval.new(new_lo, new_hi)
      # `slice!` removes the touched range; then we splice the merged
      # interval at i0. Equivalent to the §6.1 reference pseudocode but
      # avoids repeated O(m_e) shifts that delete_at would cause in a loop.
      @entries.slice!(i0, merge_count) if merge_count.positive?
      @entries.insert(i0, merged)
      MUTATED
    end
  end
end
