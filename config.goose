// SPDX-License-Identifier: Apache-2.0
import std;
namespace config;

const MAX_FIELDS = 256;
const MAX_KEY_BYTES = 256;
const MAX_VALUE_BYTES = 4096;
const MAX_SOURCE_BYTES = 256;
const MAX_NUMBER_BYTES = 128;

enum Kind { Text, Integer, Float, Boolean }
struct Field {
    key:       const u8[:], kind: Kind, required: bool = false,
    int_min:   i64                                     = -9223372036854775808, int_max: i64 = 9223372036854775807,
    float_min: f64                                     = -1.7976931348623157e308, float_max: f64 = 1.7976931348623157e308,
}
struct Override { key: const u8[:], value: const u8[:], source: const u8[:] }
// Internal storage. Mutating these fields directly is outside the API contract.
struct Span { start: i64 = 0, len: i64 = 0 }
struct OwnedField {
    kind:      Kind, required: bool, int_min: i64, int_max: i64,
    float_min: f64, float_max: f64, key: Span,
}
struct Value {
    present: bool = false, integer: i64 = 0, number: f64 = 0.0, boolean: bool = false,
    source:  Span, text: Span,
}
struct Candidate {
    integer: i64 = 0, number: f64 = 0.0, boolean: bool = false,
    source:  const u8[:], text: const u8[:],
}
root struct Store {
    initialized: bool = false, fields: OwnedField[>..], values: Value[>..],
    keys:        u8[>..], bytes: u8[>..],
}
fn view(bytes: const u8[:], span: Span) -> const u8[:] { bytes[span.start..span.start + span.len] }
fn save(bytes: u8[>..]&, text: const u8[:]) -> Span {
    let span = Span { bytes.len, text.len }; bytes.append(text); return span;
}

fn finite(value: f64) -> bool { value >= -1.7976931348623157e308 && value <= 1.7976931348623157e308 }
fn component(s: const u8[:]) -> bool {
    if s.len == 0 || s.len > MAX_KEY_BYTES { return false; }
    for c in s {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || c == '_' || c == '-') { return false; }
    }
    true
}
fn valid_key(s: const u8[:]) -> bool {
    if s.len == 0 || s.len > MAX_KEY_BYTES { return false; }
    var start = 0;
    for i in s.len {
        if s[i] == '.' {
            if !component(s[start..i]) { return false; }
            start = i + 1;
        }
    }
    component(s[start..])
}
fn prefix(a: const u8[:], b: const u8[:]) -> bool {
    a.len < b.len && b[a.len] == '.' && b[..a.len] == a
}
// Bounded, byte-safe diagnostics. Raw values are never included.
fn escaped(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    let digits = "0123456789abcdef";
    for i in s.len {
        if i >= MAX_KEY_BYTES { out.append("..."); break; }
        let c = s[i];
        if c >= 32 && c <= 126 && c != '\\' && c != '\'' { out.push(c); }
        else { out.append("\\x"); out.push(digits[c / 16]); out.push(digits[c % 16]); }
    }
    out
}
fn problem(message: const u8[:], key: const u8[:] = "", source: const u8[:] = "") -> u8[>..] {
    var out: u8[>..] = [];
    out.append("config: "); out.append(message); out.append(" [key='");
    out.append(escaped(key)); out.append("', source='"); out.append(escaped(source)); out.append("']");
    out
}
fn locate(store: Store&, key: const u8[:]) -> i64 {
    if key.len > MAX_KEY_BYTES { return -1; }
    for i in store.fields.len { if view(store.keys, store.fields[i].key) == key { return i; } }
    -1
}

// Atomic initialization: failure preserves the previous store.
fn init(schema: Field[:], store: Store&) -> u8[>..] {
    if schema.len > MAX_FIELDS { return problem("too many schema fields"); }
    for i in schema.len {
        let f = schema[i];
        if !valid_key(f.key) { return problem("invalid schema key", f.key); }
        if f.int_min > f.int_max || !finite(f.float_min) || !finite(f.float_max) || f.float_min > f.float_max {
            return problem("invalid numeric range", f.key);
        }
        for j in i {
            let previous = schema[j].key;
            if previous == f.key || prefix(previous, f.key) || prefix(f.key, previous) {
                return problem("duplicate or conflicting schema key", f.key);
            }
        }
    }
    // Copy everything before clearing: inputs may be independent temporary owners.
    var fields: OwnedField[>..] = [];
    var keys:   u8[>..]         = [];
    for f in schema {
        fields.push(OwnedField { f.kind, f.required, f.int_min, f.int_max, f.float_min, f.float_max, save(keys, f.key) });
    }
    store.values.clear(); store.fields.clear(); store.keys.clear(); store.bytes.clear();
    store.fields.append(fields); store.keys.append(keys);
    for f in schema { store.values.push(Value { .. }); }
    store.initialized = true;
    []
}

