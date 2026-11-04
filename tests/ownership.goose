// SPDX-License-Identifier: Apache-2.0
// Inputs may borrow old storage solely until the next transaction copies them.
import config from "..";
import config.toml;
import std;

// The language operation must stay independent of consumer UFCS overloads.
fn move_from(destination: u8[:], source: const u8[:]) { assert(false); }

fn text_is(store: config::Store&, key: const u8[:], expected: const u8[:], origin: const u8[:]) {
    let text, te = config::get_text(store, key);
    let source, se = config::source(store, key);
    assert(te.len == 0 && se.len == 0 && text == expected && source == origin);
}
fn scalar_alias_boundaries() {
    var store = config::Store { .. };
    assert(config::init([config::Field { "name", config::Kind.Text }, config::Field { "other", config::Kind.Text }], store).len == 0);
    assert(config::apply(store, [config::Override { "name", "name", "origin" }, config::Override { "other", "retained", "neighbor" }]).len == 0);
    let size = store.bytes.len;
    // The old text supplies both the key and new source. Swapping source/text
    // moves their boundary while retaining the same combined byte length.
    let key, ke = config::get_text(store, "name");
    let origin, oe = config::source(store, "name");
    assert(ke.len == 0 && oe.len == 0);
    assert(config::apply(store, [config::Override { key, origin, key }]).len == 0);
    text_is(store, "name", "origin", "name");
    text_is(store, "other", "retained", "neighbor");
    assert(store.bytes.len == size);
    let text, te = config::get_text(store, "name");
    let source, se = config::source(store, "name");
    assert(te.len == 0 && se.len == 0);
    assert(config::apply(store, [config::Override { "name", source, text }]).len == 0);
    text_is(store, "name", "name", "origin");
    assert(store.bytes.len == size);
}
fn scalar_binary_overlap() {
    var store = config::Store { .. };
    assert(config::init([config::Field { "x", config::Kind.Text }], store).len == 0);
    let seed: u8[6] = [0, 255, 'a', 'b', 'c', 'd'];
    assert(config::apply(store, [config::Override { "x", seed, "" }]).len == 0);
    let text, error = config::get_text(store, "x"); assert(error.len == 0);
    // Both replacement slices overlap the old payload, and each other.
    assert(config::apply(store, [config::Override { "x", text[1..5], text[..2] }]).len == 0);
    let expected: u8[4] = [255, 'a', 'b', 'c'];
    let origin:   u8[2] = [0, 255];
    text_is(store, "x", expected, origin);
    assert(store.bytes.len == seed.len);
    let replacement: u8[5] = [0, 255, 'a', 'b', 'c'];
    assert(config::apply(store, [config::Override { "x", replacement, "s" }]).len == 0);
    text_is(store, "x", replacement, "s");
    assert(store.bytes.len == seed.len);
}
fn scalar_empty_boundaries() {
    var store = config::Store { .. };
    assert(config::init([config::Field { "x", config::Kind.Text }], store).len == 0);
    let missing, error = config::get_text(store, "x"); assert(error.len > 0);
    for round in 2 {
        assert(config::apply(store, [config::Override { "x", "", "" }]).len == 0);
        text_is(store, "x", "", "");
        assert(store.bytes.len == 0);
    }
    assert(config::apply(store, [config::Override { "x", "", "abcd" }]).len == 0);
    let origin, oe = config::source(store, "x"); assert(oe.len == 0);
    assert(config::apply(store, [config::Override { "x", origin, "" }]).len == 0);
    text_is(store, "x", "abcd", "");
    let text, te = config::get_text(store, "x"); assert(te.len == 0);
    assert(config::apply(store, [config::Override { "x", "", text }]).len == 0);
    text_is(store, "x", "", "abcd");
    assert(store.bytes.len == 4);
}
fn scalar_numeric_replacements() {
    var store = config::Store { .. };
    let schema = [config::Field { "integer", config::Kind.Integer }, config::Field { "float", config::Kind.Float }, config::Field { "boolean", config::Kind.Boolean }];
    assert(config::init(schema, store).len == 0);
    // Numeric payloads occupy metadata only, including absent-to-present writes.
    assert(config::apply(store, [config::Override { "integer", "9223372036854775807", "" }]).len == 0);
    assert(config::apply(store, [config::Override { "float", "1.25", "" }]).len == 0);
    assert(config::apply(store, [config::Override { "boolean", "true", "" }]).len == 0);
    assert(store.bytes.len == 0);
    let first_integer, fie = config::get_integer(store, "integer");
    let first_float, ffe = config::get_float(store, "float");
    let first_boolean, fbe = config::get_boolean(store, "boolean");
    assert(fie.len == 0 && first_integer == 9223372036854775807);
    assert(ffe.len == 0 && first_float == 1.25 && fbe.len == 0 && first_boolean);
    assert(config::apply(store, [config::Override { "integer", "9007199254740993", "first" }, config::Override { "float", "2.5", "first" }, config::Override { "boolean", "false", "first" }]).len == 0);
    let size = store.bytes.len;
    assert(config::apply(store, [config::Override { "integer", "-9223372036854775808", "later" }]).len == 0);
    assert(config::apply(store, [config::Override { "float", "-1.25e2", "later" }]).len == 0);
    assert(config::apply(store, [config::Override { "boolean", "true", "later" }]).len == 0);
    let integer, ie = config::get_integer(store, "integer");
    let number, ne = config::get_float(store, "float");
    let boolean, be = config::get_boolean(store, "boolean");
    assert(ie.len == 0 && integer == -9223372036854775808);
    assert(ne.len == 0 && number == -125.0 && be.len == 0 && boolean);
    for key in ["integer", "float", "boolean"] {
        let source, se = config::source(store, key); assert(se.len == 0 && source == "later");
    }
    assert(store.bytes.len == size);
}
fn retained_lists(store: config::Store&) {
    let texts, te = config::get_text_list(store, "head");
    let empty, ee = config::get_text_list(store, "empty");
    let integers, ie = config::get_integer_list(store, "integers");
    let numbers, ne = config::get_float_list(store, "numbers");
    let booleans, be = config::get_boolean_list(store, "booleans");
    assert(te.len == 0 && texts.len == 2);
    for text, i in texts { assert(text == (if i == 0 { "" } else { "alpha" })); }
    assert(ee.len == 0 && empty.len == 0);
    assert(ie.len == 0 && integers == [9007199254740993, -9223372036854775808]);
    assert(ne.len == 0 && numbers == [1.5, -2.5] && be.len == 0 && booleans == [true, false]);
    for key in ["head", "empty", "integers", "numbers", "booleans"] {
        let source, se = config::source(store, key); assert(se.len == 0 && source == "lists");
    }
    text_is(store, "tail", "retained", "tail-source");
}
fn scalar_updates_among_lists() {
    var store = config::Store { .. };
    let schema = [config::Field { "head", config::Kind.TextList }, config::Field { "target", config::Kind.Text },
                  config::Field { "empty", config::Kind.TextList }, config::Field { "integers", config::Kind.IntegerList },
                  config::Field { "numbers", config::Kind.FloatList }, config::Field { "booleans", config::Kind.BooleanList },
                  config::Field { "tail", config::Kind.Text }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply_lists(store, [config::ListOverride { "head", ["", "alpha"], "lists" }, config::ListOverride { "empty", [], "lists" },
                                       config::ListOverride { "integers", ["9007199254740993", "-9223372036854775808"], "lists" },
                                       config::ListOverride { "numbers", ["1.5", "-2.5"], "lists" }, config::ListOverride { "booleans", ["true", "false"], "lists" }]).len == 0);
    assert(config::apply(store, [config::Override { "target", "x", "p" }, config::Override { "tail", "retained", "tail-source" }]).len == 0);
    let owned, oe = config::get_text_list(store, "head");
    let owned_integers, oie = config::get_integer_list(store, "integers");
    assert(oe.len == 0 && oie.len == 0);
    let size = store.bytes.len;
    for round in 96 {
        let text = if round % 2 == 0 { "y" } else { "x" };
        let source = if round % 2 == 0 { "q" } else { "p" };
        assert(config::apply(store, [config::Override { "target", text, source }]).len == 0);
        text_is(store, "target", text, source);
        assert(store.bytes.len == size);
    }
    assert(config::apply(store, [config::Override { "target", "", "xy" }]).len == 0);
    text_is(store, "target", "", "xy");
    assert(store.bytes.len == size);
    retained_lists(store);
    // Length changes and multiple replacements use the general transaction path.
    assert(config::apply(store, [config::Override { "target", "longer", "grow" }]).len == 0);
    text_is(store, "target", "longer", "grow");
    assert(store.bytes.len == size + 8);
    assert(config::apply(store, [config::Override { "target", "", "" }]).len == 0);
    text_is(store, "target", "", "");
    assert(store.bytes.len == size - 2);
    assert(config::apply(store, [config::Override { "target", "z", "r" }, config::Override { "tail", "retained", "tail-source" }]).len == 0);
    text_is(store, "target", "z", "r");
    retained_lists(store);
    let error = config::apply(store, [config::Override { "target", "bad", "late" }, config::Override { "unknown", "bad", "late" }]);
    assert(error.len > 0 && store.bytes.len == size);
    text_is(store, "target", "z", "r");
    retained_lists(store);
    assert(config::apply_lists(store, [config::ListOverride { "head", ["replacement"], "new" }]).len == 0);
    assert(config::apply(store, [config::Override { "target", "w", "s" }]).len == 0);
    let replacement, re = config::get_text_list(store, "head"); assert(re.len == 0 && replacement.len == 1);
    for text in replacement { assert(text == "replacement"); }
    let source, se = config::source(store, "head"); assert(se.len == 0 && source == "new");
    assert(config::init([], store).len == 0);
    assert(owned.len == 2 && owned_integers == [9007199254740993, -9223372036854775808]);
    for text, i in owned { assert(text == (if i == 0 { "" } else { "alpha" })); }
    for text in replacement { assert(text == "replacement"); }
}
fn scalar_maximum_span() {
    var store = config::Store { .. };
    let schema = [config::Field { "target", config::Kind.Text }, config::Field { "neighbor", config::Kind.Text }, config::Field { "items", config::Kind.TextList }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply_lists(store, [config::ListOverride { "items", ["first", "", "last"], "list-source" }]).len == 0);
    var initial:      u8[>..] = []; var replacement: u8[>..] = [];
    var first_source: u8[>..] = []; var next_source: u8[>..] = [];
    for i in config::MAX_VALUE_BYTES { initial.push('a'); replacement.push((i % 256) as u8); }
    for i in config::MAX_SOURCE_BYTES { first_source.push('s'); next_source.push('t'); }
    assert(config::apply(store, [config::Override { "target", initial, first_source }, config::Override { "neighbor", "retained", "neighbor-source" }]).len == 0);
    let owned, oe = config::get_text_list(store, "items"); assert(oe.len == 0);
    let size = store.bytes.len;
    assert(config::apply(store, [config::Override { "target", replacement, next_source }]).len == 0);
    text_is(store, "target", replacement, next_source);
    assert(store.bytes.len == size);
    // Both incoming views borrow the full-size old payload and overlap.
    var expected_source: u8[>..] = []; expected_source.append(replacement[..config::MAX_SOURCE_BYTES]);
    let borrowed, be = config::get_text(store, "target"); assert(be.len == 0);
    assert(config::apply(store, [config::Override { "target", borrowed, borrowed[..config::MAX_SOURCE_BYTES] }]).len == 0);
    text_is(store, "target", replacement, expected_source);
    assert(store.bytes.len == size);
    // Keep the combined size equal while exceeding each individual byte bound.
    var long_source: u8[>..] = []; long_source.append(expected_source); long_source.push('x');
    assert(config::apply(store, [config::Override { "target", replacement[..config::MAX_VALUE_BYTES - 1], long_source }]).len > 0);
    text_is(store, "target", replacement, expected_source);
    assert(store.bytes.len == size);
    var long_text: u8[>..] = []; long_text.append(replacement); long_text.push('x');
    assert(config::apply(store, [config::Override { "target", long_text, expected_source[..config::MAX_SOURCE_BYTES - 1] }]).len > 0);
    text_is(store, "target", replacement, expected_source);
    assert(store.bytes.len == size);
    text_is(store, "neighbor", "retained", "neighbor-source");
    let items, ie = config::get_text_list(store, "items"); assert(ie.len == 0 && items.len == 3);
    for text, i in items { assert(text == (if i == 0 { "first" } else { if i == 1 { "" } else { "last" } })); }
    let source, se = config::source(store, "items"); assert(se.len == 0 && source == "list-source");
    assert(config::init([], store).len == 0);
    assert(owned.len == 3);
    for text, i in owned { assert(text == (if i == 0 { "first" } else { if i == 1 { "" } else { "last" } })); }
}

