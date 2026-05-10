# frozen_string_literal: true

# Generates the v2 cross-language fixture JSON consumed by all six reference
# implementations (Ruby / Swift / Python / JS / Kotlin / Go). Running this
# script is reproducible: it uses three independent fixed-seed RNGs so each
# subsection (v1 inserts, v2 mixed ops, set_ops) can be regenerated without
# perturbing the others.
#
#   ruby test/cross_language_fixture.rb        # writes to test/fixtures/cross_language.json
#   ruby test/cross_language_fixture.rb -      # writes to STDOUT
#
# Schema (v2):
#   {
#     "schema_version": 2,
#     "seed": 0xC0DEFEED,
#     "ops": [                              # 200 deterministic ops
#       { "op": "insert"|"remove"|"remove_element"|"clear"|"remove_ranges",
#         "element": <index 0..4>?, "start": <int>?, "end": <int>? }
#     ],
#     "probes": [                           # ~135 subscript + transitions
#       { "kind": "subscript"|"transitions", ..., "expected": ... }
#     ],
#     "set_ops": [                          # 20 set-op tests
#       { "id": "...", "op": "union"|"intersect"|"difference"|"symmetric_difference",
#         "self_ops": [...], "other_ops": [...],
#         "expected_state": { "insertion_order": [...], "intervals": {key: [[lo,hi],...]} },
#         "probes": [...]
#       }
#     ]
#   }
#
# Backward-compat: v1 fixture (no `schema_version`, no `op` field, no `set_ops`)
# is still parseable — readers default `op` to "insert" when absent.
#
# Determinism contract:
#   * primary RNG `Random.new(0xC0DEFEED)` generates the v1 161 inserts
#     (byte-identical to the v1 fixture; do NOT perturb its consumption order).
#   * secondary RNG `Random.new(0xC0DEFEED + 1)` generates v2 mixed ops 162..200.
#   * tertiary RNG `Random.new(0xC0DEFEED + 2)` generates set_ops inputs.
#   * v1 probes (86) are recomputed against the post-op-161 state and MUST be
#     byte-identical to the v1 fixture's probes.

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'rangeable'
require 'json'

# ---------------------------------------------------------------------------
# Element catalogue — shared across v1 ops, v2 ops, and set_ops.
# Index 0..4 maps to a deterministic, language-neutral element kind. The
# canonical string keys (`element_key`) are what we serialise into JSON for
# subscript / transitions / expected_state lookups.
# ---------------------------------------------------------------------------
ELEMENTS = [
  { kind: 'strong' },
  { kind: 'italic' },
  { kind: 'code' },
  { kind: 'link', payload: 'a' },
  { kind: 'link', payload: 'b' }
].freeze

def element_key(spec_or_idx)
  spec = spec_or_idx.is_a?(Integer) ? ELEMENTS[spec_or_idx] : spec_or_idx
  case spec[:kind]
  when 'link'
    "link:#{spec[:payload]}"
  else
    spec[:kind]
  end
end

# Runtime element types: each kind has a tiny Struct so equality + hashing
# behaves identically to a real markup type (per RFC §4.2 element-equality).
StrongElem = Struct.new(:tag) unless defined?(StrongElem)
ItalicElem = Struct.new(:tag) unless defined?(ItalicElem)
CodeElem   = Struct.new(:tag) unless defined?(CodeElem)
LinkElem   = Struct.new(:url) unless defined?(LinkElem)

def make_element(spec_or_idx)
  spec = spec_or_idx.is_a?(Integer) ? ELEMENTS[spec_or_idx] : spec_or_idx
  case spec[:kind]
  when 'strong' then StrongElem.new(:strong)
  when 'italic' then ItalicElem.new(:italic)
  when 'code'   then CodeElem.new(:code)
  when 'link'   then LinkElem.new(spec[:payload])
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

# ---------------------------------------------------------------------------
# Section 1: v1 inserts (161 ops). RNG `0xC0DEFEED`. MUST be byte-identical
# to the v1 fixture's `ops` payload (modulo the additive `op: "insert"` tag).
# ---------------------------------------------------------------------------
v1_rng = Random.new(0xC0DEFEED)
v1_ops = []
160.times do
  e_idx = v1_rng.rand(ELEMENTS.length)
  lo = v1_rng.rand(-30..30)
  hi = lo + v1_rng.rand(0..15)
  v1_ops << { op: 'insert', element: e_idx, start: lo, end: hi }
