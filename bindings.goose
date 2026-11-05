// SPDX-License-Identifier: Apache-2.0
// Optional explicit environment and command-line adapters.
import config;
import os;
namespace config;

struct Binding { key: const u8[:], name: const u8[:], separator: const u8[:] = "," }
struct EnvValue { name: const u8[:], value: const u8[:] }
const MAX_CLI_ARGUMENTS = 512;
// Bind the same runtime primitive as os.env inside our namespace, so consumer
// overloads of the standard library's global env function cannot redirect it.
extern fn binding_env_read(name: const u8[:], out: u8[>..]&) -> bool = "gs_os_getenv";

fn binding_name(name: const u8[:], cli: bool) -> bool {
    let limit = if cli { MAX_SOURCE_BYTES - 2 } else { MAX_SOURCE_BYTES };
    if name.len == 0 || name.len > limit { return false; }
    if cli { return component(name) && name[0] != '-'; }
    for byte in name { if byte == 0 || byte == '=' { return false; } }
    true
}
fn binding_error(store: Store&, bindings: Binding[:], cli: bool) -> u8[>..] {
    if !store.initialized { return problem("store is not initialized"); }
    if bindings.len > MAX_FIELDS { return problem("too many bindings"); }
    for i in bindings.len {
        let binding = bindings[i];
        if !binding_name(binding.name, cli) { return problem("invalid binding name", binding.key, binding.name); }
        if !valid_key(binding.key) { return problem("invalid binding key", binding.key, binding.name); }
        let target = locate(store, binding.key);
        if target < 0 { return problem("unknown binding key", binding.key, binding.name); }
        if !cli && list_kind(store.fields[target].kind) &&
           (binding.separator.len == 0 || binding.separator.len > MAX_KEY_BYTES) {
            return problem("invalid list separator", binding.key, binding.name);
        }
        for j in i {
            if bindings[j].name == binding.name { return problem("duplicate binding name", binding.key, binding.name); }
            if bindings[j].key == binding.key || (store.aliases.len > 0 && locate(store, bindings[j].key) == target) { return problem("duplicate binding target", binding.key, binding.name); }
        }
    }
    []
}
fn binding_index(bindings: Binding[:], name: const u8[:]) -> i64 {
    for i in bindings.len { if bindings[i].name == name { return i; } }
    -1
}

// Supplied pairs may include unbound names, just as the process environment
// does. All pair names are validated and unique, including unbound names.
// Empty text is present; absence is represented by an omitted pair.
fn apply_env_values(store: Store&, bindings: Binding[:], values: EnvValue[:]) -> u8[>..] {
    let error = binding_error(store, bindings, false);
    if error.len > 0 { return own_text(error); }
    if values.len > MAX_FIELDS { return problem("too many environment values"); }
    var bytes:  u8[>..]        = [];
    var staged: BoundSpan[>..] = [];
    for i in values.len {
        let pair = values[i];
        if !binding_name(pair.name, false) { return problem("invalid environment name", "", pair.name); }
        if pair.value.len > MAX_VALUE_BYTES { return problem("environment value exceeds byte limit", "", pair.name); }
        for j in i {
            if values[j].name == pair.name { return problem("duplicate environment name", "", pair.name); }
        }
        let id = binding_index(bindings, pair.name);
        if id >= 0 {
            let text = save(bytes, pair.value);
            let source = save(bytes, pair.name);
            staged.push(BoundSpan { id, text, source });
        }
    }
    apply_bound_spans(store, bindings, staged, bytes, true)
}

