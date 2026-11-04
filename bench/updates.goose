// SPDX-License-Identifier: Apache-2.0
import config from "..";
import std;
import os;
const SAMPLES = 7;
fn report(name: const u8[:], samples: f64[:], checksum: i64) {
    print(name, " samples_ns=", samples, " checksum=", checksum);
    sort(samples);
    print("median=", samples[SAMPLES / 2], " min=", samples[0], " max=", samples[SAMPLES - 1]);
}
// All cases retain 254 or 255 large Text neighbors. The target starts in state
// B; global operation parity alternates A/B even across one-operation batches.
// Modes: equal combined scalar span with moving source/text boundary, changing
// scalar span, Integer, TextList, and two-field Text layer.
fn scenario(name: const u8[:], count: i64, mode: i64) {
    var keys: u8[][>..] = [];
    for i in 256 { keys.push(str("field", i)); }
    var schema: config::Field[>..] = [];
    for key, i in keys {
        let kind = if i == 128 && mode == 2 { config::Kind.Integer }
                   else if i == 128 && mode == 3 { config::Kind.TextList }
                   else { config::Kind.Text };
        schema.push(config::Field { key, kind });
    }
    var payload: u8[>..] = [];
    for i in 4096 { payload.push('x'); }
    let text_a = if mode == 0 { "aaaaa" } else if mode == 2 { "17" } else { "a" };
    let text_b = if mode == 0 { "bbb" } else if mode == 1 { "bb" } else if mode == 2 { "29" } else { "b" };
    let source_a = "cli";
    let source_b = if mode == 0 { "layer" } else { "cli" };
    let input_a = [config::Override { "field128", text_a, source_a }];
    let input_b = [config::Override { "field128", text_b, source_b }];
    let batch_a = [config::Override { "field128", text_a, source_a }, config::Override { "field129", "cc", "cli" }];
    let batch_b = [config::Override { "field128", text_b, source_b }, config::Override { "field129", "dd", "cli" }];
    let list_a = ["red", "green", "blue"];
    let list_b = ["cyan", "magenta"];
    let lists_a = [config::ListOverride { "field128", list_a, "cli" }];
    let lists_b = [config::ListOverride { "field128", list_b, "cli" }];
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    var initial: config::Override[>..] = [];
    for key, i in keys {
        if i == 128 && mode == 3 { continue; }
        let text = if i == 128 { text_b } else if i == 129 && mode == 4 { "dd" } else { payload };
        let source = if i == 128 { source_b } else if i == 129 && mode == 4 { "cli" } else { "defaults" };
        initial.push(config::Override { key, text, source });
    }
    assert(config::apply(store, initial).len == 0);
    if mode == 3 { assert(config::apply_lists(store, lists_b).len == 0); }
    var samples:  f64[SAMPLES] = [0.0; SAMPLES];
    var checksum: i64          = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            let first = (sample * count + i) % 2 == 0;
            if mode == 3 {
                assert(config::apply_lists(store, if first { lists_a } else { lists_b }).len == 0);
                let values, error = config::get_text_list(store, "field128");
                assert(error.len == 0 && values.len == (if first { 3 } else { 2 }));
                for value in values { checksum += value.len + value[0]; }
            } else {
                if mode == 4 {
                    assert(config::apply(store, if first { batch_a } else { batch_b }).len == 0);
                } else { assert(config::apply(store, if first { input_a } else { input_b }).len == 0); }
                if mode == 2 {
                    let value, error = config::get_integer(store, "field128");
                    assert(error.len == 0 && value == (if first { 17 } else { 29 }));
                    checksum += value;
                } else {
                    let value, error = config::get_text(store, "field128");
                    assert(error.len == 0 && value == (if first { text_a } else { text_b }));
                    checksum += value.len + value[0];
                    if mode == 4 {
                        let second, se = config::get_text(store, "field129");
                        assert(se.len == 0 && second == (if first { "cc" } else { "dd" }));
                        checksum += second.len + second[0];
                    }
                }
            }
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    let final_a = (SAMPLES * count) % 2 == 1;
    // Check every full value and source outside the timer, including each list
    // element and all large retained neighbors rather than only their lengths.
    for field, i in schema {
        let source, se = config::source(store, field.key);
        assert(se.len == 0);
        if i == 128 {
            assert(source == (if final_a { source_a } else { source_b }));
            if mode == 2 {
                let value, error = config::get_integer(store, field.key);
                assert(error.len == 0 && value == (if final_a { 17 } else { 29 }));
            } else if mode == 3 {
                let values, error = config::get_text_list(store, field.key);
                assert(error.len == 0);
                if final_a {
                    assert(values.len == list_a.len);
                    for value, j in values { assert(value == list_a[j]); }
                } else {
                    assert(values.len == list_b.len);
                    for value, j in values { assert(value == list_b[j]); }
                }
            } else {
                let value, error = config::get_text(store, field.key);
                assert(error.len == 0 && value == (if final_a { text_a } else { text_b }));
            }
        } else {
            let value, error = config::get_text(store, field.key);
            assert(error.len == 0);
            if i == 129 && mode == 4 {
                assert(value == (if final_a { "cc" } else { "dd" }) && source == "cli");
            } else { assert(value == payload && source == "defaults"); }
        }
    }
    report(name, samples, checksum);
}
fn main() {
    var count: i64 = 1000;
    if arg_count() > 1 {
        var argument: u8[>..] = []; arg(1, argument);
        let parsed, ok = parse_int(argument, 10);
        assert(ok && parsed > 0 && parsed <= 100000); count = parsed;
    }
    scenario("update-text-boundary-large", count, 0);
    scenario("update-text-resize-large", count, 1);
    scenario("update-integer-large", count, 2);
    scenario("update-text-list-large", count, 3);
    scenario("update-two-text-large", count, 4);
}
