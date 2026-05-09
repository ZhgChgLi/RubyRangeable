# frozen_string_literal: true

# Generates a cross-language fixture JSON consumed by both Ruby (this gem's
# tests) and Swift (SwiftRangeable's CrossLanguageFixtureTests). Running this
# script is reproducible: it uses a fixed seed and deterministic operations.
#
#   ruby -Ilib test/cross_language_fixture.rb > test/fixtures/cross_language.json
#
# The fixture has two sections:
#   ops: deterministic insert sequence
#   probes: list of (kind, i) tuples to query, where kind is "subscript" or
#           "transitions". For "subscript" the expected value is the active
#           element list at i; for "transitions" the expected value is the
#           transitions(over: lo..hi) result.
# Each entry includes the language-neutral "expected" payload.

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'rangeable'
require 'json'

ELEMENTS = [
  { kind: 'strong' },
  { kind: 'italic' },
  { kind: 'code' },
  { kind: 'link', payload: 'a' },
  { kind: 'link', payload: 'b' }
].freeze

def element_for(idx)
  spec = ELEMENTS[idx]
  case spec[:kind]
  when 'strong' then [spec, :Strong]
  when 'italic' then [spec, :Italic]
  when 'code'   then [spec, :Code]
  when 'link'   then [spec, "Link(#{spec[:payload]})".to_sym]
  end
end

# The canonical key we serialize for an element. Keep stable between languages.
def element_key(spec)
  case spec[:kind]
  when 'link'
    "link:#{spec[:payload]}"
  else
    spec[:kind]
  end
end

rng = Random.new(0xC0DEFEED)
ops = []
160.times do
  e_idx = rng.rand(ELEMENTS.length)
  lo = rng.rand(-30..30)
  hi = lo + rng.rand(0..15)
  ops << { element: e_idx, start: lo, end: hi }
end

# Also throw in a couple of boundary ops (Int.max sentinel close).
ops << { element: 0, start: 100, end: (2**62) - 1 } # Int.max simulator (not used in subscript probes)

# Sample probes
probes = []
(-40..40).each { |i| probes << { kind: 'subscript', i: i } }
[
  [-40, 40],
  [-5, 5],
  [0, 100],
  [-30, 30],
  [50, 150]
].each { |lo, hi| probes << { kind: 'transitions', lo: lo, hi: hi } }

# Build Rangeable
r = Rangeable.new
elements_seen = {}
def fixture_element(spec)
  case spec[:kind]
  when 'strong'
    [:strong, nil]
  when 'italic'
    [:italic, nil]
  when 'code'
    [:code, nil]
  when 'link'
    [:link, spec[:payload]]
  end
end

# We need a runtime element type with proper equality. Use Struct.
StrongElem = Struct.new(:tag) unless defined?(StrongElem)
ItalicElem = Struct.new(:tag) unless defined?(ItalicElem)
CodeElem   = Struct.new(:tag) unless defined?(CodeElem)
LinkElem   = Struct.new(:url) unless defined?(LinkElem)

def make_element(spec)
  case spec[:kind]
  when 'strong' then StrongElem.new(:strong)
  when 'italic' then ItalicElem.new(:italic)
  when 'code'   then CodeElem.new(:code)
  when 'link'   then LinkElem.new(spec[:payload])
  end
end

ops.each do |op|
  spec = ELEMENTS[op[:element]]
  e = make_element(spec)
  begin
    r.insert(e, start: op[:start], end: op[:end])
  rescue Rangeable::InvalidIntervalError
    # never expected for the generator above
  end
end

# Serialize element back to canonical key
def element_keyed(elem)
  case elem
  when StrongElem then 'strong'
  when ItalicElem then 'italic'
  when CodeElem   then 'code'
  when LinkElem   then "link:#{elem.url}"
  else
    raise "unknown element #{elem.inspect}"
  end
end

probes_with_expected = probes.map do |p|
  case p[:kind]
  when 'subscript'
    expected = r[p[:i]].objs.map { |elem| element_keyed(elem) }
    p.merge(expected: expected)
  when 'transitions'
    events = r.transitions(over: (p[:lo]..p[:hi])).map do |ev|
      {
        coordinate: ev.coordinate,
        kind: ev.kind.to_s,
        element: element_keyed(ev.element)
      }
    end
    p.merge(expected: events)
  end
end

fixture = {
  seed: 0xC0DEFEED,
  ops: ops,
  probes: probes_with_expected
}

puts JSON.pretty_generate(fixture)
