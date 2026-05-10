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
  # changed the canonical state. `remove` follows RFC §6.6 with the same
  # mutated-vs-idempotent distinction (both use the same return symbols so
  # the upstream `Rangeable` only writes one version-bump branch).
  class DisjointSet
    # Result codes returned from `insert` / `remove_subrange`. The caller
    # (Rangeable) uses these to decide whether to bump the container-level
    # version counter.
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

    # Read-only access to the underlying Array<Interval>. Returned reference
    # is the live storage — callers that mutate it violate (I1). Used by the
    # set-op two-pointer sweeps in `Rangeable` to avoid an Array allocation
    # on every union/intersect/difference call.
    def entries
      @entries
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

    # Subtract `[start_, end_]` from the set (§6.6 sweep+splice). Returns
    # `MUTATED` if any entry was changed; `IDEMPOTENT` if no overlap.
    # Caller is responsible for the eager-prune (§4.10 N1) check via `empty?`.
    def remove_subrange(start_, end_)
      raise ArgumentError, "lo (#{start_}) > hi (#{end_})" if start_ > end_

      # Step 3 of §6.6: leftmost entry where `iv.hi >= start_`. Strict
      # overlap; adjacency does NOT subtract anything.
      i = @entries.bsearch_index { |iv| iv.hi >= start_ } || @entries.size

      # Step 4: quick-exit. Either no entry crosses or past the cut window.
      return IDEMPOTENT if i == @entries.size || @entries[i].lo > end_

      # Step 5: sweep all overlapping entries; produce 0..2 residuals each.
      to_replace_start = i
      replacements = []
      while i < @entries.size && @entries[i].lo <= end_
        iv = @entries[i]
        # Left residual exists iff iv.lo < start_; underflow-safe since
        # start_ > iv.lo >= Int.min ⇒ start_ - 1 well-defined (§6.6).
        replacements << Interval.new(iv.lo, start_ - 1) if iv.lo < start_
        # Right residual exists iff end_ < iv.hi; overflow-safe since
        # end_ < iv.hi <= Int.max ⇒ end_ + 1 well-defined.
        replacements << Interval.new(end_ + 1, iv.hi) if end_ < iv.hi
        i += 1
      end
      to_replace_end = i

      # Step 6/7: splice. `slice!` then `insert` mirrors the reference
      # `replace_subrange` and avoids quadratic shifts.
      @entries.slice!(to_replace_start, to_replace_end - to_replace_start)
      @entries.insert(to_replace_start, *replacements) unless replacements.empty?
      MUTATED
    end

    # Replace the live entries with the given (I1)-canonical list. Used by
    # set-op pipelines that compute the canonical result list externally
    # (e.g. `merge_disjoint_lists`) and want to drop it in without re-running
    # `insert`. Caller MUST guarantee the list satisfies (I1.1)–(I1.3); we
    # do not re-verify (this is the internal hot path).
    def replace_entries(new_entries)
      @entries = new_entries
    end

    # Build a new DisjointSet directly from a known-canonical Array<Interval>.
    # Used by set-op result construction; bypasses the `insert` cost path.
    def self.from_entries(entries)
      ds = new
      ds.replace_entries(entries.dup)
      ds
    end

    # === Set-op primitives (RFC §6.10–§6.13) ===
    #
    # All three primitives take Array<Interval> inputs and return
    # Array<Interval> outputs. They live here (rather than on Rangeable)
    # because they operate on per-element interval lists, which is exactly
    # the DisjointSet's domain.

    # §6.10 union helper: merge two (I1)-canonical lists into one
    # (I1)-canonical list via two-pointer sweep + adjacency-collapse.
    # `O(|l1| + |l2|)`. Either input may be empty.
    def self.merge_disjoint_lists(l1, l2)
      out = []
      i = 0
      j = 0
      n1 = l1.size
      n2 = l2.size
      while i < n1 && j < n2
        if l1[i].lo <= l2[j].lo
          append_or_merge(out, l1[i])
          i += 1
        else
          append_or_merge(out, l2[j])
          j += 1
        end
      end
      while i < n1
        append_or_merge(out, l1[i])
        i += 1
      end
      while j < n2
        append_or_merge(out, l2[j])
        j += 1
      end
      out
    end

    # §6.11 intersect helper: pairwise intersection via two-pointer sweep.
    # No adjacency-collapse needed (Lemma 6.11.A). `O(|l1| + |l2|)`.
    def self.intersect_disjoint_lists(l1, l2)
      out = []
      i = 0
      j = 0
      n1 = l1.size
      n2 = l2.size
      while i < n1 && j < n2
        a = l1[i]
        b = l2[j]
        lo = a.lo > b.lo ? a.lo : b.lo
        hi = a.hi < b.hi ? a.hi : b.hi
        out << Interval.new(lo, hi) if lo <= hi
        if a.hi <= b.hi
          i += 1
        else
          j += 1
        end
      end
      out
    end

    # §6.12 difference helper: subtract every interval in `l_b` from every
    # interval in `l_a`. Two-pointer "in-flight current" sweep. `O(|l_a| + |l_b|)`.
    def self.subtract_disjoint_lists(l_a, l_b)
      out = []
      i = 0
      j = 0
      n_a = l_a.size
      n_b = l_b.size
      current_lo = nil
      current_hi = nil
      while i < n_a
        if current_lo.nil?
          current_lo = l_a[i].lo
          current_hi = l_a[i].hi
        end
        # Skip l_b entries strictly before the current entry.
        j += 1 while j < n_b && l_b[j].hi < current_lo

        if j == n_b || l_b[j].lo > current_hi
          # No more l_b cuts on this entry; commit and advance i.
          out << Interval.new(current_lo, current_hi)
          i += 1
          current_lo = nil
          current_hi = nil
          next
        end

        # l_b[j] overlaps [current_lo, current_hi]; cut.
        # Left residual: (current_lo, l_b[j].lo - 1). Underflow-safe: only
        # taken when l_b[j].lo > current_lo, so l_b[j].lo > Int.min.
        out << Interval.new(current_lo, l_b[j].lo - 1) if l_b[j].lo > current_lo
        if l_b[j].hi < current_hi
          # Right residual remains as the new current; advance j.
          # Overflow-safe: l_b[j].hi < current_hi ≤ Int.max.
          current_lo = l_b[j].hi + 1
          j += 1
        else
          # l_b[j] swallows the rest of the current entry; advance i.
          i += 1
          current_lo = nil
          current_hi = nil
        end
      end
      out
    end

    # @api private
    # Helper for `merge_disjoint_lists`: append `iv` to `out`, collapsing
    # if it overlaps or is integer-adjacent to `out.last`.
    def self.append_or_merge(out, iv)
      if out.empty? || out.last.hi + 1 < iv.lo
        out << iv
      else
        # Overlap or adjacency: extend the last entry's hi if needed.
        last = out.last
        if iv.hi > last.hi
          out[-1] = Interval.new(last.lo, iv.hi)
        end
      end
    end
  end
end
