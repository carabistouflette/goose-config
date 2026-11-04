// SPDX-License-Identifier: Apache-2.0
import config from "..";
import std;

// Application overloads must not intercept owned list results or their parsers.
fn copy(value: u8[>..]&) -> u8[>..] { [] }
fn copy(value: i64[>..]&) -> i64[>..] { [] }
fn parse_int(value: const u8[:]) -> i64, bool { return 7, true; }
fn parse_int(value: u8[>..]&, base: i64) -> i64, bool { return 7, true; }
fn parse_flt(value: u8[>..]&) -> f64, bool { return 7.0, true; }

fn texts_equal(values: const u8[][:], expected: const (const u8[:])[:]) -> bool {
    if values.len != expected.len { return false; }
    for text, i in values { if text != expected[i] { return false; } }
    true
}
fn check_seed(store: config::Store&) {
    let text, te = config::get_text_list(store, "text");
    let integers, ie = config::get_integer_list(store, "integers");
    let numbers, ne = config::get_float_list(store, "numbers");
    let booleans, be = config::get_boolean_list(store, "booleans");
    assert(te.len == 0 && texts_equal(text, ["first", "", "last"]));
    assert(ie.len == 0 && integers == [-9223372036854775808, 9007199254740993, 9223372036854775807]);
    assert(ne.len == 0 && numbers == [-1.25, 0.0, 2.5]);
    assert(be.len == 0 && booleans == [false, true]);
    for key in ["text", "integers", "numbers", "booleans"] {
        let source, se = config::source(store, key);
        assert(se.len == 0 && source == "seed");
    }
}
fn transactions() {
    var store = config::Store { .. };
    assert(config::apply_lists(store, []).len > 0);
    let schema = [config::Field { "text", config::Kind.TextList },
                  config::Field { "integers", config::Kind.IntegerList },
                  config::Field { "numbers", config::Kind.FloatList },
                  config::Field { "booleans", config::Kind.BooleanList },
                  config::Field { "scalar", config::Kind.Text }];
    assert(config::init(schema, store).len == 0);
    let text_seed = ["first", "", "last"];
    let integer_seed = ["-9223372036854775808", "9007199254740993", "9223372036854775807"];
    let number_seed = ["-1.25", "-1e-999", "2.5"];
    let boolean_seed = ["false", "true"];
    let seed = [config::ListOverride { "text", text_seed, "seed" },
                config::ListOverride { "integers", integer_seed, "seed" },
                config::ListOverride { "numbers", number_seed, "seed" },
                config::ListOverride { "booleans", boolean_seed, "seed" }];
    assert(config::apply_lists(store, seed).len == 0);
    check_seed(store);
    assert(config::apply_lists(store, []).len == 0);
    assert(config::apply_lists(store, [config::ListOverride { "text", ["changed"], "bad" },
                                       config::ListOverride { "text", ["again"], "bad" }]).len > 0);
    assert(config::apply_lists(store, [config::ListOverride { "text", ["changed"], "bad" },
                                       config::ListOverride { "numbers", ["1.0", "NaN"], "bad" }]).len > 0);
    assert(config::apply_lists(store, [config::ListOverride { "text", ["changed"], "bad" },
                                       config::ListOverride { "unknown", [], "bad" }]).len > 0);
    let bad_integers = ["9223372036854775808", "-9223372036854775809", "1.0", "1e2", " 1", "0x10", ""];
    for bad in bad_integers {
        assert(config::apply_lists(store, [config::ListOverride { "integers", ["1", bad], "bad" }]).len > 0);
    }
    let bad_numbers = ["1e99999", "nan", "inf", ".5", "1.", " 1", ""];
    for bad in bad_numbers {
        assert(config::apply_lists(store, [config::ListOverride { "numbers", ["1.0", bad], "bad" }]).len > 0);
    }
    assert(config::apply_lists(store, [config::ListOverride { "booleans", ["true", "1"], "bad" }]).len > 0);
    assert(config::apply_lists(store, [config::ListOverride { "scalar", [], "bad" }]).len > 0);
    assert(config::apply(store, [config::Override { "text", "hello", "bad" }]).len > 0);
    assert(config::apply(store, [config::Override { "integers", "1", "bad" }]).len > 0);
    let wrong, we = config::get_text(store, "text"); assert(we.len > 0);
    let wrong_list, wle = config::get_integer_list(store, "text"); assert(wle.len > 0);
    let missing, me = config::get_text_list(store, "unknown"); assert(me.len > 0);
    check_seed(store);
    // Scalar layers preserve existing lists, then list replacement preserves scalars.
    assert(config::apply(store, [config::Override { "scalar", "retained", "scalar-source" }]).len == 0);
    check_seed(store);
    let owned, oe = config::get_text_list(store, "text"); assert(oe.len == 0);
    let owned_integers, oie = config::get_integer_list(store, "integers"); assert(oie.len == 0);
    assert(config::apply_lists(store, [config::ListOverride { "text", ["replacement"], "later" },
                                       config::ListOverride { "integers", [], "later" }]).len == 0);
    assert(texts_equal(owned, ["first", "", "last"]));
    assert(owned_integers == [-9223372036854775808, 9007199254740993, 9223372036854775807]);
    let replacement, re = config::get_text_list(store, "text"); assert(re.len == 0 && texts_equal(replacement, ["replacement"]));
    let empty, ee = config::get_integer_list(store, "integers"); assert(ee.len == 0 && empty.len == 0);
    let scalar, se = config::get_text(store, "scalar"); assert(se.len == 0 && scalar == "retained");
    var clone = config::Store { .. };
    config::publish_store(clone, store);
    assert(config::init([], store).len == 0);
    let cloned, ce = config::get_text_list(clone, "text"); assert(ce.len == 0 && texts_equal(cloned, ["replacement"]));
    let cloned_scalar, cse = config::get_text(clone, "scalar"); assert(cse.len == 0 && cloned_scalar == "retained");
}
fn limits_and_ranges() {
    var store = config::Store { .. };
    let schema = [config::Field { key: "text", kind: config::Kind.TextList, required: true },
                  config::Field { key: "integers", kind: config::Kind.IntegerList, int_min: 9007199254740993, int_max: 9007199254740994 },
                  config::Field { key: "numbers", kind: config::Kind.FloatList, float_min: -1.5, float_max: 1.5 }];
    assert(config::init(schema, store).len == 0);
    assert(config::validate(store).len > 0);
    assert(config::apply_lists(store, [config::ListOverride { "text", [], "empty" }]).len == 0);
    assert(config::validate(store).len == 0);
    assert(config::apply_lists(store, [config::ListOverride { "integers", ["9007199254740993", "9007199254740994"], "range" },
                                       config::ListOverride { "numbers", ["-1.5", "1.5"], "range" }]).len == 0);
    let outside_integers = ["9007199254740992", "9007199254740995"];
    for token in outside_integers {
        assert(config::apply_lists(store, [config::ListOverride { "integers", [token], "bad" }]).len > 0);
    }
    let outside_numbers = ["-1.50000000001", "1.50000000001", "1e9999"];
    for token in outside_numbers {
        assert(config::apply_lists(store, [config::ListOverride { "numbers", [token], "bad" }]).len > 0);
    }
    var entries: const u8[:][>..] = [];
    for i in config::MAX_LIST_ITEMS { entries.push(""); }
    assert(config::apply_lists(store, [config::ListOverride { "text", entries, "maximum" }]).len == 0);
    let full, fe = config::get_text_list(store, "text"); assert(fe.len == 0 && full.len == config::MAX_LIST_ITEMS);
    entries.push("");
    assert(config::apply_lists(store, [config::ListOverride { "text", entries, "too-many" }]).len > 0);
    var half: u8[>..] = [];
    for i in config::MAX_VALUE_BYTES / 2 { half.push('x'); }
    assert(config::apply_lists(store, [config::ListOverride { "text", [half, half], "maximum-bytes" }]).len == 0);
    assert(config::apply_lists(store, [config::ListOverride { "text", [half, half, "x"], "too-big" }]).len > 0);
    let large, le = config::get_text_list(store, "text"); assert(le.len == 0 && large.len == 2);
    for text in large { assert(text == half); }
    var long_label: u8[>..] = [];
    for i in config::MAX_SOURCE_BYTES + 1 { long_label.push('s'); }
    assert(config::apply_lists(store, [config::ListOverride { "text", [], long_label }]).len > 0);
    assert(config::apply_lists(store, [config::ListOverride { long_label, [], "bad" }]).len > 0);
    var too_many: config::ListOverride[>..] = [];
    let empty_values: const u8[:][0] = [];
    for i in config::MAX_FIELDS + 1 { too_many.push(config::ListOverride { "text", empty_values, "bad" }); }
    assert(config::apply_lists(store, too_many).len > 0);
    var token: u8[>..] = [];
    for i in config::MAX_NUMBER_BYTES + 1 { token.push('1'); }
    assert(config::apply_lists(store, [config::ListOverride { "numbers", [token], "bad" }]).len > 0);
    let source, se = config::source(store, "text"); assert(se.len == 0 && source == "maximum-bytes");
    let bad_schema = [config::Field { key: "text", kind: config::Kind.TextList, int_min: 2, int_max: 1 }];
    assert(config::init(bad_schema, store).len > 0);
    let preserved, pe = config::get_text_list(store, "text"); assert(pe.len == 0 && preserved.len == 2);
    assert(config::init(schema, store).len == 0);
    let absent, ae = config::get_text_list(store, "text"); assert(ae.len > 0);
    assert(config::validate(store).len > 0);
    assert(config::apply_lists(store, [config::ListOverride { "text", [], "new-empty" }]).len == 0);
    let new_source, nse = config::source(store, "text"); assert(nse.len == 0 && new_source == "new-empty");
}
fn aliases_and_arbitrary_bytes() {
    var store = config::Store { .. };
    let schema = [config::Field { "key", config::Kind.Text }, config::Field { "text", config::Kind.TextList }];
    assert(config::init(schema, store).len == 0);
    var payload: u8[>..] = []; payload.push(0); payload.push(0xff); payload.push('z');
    assert(config::apply_lists(store, [config::ListOverride { "text", [payload], "owned" }]).len == 0);
    payload.clear(); payload.push('q');
    let result, re = config::get_text_list(store, "text"); assert(re.len == 0 && result.len == 1);
    let expected: u8[3] = [0, 0xff, 'z'];
    for text in result { assert(text == expected); }
    assert(config::apply(store, [config::Override { "key", "text", "source" }]).len == 0);
    let key, ke = config::get_text(store, "key"); assert(ke.len == 0);
    let source, se = config::source(store, "text"); assert(se.len == 0);
    let item = config::view(store.bytes, store.items[store.values[1].list.start].text);
    assert(config::apply_lists(store, [config::ListOverride { key, [item, item], source }]).len == 0);
    let aliased, ae = config::get_text_list(store, "text"); assert(ae.len == 0 && aliased.len == 2);
    for text in aliased { assert(text == expected); }
}
fn main() {
    transactions(); limits_and_ranges(); aliases_and_arbitrary_bytes();
    print("typed lists: OK");
}
