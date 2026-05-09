# frozen_string_literal: true

require_relative 'test_helper'

# Property test: 1000 random insertions across a fixed seed, then sweep
# every coordinate in the spanning range and compare against the brute-
# force oracle. The oracle independently rebuilds the active set for each
# coordinate by walking the raw triple list, so any RFC §4.5 ordering bug
# or merge bug surfaces immediately.
class PropertyTest < Minitest::Test
  ITERATIONS = 1_000
  COORD_BOUND = 200

  def test_random_inserts_match_brute_force
    rng = Random.new(2026_05_09)
    elements = [Fixtures.strong, Fixtures.italic, Fixtures.code, Fixtures.link('x'), Fixtures.link('y')]
    triples = Array.new(ITERATIONS) do
      lo = rng.rand(-COORD_BOUND..COORD_BOUND)
      hi = lo + rng.rand(0..40)
      [elements.sample(random: rng), lo, hi]
    end

    r = Rangeable.new
    triples.each { |e, lo, hi| r.insert(e, start: lo, end: hi) }

    by_element_first_seen = build_first_seen(triples)
    intervals_by_element = collect_intervals(triples)

    failures = []
    (-(COORD_BOUND + 5)..(COORD_BOUND + 5)).each do |i|
      expected = brute_force(by_element_first_seen, intervals_by_element, i)
      actual = r[i].objs
      failures << [i, expected, actual] if expected != actual
    end

    assert_empty failures, sample_failures(failures)
  end

  def test_random_get_range_matches_brute_force
    rng = Random.new(20_260_510)
    elements = [Fixtures.strong, Fixtures.italic, Fixtures.code, Fixtures.link('p'), Fixtures.link('q')]
    triples = Array.new(500) do
      lo = rng.rand(-100..100)
      hi = lo + rng.rand(0..15)
      [elements.sample(random: rng), lo, hi]
    end

    r = Rangeable.new
    triples.each { |e, lo, hi| r.insert(e, start: lo, end: hi) }

    intervals_by_element = collect_intervals(triples)
    elements.each do |e|
      next unless intervals_by_element.key?(e)

      expected = canonicalize(intervals_by_element[e])
      actual = r.get_range(e)
      assert_equal expected, actual, "get_range mismatch for #{e.inspect}"
    end
  end

  private

  def build_first_seen(triples)
    seen = {}
    order = []
    triples.each do |e, _lo, _hi|
      next if seen.key?(e)

      seen[e] = order.size
      order << e
    end
    [seen, order]
  end

  def collect_intervals(triples)
    by_element = Hash.new { |h, k| h[k] = [] }
    triples.each { |e, lo, hi| by_element[e] << [lo, hi] }
    by_element
  end

  def brute_force(first_seen_pair, intervals_by_element, i)
    _, order = first_seen_pair
    order.select do |e|
      intervals_by_element[e].any? { |lo, hi| lo <= i && i <= hi }
    end
  end

  # Canonicalize a list of `[lo, hi]` pairs to the same I1-canonical form
  # that DisjointSet maintains: sorted by lo, no overlap, no integer
  # adjacency.
  def canonicalize(pairs)
    sorted = pairs.map(&:dup).sort_by { |lo, _hi| lo }
    out = []
    sorted.each do |lo, hi|
      if out.any? && out.last[1] + 1 >= lo
        out.last[1] = hi if hi > out.last[1]
      else
        out << [lo, hi]
      end
    end
    out
  end

  def sample_failures(failures)
    return '' if failures.empty?

    head = failures.first(5).map do |i, expected, actual|
      "i=#{i} expected=#{expected.inspect} actual=#{actual.inspect}"
    end
    "first failures (#{failures.size} total):\n#{head.join("\n")}"
  end
end
