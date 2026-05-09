# frozen_string_literal: true

class Rangeable
  # Immutable closed integer interval [lo, hi].
  #
  # Used internally as the storage form within Rangeable::DisjointSet. Instances
  # are produced by `insert` and never mutated; equality is structural so two
  # intervals with the same `lo` / `hi` compare equal under `==`, `eql?` and
  # `hash`.
  class Interval
    attr_reader :lo, :hi

    def initialize(lo, hi)
      raise ArgumentError, "lo (#{lo}) > hi (#{hi})" if lo > hi

      @lo = lo
      @hi = hi
      freeze
    end

    # Inclusive containment check: true when `coord` falls inside [lo, hi].
    def include?(coord)
      lo <= coord && coord <= hi
    end

    # Returns the interval as a 2-element array `[lo, hi]`.
    def to_a
      [lo, hi]
    end

    def ==(other)
      other.is_a?(Interval) && other.lo == lo && other.hi == hi
    end
    alias eql? ==

    def hash
      [Interval, lo, hi].hash
    end

    def to_s
      "[#{lo}, #{hi}]"
    end

    def inspect
      "#<Rangeable::Interval lo=#{lo} hi=#{hi}>"
    end
  end
end