end
# Boundary op: large `end` exercising "Int.max-ish sentinel" path. The probe
# windows below intentionally do NOT touch this region so the probes stay
# computable in finite time.
v1_ops << { op: 'insert', element: 0, start: 100, end: (2**62) - 1 }

# ---------------------------------------------------------------------------
# Section 2: v2 mixed removal ops (39 new). RNG `0xC0DEFEED + 1`.
# Composition target (per plan §C):
#   30 × remove(e, start, end)
#    5 × remove_element(e)
#    3 × clear()
#    1 × remove_ranges(start, end)
# Plus we deliberately seed in some no-op variants (remove non-existent
# element, remove a range that doesn't overlap, clear empty) so the §4.10
# (N3) "no-op MUST NOT bump version" rule gets cross-language exercise.
#
# Coordinate window stays in [-50, 60] so we don't accidentally touch the
# Int.max-ish sentinel from op #161 (which lives at [100, 2^62 - 1]).
# ---------------------------------------------------------------------------
v2_rng = Random.new(0xC0DEFEED + 1)
v2_ops = []

# 30 × remove (mostly overlapping removes, a few intentional no-ops)
30.times do |k|
  e_idx = v2_rng.rand(ELEMENTS.length)
  lo = v2_rng.rand(-40..50)
  hi = lo + v2_rng.rand(0..10)
  # Every 7th remove targets a coordinate window outside any v1 inserts
  # ([70..90]) so it lands as a no-op on most elements.
  if (k % 7).zero?
    lo = v2_rng.rand(70..85)
    hi = lo + v2_rng.rand(0..3)
  end
  v2_ops << { op: 'remove', element: e_idx, start: lo, end: hi }
end

# 5 × remove_element (some target indices that may already have been pruned)
5.times do
  e_idx = v2_rng.rand(ELEMENTS.length)
  v2_ops << { op: 'remove_element', element: e_idx }
end

# 3 × clear (the second and third are guaranteed no-ops since the first
# emptied the container — exercises §4.10 N3 idempotence).
3.times do
  v2_ops << { op: 'clear' }
end

# 1 × remove_ranges. After the clears above the container is empty; this op
# MUST be a no-op (no version bump). This is intentional to exercise the
# atomic no-bump path on an empty container.
v2_ops << { op: 'remove_ranges', start: v2_rng.rand(-30..30), end: v2_rng.rand(31..60) }

# Total v2 mixed ops = 30 + 5 + 3 + 1 = 39. Combined with v1's 161, we get
# exactly 200 entries in the final `ops` array (matching the plan target).
ops = v1_ops + v2_ops

# ---------------------------------------------------------------------------
# Section 3: probes. v1's 86 probes (81 subscript + 5 transitions) are
# computed against the post-v1-op state (so the v1 self-check still passes
# byte-for-byte). v2 probes are computed against the post-v2-op state.
# ---------------------------------------------------------------------------

# v1 probe windows (preserved from the v1 generator verbatim).
v1_probes = []
(-40..40).each { |i| v1_probes << { kind: 'subscript', i: i } }
[
  [-40, 40],
  [-5, 5],
  [0, 100],
  [-30, 30],
  [50, 150]
].each { |lo, hi| v1_probes << { kind: 'transitions', lo: lo, hi: hi } }

# Build a Rangeable through v1 ops only, snapshot the v1 probe expectations.
r_v1 = Rangeable.new
v1_ops.each do |op|
  e = make_element(op[:element])
  r_v1.insert(e, start: op[:start], end: op[:end])
end

v1_probes_with_expected = v1_probes.map do |p|
  case p[:kind]
  when 'subscript'
    expected = r_v1[p[:i]].objs.map { |elem| canonical_key(elem) }
    p.merge(expected: expected)
  when 'transitions'
    events = r_v1.transitions(over: (p[:lo]..p[:hi])).map do |ev|
      { coordinate: ev.coordinate, kind: ev.kind.to_s, element: canonical_key(ev.element) }
    end
    p.merge(expected: events)
  end
end

