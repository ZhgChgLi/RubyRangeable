# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

# Self-check: re-run the fixture's ops through the Ruby implementation and
# verify each probe's expected output matches what the live `Rangeable` returns.
# This both validates the fixture file itself and acts as a smoke test that the
# Swift twin's expected outputs are reproducible end-to-end on the Ruby side.
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
    r = Rangeable.new
    fixture[:ops].each do |op|
      element = ELEMENT_BUILDERS[op[:element]].call
      r.insert(element, start: op[:start], end: op[:end])
    end

    fixture[:probes].each do |probe|
      case probe[:kind]
      when 'subscript'
        actual = r[probe[:i]].objs.map { |elem| canonical_key(elem) }
        assert_equal probe[:expected], actual, "subscript mismatch at i=#{probe[:i]}"
      when 'transitions'
        events = r.transitions(over: probe[:lo]..probe[:hi]).map do |ev|
          {
            coordinate: ev.coordinate,
            kind: ev.kind.to_s,
            element: canonical_key(ev.element)
          }
        end
        expected = probe[:expected].map do |e|
          { coordinate: e[:coordinate], kind: e[:kind], element: e[:element] }
        end
        assert_equal expected, events, "transitions mismatch lo=#{probe[:lo]} hi=#{probe[:hi]}"
      else
        flunk "unknown probe kind #{probe[:kind]}"
      end
    end
  end

  private

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