struct BoundSpan { binding: i64, value: Span, source: Span }
fn apply_bound_spans(store: Store&, bindings: Binding[:], staged: BoundSpan[:], bytes: const u8[:], environment: bool) -> u8[>..] {
    if staged.len == 0 { return []; }
    var next = Store { .. };
    publish_store(next, store);
    for id in bindings.len {
        var values: const u8[:][>..] = [];
        var source: const u8[:]      = bytes[..0];
        let key = bindings[id].key;
        let is_list = list_kind(store.fields[locate(store, key)].kind);
        var present = false;
        for entry in staged {
            if entry.binding != id { continue; }
            present = true;
            source = view(bytes, entry.source);
            let text = view(bytes, entry.value);
            if environment && is_list {
                // Empty environment text explicitly sets an empty list.
                if text.len == 0 { continue; }
                let separator = bindings[id].separator;
                var start = 0;
                var offset = 0;
                while offset <= text.len - separator.len {
                    if text[offset..offset + separator.len] == separator {
                        values.push(text[start..offset]);
                        if values.len > MAX_LIST_ITEMS { return problem("too many list items", key, source); }
                        offset += separator.len; start = offset;
                    } else { offset++; }
                }
                values.push(text[start..]);
            } else { values.push(text); }
            if is_list && values.len > MAX_LIST_ITEMS { return problem("too many list items", key, source); }
        }
        if !present { continue; }
        if is_list {
            let input = [ListOverride { key, values, source }];
            let error = apply_lists(next, input);
            if error.len > 0 { return error; }
        } else {
            let input = [Override { key, values[0], source }];
            let error = apply(next, input);
            if error.len > 0 { return error; }
        }
    }
    publish_store(store, next);
    []
}
// Reads only explicitly registered names. std.os distinguishes unset from
// empty and does not mutate the process environment. Its getter copies before
// this adapter can check the value-size limit.
fn apply_env(store: Store&, bindings: Binding[:]) -> u8[>..] {
    let error = binding_error(store, bindings, false);
    if error.len > 0 { return own_text(error); }
    var bytes:  u8[>..]        = [];
    var staged: BoundSpan[>..] = [];
    for i in bindings.len {
        var value: u8[>..] = [];
        if binding_env_read(bindings[i].name, value) {
            if value.len > MAX_VALUE_BYTES { return problem("environment value exceeds byte limit", bindings[i].key, bindings[i].name); }
            let text = save(bytes, value);
            let source = save(bytes, bindings[i].name);
            staged.push(BoundSpan { i, text, source });
        }
    }
    apply_bound_spans(store, bindings, staged, bytes, true)
}

// Names omit the '--' prefix. No shorthand, positional arguments, implicit
// booleans, normalization, or list splitting. Repeated options accumulate list
// elements in argument order; repeated scalar options fail. A final '--' is accepted.
// A separated value may start with one '-' (e.g. -12), but '--...' denotes
// another option and must use '--name=--text' when intended as text.
fn apply_cli(store: Store&, bindings: Binding[:], args: const u8[:][:]) -> u8[>..] {
    let error = binding_error(store, bindings, true);
    if error.len > 0 { return own_text(error); }
    if args.len > MAX_CLI_ARGUMENTS { return problem("too many command-line arguments"); }
    var bytes:  u8[>..]          = [];
    var staged: BoundSpan[>..]   = [];
    var seen:   bool[MAX_FIELDS] = [false; MAX_FIELDS];
    var i = 0;
    while i < args.len {
        let arg = args[i];
        if arg == "--" {
            if i + 1 < args.len { return problem("positional arguments are not supported"); }
            break;
        }
        if arg.len < 3 || arg[..2] != "--" { return problem("expected a registered long option"); }
        var end = 2;
        while end < arg.len && arg[end] != '=' {
            if end >= MAX_SOURCE_BYTES { return problem("option name exceeds byte limit", "", arg[2..end]); }
            end++;
        }
        let name = arg[2..end];
        if !binding_name(name, true) { return problem("invalid option name", "", name); }
        let id = binding_index(bindings, name);
        if id < 0 { return problem("unknown option", "", name); }
        let field = store.fields[locate(store, bindings[id].key)];
        if seen[id] && !list_kind(field.kind) { return problem("duplicate option target", bindings[id].key, name); }
        seen[id] = true;
        var value = arg[end..end];
        if end < arg.len { value = arg[end + 1..]; }
        else {
            i++;
            if i >= args.len { return problem("missing option value", bindings[id].key, name); }
            let next = args[i];
            if next.len >= 2 && next[..2] == "--" { return problem("missing option value", bindings[id].key, name); }
            value = next;
        }
        if value.len > MAX_VALUE_BYTES { return problem("option value exceeds byte limit", bindings[id].key, name); }
        let text = save(bytes, value);
        let start = bytes.len;
        bytes.push('-'); bytes.push('-'); bytes.append(name);
        staged.push(BoundSpan { id, text, Span { start, name.len + 2 } });
        i++;
    }
    apply_bound_spans(store, bindings, staged, bytes, false)
}