# Now apply v2 ops on top of r_v1 to get the post-200-op state.
r_post = r_v1
v2_ops.each do |op|
  case op[:op]
  when 'remove'
    e = make_element(op[:element])
    r_post.remove(e, start: op[:start], end: op[:end])
  when 'remove_element'
    e = make_element(op[:element])
    r_post.remove_element(e)
  when 'clear'
    r_post.clear
  when 'remove_ranges'
    r_post.remove_ranges(start: op[:start], end: op[:end])
  end
end

# v2 probe windows: the v2 ops sequence ends with three `clear`s + a no-op
# `remove_ranges`, so the post state is empty. To get probes that exercise
# real removal/eager-prune behaviour we use a SEPARATE staged rebuild here:
# rebuild a fresh Rangeable, apply v1 ops, then apply ONLY the first 30
# remove ops (skip the destructive clears that follow), and probe THAT
# state. This keeps the published `ops` sequence exactly as planned (200
# entries, with the empty-final-state exercise) AND gives us meaningful
# v2 probes.
r_v2_probe_state = Rangeable.new
v1_ops.each do |op|
  e = make_element(op[:element])
  r_v2_probe_state.insert(e, start: op[:start], end: op[:end])
end
# Apply only the 30 remove ops (skip the remove_element/clear/remove_ranges
# tail so the probe state has interesting non-empty content).
v2_ops.first(30).each do |op|
  next unless op[:op] == 'remove'

  e = make_element(op[:element])
  r_v2_probe_state.remove(e, start: op[:start], end: op[:end])
end

# Construct v2 probes covering both:
#   (a) post-30-remove state via subscript over [-40, 40] (exercises eager-
#       prune holes opened by remove);
#   (b) post-30-remove state via transitions over wider windows.
# Plus we include final-state probes against `r_post` (empty container)
# tagged distinctly via a `phase` field so consumers can replay either.
v2_probes_remove_phase = []
(-40..40).step(3) { |i| v2_probes_remove_phase << { kind: 'subscript', phase: 'after_removes', i: i } }
[
  [-40, 40],
  [-50, 60],
  [0, 30]
].each { |lo, hi| v2_probes_remove_phase << { kind: 'transitions', phase: 'after_removes', lo: lo, hi: hi } }

v2_probes_final_phase = []
[-30, -10, 0, 10, 25, 50, 90, 120].each do |i|
  v2_probes_final_phase << { kind: 'subscript', phase: 'final', i: i }
end
[
  [-50, 50],
  [80, 200]
].each { |lo, hi| v2_probes_final_phase << { kind: 'transitions', phase: 'final', lo: lo, hi: hi } }

v2_probes = []
v2_probes_remove_phase.each do |p|
  case p[:kind]
  when 'subscript'
    expected = r_v2_probe_state[p[:i]].objs.map { |elem| canonical_key(elem) }
    v2_probes << p.merge(expected: expected)
  when 'transitions'
    events = r_v2_probe_state.transitions(over: (p[:lo]..p[:hi])).map do |ev|
      { coordinate: ev.coordinate, kind: ev.kind.to_s, element: canonical_key(ev.element) }
    end
    v2_probes << p.merge(expected: events)
  end
end
v2_probes_final_phase.each do |p|
  case p[:kind]
  when 'subscript'
    expected = r_post[p[:i]].objs.map { |elem| canonical_key(elem) }
    v2_probes << p.merge(expected: expected)
  when 'transitions'
    events = r_post.transitions(over: (p[:lo]..p[:hi])).map do |ev|
      { coordinate: ev.coordinate, kind: ev.kind.to_s, element: canonical_key(ev.element) }
    end
    v2_probes << p.merge(expected: events)
  end
end

probes = v1_probes_with_expected + v2_probes

# ---------------------------------------------------------------------------
# Section 4: set_ops (20 tests). Five each of union / intersect / difference
# / symmetric_difference. Several map directly to the worked examples in
# RFC §10.C–§10.G so a passing fixture corroborates the normative tests.
#
# Constraints (per the plan):
#   * Same element pool, no Int.max sentinel mixing (RFC bug #2 avoidance).
#   * No "difference == removeRanges-loop" cross-element equivalence claim
#     (RFC bug #1 avoidance — the only `difference` ↔ `removeRanges` parity
#     case we encode is single-element-only, which avoids the cross-pollute
#     trap).
#   * Tertiary RNG `0xC0DEFEED + 2` for the 5×4 = 20 random fillers we add.
# ---------------------------------------------------------------------------

