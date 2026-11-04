// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.toml;
import std;

fn texts_equal(values: const u8[][:], expected: const (const u8[:])[:]) -> bool {
    if values.len != expected.len { return false; }
    for text, i in values { if text != expected[i] { return false; } }
    true
}

fn main() {
    var store = config::Store { .. };
    let schema = [config::Field { key: "server.ports", kind: config::Kind.IntegerList, int_min: 1, int_max: 65535 },
                  config::Field { key: "names", kind: config::Kind.TextList, required: true },
                  config::Field { key: "ratios", kind: config::Kind.FloatList, float_min: -2.0, float_max: 2.0 },
                  config::Field { key: "flags", kind: config::Kind.BooleanList },
                  config::Field { key: "large", kind: config::Kind.IntegerList },
                  config::Field { key: "mode", kind: config::Kind.Text }];
    assert(config::init(schema, store).len == 0);
    let document = "names=['goose','duck']\nratios=[1.25,-0.0]\nflags=[true,false]\nlarge=[9007199254740993,-9223372036854775808]\nmode='before'\n[server]\nports=[8080,9000]";
    assert(config::apply_toml(store, document, "baseline.toml").len == 0);
    let names, ne = config::get_text_list(store, "names");
    let ports, pe = config::get_integer_list(store, "server.ports");
    let ratios, re = config::get_float_list(store, "ratios");
    let flags, fe = config::get_boolean_list(store, "flags");
    let large, le = config::get_integer_list(store, "large");
    assert(ne.len == 0 && texts_equal(names, ["goose", "duck"]));
    assert(pe.len == 0 && ports.len == 2 && ports[0] == 8080 && ports[1] == 9000);
    assert(re.len == 0 && ratios.len == 2 && ratios[0] == 1.25 && ratios[1] == 0.0);
    assert(fe.len == 0 && flags.len == 2 && flags[0] && !flags[1]);
    assert(le.len == 0 && large.len == 2 && large[0] == 9007199254740993 && large[1] == -9223372036854775808);
    let bad = ["names=['SECRET-NEW']\n[server]\nports=[7,'bad']",
               "mode='changed'\nratios=[nan]", "mode='changed'\nratios=[inf]",
               "mode='changed'\nratios=[3.0]", "mode='changed'\nratios=[1]",
               "mode='changed'\nflags=[true,1]", "mode='changed'\nnames=[[]]",
               "mode='changed'\nnames=[{x=1}]", "mode='changed'\nnames='scalar'",
               "mode='changed'\n[server]\nports=[0]", "mode='changed'\nmode2=[]"];
    for text in bad {
        let error = config::apply_toml(store, text, "rejected.toml");
        assert(error.len > 0 && find(error, "SECRET-NEW") < 0);
        let mode, me = config::get_text(store, "mode");
        let source, se = config::source(store, "names");
        let kept, ke = config::get_text_list(store, "names");
        assert(me.len == 0 && mode == "before" && se.len == 0 && source == "baseline.toml");
        assert(ke.len == 0 && texts_equal(kept, ["goose", "duck"]));
    }
    assert(config::apply_toml(store, "names=[]\n[server]\nports=[]", "empty.toml").len == 0);
    let empty, ee = config::get_text_list(store, "names");
    assert(ee.len == 0 && empty.len == 0 && config::validate(store).len == 0);
    assert(texts_equal(names, ["goose", "duck"]) && ports[0] == 8080); // owned getter results
    var at_limit: u8[>..] = []; at_limit.append("names=['");
    for i in config::MAX_VALUE_BYTES { at_limit.push('a'); }
    at_limit.append("']");
    assert(config::apply_toml(store, at_limit, "limit.toml").len == 0);
    at_limit.clear(); at_limit.append("names=['");
    for i in config::MAX_VALUE_BYTES { at_limit.push('a'); }
    at_limit.append("','b']");
    assert(config::apply_toml(store, at_limit, "over.toml").len > 0);
    let retained, rte = config::get_text_list(store, "names");
    assert(rte.len == 0 && retained.len == 1);
    for text in retained { assert(text.len == config::MAX_VALUE_BYTES); }
    var count_limit: u8[>..] = []; count_limit.append("flags=[");
    for i in config::MAX_LIST_ITEMS { if i > 0 { count_limit.push(','); } count_limit.append("true"); }
    count_limit.push(']');
    assert(config::apply_toml(store, count_limit, "count.toml").len == 0);
    count_limit.pop(); count_limit.append(",false]");
    assert(config::apply_toml(store, count_limit, "count-over.toml").len > 0);
    let retained_flags, rfe = config::get_boolean_list(store, "flags");
    assert(rfe.len == 0 && retained_flags.len == config::MAX_LIST_ITEMS);
    print("TOML homogeneous lists, bounds and mixed-layer rollback passed");
}