fn main() {
    var store = config::Store { .. };
    let schema = [config::Field { "a", config::Kind.Text }, config::Field { "b", config::Kind.Text }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply(store, [config::Override { "a", "b", "a" }, config::Override { "b", "a = 'changed'", "origin" }]).len == 0);
    let key, ke = config::get_text(store, "a"); assert(ke.len == 0);
    let text, te = config::get_text(store, "b"); assert(te.len == 0);
    let source, se = config::source(store, "a"); assert(se.len == 0);
    assert(config::apply(store, [config::Override { key, text, source }]).len == 0);
    let document, de = config::get_text(store, "b"); assert(de.len == 0);
    let origin, oe = config::source(store, "b"); assert(oe.len == 0);
    assert(config::apply_toml(store, document, origin).len == 0);
    let changed, ce = config::get_text(store, "a"); assert(ce.len == 0 && changed == "changed");
    let retained, re = config::get_text(store, "b"); assert(re.len == 0 && retained == "a = 'changed'");
    let oldsource, ose = config::source(store, "a"); assert(ose.len == 0 && oldsource == "a");
    // Reinitialization from a schema whose key comes from the current store.
    let newkey, ne = config::get_text(store, "a"); assert(ne.len == 0);
    let newschema = [config::Field { newkey, config::Kind.Text }];
    assert(config::init(newschema, store).len == 0);
    assert(config::apply(store, [config::Override { "changed", "ok", "new" }]).len == 0);
    let check, err = config::get_text(store, "changed"); assert(err.len == 0 && check == "ok");
    scalar_alias_boundaries(); scalar_binary_overlap(); scalar_empty_boundaries();
    scalar_numeric_replacements(); scalar_updates_among_lists(); scalar_maximum_span();
    print("aliasing: OK");
}
