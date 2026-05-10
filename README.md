# RubyRangeable

[![Gem Version](https://img.shields.io/gem/v/rangeable)](https://rubygems.org/gems/rangeable) [![Ruby](https://img.shields.io/badge/ruby-3.2%2B-red)]() [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Reference Ruby implementation of [`Rangeable<Element>`](https://github.com/ZhgChgLi/RangeableRFC) — a generic, integer-coordinate, closed-interval set container with first-insert ordered active queries.

## Installation

Add to your `Gemfile`:

```ruby
gem 'rangeable', '~> 1.0'
```

Or install directly:

```sh
$ gem install rangeable
```

## Usage

```ruby
require 'rangeable'

# Any Ruby object with sensible == / hash works as an element.
Strong = Struct.new(:tag)
Italic = Struct.new(:tag)

r = Rangeable.new
r.insert(Strong.new(:bold), start: 2, end: 5)
r.insert(Strong.new(:bold), start: 3, end: 7)   # merges with [2, 5] → [2, 7]
r.insert(Strong.new(:bold), start: 9, end: 11)  # disjoint
r.insert(Italic.new(:em),   start: 3, end: 8)

r.get_range(Strong.new(:bold))  # => [[2, 7], [9, 11]]
r.get_range(Italic.new(:em))    # => [[3, 8]]

r[4].objs   # => [Strong<:bold>, Italic<:em>]   first-insert order
r[8].objs   # => [Italic<:em>]
r[10].objs  # => [Strong<:bold>]
```

### Refinement sugar

Avoid polluting the global namespace:

```ruby
using Rangeable::Refinements

Strong.new(:bold).get_range(from: r)  # => [[2, 7], [9, 11]]
```

### Sweep iteration via transitions

```ruby
r.transitions(over: 0..15).each do |event|
  case event.kind
  when :open  then puts "#{event.coordinate}: open #{event.element}"
  when :close then puts "#{event.coordinate}: close #{event.element}"
  end
end
```

## API

| Method | Returns | Notes |
|---|---|---|
| `Rangeable.new` | empty `Rangeable` | |
| `r.insert(element, start:, end:)` | `:mutated` / `:idempotent` | raises `Rangeable::InvalidIntervalError` if `start > end` |
| `r[i]` | `Rangeable::Slot` | wrapper exposing `.objs` |
| `r[i].objs` | frozen `Array<Element>` | first-insert order |
| `r.get_range(element)` | `Array<[lo, hi]>` | merged disjoint ranges |
| `r.transitions(over: a..b)` | `Array<Event>` | each `Event` has `coordinate`, `kind`, `element` |
| `r.count` | `Integer` | distinct elements |
| `r.empty?` | `Boolean` | |
| `r.each { \|element, ranges\| ... }` | `self` | iteration |
| `r.copy` | `Rangeable` | deep copy |

## Semantics

- **End is inclusive**: `[a, b]` covers `a..b`, both ends.
- **Same-element merging**: equal elements (by `==` / `hash`) merge on overlap or integer adjacency. `[2, 4] ∪ [5, 7] = [2, 7]`.
- **Idempotent insert**: re-inserting a contained interval costs no version bump.
- **Out-of-order rejected**: `insert(_, start: 5, end: 2)` raises.
- **Active-set ordering**: deterministic across runs — first-insert order of the element, not hash bucket order.
- **Element immutability**: elements are frozen on insert (`element.dup.freeze`); mutating an element after insert is undefined behaviour.

See [RangeableRFC](https://github.com/ZhgChgLi/RangeableRFC) § 4 for normative semantics, § 6 for algorithms, § 7 for the Φ-potential amortised-complexity proof, and § 10 for the 23-case normative test contract this gem must pass.

## Performance

| Workload | Result |
|---|---|
| Brute-force baseline (m=50, L=2000) vs `Rangeable` | **~5.5× speedup** in micro-benchmark |
| Real consumer ([ZMediumToMarkdown](https://github.com/ZhgChgLi/ZMediumToMarkdown)) | **2.23× end-to-end speedup**, 55% render-time reduction; all 306 existing tests byte-identical |

## Cross-language consistency

This Ruby implementation joins the [Swift](https://github.com/ZhgChgLi/SwiftRangeable), [Python](https://github.com/ZhgChgLi/PythonRangeable), [JS](https://github.com/ZhgChgLi/JSRangeable), [Kotlin](https://github.com/ZhgChgLi/KotlinRangeable) and [Go](https://github.com/ZhgChgLi/GoRangeable) implementations. All six share a 160-op / 86-probe JSON fixture and produce byte-identical outputs.

## See also

- **[RangeableRFC](https://github.com/ZhgChgLi/RangeableRFC)** — the normative specification this gem implements.
- **[SwiftRangeable](https://github.com/ZhgChgLi/SwiftRangeable)** — Swift reference (SPM).
- **[PythonRangeable](https://github.com/ZhgChgLi/PythonRangeable)** — Python reference (`pip install rangeable`).
- **[JSRangeable](https://github.com/ZhgChgLi/JSRangeable)** — TypeScript reference (`npm i rangeable-js`).
- **[KotlinRangeable](https://github.com/ZhgChgLi/KotlinRangeable)** — Kotlin/JVM reference (JitPack).
- **[GoRangeable](https://github.com/ZhgChgLi/GoRangeable)** — Go reference (`go get github.com/ZhgChgLi/GoRangeable`).
- **[ZMediumToMarkdown](https://github.com/ZhgChgLi/ZMediumToMarkdown)** — real-world consumer that exercises this gem on Medium GraphQL renderers.

## Development

```sh
$ bundle install
$ bundle exec rake test
```

The test suite covers the full RFC § 10 contract (23 normative tests), a 1000-iteration property test against a brute-force oracle, and a markdown-shaped micro-benchmark.

## License

MIT © [ZhgChgLi](https://github.com/ZhgChgLi)

# Buy me a beer ❤️❤️❤️

[![Buy Me A Beer](https://github.com/user-attachments/assets/63f01edf-2aa5-4d91-8f8a-861e5b6b4feb)](https://www.paypal.com/ncp/payment/CMALMPT8UUTY2)

[**If this project has helped you, feel free to sponsor me a cup of coffee, thank you.**](https://www.paypal.com/ncp/payment/CMALMPT8UUTY2)
