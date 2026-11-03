// SPDX-License-Identifier: Apache-2.0
// Optional adapter. Import config.toml after declaring the config package.
import config;
import vendor;
namespace config;

fn table_known(store: Store&, path: const u8[:]) -> bool {
    if path.len == 0 { return true; }
    for field in store.fields { if prefix(path, view(store.keys, field.key)) { return true; } }
    false
}
recursive fn gather_toml(store: Store&, doc: config_toml::Document&, parent: i64, path: const u8[:],
               origin: const u8[:], ids: i64[>..]&, candidates: Candidate[>..]&, error: u8[>..]&) {
    var child = doc.nodes[parent].first;
    while child >= 0 {
        let key = config_toml::key(doc, child);
        if !component(key) { error = problem("unsupported TOML key component", key, origin); return; }
        let size = path.len + key.len + (if path.len == 0 { 0 } else { 1 });
        if size > MAX_KEY_BYTES { error = problem("TOML path exceeds byte limit", key, origin); return; }
        var full: u8[..MAX_KEY_BYTES] = [];
        if path.len > 0 { full.append(path); full.push('.'); }
        full.append(key);
        let node = doc.nodes[child];
        if node.kind == config_toml::Kind.Table {
            if !table_known(store, full) { error = problem("unknown TOML table", full, origin); return; }
            gather_toml(store, doc, child, full, origin, ids, candidates, error);
            if error.len > 0 { return; }
        } else {
            if ids.len >= MAX_FIELDS { error = problem("too many TOML values", full, origin); return; }
            let id = locate(store, full);
            if id < 0 { error = problem("unknown key", full, origin); return; }
            let field = store.fields[id];
            var value = Candidate { source: origin, text: "", .. };
            if node.kind == config_toml::Kind.String && field.kind == Kind.Text {
                let text = config_toml::text(doc, child);
                if text.len > MAX_VALUE_BYTES { error = problem("TOML string exceeds byte limit", full, origin); return; }
                value.text = text;
            } else if node.kind == config_toml::Kind.Integer && field.kind == Kind.Integer { value.integer = node.integer; }
            else if node.kind == config_toml::Kind.Float && field.kind == Kind.Float { value.number = node.number; }
            else if node.kind == config_toml::Kind.Boolean && field.kind == Kind.Boolean { value.boolean = node.boolean; }
            else { error = problem("unsupported or mismatched TOML type", full, origin); return; }
            if range_error(store.fields[id], value) { error = problem("value outside allowed range", full, origin); return; }
            ids.push(id); candidates.push(value);
        }
        child = node.next;
    }
}
// Parse and validate the entire document before committing any values.
fn apply_toml(store: Store&, text: const u8[:], origin: const u8[:]) -> u8[>..] {
    if !store.initialized { return problem("store is not initialized"); }
    if origin.len > MAX_SOURCE_BYTES { return problem("source exceeds byte limit", "", origin); }
    var doc = config_toml::Document { .. };
    let error = config_toml::parse_into(text, doc);
    // Do not forward parser diagnostics, which are not part of this API's
    // escaped, value-free error contract.
    if error.len > 0 { return problem("invalid TOML document or parser resource limit", "", origin); }
    var ids:          i64[>..]       = [];
    var candidates:   Candidate[>..] = [];
    var gather_error: u8[>..]        = [];
    gather_toml(store, doc, 0, "", origin, ids, candidates, gather_error);
    if gather_error.len > 0 { return gather_error; }
    if ids.len > 0 { commit_layer(store, ids, candidates); }
    []
}
