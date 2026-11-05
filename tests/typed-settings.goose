// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.typed;
import config.reload;
import typed_fixture;
import std;

// Consumer overloads cannot replace generated ownership or diagnostics.
fn str(input: const u8[:]) -> u8[>..] { [] }
fn own_text(input: const u8[:]) -> u8[>..] { [] }
fn copy(input: u8[>..]&) -> u8[>..] { [] }

var validations: i64 = 0;
fn reject(candidate: const typed_fixture::Settings&) -> u8[>..] {
    validations++; assert(candidate.label.len > 0);
    var error: u8[>..] = []; error.append("application rejected"); error
}
fn accept(candidate: const typed_fixture::Settings&) -> u8[>..] { validations++; [] }
fn populated(value: const typed_fixture::Settings&) {
    assert(value.label == "original" && value.label_source == "seed");
    assert(value.count_present && value.count == 4 && value.ratio_present && value.ratio == 2.5);
    assert(value.enabled_present && !value.enabled && value.timeout_present && value.timeout.nanoseconds == 1000000000);
    assert(value.tags_present && value.tags.len == 2 && value.tags_source == "lists");
    for tag, i in value.tags { assert(tag == (if i == 0 { "red" } else { "blue" })); }
    assert(value.counts_present && value.counts.len == 2 && value.counts[0] == -2 && value.counts[1] == 4);
    assert(value.ratios_present && value.ratios.len == 2 && value.ratios[0] == 0.0 && value.ratios[1] == 2.5);
    assert(value.switches_present && value.switches.len == 2 && !value.switches[0] && value.switches[1]);
    assert(value.delays_present && value.delays.len == 2 && value.delays[0].nanoseconds == 0 && value.delays[1].nanoseconds == 1000000000);
}
fn main() {
    var destination = typed_fixture::Settings { .. };
    var store = config::Store { .. };
    let fields = typed_fixture::schema(); let aliases = typed_fixture::aliases();
    let absent, uninitialized = config::has_value(store, "count", config::Kind.Integer);
    assert(!absent && uninitialized.len > 0);
    assert(config::init(fields, store, aliases).len == 0);
    let missing, me = config::has_value(store, "old.count", config::Kind.Integer);
    let wrong, we = config::has_value(store, "count", config::Kind.Text);
    let unknown, ue = config::has_value(store, "unknown", config::Kind.Integer);
    assert(!missing && me.len == 0 && !wrong && we.len > 0 && !unknown && ue.len > 0);
    assert(typed_fixture::load(store, destination, accept).len > 0 && validations == 0);
    let values = [config::Override { "old.label", "original", "seed" }, config::Override { "old.count", "4", "seed" },
                  config::Override { "ratio", "2.5", "seed" }, config::Override { "enabled", "false", "seed" },
                  config::Override { "timeout", "1s", "seed" }];
    let tags = ["red", "blue"]; let counts = ["-2", "4"]; let ratios = ["0.0", "2.5"];
    let switches = ["false", "true"]; let delays = ["0s", "1s"];
    let lists = [config::ListOverride { "tags", tags, "lists" }, config::ListOverride { "counts", counts, "lists" },
                 config::ListOverride { "ratios", ratios, "lists" }, config::ListOverride { "switches", switches, "lists" },
                 config::ListOverride { "delays", delays, "lists" }];
    assert(config::apply(store, values).len == 0 && config::apply_lists(store, lists).len == 0);
    assert(typed_fixture::load(store, destination, accept).len == 0 && validations == 1); populated(destination);
    assert(typed_fixture::load(store, destination, reject).len > 0 && validations == 2); populated(destination);
    // A late differently typed optional field must fail before the callback,
    // even while absent, and preserve every populated destination field.
    var alternate: config::Field[>..] = []; alternate.append(fields); alternate[9].kind = config::Kind.Text;
    var other = config::Store { .. };
    assert(config::init(alternate, other).len == 0);
    assert(config::apply(other, values[..1]).len > 0); // alias not declared
    assert(config::apply(other, [config::Override { "label", "changed", "other" }]).len == 0);
    assert(typed_fixture::load(other, destination, accept).len > 0 && validations == 2); populated(destination);
    // The Store's looser ranges do not bypass generated rules.
    alternate.clear(); alternate.append(fields); alternate[9].int_max = 2000000000;
    assert(config::init(alternate, other).len == 0);
    assert(config::apply(other, [config::Override { "label", "changed", "other" }]).len == 0);
    let too_long = ["1s", "2s"];
    assert(config::apply_lists(other, [config::ListOverride { "delays", too_long, "other" }]).len == 0);
    assert(typed_fixture::load(other, destination, accept).len > 0 && validations == 2); populated(destination);
    // Unknown generated fields also fail before application validation.
    assert(config::init(fields[..9], other).len == 0);
    assert(config::apply(other, [config::Override { "label", "changed", "other" }]).len == 0);
    assert(typed_fixture::load(other, destination, accept).len > 0 && validations == 2); populated(destination);
    // Successful replacement resets every absent value/flag/source. Empty,
    // zero and false remain present rather than receiving implicit defaults.
    let minimal = [config::Override { "label", "", "empty" }, config::Override { "count", "0", "empty" }, config::Override { "enabled", "false", "empty" }];
    let empty: const u8[:][0] = [];
    let empty_lists = [config::ListOverride { "tags", empty, "empty-list" }];
    let layers = [config::Layer { kind: config::LayerKind.Values, overrides: minimal, .. }, config::Layer { kind: config::LayerKind.Lists, lists: empty_lists, .. }];
    assert(config::reload(fields, layers, store, aliases).len == 0);
    assert(typed_fixture::load(store, destination).len == 0);
    assert(destination.label.len == 0 && destination.label_source == "empty");
    assert(destination.count_present && destination.count == 0 && destination.enabled_present && !destination.enabled);
    assert(!destination.ratio_present && destination.ratio == 0.0 && !destination.timeout_present && destination.timeout.nanoseconds == 0);
    assert(destination.tags_present && destination.tags.len == 0 && destination.tags_source == "empty-list");
    assert(!destination.counts_present && destination.counts.len == 0 && !destination.ratios_present && destination.ratios.len == 0);
    assert(!destination.switches_present && destination.switches.len == 0 && !destination.delays_present && destination.delays.len == 0);
    let label_only = [config::Override { "label", "retained", "last" }];
    let only = [config::Layer { kind: config::LayerKind.Values, overrides: label_only, .. }];
    assert(config::reload(fields, only, store, aliases).len == 0 && typed_fixture::load(store, destination).len == 0);
    assert(!destination.tags_present && destination.tags.len == 0 && destination.tags_source.len == 0);
    // Destruction/reinitialization of source storage cannot affect owned output.
    assert(config::init([], store).len == 0);
    assert(destination.label == "retained" && destination.label_source == "last");
    print("generated settings ownership, presence, ranges, aliases and atomic publication passed");
}