# Helper: build a Rangeable from an array of `insert` op records. Used both
# for computing `expected_state` and for replaying inside the conformance
# runner.
def build_rangeable(ops_array)
  r = Rangeable.new
  ops_array.each do |op|
    raise "set_op build_rangeable expected insert, got #{op[:op].inspect}" unless op[:op] == 'insert'

    e = make_element(op[:element])
    r.insert(e, start: op[:start], end: op[:end])
  end
  r
end

# Helper: serialise a Rangeable's full state into the schema's
# `expected_state` shape — `insertion_order` (array of canonical keys) and
# `intervals` (canonical key → [[lo, hi], ...]).
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

# Helper: serialise a list of probes (already with explicit lo/hi or i) by
# evaluating them against `r`.
def evaluate_probes(r, probe_specs)
  probe_specs.map do |p|
    case p[:kind]
    when 'subscript'
      expected = r[p[:i]].objs.map { |elem| canonical_key(elem) }
      p.merge(expected: expected)
    when 'transitions'
      events = r.transitions(over: (p[:lo]..p[:hi])).map do |ev|
        { coordinate: ev.coordinate, kind: ev.kind.to_s, element: canonical_key(ev.element) }
      end
      p.merge(expected: events)
    else
      raise "unknown probe kind #{p[:kind].inspect}"
    end
  end
end

# Helper: apply a set op and return the result Rangeable.
def apply_set_op(self_r, other_r, op_name)
  case op_name
  when 'union'
    self_r.union(other_r)
  when 'intersect'
    self_r.intersect(other_r)
  when 'difference'
    self_r.difference(other_r)
  when 'symmetric_difference'
    self_r.symmetric_difference(other_r)
  else
    raise "unknown set op #{op_name.inspect}"
  end
end

# Helper: bake a single set-op test entry. Runs the op in-process to
# precompute `expected_state` and any probe `expected` payloads.
def bake_set_op(id:, op:, self_ops:, other_ops:, probe_specs:, chain_ops: nil)
  self_r  = build_rangeable(self_ops)
  other_r = build_rangeable(other_ops)
  result  = apply_set_op(self_r, other_r, op)
  # Optional second op (used for the sym-diff associativity case where we
  # need (a △ b) △ c). `chain_ops` is the third Rangeable's ops.
  if chain_ops
    chain_r = build_rangeable(chain_ops)
    result = apply_set_op(result, chain_r, op)
  end
  expected_state = serialise_state(result)
  probes_with_expected = evaluate_probes(result, probe_specs)
  entry = {
    id: id,
    op: op,
    self_ops: self_ops,
    other_ops: other_ops,
    expected_state: expected_state,
    probes: probes_with_expected
  }
  entry[:chain_ops] = chain_ops if chain_ops
  entry
end

set_ops = []

# -- Union (5) --------------------------------------------------------------

# union_001: RFC §10.C #44 — disjoint elements (Strong + Italic).
set_ops << bake_set_op(
  id: 'union_001_disjoint_elements',
  op: 'union',
  self_ops:  [{ op: 'insert', element: 0, start: 0, end: 5 }],
  other_ops: [{ op: 'insert', element: 1, start: 10, end: 15 }],
  probe_specs: [
    { kind: 'subscript', i: 3 },
    { kind: 'subscript', i: 7 },
    { kind: 'subscript', i: 12 },
    { kind: 'transitions', lo: -5, hi: 20 }
  ]
)

# union_002: RFC §10.C #45 + #46 combined — overlapping AND adjacency-merge
# on the same element. self: Strong [0,10], other: Strong [5,15] (overlap)
# + Strong [16,20] (adjacent to merged [0,15] via 15+1==16).
set_ops << bake_set_op(
  id: 'union_002_overlap_and_adjacency',
  op: 'union',
  self_ops:  [{ op: 'insert', element: 0, start: 0, end: 10 }],
  other_ops: [
    { op: 'insert', element: 0, start: 5,  end: 15 },
    { op: 'insert', element: 0, start: 16, end: 20 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 0 },
    { kind: 'subscript', i: 18 },
    { kind: 'subscript', i: 21 },
    { kind: 'transitions', lo: -5, hi: 25 }
  ]
)

