// SPDX-License-Identifier: Apache-2.0
import std;
namespace config;

const MAX_FIELDS = 256;
const MAX_ALIASES = 256;
const MAX_KEY_BYTES = 256;
const MAX_VALUE_BYTES = 4096;
const MAX_SOURCE_BYTES = 256;
const MAX_NUMBER_BYTES = 128;
const MAX_LIST_ITEMS = 256;
const MAX_DURATION_BYTES = 128;
// Internal accelerator bounds, not Store tuning parameters. The sorted index
// remains the deterministic fallback when eight probes cannot place a key.
const LOOKUP_SLOTS = 512;
const LOOKUP_PROBES = 8;
const LOOKUP_HASH_BYTES = 32;

enum Kind { Text, Integer, Float, Boolean, TextList, IntegerList, FloatList, BooleanList, Duration, DurationList }
struct Duration { nanoseconds: i64 = 0 }
fn list_kind(kind: Kind) -> bool {
    kind == Kind.TextList || kind == Kind.IntegerList || kind == Kind.FloatList || kind == Kind.BooleanList || kind == Kind.DurationList
}
fn scalar_kind(kind: Kind) -> Kind {
    if kind == Kind.TextList { return Kind.Text; }
    if kind == Kind.IntegerList { return Kind.Integer; }
    if kind == Kind.FloatList { return Kind.Float; }
    if kind == Kind.BooleanList { return Kind.Boolean; }
    if kind == Kind.DurationList { return Kind.Duration; }
    kind
}
struct Field {
    key:       const u8[:], kind: Kind, required: bool = false,
    int_min:   i64                                     = -9223372036854775808, int_max: i64 = 9223372036854775807,
    float_min: f64                                     = -1.7976931348623157e308, float_max: f64 = 1.7976931348623157e308,
}
struct Alias { key: const u8[:], target: const u8[:] }
struct OwnedAlias { key: Span, target: i64 }
struct Override { key: const u8[:], value: const u8[:], source: const u8[:] }
struct ListOverride { key: const u8[:], values: const (const u8[:])[:], source: const u8[:] }
// Internal storage. Mutating these fields directly is outside the API contract.
struct Span { start: i64 = 0, len: i64 = 0 }
struct Item { integer: i64 = 0, number: f64 = 0.0, boolean: bool = false, text: Span }
struct OwnedField {
    kind:      Kind, required: bool, int_min: i64, int_max: i64,
    float_min: f64, float_max: f64, key: Span,
}
// The field kind determines the payload arena: byte text for scalars, Item
// records for lists. Scalar source bytes immediately precede their text bytes.
struct Value {
    present: bool = false, integer: i64 = 0, number: f64 = 0.0, boolean: bool = false,
    source:  Span, payload: Span,
}
struct Candidate {
    integer: i64 = 0, number: f64 = 0.0, boolean: bool = false,
    source:  const u8[:], text: const u8[:], list: Span,
}
root struct Store {
    aliases:     OwnedAlias[>..], alias_keys: u8[>..],
    initialized: bool = false, fields: OwnedField[>..], values: Value[>..],
    ordered:     i64[>..], hash_ids: i64[>..], keys: u8[>..], bytes: u8[>..], items: Item[>..],
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
    // Keep ordinary key bytes on the fast path; only dots update boundaries.
    var start = 0;
    for i in s.len {
        let c = s[i];
        if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '-' { continue; }
        if c != '.' || i == start { return false; }
        start = i + 1;
    }
    start < s.len
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
// Private byte ordering avoids overloadable comparison helpers. Fixed-size
// slice comparisons safely skip common prefixes without alignment assumptions.
fn compare_key(a: const u8[:], b: const u8[:]) -> i64 {
    let length = if a.len < b.len { a.len } else { b.len };
    var i = 0;
    while length - i >= 16 && a[i..i + 16] == b[i..i + 16] { i += 16; }
    while length - i >= 8 && a[i..i + 8] == b[i..i + 8] { i += 8; }
    while i < length {
        if a[i] < b[i] { return -1; }
        if a[i] > b[i] { return 1; }
        i++;
    }
    if a.len < b.len { return -1; }
    if a.len > b.len { return 1; }
    0
}
// A noncryptographic FNV-1a variant hashes the length and at most 32 trailing
// bytes, keeping long shared-prefix keys cheap. Equal suffixes may collide:
// full key equality and the sorted fallback still determine identity. Keep
// this namespaced so consumer hash overloads cannot change its behavior.
fn lookup_hash(key: const u8[:]) -> u64 {
    var result: u64 = 14695981039346656037 ^ (key.len as u64);
    let start = if key.len > LOOKUP_HASH_BYTES { key.len - LOOKUP_HASH_BYTES } else { 0 };
    for byte in key[start..] { result = (result ^ byte) * 1099511628211; }
    result
}
fn locate_canonical(store: Store&, key: const u8[:]) -> i64 {
    if key.len > MAX_KEY_BYTES { return -1; }
    // Keep tiny schemas and the first declared key cheap.
    if store.fields.len <= 8 {
        for i in store.fields.len { if view(store.keys, store.fields[i].key) == key { return i; } }
        return -1;
    }
    if view(store.keys, store.fields[0].key) == key { return 0; }
    var slot = (lookup_hash(key) & (LOOKUP_SLOTS - 1)) as i64;
    for probe in LOOKUP_PROBES {
        let id = store.hash_ids[slot];
        // No deletion occurs. An inserted key has no earlier empty slot; a
        // skipped key had all eight slots occupied and they remain occupied.
        if id < 0 { return -1; }
        if view(store.keys, store.fields[id].key) == key { return id; }
        slot = (slot + 1) & (LOOKUP_SLOTS - 1);
    }
    var low = 0;
    var high = store.ordered.len;
    while low < high {
        let middle = low + (high - low) / 2;
        let id = store.ordered[middle];
        let order = compare_key(view(store.keys, store.fields[id].key), key);
        if order == 0 { return id; }
        if order < 0 { low = middle + 1; }
        else { high = middle; }
    }
    -1
}

// Canonical reads retain their original path. Aliases are searched only on a
// miss, by bounded binary search over owned keys and direct canonical IDs.
// Keep alias metadata out of an out-of-line canonical lookup ABI. The pinned
// frontend must inline this resolver before the native compiler optimizes it.
inline fn locate(store: Store&, key: const u8[:]) -> i64 {
    let id = locate_canonical(store, key);
    if id >= 0 || key.len > MAX_KEY_BYTES { return id; }
    var low = 0; var high = store.aliases.len;
    while low < high {
        let middle = low + (high - low) / 2;
        let order = compare_key(view(store.alias_keys, store.aliases[middle].key), key);
        if order == 0 { return store.aliases[middle].target; }
        if order < 0 { low = middle + 1; } else { high = middle; }
    }
    -1
}

fn index_fields(fields: OwnedField[:], keys: const u8[:], hash_ids: i64[>..]&) {
    for i in LOOKUP_SLOTS { hash_ids.push(-1); }
    for id in fields.len {
        var slot = (lookup_hash(view(keys, fields[id].key)) & (LOOKUP_SLOTS - 1)) as i64;
        for probe in LOOKUP_PROBES {
            if hash_ids[slot] < 0 { hash_ids[slot] = id; break; }
            slot = (slot + 1) & (LOOKUP_SLOTS - 1);
        }
    }
}

// Bounded, stable bottom-up merge sort. Sorting only IDs keeps key ownership
// and declaration order unchanged; scratch is at most 256 machine integers.
fn order_fields(fields: OwnedField[:], keys: const u8[:], ordered: i64[>..]&) {
    for i in fields.len { ordered.push(i); }
    var scratch: i64[MAX_FIELDS] = [0; MAX_FIELDS];
    var width = 1;
    while width < fields.len {
        var start = 0;
        while start < fields.len {
            let middle = if start + width < fields.len { start + width } else { fields.len };
            let end = if start + width * 2 < fields.len { start + width * 2 } else { fields.len };
            var left = start; var right = middle; var target = start;
            while left < middle && right < end {
                let a = ordered[left]; let b = ordered[right];
                if compare_key(view(keys, fields[a].key), view(keys, fields[b].key)) <= 0 {
                    scratch[target] = a; left++;
                } else { scratch[target] = b; right++; }
                target++;
            }
            while left < middle { scratch[target] = ordered[left]; left++; target++; }
            while right < end { scratch[target] = ordered[right]; right++; target++; }
            start = end;
        }
        for i in fields.len { ordered[i] = scratch[i]; }
        width *= 2;
    }
}

// Keep field rules centralized; invalid schemas use the original declaration-
// ordered validator so optimizations do not change which error is reported.
fn field_problem(field: Field&) -> const u8[:] {
    if !valid_key(field.key) { return "invalid schema key"; }
    if field.int_min > field.int_max || !finite(field.float_min) || !finite(field.float_max) || field.float_min > field.float_max {
        return "invalid numeric range";
    }
    ""
}
fn schema_error(schema: Field[:]) -> u8[>..] {
    for i in schema.len {
        let field = schema[i];
        let issue = field_problem(field);
        if issue.len > 0 { return problem(issue, field.key); }
        for j in i {
            let previous = schema[j].key;
            if previous == field.key || prefix(previous, field.key) || prefix(field.key, previous) {
                return problem("duplicate or conflicting schema key", field.key);
            }
        }
    }
    []
}
// Sorted raw-prefix descendants are contiguous. Retain their ancestors across
// lexical distractors such as a-, which sorts between a and a.b. An existing
// dotted ancestor would already have rejected the first such descendant, so
// checking the nearest remaining ancestor is sufficient. Each ID is pushed
// once and popped at most once; the bounded stack holds at most MAX_FIELDS IDs.
fn conflicting(fields: OwnedField[:], keys: const u8[:], ordered: i64[:]) -> bool {
    var ancestors: i64[MAX_FIELDS] = [0; MAX_FIELDS];
    var depth = 0;
    for id in ordered {
        let key = view(keys, fields[id].key);
        while depth > 0 {
            let previous = view(keys, fields[ancestors[depth - 1]].key);
            if previous.len <= key.len && previous == key[..previous.len] {
                if previous.len == key.len || key[previous.len] == '.' { return true; }
                break;
            }
            depth--;
        }
        ancestors[depth] = id;
        depth++;
    }
    false
}

// Atomic initialization: failure preserves the previous store.
fn init(schema: Field[:], store: Store&) -> u8[>..] { init(schema, store, []) }
fn init(schema: Field[:], store: Store&, aliases: const Alias[:]) -> u8[>..] {
    if schema.len > MAX_FIELDS { return problem("too many schema fields"); }
    if aliases.len > MAX_ALIASES { return problem("too many aliases"); }
    if schema.len <= 8 {
        let error = schema_error(schema);
        if error.len > 0 { return error; }
    } else {
        for field in schema {
            if field_problem(field).len > 0 { return schema_error(schema); }
        }
    }
    // Copy everything before clearing: inputs may be independent temporary owners.
    var fields: OwnedField[>..] = [];
    var keys:   u8[>..]         = [];
    for f in schema {
        fields.push(OwnedField { f.kind, f.required, f.int_min, f.int_max, f.float_min, f.float_max, save(keys, f.key) });
    }
    // Stage the index before invalidating old views. Keep metadata and values
    // in declaration order, so validation diagnostics retain their order.
    var ordered:  i64[>..] = [];
    var hash_ids: i64[>..] = [];
    let count = fields.len;
    if count > 8 {
        order_fields(fields, keys, ordered);
        if conflicting(fields, keys, ordered) {
            let error = schema_error(schema);
            if error.len > 0 { return error; }
        }
        index_fields(fields, keys, hash_ids);
    }
    var owned_aliases: OwnedAlias[>..] = [];
    var alias_keys:    u8[>..]         = [];
    for alias, i in aliases {
        if !valid_key(alias.key) || !valid_key(alias.target) { return problem("invalid alias key or target", alias.key); }
        var target = -1;
        for field, id in fields {
            let key = view(keys, field.key);
            if key == alias.target { target = id; }
            if key == alias.key || prefix(key, alias.key) || prefix(alias.key, key) {
                return problem("alias conflicts with schema key", alias.key);
            }
        }
        if target < 0 { return problem("alias target is not a canonical field", alias.key); }
        for j in i {
            let key = aliases[j].key;
            if key == alias.key || prefix(key, alias.key) || prefix(alias.key, key) {
                return problem("duplicate or conflicting alias key", alias.key);
            }
        }
        // Insertion sort is bounded by256 entries and retains direct target IDs.
        let entry = OwnedAlias { save(alias_keys, alias.key), target };
        var at = owned_aliases.len;
        owned_aliases.push(entry);
        while at > 0 && compare_key(view(alias_keys, owned_aliases[at - 1].key), alias.key) > 0 {
            owned_aliases[at] = owned_aliases[at - 1]; at--;
        }
        owned_aliases[at] = entry;
    }
    store.aliases.clear(); store.aliases.append(owned_aliases);
    store.alias_keys.clear(); store.alias_keys.append(alias_keys);
    store.values.clear(); store.fields.clear(); store.keys.clear(); store.bytes.clear(); store.items.clear(); store.ordered.clear(); store.hash_ids.clear();
    store.fields.append(fields); store.keys.append(keys); store.ordered.append(ordered); store.hash_ids.append(hash_ids);
    for i in count { store.values.push(Value { .. }); }
    store.initialized = true;
    []
}

// Publish an already validated independent staging store. Source and destination
// must be distinct stores. Arena offsets remain valid because all arenas and
// their metadata are copied together, without sharing their owned storage.
fn publish_store(destination: Store&, source: Store&) {
    destination.aliases.clear(); destination.aliases.append(source.aliases);
    destination.alias_keys.clear(); destination.alias_keys.append(source.alias_keys);
    destination.fields.clear(); destination.fields.append(source.fields);
    destination.values.clear(); destination.values.append(source.values);
    destination.keys.clear(); destination.keys.append(source.keys);
    destination.bytes.clear(); destination.bytes.append(source.bytes);
    destination.ordered.clear(); destination.ordered.append(source.ordered);
    destination.hash_ids.clear(); destination.hash_ids.append(source.hash_ids);
    destination.items.clear(); destination.items.append(source.items);
    destination.initialized = source.initialized;
}

fn range_error(field: OwnedField&, value: Candidate&) -> bool {
    let kind = scalar_kind(field.kind);
    if kind == Kind.Integer || kind == Kind.Duration { return value.integer < field.int_min || value.integer > field.int_max; }
    if scalar_kind(field.kind) == Kind.Float { return !finite(value.number) || value.number < field.float_min || value.number > field.float_max; }
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
// Parse bounded duration text without allocations or floating-point rounding.
// Unsigned magnitudes admit abs(i64 minimum) without overflowing a signed value.
fn duration_digit(c: u8) -> bool { c >= '0' && c <= '9' }
fn duration_unit(unit: const u8[:]) -> u64 {
    if unit == "ns" { return 1; }
    if unit == "us" || unit == "µs" || unit == "μs" { return 1000; }
    if unit == "ms" { return 1000000; }
    if unit == "s" { return 1000000000; }
    if unit == "m" { return 60000000000; }
    if unit == "h" { return 3600000000000; }
    if unit == "d" { return 86400000000000; }
    0
}
fn duration_number(text: const u8[:]) -> i64, const u8[:] {
    if text.len > MAX_DURATION_BYTES { return 0, "duration exceeds byte limit"; }
    if text.len == 0 { return 0, "invalid duration syntax"; }
    var at = 0;
    var negative = false;
    if text[at] == '+' || text[at] == '-' { negative = text[at] == '-'; at++; }
    if at == text.len { return 0, "invalid duration syntax"; }
    if text[at..] == "0" { return 0, ""; }
    let limit: u64 = if negative { 9223372036854775808 } else { 9223372036854775807 };
    var total: u64 = 0;
    while at < text.len {
        let begin = at;
        var whole: u64 = 0;
        while at < text.len && duration_digit(text[at]) {
            let digit = (text[at] - '0') as u64;
            if whole > (limit - digit) / 10 { return 0, "duration outside i64 nanoseconds"; }
            whole = whole * 10 + digit; at++;
        }
        let integer_digits = at - begin;
        var fraction_begin = at;
        var fraction_end = at;
        if at < text.len && text[at] == '.' {
            at++; fraction_begin = at;
            while at < text.len && duration_digit(text[at]) { at++; }
            fraction_end = at;
        }
        if integer_digits == 0 && fraction_begin == fraction_end { return 0, "invalid duration syntax"; }
        let unit_begin = at;
        while at < text.len && !duration_digit(text[at]) && text[at] != '.' { at++; }
        let unit = duration_unit(text[unit_begin..at]);
        if unit == 0 { return 0, "invalid duration unit"; }
        let remaining = limit - total;
        if whole > remaining / unit { return 0, "duration outside i64 nanoseconds"; }
        let scaled = whole * unit;
        // Reverse decimal recurrence computes floor(fraction*unit) exactly;
        // each intermediate is <10*unit, including the fixed24h day.
        var fraction: u64 = 0;
        var digit_at = fraction_end;
        while digit_at > fraction_begin {
            digit_at--;
            fraction = ((text[digit_at] - '0') * unit + fraction) / 10;
        }
        if fraction > remaining - scaled { return 0, "duration outside i64 nanoseconds"; }
        total += scaled + fraction;
    }
    if negative {
        if total == 9223372036854775808 { return -9223372036854775808, ""; }
        return -(total as i64), "";
    }
    return total as i64, "";
}
fn parse_duration(text: const u8[:]) -> Duration, u8[>..] {
    let number, issue = duration_number(text);
    if issue.len > 0 { return Duration { .. }, problem(issue); }
    return Duration { number }, [];
}
fn parse_value(field: OwnedField&, input: Override&) -> Candidate, u8[>..] {
    var v = Candidate { source: input.source, text: "", .. };
    if list_kind(field.kind) { return v, problem("expected a list override", input.key, input.source); }
    if field.kind == Kind.Text { v = Candidate { source: input.source, text: input.value, .. }; }
    else if field.kind == Kind.Boolean {
        if input.value != "true" && input.value != "false" { return v, problem("expected true or false", input.key, input.source); }
        v.boolean = input.value == "true";
    } else if field.kind == Kind.Duration {
        let number, issue = duration_number(input.value);
        if issue.len > 0 { return v, problem(issue, input.key, input.source); }
        v.integer = number;
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
// Item text spans refer to list_bytes for staged items, or store.bytes for old
// items. Own every value and source before invalidating any previous storage.
fn commit_layer(store: Store&, ids: i64[:], candidates: Candidate[:], items: Item[:] = [], list_bytes: const u8[:] = "") {
    if ids.len == 1 {
        let id = ids[0];
        let c = candidates[0];
        let previous = store.values[id];
        if previous.present && !list_kind(store.fields[id].kind) &&
           previous.source.len + previous.payload.len == c.source.len + c.text.len {
            // Stage both borrowed inputs before overwriting their old storage.
            // Exact size preserves compact storage and all unrelated spans.
            var staged: u8[>..] = [];
            staged.append(c.source); staged.append(c.text);
            let destination = store.bytes[previous.source.start..previous.source.start + staged.len];
            for byte, i in staged { destination[i] = byte; }
            store.values[id] = Value { present: true, integer: c.integer, number: c.number, boolean: c.boolean,
                                      source: Span { previous.source.start, c.source.len },
                                      payload: Span { previous.source.start + c.source.len, c.text.len } };
            return;
        }
    }
    var next:         Value[>..]      = [];
    var bytes:        u8[>..]         = [];
    var next_items:   Item[>..]       = [];
    var replacements: i64[MAX_FIELDS] = [-1; MAX_FIELDS];
    for j in ids.len { replacements[ids[j]] = j; }
    for i in store.fields.len {
        let replacement = replacements[i];
        if replacement >= 0 {
            let c = candidates[replacement];
            let source = save(bytes, c.source);
            var payload = Span { next_items.len, c.list.len };
            if list_kind(store.fields[i].kind) {
                for item_index in c.list.len {
                    var item = items[c.list.start + item_index];
                    item.text = save(bytes, view(list_bytes, item.text));
                    next_items.push(item);
                }
            } else { payload = save(bytes, c.text); }
            next.push(Value { present: true, integer: c.integer, number: c.number, boolean: c.boolean,
                              source: source, payload: payload });
        } else {
            var previous = store.values[i];
            if list_kind(store.fields[i].kind) {
                let list = Span { next_items.len, previous.payload.len };
                for item_index in previous.payload.len {
                    var item = store.items[previous.payload.start + item_index];
                    item.text = save(bytes, view(store.bytes, item.text));
                    next_items.push(item);
                }
                previous.payload = list;
                previous.source = save(bytes, view(store.bytes, previous.source));
            } else {
                // Scalar source and text were saved consecutively. Copy their
                // bounded combined span once while retaining separate views.
                let start = bytes.len;
                bytes.append(view(store.bytes, Span { previous.source.start, previous.source.len + previous.payload.len }));
                previous.source.start = start;
                previous.payload.start = start + previous.source.len;
            }
            next.push(previous);
        }
    }
    store.values.clear(); store.values.append(next);
    store.bytes.clear(); store.bytes.append(bytes);
    store.items.clear(); store.items.append(next_items);
}
fn apply(store: Store&, inputs: Override[:]) -> u8[>..] {
    if !store.initialized { return problem("store is not initialized"); }
    if inputs.len > MAX_FIELDS { return problem("too many overrides"); }
    var ids:        i64[>..]         = [];
    var candidates: Candidate[>..]   = [];
    var seen:       bool[MAX_FIELDS] = [false; MAX_FIELDS];
    for input_index in inputs.len {
        let input .= inputs[input_index];
        if input.key.len > MAX_KEY_BYTES || input.source.len > MAX_SOURCE_BYTES || input.value.len > MAX_VALUE_BYTES {
            return problem("override exceeds byte limit", input.key, input.source);
        }
        let id = locate(store, input.key);
        if id < 0 { return problem("unknown key", input.key, input.source); }
        if seen[id] { return problem("duplicate key in layer", input.key, input.source); }
        seen[id] = true;
        let value, error = parse_value(store.fields[id], input);
        if error.len > 0 { return error; }
        ids.push(id); candidates.push(value);
    }
    if inputs.len > 0 { commit_layer(store, ids, candidates); }
    []
}
// Textual list inputs use the scalar grammar for every element. The list and
// all text bytes are staged in one transaction, so a late failure changes nothing.
fn apply_lists(store: Store&, inputs: ListOverride[:]) -> u8[>..] {
    if !store.initialized { return problem("store is not initialized"); }
    if inputs.len > MAX_FIELDS { return problem("too many overrides"); }
    var ids:        i64[>..]         = [];
    var candidates: Candidate[>..]   = [];
    var items:      Item[>..]        = [];
    var bytes:      u8[>..]          = [];
    var seen:       bool[MAX_FIELDS] = [false; MAX_FIELDS];
    for input_index in inputs.len {
        let input .= inputs[input_index];
        if input.key.len > MAX_KEY_BYTES || input.source.len > MAX_SOURCE_BYTES {
            return problem("override exceeds byte limit", input.key, input.source);
        }
        if input.values.len > MAX_LIST_ITEMS { return problem("too many list items", input.key, input.source); }
        let id = locate(store, input.key);
        if id < 0 { return problem("unknown key", input.key, input.source); }
        if seen[id] { return problem("duplicate key in layer", input.key, input.source); }
        seen[id] = true;
        var field = store.fields[id];
        if !list_kind(field.kind) { return problem("expected a scalar override", input.key, input.source); }
        field.kind = scalar_kind(field.kind);
        var candidate = Candidate { source: input.source, text: "", list: Span { items.len, input.values.len }, .. };
        var text_bytes = 0;
        for text in input.values {
            if field.kind == Kind.Text {
                if text.len > MAX_VALUE_BYTES - text_bytes { return problem("list text exceeds byte limit", input.key, input.source); }
                text_bytes += text.len;
            }
            let scalar = Override { input.key, text, input.source };
            let value, error = parse_value(field, scalar);
            if error.len > 0 { return error; }
            items.push(Item { value.integer, value.number, value.boolean, save(bytes, value.text) });
        }
        ids.push(id); candidates.push(candidate);
    }
    if inputs.len > 0 { commit_layer(store, ids, candidates, items, bytes); }
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
fn get_duration(store: Store&, key: const u8[:]) -> Duration, u8[>..] {
    let id, error = typed_access(store, key, Kind.Duration);
    if error.len > 0 { return Duration { .. }, error; }
    return Duration { store.values[id].integer }, [];
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
    return view(store.bytes, store.values[id].payload), [];
}
fn source(store: Store&, key: const u8[:]) -> const u8[:], u8[>..] {
    let id, error = access(store, key);
    if error.len > 0 { return "", error; }
    return view(store.bytes, store.values[id].source), [];
}

// Copy through explicit bytes to avoid consumer copy overloads.
fn own_text(input: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.append(input);
    out
}

// List getters return independent owned arrays, including every text element.
fn get_text_list(store: Store&, key: const u8[:]) -> u8[][>..], u8[>..] {
    var values: u8[][>..] = [];
    let id, error = typed_access(store, key, Kind.TextList);
    if error.len > 0 { return values, error; }
    let list = store.values[id].payload;
    for index in list.len {
        values.push(own_text(view(store.bytes, store.items[list.start + index].text)));
    }
    return values, [];
}
fn get_integer_list(store: Store&, key: const u8[:]) -> i64[>..], u8[>..] {
    var values: i64[>..] = [];
    let id, error = typed_access(store, key, Kind.IntegerList);
    if error.len > 0 { return values, error; }
    let list = store.values[id].payload;
    for index in list.len { values.push(store.items[list.start + index].integer); }
    return values, [];
}
fn get_duration_list(store: Store&, key: const u8[:]) -> Duration[>..], u8[>..] {
    var out: Duration[>..] = [];
    let id, error = typed_access(store, key, Kind.DurationList);
    if error.len > 0 { return out, error; }
    let span = store.values[id].payload;
    for item in store.items[span.start..span.start + span.len] { out.push(Duration { item.integer }); }
    return out, [];
}
fn get_float_list(store: Store&, key: const u8[:]) -> f64[>..], u8[>..] {
    var values: f64[>..] = [];
    let id, error = typed_access(store, key, Kind.FloatList);
    if error.len > 0 { return values, error; }
    let list = store.values[id].payload;
    for index in list.len { values.push(store.items[list.start + index].number); }
    return values, [];
}
fn get_boolean_list(store: Store&, key: const u8[:]) -> bool[>..], u8[>..] {
    var values: bool[>..] = [];
    let id, error = typed_access(store, key, Kind.BooleanList);
    if error.len > 0 { return values, error; }
    let list = store.values[id].payload;
    for index in list.len { values.push(store.items[list.start + index].boolean); }
    return values, [];
}
