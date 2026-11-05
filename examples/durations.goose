// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.json_layer;
import std;
fn main() {
    let schema = [config::Field { key: "timeout", kind: config::Kind.Duration, required: true, int_min: 0, int_max: 30000000000 },
                  config::Field { "retries", config::Kind.DurationList }];
    var store = config::Store { .. };
    assert(config::init(schema, store).len == 0);
    assert(config::apply(store, [config::Override { "timeout", "250ms", "defaults" }]).len == 0);
    assert(config::apply_json(store, "{\"timeout\":\"2s\",\"retries\":[\"100ms\",\"1s\"]}", "app.json").len == 0);
    assert(config::validate(store).len == 0);
    let timeout, error = config::get_duration(store, "timeout");
    let retries, list_error = config::get_duration_list(store, "retries");
    assert(error.len == 0 && list_error.len == 0 && retries.len == 2);
    print("timeout=", timeout.nanoseconds, "ns retries=", retries[0].nanoseconds, "ns,", retries[1].nanoseconds, "ns");
}