# union_003: RFC §10.C #50 — insertion_order tail-append.
# r1 = [A:(0,1), B:(2,3)]; r2 = [C:(4,5), B:(10,11), D:(12,13)].
# Expected order: [A, B, C, D]; B is shared so NOT re-appended.
set_ops << bake_set_op(
  id: 'union_003_insertion_order_tail_append',
  op: 'union',
  self_ops: [
    { op: 'insert', element: 0, start: 0, end: 1 },
    { op: 'insert', element: 1, start: 2, end: 3 }
  ],
  other_ops: [
    { op: 'insert', element: 2, start: 4,  end: 5 },
    { op: 'insert', element: 1, start: 10, end: 11 },
    { op: 'insert', element: 3, start: 12, end: 13 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 0 },
    { kind: 'subscript', i: 5 },
    { kind: 'subscript', i: 12 },
    { kind: 'transitions', lo: -2, hi: 16 }
  ]
)

# union_004: idempotent — union with self yields structurally equal result.
set_ops << bake_set_op(
  id: 'union_004_idempotent_self_union',
  op: 'union',
  self_ops: [
    { op: 'insert', element: 0, start: -5, end: 5 },
    { op: 'insert', element: 1, start: 10, end: 20 }
  ],
  other_ops: [
    { op: 'insert', element: 0, start: -5, end: 5 },
    { op: 'insert', element: 1, start: 10, end: 20 }
  ],
  probe_specs: [
    { kind: 'subscript', i: -5 },
    { kind: 'subscript', i: 0 },
    { kind: 'subscript', i: 5 },
    { kind: 'subscript', i: 15 },
    { kind: 'transitions', lo: -10, hi: 25 }
  ]
)

# union_005: RFC §10.G #76 — three-way union (chained).
# r1 = [A:(0,5), B:(10,15)]; r2 = [B:(20,25), C:(30,35)].
# Then chain with r3 = [C:(40,45), D:(50,55)].
# Final per-element: A=[(0,5)]; B=[(10,15),(20,25)]; C=[(30,35),(40,45)];
# D=[(50,55)]. insertion_order = [A, B, C, D].
set_ops << bake_set_op(
  id: 'union_005_chain_three_way',
  op: 'union',
  self_ops: [
    { op: 'insert', element: 0, start: 0,  end: 5 },
    { op: 'insert', element: 1, start: 10, end: 15 }
  ],
  other_ops: [
    { op: 'insert', element: 1, start: 20, end: 25 },
    { op: 'insert', element: 2, start: 30, end: 35 }
  ],
  chain_ops: [
    { op: 'insert', element: 2, start: 40, end: 45 },
    { op: 'insert', element: 3, start: 50, end: 55 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 3 },
    { kind: 'subscript', i: 22 },
    { kind: 'subscript', i: 42 },
    { kind: 'subscript', i: 53 },
    { kind: 'transitions', lo: -5, hi: 60 }
  ]
)

# -- Intersect (5) ----------------------------------------------------------

# intersect_001: RFC §10.D #52 — shared element, overlapping intervals.
set_ops << bake_set_op(
  id: 'intersect_001_basic_overlap',
  op: 'intersect',
  self_ops:  [{ op: 'insert', element: 0, start: 0,  end: 10 }],
  other_ops: [{ op: 'insert', element: 0, start: 5,  end: 15 }],
  probe_specs: [
    { kind: 'subscript', i: 4 },   # outside intersection
    { kind: 'subscript', i: 7 },   # inside [5, 10]
    { kind: 'subscript', i: 11 },  # outside intersection
    { kind: 'transitions', lo: -5, hi: 20 }
  ]
)

# intersect_002: RFC §10.D #53 — shared element, disjoint intervals; element
# eagerly pruned, result is empty.
set_ops << bake_set_op(
  id: 'intersect_002_disjoint_pruned',
  op: 'intersect',
  self_ops:  [{ op: 'insert', element: 0, start: 0,   end: 5 }],
  other_ops: [{ op: 'insert', element: 0, start: 100, end: 200 }],
  probe_specs: [
    { kind: 'subscript', i: 3 },
    { kind: 'subscript', i: 150 },
    { kind: 'transitions', lo: -5, hi: 250 }
  ]
)

