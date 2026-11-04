// SPDX-License-Identifier: Apache-2.0
// Fixed workloads. Logical lengths are not allocator capacity or physical use.
import config from "..";
import config.reload;
import std;
import os;

fn selected(cycle: i64, count: i64) -> bool {
    cycle == 1 || cycle == 10 || cycle == 100 || cycle == count
}
fn checkpoint(store: config::Store&, cycle: i64, state: const u8[:]) {
    print("MEMORY1 ", cycle, " ", state, " ", store.bytes.len, " ", store.items.len,
          " ", store.keys.len, " ", store.fields.len);
    flush_stdout();
    var reply: u8[>..] = [];
    assert(read_line(reply) && reply == "continue");
}
// Owned getter results leave scope before the checkpoint and parent sample.
fn verify(store: config::Store&, schema: config::Field[:], mode: i64, state: i64,
          payload: const u8[:], list: const (const u8[:])[:]) {
    var expected_bytes = 0;
    var expected_items = 0;
    var expected_keys = 0;
    for field, i in schema {
        expected_keys += field.key.len;
        let present = if mode == 2 { state == 1 || (state == 2 && i < 2) } else { state > 0 };
        let source, se = config::source(store, field.key);
        if !present { assert(se.len > 0); }
        else {
            let origin = if mode == 2 { if i < 2 { "json" } else { "lists" } } else { "input" };
            assert(se.len == 0 && source == origin);
            expected_bytes += origin.len;
        }
        if field.kind == config::Kind.Text {
            let value, error = config::get_text(store, field.key);
            if !present { assert(error.len > 0); }
            else {
                let expected = if state == 1 { payload } else if mode == 2 { "ready" } else { "" };
                assert(error.len == 0 && value == expected);
                expected_bytes += expected.len;
            }
        } else {
            let values, error = config::get_text_list(store, field.key);
            if !present { assert(error.len > 0); }
            else {
                assert(error.len == 0 && values.len == (if state == 1 { 256 } else { 0 }));
                if state == 1 {
                    expected_items += 256;
                    for value, j in values { assert(value == list[j]); expected_bytes += 16; }
                }
            }
        }
    }
    assert(store.initialized && store.fields.len == 256 && store.values.len == 256);
    assert(store.keys.len == expected_keys && store.bytes.len == expected_bytes && store.items.len == expected_items);
    if mode != 2 || state > 0 { assert(config::validate(store).len == 0); }
}
fn scenario(mode: i64, count: i64) {
    var keys: u8[][>..] = [];
    for i in 256 { keys.push(str("field", i)); }
    var schema: config::Field[>..] = [];
    for key, i in keys {
        schema.push(config::Field { key: key, kind: if mode == 0 || (mode == 2 && i == 0) { config::Kind.Text } else { config::Kind.TextList }, required: mode == 2 && i == 0 });
    }
    var payload: u8[>..] = [];
    for i in 4096 { payload.push('x'); }
    var list: const u8[:][>..] = [];
    for i in 256 { list.push("0123456789abcdef"); }
    let empty: const u8[:][0] = [];
    var large:       config::Override[>..]     = [];
    var small:       config::Override[>..]     = [];
    var large_lists: config::ListOverride[>..] = [];
    var small_lists: config::ListOverride[>..] = [];
    for key, i in keys {
        if mode == 0 {
            large.push(config::Override { key, payload, "input" });
            small.push(config::Override { key, "", "input" });
        } else if mode == 1 || i > 0 {
            large_lists.push(config::ListOverride { key, list, if mode == 2 { "lists" } else { "input" } });
            small_lists.push(config::ListOverride { key, empty, "input" });
        }
    }
    var document: u8[>..] = [];
    document.append("{\"field0\":\""); document.append(payload); document.append("\",\"field1\":[");
    for i in 256 { if i > 0 { document.push(','); } document.append("\"0123456789abcdef\""); }
    document.append("]}");
    let large_layers = [config::Layer { kind: config::LayerKind.Lists, lists: large_lists, .. },
                        config::Layer { kind: config::LayerKind.Json, text: document, source: "json", .. }];
    let small_layers = [config::Layer { kind: config::LayerKind.Json, text: "{\"field0\":\"ready\",\"field1\":[]}", source: "json", .. }];
    let missing_layers = [config::Layer { kind: config::LayerKind.Json, text: "{\"field1\":[]}", source: "bad", .. }];
    let bad_layers = [config::Layer { kind: config::LayerKind.Json, text: "{\"field0\":\"changed\",\"unknown\":0}", source: "bad", .. }];
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    verify(store, schema, mode, 0, payload, list);
    checkpoint(store, 0, "initial");
    for i in count {
        let cycle = i + 1;
        if mode == 0 { assert(config::apply(store, large).len == 0); }
        else if mode == 1 { assert(config::apply_lists(store, large_lists).len == 0); }
        else { assert(config::reload(schema, large_layers, store).len == 0); }
        verify(store, schema, mode, 1, payload, list);
        if selected(cycle, count) { checkpoint(store, cycle, "large"); }
        if mode == 0 { assert(config::apply(store, small).len == 0); }
        else if mode == 1 { assert(config::apply_lists(store, small_lists).len == 0); }
        else { assert(config::reload(schema, small_layers, store).len == 0); }
        verify(store, schema, mode, 2, payload, list);
        if selected(cycle, count) { checkpoint(store, cycle, "small"); }
        if mode == 2 {
            assert(config::reload(schema, missing_layers, store).len > 0);
            verify(store, schema, mode, 2, payload, list);
            assert(config::reload(schema, bad_layers, store).len > 0);
            verify(store, schema, mode, 2, payload, list);
            if selected(cycle, count) { checkpoint(store, cycle, "rejected"); }
        }
    }
}
fn main() {
    assert(arg_count() == 3);
    var mode_text:  u8[>..] = []; arg(1, mode_text);
    var count_text: u8[>..] = []; arg(2, count_text);
    let mode, mode_ok = parse_int(mode_text, 10);
    let count, count_ok = parse_int(count_text, 10);
    assert(mode_ok && mode >= 0 && mode <= 3 && count_ok && count >= 1 && count <= 1000);
    if mode == 3 {
        // Same binary and launcher without Store or scenario input setup.
        print("MEMORY1 0 initial 0 0 0 0"); flush_stdout();
        var ready: u8[>..] = [];
        assert(read_line(ready) && ready == "continue");
    } else { scenario(mode, count); }
    // No Store or scenario input owners remain; these zeros describe no live
    // Store, rather than measured zero allocator capacity or physical memory.
    print("MEMORY1 0 released 0 0 0 0"); flush_stdout();
    var reply: u8[>..] = [];
    assert(read_line(reply) && reply == "continue");
    print("DONE1"); flush_stdout();
}
