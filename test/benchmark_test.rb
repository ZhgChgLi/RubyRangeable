# frozen_string_literal: true

require_relative 'test_helper'
require 'benchmark'

# Benchmark sized for the canonical reference workload: a 2000-character
# paragraph (L=2000) carrying ~50 markups (m=50). For Rangeable we pay an
# O(M log M) lazy build and then O(log |segments| + r) per query; the
# brute-force baseline pays O(L * m) per sweep. We require a >= 5x
# speed-up at the canonical workload size.
#
# The assertion is taken over the best-of-N speed-up to absorb timing
# noise on warm laptops / CI runners — single-shot timings on this size
# of work (~5ms total) are jittery enough that a strict per-sample bound
# flakes. Best-of-N reflects the algorithmic gap, which is the property
# we actually want to enforce.
class BenchmarkTest < Minitest::Test
  L = 2000
  M = 50
  REPEAT = 10
  TRIALS = 5
  REQUIRED_SPEEDUP = 5.0

  def test_markdown_paragraph_speedup_vs_brute_force
    rng = Random.new(2026_05_10)
    elements = [Fixtures.strong, Fixtures.italic, Fixtures.code, Fixtures.link('a'), Fixtures.link('b')]
    triples = Array.new(M) do
      lo = rng.rand(0..(L - 1))
      hi = [lo + rng.rand(0..200), L - 1].min
      [elements.sample(random: rng), lo, hi]
    end

    # Build once, query L * REPEAT times per trial. This matches the
    # actual build-once-then-query-densely workload (RFC §1.4 W1) and
    # amortises the lazy-build cost the way real callers will.
    rangeable = Rangeable.new
    triples.each { |e, lo, hi| rangeable.insert(e, start: lo, end: hi) }

    # Warm up the lazy index and the JIT/inline caches so the first sweep
    # doesn't pay one-off costs in isolation; both sides are then
    # comparing pure query time.
    rangeable[0].objs
    brute_intervals = group_intervals(triples)
    brute_force_active(brute_intervals, 0)

    rangeable_times = Array.new(TRIALS) do
      Benchmark.realtime do
        REPEAT.times do
          (0...L).each do |i|
            rangeable[i].objs
          end
        end
      end
    end

    brute_times = Array.new(TRIALS) do
      Benchmark.realtime do
        REPEAT.times do
          (0...L).each do |i|
            brute_force_active(brute_intervals, i)
          end
        end
      end
    end

    rangeable_best = rangeable_times.min
    brute_best = brute_times.min
    speedup = brute_best / rangeable_best

    summary = format(
      'L=%d, M=%d, repeats=%d, trials=%d | brute_best=%.4fs rangeable_best=%.4fs speedup=%.2fx',
      L, M, REPEAT, TRIALS, brute_best, rangeable_best, speedup
    )
    puts ''
    puts "[Rangeable benchmark] #{summary}"

    assert_operator speedup, :>=, REQUIRED_SPEEDUP,
      "expected >= #{REQUIRED_SPEEDUP}x speedup, got #{speedup.round(2)}x"
  end

  private

  def group_intervals(triples)
    seen = {}
    order = []
    by_element = Hash.new { |h, k| h[k] = [] }
    triples.each do |e, lo, hi|
      unless seen.key?(e)
        seen[e] = true
        order << e
      end
      by_element[e] << [lo, hi]
    end
    [order, by_element]
  end

  def brute_force_active(grouped, i)
    order, by_element = grouped
    order.select do |e|
      by_element[e].any? { |lo, hi| lo <= i && i <= hi }
    end
  end
end
