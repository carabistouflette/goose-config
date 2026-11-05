// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.reload;
import std;
import os;
const SAMPLES = 7;
fn duration_bench(count: i64, mode: i64) {
    var schema: config::Field[>..] = [];
    schema.push(config::Field { "delay", config::Kind.Duration });
    if mode == 0 { schema.push(config::Field { "other", config::Kind.Duration }); }
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    assert(config::apply(store, [config::Override { "delay", "250ms", "initial" }]).len == 0);
    if mode == 0 { assert(config::apply(store, [config::Override { "other", "1.5s", "initial" }]).len == 0); }
    let texts = ["250ms", "1.5s"];
    let json = ["{\"delay\":\"250ms\"}", "{\"delay\":\"1.5s\"}"];
    let toml = ["delay='250ms'", "delay='1.5s'"];
    var times:    f64[SAMPLES] = [0.0; SAMPLES];
    var checksum: i64          = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            var error: u8[>..] = [];
            if mode == 1 { error = config::apply(store, [config::Override { "delay", texts[i % 2], "override" }]); }
            else if mode == 2 { error = config::apply_json(store, json[i % 2], "app.json"); }
            else if mode == 3 { error = config::apply_toml(store, toml[i % 2], "app.toml"); }
            assert(error.len == 0);
            let value, issue = config::get_duration(store, if mode == 0 && i % 2 == 1 { "other" } else { "delay" });
            assert(issue.len == 0); checksum += value.nanoseconds;
        }
        times[sample] = (clock_ns() - start) / (count as f64);
    }
    let expected = SAMPLES * (((count + 1) / 2) * 250000000 + (count / 2) * 1500000000);
    assert(checksum == expected);
    let value, error = config::get_duration(store, "delay");
    if mode == 0 {
        let other, oe = config::get_duration(store, "other");
        let osource, ose = config::source(store, "other");
        assert(oe.len == 0 && other.nanoseconds == 1500000000 && ose.len == 0 && osource == "initial");
    }
    let source, issue = config::source(store, "delay");
    assert(error.len == 0 && issue.len == 0 && value.nanoseconds == (if mode == 0 || count % 2 == 1 { 250000000 } else { 1500000000 }));
    assert(source == (if mode == 0 { "initial" } else if mode == 1 { "override" } else if mode == 2 { "app.json" } else { "app.toml" }));
    let name = if mode == 0 { "duration-get" } else if mode == 1 { "duration-override" } else if mode == 2 { "duration-json" } else { "duration-toml" };
    print(name, " samples_ns=", times, " checksum=", checksum);
}
fn main() {
    var count: i64 = 1000;
    if arg_count() > 1 {
        var argument: u8[>..] = []; arg(1, argument);
        let value, ok = parse_int(argument, 10); assert(ok && value >= 1 && value <= 100000); count = value;
    }
    for mode in 4 { duration_bench(count, mode); }
}
