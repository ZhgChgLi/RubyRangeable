# frozen_string_literal: true

class Rangeable
  # Thin wrapper returned by `Rangeable#[]`. Wraps the active-element list at
  # a single coordinate so we can grow the surface (e.g. add `count`,
  # `transitions`, etc.) without changing the public type.
  #
  # `objs` is always a frozen `Array` of elements ordered by first-insert
  # `ord(e)` ascending (RFC §4.5). We use a `Struct` (rather than a plain
  # class) because the hot-path call sites are `r[i].objs` and the Struct
  # accessor is materially faster than going through `attr_reader` + an
  # ivar in MRI.
  Slot = Struct.new(:objs) do
    def empty?
      objs.empty?
    end

    def size
      objs.size
    end
    alias_method :count, :size
    alias_method :length, :size

    def each(&block)
      objs.each(&block)
    end

    def to_a
      objs.dup
    end

    def inspect
      "#<Rangeable::Slot objs=#{objs.inspect}>"
    end
  end
end
