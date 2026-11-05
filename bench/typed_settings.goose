// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.reload;
import typed_fixture;
import typed_reference;
import std;
import os;
const SAMPLES = 7;
fn text(input: const u8[:]) -> u8[>..] { var out: u8[>..] = []; out.append(input); out }
fn document(first: bool, large: bool, optional: bool, omit_delays: bool = false) -> u8[>..] {
    var out = text("{\"label\":\"");
    if large { for i in (if first { 1024 } else { 1001 }) { out.push(if first { 'A' } else { 'B' }); } }
    else { out.append(if first { "alpha" } else { "bravo-x" }); }
    out.push('"'); if optional { out.push('}'); return out; }
    out.append(if first { ",\"count\":1,\"ratio\":1.25,\"enabled\":false,\"timeout\":\"250ms\",\"tags\":[\"" }
                        else { ",\"count\":4,\"ratio\":2.5,\"enabled\":true,\"timeout\":\"1s\",\"tags\":[\"" });
    if large { for i in (if first { 3000 } else { 2991 }) { out.push(if first { 'a' } else { 'b' }); } }
    else { out.append(if first { "red" } else { "blue" }); }
    out.append(if first { "\",\"tail-a\"],\"counts\":[-2,4],\"ratios\":[0.0,2.5],\"switches\":[false,true]" }
                        else { "\",\"\"],\"counts\":[0,3],\"ratios\":[1.25,0.5],\"switches\":[true,false]" });
    if !omit_delays { out.append(if first { ",\"delays\":[\"0s\",\"1s\"]" } else { ",\"delays\":[\"250ms\",\"500ms\"]" }); }
    out.push('}'); out
}
fn validate(candidate: const typed_fixture::Settings&) -> u8[>..] {
    if candidate.label.len == 0 || (candidate.count_present && candidate.count < 0) || (candidate.tags_present && candidate.tags.len > 128) {
        return text("policy rejected");
    }
    []
}
fn deny(candidate: const typed_fixture::Settings&) -> u8[>..] {
    assert(validate(candidate).len == 0); text("policy rejected")
}
fn digest(value: const typed_fixture::Settings&) -> i64 {
    var result = value.label.len + value.label_source.len;
    if value.count_present { result += value.count; }
    if value.ratio_present { result += (value.ratio * 4.0) as i64; }
    if value.enabled_present { result += if value.enabled { 17 } else { 19 }; }
    if value.timeout_present { result += value.timeout.nanoseconds; }
    if value.tags_present { for item in value.tags { result += item.len; } result += value.tags_source.len; }
    if value.counts_present { for item in value.counts { result += item; } }
    if value.ratios_present { for item in value.ratios { result += (item * 4.0) as i64; } }
    if value.switches_present { for item in value.switches { result += if item { 23 } else { 29 }; } }
    if value.delays_present { for item in value.delays { result += item.nanoseconds; } }
    result
}
fn verify(value: const typed_fixture::Settings&, first: bool, large: bool, optional: bool) {
    if large {
        assert(value.label.len == (if first { 1024 } else { 1001 }));
        for byte in value.label { assert(byte == (if first { 'A' } else { 'B' })); }
    } else { assert(value.label == (if first { "alpha" } else { "bravo-x" })); }
    assert(value.label_source == (if first { "snapshot-a" } else { "snapshot-b" }));
    assert(value.count_present == !optional && value.ratio_present == !optional && value.enabled_present == !optional && value.timeout_present == !optional);
    assert(value.tags_present == !optional && value.counts_present == !optional && value.ratios_present == !optional && value.switches_present == !optional && value.delays_present == !optional);
    if optional {
        assert(value.count == 0 && value.ratio == 0.0 && !value.enabled && value.timeout.nanoseconds == 0);
        assert(value.tags.len == 0 && value.tags_source.len == 0 && value.counts.len == 0 && value.ratios.len == 0 && value.switches.len == 0 && value.delays.len == 0);
        return;
    }
    assert(value.count == (if first { 1 } else { 4 }) && value.ratio == (if first { 1.25 } else { 2.5 }));
    assert(value.enabled == !first && value.timeout.nanoseconds == (if first { 250000000 } else { 1000000000 }));
    assert(value.tags.len == 2 && value.tags_source == (if first { "snapshot-a" } else { "snapshot-b" }));
    for item, i in value.tags {
        if i == 0 {
            if large { assert(item.len == (if first { 3000 } else { 2991 })); for byte in item { assert(byte == (if first { 'a' } else { 'b' })); } }
            else { assert(item == (if first { "red" } else { "blue" })); }
        } else { assert(item == (if first { "tail-a" } else { "" })); }
    }
    assert(value.counts.len == 2 && value.counts[0] == (if first { -2 } else { 0 }) && value.counts[1] == (if first { 4 } else { 3 }));
    assert(value.ratios.len == 2 && value.ratios[0] == (if first { 0.0 } else { 1.25 }) && value.ratios[1] == (if first { 2.5 } else { 0.5 }));
    assert(value.switches.len == 2 && value.switches[0] == !first && value.switches[1] == first);
    assert(value.delays.len == 2 && value.delays[0].nanoseconds == (if first { 0 } else { 250000000 }) && value.delays[1].nanoseconds == (if first { 1000000000 } else { 500000000 }));
}
fn report(name: const u8[:], samples: f64[:], checksum: i64) {
    print(name, " samples_ns=", samples, " checksum=", checksum);
    sort(samples); print("median=", samples[SAMPLES / 2], " min=", samples[0], " max=", samples[SAMPLES - 1]);
}
fn scenario<Load>(name: const u8[:], count: i64, mode: i64, generated: bool) {
    let large = mode == 1 || mode == 2 || mode == 4 || mode == 5;
    let schema = typed_fixture::schema();
    let a_text = document(true, large, false); let b_text = document(false, large, mode == 3, mode == 6);
    var a = config::Store { .. }; var b = config::Store { .. };
    assert(config::init(schema, a).len == 0);
    assert(config::init(if mode == 6 { schema[..9] } else { schema[..] }, b).len == 0);
    assert(config::apply_json(a, a_text, "snapshot-a").len == 0 && config::apply_json(b, b_text, "snapshot-b").len == 0);
    var active = typed_fixture::Settings { .. };
    assert(Load(a, active, validate).len == 0); verify(active, true, large, false);
    var samples: f64[SAMPLES] = [0.0; SAMPLES]; var checksum: i64 = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            let first = (sample * count + i) % 2 == 0;
            if mode == 5 { let error = Load(b, active, deny); assert(error.len > 0); checksum += error.len; }
            else if mode == 6 { let error = Load(b, active, validate); assert(error.len > 0); checksum += error.len; }
            else if mode == 7 {
                if generated { checksum += if first { active.count } else { active.timeout.nanoseconds }; }
                else if first { let value, error = config::get_integer(a, "count"); assert(error.len == 0); checksum += value; }
                else { let value, error = config::get_duration(a, "timeout"); assert(error.len == 0); checksum += value.nanoseconds; }
            } else if mode == 2 {
                var cold = typed_fixture::Settings { .. };
                if first { assert(Load(a, cold, validate).len == 0); } else { assert(Load(b, cold, validate).len == 0); }
                checksum += digest(cold);
            } else {
                if mode == 4 {
                    let layers = [config::Layer { kind: config::LayerKind.Json, text: if first { a_text } else { b_text }, source: if first { "snapshot-a" } else { "snapshot-b" }, .. }];
                    assert(config::reload(schema, layers, a).len == 0); assert(Load(a, active, validate).len == 0);
                } else if first { assert(Load(a, active, validate).len == 0); }
                else { assert(Load(b, active, validate).len == 0); }
                checksum += digest(active);
            }
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    let last_first = (SAMPLES * count - 1) % 2 == 0;
    if mode == 2 || mode >= 5 { verify(active, true, large, false); }
    else { verify(active, last_first, large, mode == 3 && !last_first); }
    if mode < 5 { var probe = typed_fixture::Settings { .. }; assert(Load(b, probe, validate).len == 0); verify(probe, false, large, mode == 3); }
    report(name, samples, checksum);
}
fn main() {
    let arguments = args(); assert(arguments.len == 3);
    let count, ok = parse_int(arguments[1], 10); assert(ok && count > 0 && count <= 100000);
    let generated = arguments[2] == "generated"; assert(generated || arguments[2] == "reference");
    let names = ["load-small", "load-owned", "cold-owned", "optional-removal", "refresh-owned", "reject-validator", "reject-schema", "application-read"];
    for name, mode in names {
        if generated { scenario(name, count, mode, generated, typed_fixture::load); }
        else { scenario(name, count, mode, generated, typed_reference::load); }
    }
}
