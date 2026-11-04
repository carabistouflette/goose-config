// SPDX-License-Identifier: Apache-2.0
// Optional JSON adapter. Import config.json_layer after declaring the config package.
import config;
import .vendor;
namespace config;

// This is a private RFC 8259 scanner, not the reflection JSON codec. Error
// state is independent of diagnostic strings and consumer str/copy overloads.
// Configuration deliberately accepts only objects and homogeneous primitive
// arrays. Numbers retain their lexical kind: 1 is Integer, 1.0/1e0 are Float.
// Duplicate object branches are rejected even when their leaves are disjoint.
const JSON_MAX_INPUT_BYTES = 1048576;
const JSON_MAX_DEPTH = 64;
const JSON_MAX_NODES = 65536;
const JSON_MAX_WORK = 16777216;
root struct JsonReader {
    input: const u8[:], pos: i64 = 0, bad: bool = false, nodes: i64 = 0, work: i64 = 0,
    bytes: u8[>..], key_bytes: u8[>..], items: Item[>..], ids: i64[>..], candidates: Candidate[>..], texts: Span[>..],
}
fn json_peek(r: JsonReader&) -> u8 { if r.pos >= r.input.len { return 0; } r.input[r.pos] }
fn json_space(r: JsonReader&) {
    while r.pos < r.input.len {
        let c = r.input[r.pos];
        if c != ' ' && c != '\t' && c != '\r' && c != '\n' { break; }
        r.pos++;
    }
}
fn json_take(r: JsonReader&, expected: u8) -> bool {
    if r.pos >= r.input.len || r.input[r.pos] != expected { r.bad = true; return false; }
    r.pos++; true
}
fn json_node(r: JsonReader&, depth: i64) -> bool {
    if depth > JSON_MAX_DEPTH || r.nodes >= JSON_MAX_NODES { r.bad = true; return false; }
    r.nodes++; true
}
fn json_hex(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return (c - 'a') as i64 + 10; }
    if c >= 'A' && c <= 'F' { return (c - 'A') as i64 + 10; }
    -1
}
fn json_code(r: JsonReader&) -> i64 {
    if r.input.len - r.pos < 4 { r.bad = true; return 0; }
    var code = 0;
    for i in 4 {
        let n = json_hex(r.input[r.pos]); r.pos++;
        if n < 0 { r.bad = true; return 0; }
        code = code * 16 + n;
    }
    code
}
fn json_string(r: JsonReader&, out: u8[>..]&, limit: i64) {
    if !json_take(r, '"') { return; }
    while !r.bad && r.pos < r.input.len {
        var c = r.input[r.pos]; r.pos++;
        if c == '"' { return; }
        if c < 32 { r.bad = true; return; }
        if c != '\\' { out.push(c); }
        else {
            if r.pos >= r.input.len { r.bad = true; return; }
            c = r.input[r.pos]; r.pos++;
            if c == '"' || c == '\\' || c == '/' { out.push(c); }
            else if c == 'b' { out.push(8); }
            else if c == 'f' { out.push(12); }
            else if c == 'n' { out.push('\n'); }
            else if c == 'r' { out.push('\r'); }
            else if c == 't' { out.push('\t'); }
            else if c == 'u' {
                var code = json_code(r);
                if r.bad { return; }
                if code >= 0xd800 && code <= 0xdbff {
                    if !json_take(r, '\\') || !json_take(r, 'u') { return; }
                    let low = json_code(r);
                    if r.bad || low < 0xdc00 || low > 0xdfff { r.bad = true; return; }
                    code = 0x10000 + (code - 0xd800) * 1024 + low - 0xdc00;
                } else if code >= 0xdc00 && code <= 0xdfff { r.bad = true; return; }
                config_toml::utf8(out, code);
            } else { r.bad = true; return; }
        }
        if out.len > limit { r.bad = true; return; }
    }
    r.bad = true;
}
fn json_digits(r: JsonReader&) {
    while r.pos < r.input.len && r.input[r.pos] >= '0' && r.input[r.pos] <= '9' { r.pos++; }
}
fn json_number(r: JsonReader&, expected: Kind, out: Item&) {
    let start = r.pos;
    if json_peek(r) == '-' { r.pos++; }
    let c = json_peek(r);
    if c == '0' { r.pos++; }
    else if c >= '1' && c <= '9' { json_digits(r); }
    else { r.bad = true; return; }
    var floating = false;
    if json_peek(r) == '.' {
        floating = true; r.pos++; let fraction = r.pos; json_digits(r);
        if r.pos == fraction { r.bad = true; return; }
    }
    if json_peek(r) == 'e' || json_peek(r) == 'E' {
        floating = true; r.pos++;
        if json_peek(r) == '+' || json_peek(r) == '-' { r.pos++; }
        let exponent = r.pos; json_digits(r);
        if r.pos == exponent { r.bad = true; return; }
    }
    if r.pos - start > MAX_NUMBER_BYTES { r.bad = true; return; }
    let token = r.input[start..r.pos];
    if expected == Kind.Integer && !floating {
        // Parse the original bytes directly: never round-trip integers via f64.
        let value, ok = parse_int(token, 10);
        if !ok { r.bad = true; return; }
        out.integer = value;
    } else if expected == Kind.Float && floating {
        let value, ok = parse_flt(token);
        if !ok || !finite(value) { r.bad = true; return; }
        out.number = value;
    } else { r.bad = true; }
}
fn json_literal(r: JsonReader&, text: const u8[:]) -> bool {
    if text.len > r.input.len - r.pos || r.input[r.pos..r.pos + text.len] != text { r.bad = true; return false; }
    r.pos += text.len; true
}
fn json_scalar(r: JsonReader&, kind: Kind, out: Item&, depth: i64) {
    if !json_node(r, depth) { return; }
    let c = json_peek(r);
    if kind == Kind.Text && c == '"' {
        let start = r.bytes.len; json_string(r, r.bytes, start + MAX_VALUE_BYTES);
        out.text = Span { start, r.bytes.len - start };
    } else if kind == Kind.Boolean && c == 't' { out.boolean = json_literal(r, "true"); }
    else if kind == Kind.Boolean && c == 'f' { json_literal(r, "false"); out.boolean = false; }
    else if (kind == Kind.Integer || kind == Kind.Float) && (c == '-' || (c >= '0' && c <= '9')) { json_number(r, kind, out); }
    else { r.bad = true; }
}
fn json_known_table(store: Store&, path: const u8[:]) -> bool {
    for field in store.fields { if prefix(path, view(store.keys, field.key)) { return true; } }
    false
}
fn json_equal(r: JsonReader&, a: const u8[:], b: const u8[:]) -> bool {
    // Charge every compared byte; 256 siblings and a global work cap bound
    // adversarial shared-prefix duplicate scans independently of input size.
    if a.len != b.len { return false; }
    for i in a.len {
        if r.work >= JSON_MAX_WORK { r.bad = true; return false; }
        r.work++; if a[i] != b[i] { return false; }
    }
    true
}
fn json_leaf(r: JsonReader&, store: Store&, path: const u8[:], origin: const u8[:], depth: i64) {
    let id = locate(store, path);
    if id < 0 || r.ids.len >= MAX_FIELDS { r.bad = true; return; }
    let field = store.fields[id];
    var candidate = Candidate { source: origin, text: "", .. };
    var scalar = Item { .. };
    if list_kind(field.kind) {
        if !json_node(r, depth) || !json_take(r, '[') { return; }
        let start = r.items.len;
        let text_start = r.bytes.len;
        json_space(r);
        if json_peek(r) != ']' {
            loop {
                if r.items.len - start >= MAX_LIST_ITEMS { r.bad = true; return; }
                var item = Item { .. }; json_scalar(r, scalar_kind(field.kind), item, depth + 1);
                if r.bad || r.bytes.len - text_start > MAX_VALUE_BYTES { r.bad = true; return; }
                var checked = Candidate { integer: item.integer, number: item.number, boolean: item.boolean, source: origin, text: "", .. };
                if range_error(field, checked) { r.bad = true; return; }
                r.items.push(item); json_space(r);
                if json_peek(r) != ',' { break; }
                r.pos++; json_space(r);
            }
        }
        if !json_take(r, ']') { return; }
        candidate.list = Span { start, r.items.len - start };
    } else {
        json_scalar(r, field.kind, scalar, depth);
        if r.bad { return; }
        candidate.integer = scalar.integer; candidate.number = scalar.number; candidate.boolean = scalar.boolean;
        if range_error(field, candidate) { r.bad = true; return; }
    }
    r.ids.push(id); r.candidates.push(candidate); r.texts.push(scalar.text);
}
recursive fn json_object(r: JsonReader&, store: Store&, path: const u8[:], origin: const u8[:], depth: i64) {
    if !json_node(r, depth) || !json_take(r, '{') { return; }
    var spans: Span[MAX_FIELDS] = [Span { .. }; MAX_FIELDS]; var count = 0;
    json_space(r);
    if json_peek(r) == '}' { r.pos++; return; }
    loop {
        if count >= MAX_FIELDS { r.bad = true; return; }
        var full: u8[..MAX_KEY_BYTES] = [];
        {
            var key: u8[>..] = []; json_string(r, key, MAX_KEY_BYTES);
            if r.bad || !component(key) { r.bad = true; return; }
            for i in count {
                if json_equal(r, key, view(r.key_bytes, spans[i])) { r.bad = true; return; }
                if r.bad { return; }
            }
            spans[count] = save(r.key_bytes, key); count++;
            let size = path.len + key.len + (if path.len > 0 { 1 } else { 0 });
            if size > MAX_KEY_BYTES { r.bad = true; return; }
            if path.len > 0 { full.append(path); full.push('.'); } full.append(key);
        }
        json_space(r); if !json_take(r, ':') { return; } json_space(r);
        if json_peek(r) == '{' {
            if !json_known_table(store, full) { r.bad = true; return; }
            json_object(r, store, full, origin, depth + 1);
        } else { json_leaf(r, store, full, origin, depth + 1); }
        if r.bad { return; }
        json_space(r);
        if json_peek(r) == '}' { r.pos++; return; }
        if !json_take(r, ',') { return; } json_space(r);
    }
}
// Own every value and the bounded source label before commit. Rejected input
// never mutates the store, including mixed scalar/list and duplicate branches.
fn apply_json(store: Store&, text: const u8[:], origin: const u8[:]) -> u8[>..] {
    if !store.initialized { return problem("store is not initialized"); }
    if origin.len > MAX_SOURCE_BYTES { return problem("source exceeds byte limit", "", origin); }
    var label: u8[..MAX_SOURCE_BYTES] = []; label.append(origin);
    if text.len > JSON_MAX_INPUT_BYTES || !config_toml::valid_utf8(text) { return problem("invalid JSON document or resource limit", "", label); }
    var r = JsonReader { input: text, .. };
    json_space(r); json_object(r, store, "", label, 1); json_space(r);
    if r.bad || r.pos != text.len { return problem("invalid JSON document, type, key, or resource limit", "", label); }
    for i in r.candidates.len { r.candidates[i].text = view(r.bytes, r.texts[i]); }
    if r.ids.len > 0 { commit_layer(store, r.ids, r.candidates, r.items, r.bytes); }
    []
}