# intersect_003: RFC §10.D #56 — multi-segment intersection.
# r1 = Strong[(0,5), (10,15), (20,25)]; r2 = Strong[(3,22)].
# Expected Strong = [(3,5), (10,15), (20,22)].
set_ops << bake_set_op(
  id: 'intersect_003_multi_segment',
  op: 'intersect',
  self_ops: [
    { op: 'insert', element: 0, start: 0,  end: 5 },
    { op: 'insert', element: 0, start: 10, end: 15 },
    { op: 'insert', element: 0, start: 20, end: 25 }
  ],
  other_ops: [
    { op: 'insert', element: 0, start: 3, end: 22 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 4 },
    { kind: 'subscript', i: 12 },
    { kind: 'subscript', i: 21 },
    { kind: 'subscript', i: 23 },
    { kind: 'transitions', lo: -5, hi: 30 }
  ]
)

# intersect_004: RFC §10.D #57 — insertion_order preservation + dense ord.
# r1 = [A:(0,5), B:(10,15), C:(20,25), D:(30,35)];
# r2 = [A:(0,5), C:(21,24), E:(100,200)].
# Expected insertion_order = [A, C]; B/D dropped (not in r2);
# E dropped (not in r1).
set_ops << bake_set_op(
  id: 'intersect_004_insertion_order_dense_ord',
  op: 'intersect',
  self_ops: [
    { op: 'insert', element: 0, start: 0,  end: 5 },
    { op: 'insert', element: 1, start: 10, end: 15 },
    { op: 'insert', element: 2, start: 20, end: 25 },
    { op: 'insert', element: 3, start: 30, end: 35 }
  ],
  other_ops: [
    { op: 'insert', element: 0, start: 0,   end: 5 },
    { op: 'insert', element: 2, start: 21,  end: 24 },
    { op: 'insert', element: 4, start: 100, end: 200 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 0 },
    { kind: 'subscript', i: 5 },
    { kind: 'subscript', i: 22 },
    { kind: 'transitions', lo: -2, hi: 40 }
  ]
)

# intersect_005: idempotent — intersect with self yields structurally equal.
set_ops << bake_set_op(
  id: 'intersect_005_idempotent_self',
  op: 'intersect',
  self_ops: [
    { op: 'insert', element: 0, start: 0,  end: 10 },
    { op: 'insert', element: 1, start: 20, end: 30 }
  ],
  other_ops: [
    { op: 'insert', element: 0, start: 0,  end: 10 },
    { op: 'insert', element: 1, start: 20, end: 30 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 5 },
    { kind: 'subscript', i: 25 },
    { kind: 'transitions', lo: -5, hi: 35 }
  ]
)

# -- Difference (5) --------------------------------------------------------

# difference_001: RFC §10.E #58 — disjoint elements; result equal to self
# structurally. Italic in `other` is ignored since not in keys(self).
set_ops << bake_set_op(
  id: 'difference_001_disjoint_elements_no_change',
  op: 'difference',
  self_ops:  [{ op: 'insert', element: 0, start: 0, end: 10 }],
  other_ops: [{ op: 'insert', element: 1, start: 5, end: 15 }],
  probe_specs: [
    { kind: 'subscript', i: 5 },
    { kind: 'subscript', i: 12 },
    { kind: 'transitions', lo: -5, hi: 20 }
  ]
)

# difference_002: RFC §10.E #62 — split into both residuals.
# self = Strong[(0,10)]; other = Strong[(3,6)] => Strong[(0,2),(7,10)].
set_ops << bake_set_op(
  id: 'difference_002_split_both_residuals',
  op: 'difference',
  self_ops:  [{ op: 'insert', element: 0, start: 0, end: 10 }],
  other_ops: [{ op: 'insert', element: 0, start: 3, end: 6 }],
  probe_specs: [
    { kind: 'subscript', i: 1 },
    { kind: 'subscript', i: 5 },
    { kind: 'subscript', i: 9 },
    { kind: 'transitions', lo: -2, hi: 15 }
  ]
)