fn range_error(field: OwnedField&, value: Candidate&) -> bool {
    if field.kind == Kind.Integer { return value.integer < field.int_min || value.integer > field.int_max; }
    if field.kind == Kind.Float { return !finite(value.number) || value.number < field.float_min || value.number > field.float_max; }
    false
}
// Decimal grammar: optional sign, digits, optional fraction, optional exponent.
// Fractions require a digit on both sides of '.', exponents require digits.
fn decimal(s: const u8[:], floating: bool) -> bool {
    if s.len == 0 || s.len > MAX_NUMBER_BYTES { return false; }
    var i = 0;
    if s[i] == '+' || s[i] == '-' { i++; }
    let start = i;
    while i < s.len && s[i] >= '0' && s[i] <= '9' { i++; }
    if i == start { return false; }
    if floating && i < s.len && s[i] == '.' {
        i++; let fraction = i;
        while i < s.len && s[i] >= '0' && s[i] <= '9' { i++; }
        if fraction == i { return false; }
    }
    if floating && i < s.len && (s[i] == 'e' || s[i] == 'E') {
        i++;
        if i < s.len && (s[i] == '+' || s[i] == '-') { i++; }
        let exponent = i;
        while i < s.len && s[i] >= '0' && s[i] <= '9' { i++; }
        if exponent == i { return false; }
    }
    i == s.len
}
fn parse_value(field: OwnedField&, input: Override&) -> Candidate, u8[>..] {
    var v = Candidate { source: input.source, text: "", .. };
    if field.kind == Kind.Text { v = Candidate { source: input.source, text: input.value, .. }; }
    else if field.kind == Kind.Boolean {
        if input.value != "true" && input.value != "false" { return v, problem("expected true or false", input.key, input.source); }
        v.boolean = input.value == "true";
    } else {
        if !decimal(input.value, field.kind == Kind.Float) { return v, problem("invalid decimal number", input.key, input.source); }
        if field.kind == Kind.Integer {
            let number, ok = parse_int(input.value, 10);
            if !ok { return v, problem("integer outside i64", input.key, input.source); }
            v.integer = number;
        } else {
            let number, ok = parse_flt(input.value);
            if !ok || !finite(number) { return v, problem("invalid finite float", input.key, input.source); }
            v.number = number;
        }
    }
    if range_error(field, v) { return v, problem("value outside allowed range", input.key, input.source); }
    return v, [];
}
// Shared transaction commit; candidates and mapping have already been validated.
fn commit_layer(store: Store&, ids: i64[:], candidates: Candidate[:]) {
    var next:  Value[>..] = [];
    var bytes: u8[>..]    = [];
    for i in store.fields.len {
        var replacement = -1;
        for j in ids.len { if ids[j] == i { replacement = j; break; } }
        if replacement >= 0 {
            let c = candidates[replacement];
            next.push(Value { present: true, integer: c.integer, number: c.number, boolean: c.boolean,
                              source: save(bytes, c.source), text: save(bytes, c.text) });
        } else {
            var previous = store.values[i];
            previous.source = save(bytes, view(store.bytes, previous.source));
            previous.text = save(bytes, view(store.bytes, previous.text));
            next.push(previous);
        }
    }
    store.values.clear(); store.values.append(next);
    store.bytes.clear(); store.bytes.append(bytes);
}
fn apply(store: Store&, inputs: Override[:]) -> u8[>..] {
    if !store.initialized { return problem("store is not initialized"); }
    if inputs.len > MAX_FIELDS { return problem("too many overrides"); }
    var ids:        i64[>..]       = [];
    var candidates: Candidate[>..] = [];
    for input_index in inputs.len {
        let input .= inputs[input_index];
        if input.key.len > MAX_KEY_BYTES || input.source.len > MAX_SOURCE_BYTES || input.value.len > MAX_VALUE_BYTES {
            return problem("override exceeds byte limit", input.key, input.source);
        }
        let id = locate(store, input.key);
        if id < 0 { return problem("unknown key", input.key, input.source); }
        for previous in ids { if previous == id { return problem("duplicate key in layer", input.key, input.source); } }
        let value, error = parse_value(store.fields[id], input);
        if error.len > 0 { return error; }
        ids.push(id); candidates.push(value);
    }
    if inputs.len > 0 { commit_layer(store, ids, candidates); }
    []
}
// Check completeness after all layers. Range/type checks happen during apply.
fn validate(store: Store&) -> u8[>..] {
    if !store.initialized { return problem("store is not initialized"); }
    for i in store.fields.len {
        if store.fields[i].required && !store.values[i].present { return problem("required value is missing", view(store.keys, store.fields[i].key)); }
    }
    []
}
fn access(store: Store&, key: const u8[:]) -> i64, u8[>..] {
    if !store.initialized { return -1, problem("store is not initialized", key); }
    let id = locate(store, key);
    if id < 0 { return -1, problem("unknown key", key); }
    if !store.values[id].present { return -1, problem("value is missing", key); }
    return id, [];
}
fn typed_access(store: Store&, key: const u8[:], kind: Kind) -> i64, u8[>..] {
    let id, error = access(store, key);
    if error.len > 0 { return -1, error; }
    if store.fields[id].kind != kind { return -1, problem("wrong getter type", key, view(store.bytes, store.values[id].source)); }
    return id, [];
}
fn get_integer(store: Store&, key: const u8[:]) -> i64, u8[>..] {
    let id, error = typed_access(store, key, Kind.Integer);
    if error.len > 0 { return 0, error; }
    return store.values[id].integer, [];
}
fn get_float(store: Store&, key: const u8[:]) -> f64, u8[>..] {
    let id, error = typed_access(store, key, Kind.Float);
    if error.len > 0 { return 0.0, error; }
    return store.values[id].number, [];
}
fn get_boolean(store: Store&, key: const u8[:]) -> bool, u8[>..] {
    let id, error = typed_access(store, key, Kind.Boolean);
    if error.len > 0 { return false, error; }
    return store.values[id].boolean, [];
}
// Borrowed views: keep the store alive; do not mutate it while using them.
fn get_text(store: Store&, key: const u8[:]) -> const u8[:], u8[>..] {
    let id, error = typed_access(store, key, Kind.Text);
    if error.len > 0 { return "", error; }
    return view(store.bytes, store.values[id].text), [];
}
fn source(store: Store&, key: const u8[:]) -> const u8[:], u8[>..] {
    let id, error = access(store, key);
    if error.len > 0 { return "", error; }
    return view(store.bytes, store.values[id].source), [];
}
