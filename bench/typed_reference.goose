// SPDX-License-Identifier: Apache-2.0
// Explicit reference loader for the ten-kind fixture. It deliberately checks
// metadata in one loop, then stages values; errors need not have identical order.
import config from "..";
import config.typed;
import typed_fixture;
import std;
namespace typed_reference;
fn owned(input: const u8[:]) -> u8[>..] { var out: u8[>..] = []; out.append(input); out }
fn load<Validate>(store: config::Store&, destination: typed_fixture::Settings&) -> u8[>..] {
    let keys = ["label", "count", "ratio", "enabled", "timeout", "tags", "counts", "ratios", "switches", "delays"];
    let kinds = [config::Kind.Text, config::Kind.Integer, config::Kind.Float, config::Kind.Boolean, config::Kind.Duration,
                 config::Kind.TextList, config::Kind.IntegerList, config::Kind.FloatList, config::Kind.BooleanList, config::Kind.DurationList];
    var present: bool[10] = [false; 10];
    for i in 10 {
        let exists, error = config::has_value(store, keys[i], kinds[i]);
        if error.len > 0 { return error; } present[i] = exists;
    }
    if !present[0] { return owned("reference: required label missing"); }
    var candidate = typed_fixture::Settings { .. };
    let label, label_error = config::get_text(store, "label");
    let origin, origin_error = config::source(store, "label");
    if label_error.len > 0 { return label_error; } if origin_error.len > 0 { return origin_error; }
    candidate.label.append(label); candidate.label_source.append(origin);
    candidate.count_present = present[1];
    if present[1] {
        let value, error = config::get_integer(store, "count"); if error.len > 0 { return error; }
        if value < -2 || value > 4 { return owned("reference: count range"); } candidate.count = value;
    }
    candidate.ratio_present = present[2];
    if present[2] {
        let value, error = config::get_float(store, "ratio"); if error.len > 0 { return error; }
        if value < 0.0 || value > 2.5 { return owned("reference: ratio range"); } candidate.ratio = value;
    }
    candidate.enabled_present = present[3];
    if present[3] {
        let value, error = config::get_boolean(store, "enabled"); if error.len > 0 { return error; } candidate.enabled = value;
    }
    candidate.timeout_present = present[4];
    if present[4] {
        let value, error = config::get_duration(store, "timeout"); if error.len > 0 { return error; }
        if value.nanoseconds < 1 || value.nanoseconds > 1000000000 { return owned("reference: timeout range"); } candidate.timeout = value;
    }
    candidate.tags_present = present[5];
    if present[5] {
        let values, error = config::get_text_list(store, "tags"); if error.len > 0 { return error; }
        for value in values { candidate.tags.push(owned(value)); }
        let source, source_error = config::source(store, "tags"); if source_error.len > 0 { return source_error; }
        candidate.tags_source.append(source);
    }
    candidate.counts_present = present[6];
    if present[6] {
        let values, error = config::get_integer_list(store, "counts"); if error.len > 0 { return error; }
        for value in values { if value < -2 || value > 4 { return owned("reference: counts range"); } candidate.counts.push(value); }
    }
    candidate.ratios_present = present[7];
    if present[7] {
        let values, error = config::get_float_list(store, "ratios"); if error.len > 0 { return error; }
        for value in values { if value < 0.0 || value > 2.5 { return owned("reference: ratios range"); } candidate.ratios.push(value); }
    }
    candidate.switches_present = present[8];
    if present[8] {
        let values, error = config::get_boolean_list(store, "switches"); if error.len > 0 { return error; }
        for value in values { candidate.switches.push(value); }
    }
    candidate.delays_present = present[9];
    if present[9] {
        let values, error = config::get_duration_list(store, "delays"); if error.len > 0 { return error; }
        for value in values {
            if value.nanoseconds < 0 || value.nanoseconds > 1000000000 { return owned("reference: delays range"); }
            candidate.delays.push(value);
        }
    }
    let readonly: const typed_fixture::Settings& = candidate;
    let error = Validate(readonly); if error.len > 0 { return error; }
    destination.label.clear(); destination.label.append(candidate.label);
    destination.label_source.clear(); destination.label_source.append(candidate.label_source);
    destination.count = candidate.count; destination.count_present = candidate.count_present;
    destination.ratio = candidate.ratio; destination.ratio_present = candidate.ratio_present;
    destination.enabled = candidate.enabled; destination.enabled_present = candidate.enabled_present;
    destination.timeout = candidate.timeout; destination.timeout_present = candidate.timeout_present;
    destination.tags.clear(); for item in candidate.tags { destination.tags.push(owned(item)); }
    destination.tags_source.clear(); destination.tags_source.append(candidate.tags_source); destination.tags_present = candidate.tags_present;
    destination.counts.clear(); destination.counts.append(candidate.counts); destination.counts_present = candidate.counts_present;
    destination.ratios.clear(); destination.ratios.append(candidate.ratios); destination.ratios_present = candidate.ratios_present;
    destination.switches.clear(); destination.switches.append(candidate.switches); destination.switches_present = candidate.switches_present;
    destination.delays.clear(); destination.delays.append(candidate.delays); destination.delays_present = candidate.delays_present;
    []
}