# difference_003: RFC §10.E #63 — multi-entry sweep.
# self = Strong[(0,5),(10,15),(20,25)]; other = Strong[(3,22)] =>
# Strong[(0,2),(23,25)].
set_ops << bake_set_op(
  id: 'difference_003_multi_entry_sweep',
  op: 'difference',
  self_ops: [
    { op: 'insert', element: 0, start: 0,  end: 5 },
    { op: 'insert', element: 0, start: 10, end: 15 },
    { op: 'insert', element: 0, start: 20, end: 25 }
  ],
  other_ops: [
    { op: 'insert', element: 0, start: 3, end: 22 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 1 },
    { kind: 'subscript', i: 12 },
    { kind: 'subscript', i: 24 },
    { kind: 'transitions', lo: -5, hi: 30 }
  ]
)

# difference_004: RFC §10.E #64 — insertion_order preservation w/ prune.
# r1 = [A:(0,5), B:(10,15), C:(20,25), D:(30,35)];
# r2 = [B:(9,16), E:(100,200)].
# Expected: insertion_order = [A, C, D] (B fully consumed; E ignored).
set_ops << bake_set_op(
  id: 'difference_004_insertion_order_with_prune',
  op: 'difference',
  self_ops: [
    { op: 'insert', element: 0, start: 0,  end: 5 },
    { op: 'insert', element: 1, start: 10, end: 15 },
    { op: 'insert', element: 2, start: 20, end: 25 },
    { op: 'insert', element: 3, start: 30, end: 35 }
  ],
  other_ops: [
    { op: 'insert', element: 1, start: 9,   end: 16 },
    { op: 'insert', element: 4, start: 100, end: 200 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 3 },
    { kind: 'subscript', i: 12 },   # B-region; should be empty post-diff
    { kind: 'subscript', i: 22 },
    { kind: 'subscript', i: 32 },
    { kind: 'transitions', lo: -5, hi: 40 }
  ]
)

# difference_005: RFC §10.E #65 — single-element equivalence with
# removeRanges (RFC bug-1 workaround: keep single-element so the per-key
# `difference` IS equivalent to a `removeRanges` loop on the same element).
# self = Strong[(0,10)]; other = Strong[(3,6)]. Result Strong[(0,2),(7,10)]
# matches a `removeRanges(3,6)` result, but only for this single-element
# fixture (we deliberately don't claim cross-element equivalence here).
set_ops << bake_set_op(
  id: 'difference_005_single_element_residuals',
  op: 'difference',
  self_ops:  [{ op: 'insert', element: 0, start: 0, end: 10 }],
  other_ops: [{ op: 'insert', element: 0, start: 3, end: 6 }],
  probe_specs: [
    { kind: 'subscript', i: 0 },
    { kind: 'subscript', i: 4 },
    { kind: 'subscript', i: 7 },
    { kind: 'transitions', lo: -2, hi: 12 }
  ]
)

# -- Symmetric difference (5) ----------------------------------------------

# symmetric_difference_001: RFC §10.F #68 — both-side residuals.
# self = Strong[(0,10)]; other = Strong[(5,15)] => Strong[(0,4),(11,15)].
set_ops << bake_set_op(
  id: 'symmetric_difference_001_both_side_residuals',
  op: 'symmetric_difference',
  self_ops:  [{ op: 'insert', element: 0, start: 0, end: 10 }],
  other_ops: [{ op: 'insert', element: 0, start: 5, end: 15 }],
  probe_specs: [
    { kind: 'subscript', i: 0 },
    { kind: 'subscript', i: 4 },
    { kind: 'subscript', i: 7 },   # cancellation region; should be empty
    { kind: 'subscript', i: 12 },
    { kind: 'transitions', lo: -5, hi: 20 }
  ]
)

# symmetric_difference_002: RFC §10.F #66 — sym-diff with empty equals self
# structurally.
set_ops << bake_set_op(
  id: 'symmetric_difference_002_empty_equals_self',
  op: 'symmetric_difference',
  self_ops: [
    { op: 'insert', element: 0, start: 0,  end: 5 },
    { op: 'insert', element: 1, start: 10, end: 15 }
  ],
  other_ops: [],
  probe_specs: [
    { kind: 'subscript', i: 3 },
    { kind: 'subscript', i: 12 },
    { kind: 'transitions', lo: -2, hi: 18 }
  ]
)

