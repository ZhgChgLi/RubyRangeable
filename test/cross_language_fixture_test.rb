# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

# Cross-language fixture conformance test (Ruby side).
#
# Re-runs the deterministic fixture in `test/fixtures/cross_language.json`
# through the live `Rangeable` implementation and verifies every probe and
# set-op `expected_state` matches. The same fixture is shipped to the
# Swift / Python / JS / Kotlin / Go reference implementations; a green run
# here is a prerequisite for cross-language byte-identity claims.
#
# Schema versions handled:
#   v1 — no `schema_version`, only `ops` (all `insert`) + `probes`.
#   v2 — `schema_version: 2`, `ops` may include `remove`/`remove_element`/
#        `clear`/`remove_ranges`, plus a `set_ops` array. Probes carry an
#        optional `phase` field that selects which intermediate state they
#        were computed against (`v1`-style: post all v1 ops only;
#        `after_removes`: post v1 ops + first 30 `remove` ops only;
#        `final`: post all 200 ops).
class CrossLanguageFixtureTest < Minitest::Test
  StrongElem = Struct.new(:tag) unless defined?(StrongElem)
  ItalicElem = Struct.new(:tag) unless defined?(ItalicElem)
  CodeElem   = Struct.new(:tag) unless defined?(CodeElem)
  LinkElem   = Struct.new(:url) unless defined?(LinkElem)

  ELEMENT_BUILDERS = [
    -> { StrongElem.new(:strong) },
    -> { ItalicElem.new(:italic) },
    -> { CodeElem.new(:code) },
    -> { LinkElem.new('a') },
    -> { LinkElem.new('b') }
  ].freeze

  def test_fixture_round_trip
    fixture_path = File.expand_path('fixtures/cross_language.json', __dir__)
    skip "fixture missing: #{fixture_path}" unless File.exist?(fixture_path)

    fixture = JSON.parse(File.read(fixture_path), symbolize_names: true)
    schema_version = fixture[:schema_version] || 1

    if schema_version == 1
      run_v1(fixture)
    elsif schema_version == 2
      run_v2(fixture)
    else
      flunk "unsupported schema_version: #{schema_version}"
    end
  end

  private

  # v1 runner: every op is an `insert`, every probe is computed against the
  # post-all-ops state.
  def run_v1(fixture)
    r = Rangeable.new
    fixture[:ops].each { |op| apply_op(r, op) }
    fixture[:probes].each { |probe| assert_probe(r, probe) }
  end

  # v2 runner: ops may be insert/remove/remove_element/clear/remove_ranges.
  # Probes carry a `phase` flag selecting which intermediate snapshot they
  # were computed against (see fixture generator).
  def run_v2(fixture)
    ops = fixture[:ops]
    set_ops = fixture[:set_ops] || []

    # Index v1 op boundary: the last `insert` before any non-insert op.
    # In our generator this is exactly index 161 (160 random inserts + 1
    # boundary sentinel insert). Compute it dynamically so the runner stays
    # robust if the generator's tail composition changes.
    v1_boundary = ops.length
    ops.each_with_index do |op, i|
      if op[:op] != 'insert'
        v1_boundary = i
        break
      end
    end

    # Snapshot 1: r_v1 = state after ops[0...v1_boundary] (all inserts).
    r_v1 = Rangeable.new
    ops[0...v1_boundary].each { |op| apply_op(r_v1, op) }

    # Snapshot 2: r_after_removes = r_v1 + first 30 `remove` ops only
    # (skipping remove_element/clear/remove_ranges that follow).
    r_after_removes = clone_via_ops(ops[0...v1_boundary])
    remove_taken = 0
    ops[v1_boundary..].each do |op|
      break if remove_taken == 30

      if op[:op] == 'remove'
        apply_op(r_after_removes, op)
        remove_taken += 1
      end
    end

    # Snapshot 3: r_final = state after applying ALL 200 ops in order.
    r_final = clone_via_ops(ops[0...v1_boundary])
    ops[v1_boundary..].each { |op| apply_op(r_final, op) }

    # Dispatch each probe to the matching snapshot.
    fixture[:probes].each do |probe|
      target =
        case probe[:phase]
        when nil, 'v1'    then r_v1
        when 'after_removes' then r_after_removes
        when 'final'      then r_final
        else flunk "unknown probe phase: #{probe[:phase].inspect}"
        end
      assert_probe(target, probe)
    end

    # Set-op validation. Each entry: build self + other (and optional chain),
    # apply the op, then check `expected_state` (insertion_order + intervals)
    # and the `expected` payload of every probe.
    set_ops.each do |entry|
      verify_set_op(entry)
    end
  end

  # Replay a list of ops on a fresh Rangeable; helper used by the v2 runner
  # so the post-v1, post-after-removes, and post-final snapshots are all
  # independent (mutating one MUST NOT affect the others).
  def clone_via_ops(ops_array)
    r = Rangeable.new
    ops_array.each { |op| apply_op(r, op) }
    r
  end

  def apply_op(r, op)
    op_kind = op[:op] || 'insert'
    case op_kind
    when 'insert'
      e = ELEMENT_BUILDERS[op[:element]].call
      r.insert(e, start: op[:start], end: op[:end])
    when 'remove'
      e = ELEMENT_BUILDERS[op[:element]].call
      r.remove(e, start: op[:start], end: op[:end])
    when 'remove_element'
      e = ELEMENT_BUILDERS[op[:element]].call
      r.remove_element(e)
    when 'clear'
      r.clear
    when 'remove_ranges'
      r.remove_ranges(start: op[:start], end: op[:end])
    else
      flunk "unknown op kind: #{op_kind.inspect}"
    end
  end

  def assert_probe(r, probe)
    case probe[:kind]
    when 'subscript'
      actual = r[probe[:i]].objs.map { |elem| canonical_key(elem) }
      assert_equal probe[:expected], actual,
        "subscript mismatch (phase=#{probe[:phase] || 'v1'}, i=#{probe[:i]})"
    when 'transitions'
      events = r.transitions(over: probe[:lo]..probe[:hi]).map do |ev|
        { coordinate: ev.coordinate, kind: ev.kind.to_s, element: canonical_key(ev.element) }
      end
      expected = probe[:expected].map do |e|
        { coordinate: e[:coordinate], kind: e[:kind], element: e[:element] }
      end
      assert_equal expected, events,
        "transitions mismatch (phase=#{probe[:phase] || 'v1'}, lo=#{probe[:lo]}, hi=#{probe[:hi]})"
    else
      flunk "unknown probe kind #{probe[:kind].inspect}"
    end
  end

  def verify_set_op(entry)
    self_r  = build_from_inserts(entry[:self_ops])
    other_r = build_from_inserts(entry[:other_ops])
    result  = apply_set_op(self_r, other_r, entry[:op])
    if entry[:chain_ops]
      chain_r = build_from_inserts(entry[:chain_ops])
      result = apply_set_op(result, chain_r, entry[:op])
    end

    expected_state = entry[:expected_state]
    actual_state = serialise_state(result)
    assert_equal expected_state[:insertion_order], actual_state[:insertion_order],
      "set_op #{entry[:id]}: insertion_order mismatch"
    assert_equal stringify_intervals(expected_state[:intervals]), actual_state[:intervals],
      "set_op #{entry[:id]}: intervals mismatch"

    (entry[:probes] || []).each do |p|
      assert_probe(result, p)
    end
  end

  def build_from_inserts(ops_array)
    r = Rangeable.new
    ops_array.each do |op|
      apply_op(r, op)
    end
    r
  end

  def apply_set_op(self_r, other_r, name)
    case name
    when 'union'                then self_r.union(other_r)
    when 'intersect'            then self_r.intersect(other_r)
    when 'difference'           then self_r.difference(other_r)
    when 'symmetric_difference' then self_r.symmetric_difference(other_r)
    else flunk "unknown set op #{name.inspect}"
    end
  end

  # Snapshot a Rangeable into the schema's `expected_state` shape so we can
  # diff against the fixture's recorded expectation.
  def serialise_state(r)
    insertion_order = []
    intervals = {}
    r.each do |element, pairs|
      key = canonical_key(element)
      insertion_order << key
      intervals[key] = pairs.map { |lo, hi| [lo, hi] }
    end
    { insertion_order: insertion_order, intervals: intervals }
  end

  # JSON.parse with symbolize_names puts the `intervals` keys as Symbols
  # (e.g. `:strong`); our serialise_state emits String keys (e.g. `"strong"`).
  # Normalise the fixture-side dictionary to String keys for comparison.
  def stringify_intervals(intervals_hash)
    intervals_hash.each_with_object({}) do |(k, v), h|
      h[k.to_s] = v
    end
  end

  def canonical_key(elem)
    case elem
    when StrongElem then 'strong'
    when ItalicElem then 'italic'
    when CodeElem   then 'code'
    when LinkElem   then "link:#{elem.url}"
    else
      raise "unknown element #{elem.inspect}"
    end
  end
end
