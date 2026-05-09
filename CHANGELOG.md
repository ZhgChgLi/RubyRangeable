# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-05-10

### Added

- Initial public release of `Rangeable<Element>`, the Ruby reference implementation of [RangeableRFC](https://github.com/ZhgChgLi/RangeableRFC).
- Per-element sorted disjoint-interval list with idempotent containment fast-path.
- Lazy boundary-event index, rebuilt on the next read after a mutating insert; version-counter based invalidation.
- Public API: `insert(element, start:, end:)`, `[i].objs`, `get_range(element)`, `transitions(over:)`, `count`, `empty?`, `each`, `copy`.
- Refinement-style sugar `using Rangeable::Refinements` to enable `element.get_range(from: r)` without polluting `Object`.
- Full RFC § 10 normative test contract (23 tests) plus a 1000-iteration property test against a brute-force oracle and a markdown-shaped micro-benchmark.
- Cross-language fixture (160 ops, 86 probes) shared with the Swift reference implementation; outputs are byte-identical.

### Performance

- Micro-benchmark: ~5.5× speedup over brute-force at m=50, L=2000.
- Real-world consumer ([ZMediumToMarkdown](https://github.com/ZhgChgLi/ZMediumToMarkdown)): 2.23× end-to-end speedup, 55% render-time reduction; all 306 existing tests pass byte-identical.

### Specification

- Conforms to [RangeableRFC v1.0](https://github.com/ZhgChgLi/RangeableRFC), reviewed and APPROVED by an independent academic reviewer (round 2; round-1 verdict REJECTED with 6 MUST-FIX items addressed).

[1.0.0]: https://github.com/ZhgChgLi/RubyRangeable/releases/tag/v1.0.0