# symmetric_difference_003: RFC §10.F #71 — insertion_order tail-append.
# r1 = [A:(0,5), B:(10,15)]; r2 = [C:(20,25), D:(30,35)].
# No overlap on either side → expected sym-diff =
# insertion_order [A, B, C, D] with each interval intact.
set_ops << bake_set_op(
  id: 'symmetric_difference_003_tail_append',
  op: 'symmetric_difference',
  self_ops: [
    { op: 'insert', element: 0, start: 0,  end: 5 },
    { op: 'insert', element: 1, start: 10, end: 15 }
  ],
  other_ops: [
    { op: 'insert', element: 2, start: 20, end: 25 },
    { op: 'insert', element: 3, start: 30, end: 35 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 3 },
    { kind: 'subscript', i: 12 },
    { kind: 'subscript', i: 22 },
    { kind: 'subscript', i: 32 },
    { kind: 'transitions', lo: -5, hi: 40 }
  ]
)

# symmetric_difference_004: RFC §10.F #70 — associativity worked example.
# r1 = [A:(0,10)]; r2 = [A:(5,15)]; r3 = [A:(10,20)].
# Computed (r1 △ r2) △ r3 (left association via `chain_ops`).
# Expected R(A) = [(0,4), (10,10), (16,20)].
set_ops << bake_set_op(
  id: 'symmetric_difference_004_associativity_left',
  op: 'symmetric_difference',
  self_ops:  [{ op: 'insert', element: 0, start: 0,  end: 10 }],
  other_ops: [{ op: 'insert', element: 0, start: 5,  end: 15 }],
  chain_ops: [{ op: 'insert', element: 0, start: 10, end: 20 }],
  probe_specs: [
    { kind: 'subscript', i: 0 },
    { kind: 'subscript', i: 4 },
    { kind: 'subscript', i: 5 },   # cancellation between r1 and r2
    { kind: 'subscript', i: 10 },  # singleton retained in (r1△r2)△r3
    { kind: 'subscript', i: 15 },
    { kind: 'subscript', i: 18 },
    { kind: 'transitions', lo: -2, hi: 25 }
  ]
)

# symmetric_difference_005: RFC §10.F #69 — commutativity (per-element)
# probed via the same self/other; we record the canonical (self-primary)
# `r1 △ r2` form. The commutative form `r2 △ r1` is verified at runtime by
# the language conformance runner (it can apply `apply_set_op(other, self,
# 'symmetric_difference')` and check per-element ranges match).
set_ops << bake_set_op(
  id: 'symmetric_difference_005_commutativity_per_element',
  op: 'symmetric_difference',
  self_ops: [
    { op: 'insert', element: 0, start: 0,  end: 5 },
    { op: 'insert', element: 1, start: 10, end: 15 }
  ],
  other_ops: [
    { op: 'insert', element: 1, start: 12, end: 17 },
    { op: 'insert', element: 2, start: 20, end: 25 }
  ],
  probe_specs: [
    { kind: 'subscript', i: 3 },
    { kind: 'subscript', i: 11 },
    { kind: 'subscript', i: 13 },  # B-cancellation region [12, 15]
    { kind: 'subscript', i: 16 },
    { kind: 'subscript', i: 22 },
    { kind: 'transitions', lo: -2, hi: 30 }
  ]
)

# ---------------------------------------------------------------------------
# Emit. Default to writing the canonical fixture path so callers don't need
# to remember to redirect stdout. Pass `-` as the only argument to write to
# stdout instead.
# ---------------------------------------------------------------------------
fixture = {
  schema_version: 2,
  seed: 0xC0DEFEED,
  ops: ops,
  set_ops: set_ops,
  probes: probes
}

json = JSON.pretty_generate(fixture)

target = ARGV[0]
if target.nil?
  default_path = File.expand_path('fixtures/cross_language.json', __dir__)
  File.write(default_path, "#{json}\n")
  warn "wrote #{default_path} (#{json.bytesize} bytes)"
elsif target == '-'
  puts json
else
  File.write(target, "#{json}\n")
  warn "wrote #{target} (#{json.bytesize} bytes)"
end
