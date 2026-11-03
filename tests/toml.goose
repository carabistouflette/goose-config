// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.toml;
import std;
fn main() {
    var store = config::Store { .. };
    let schema = [config::Field { key: "server.port", kind: config::Kind.Integer, int_min: 1, int_max: 65535 },
                  config::Field { "name", config::Kind.Text }, config::Field { "debug", config::Kind.Boolean },
                  config::Field { "ratio", config::Kind.Float }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply_toml(store, "name = 'goose'\ndebug = true\nratio = 1.5\n[server]\nport = 8080\n", "app.toml").len == 0);
    let port, pe = config::get_integer(store, "server.port"); assert(pe.len == 0 && port == 8080);
    let name, ne = config::get_text(store, "name"); assert(ne.len == 0 && name == "goose");
    let ratio, re = config::get_float(store, "ratio"); assert(re.len == 0 && ratio == 1.5);
    let debug, de = config::get_boolean(store, "debug"); assert(de.len == 0 && debug);
    let source, se = config::source(store, "server.port"); assert(se.len == 0 && source == "app.toml");
    let invalid = ["server.port = '123'", "server.port = 1.0", "ratio = 1", "name = 42", "name = []", "name = 1979-05-27", "ratio = inf", "ratio = nan", "[unknown]", "'server.port' = 42", "[server]\nport = 0", "name = 'first'\nname = 'duplicate'", "name = 'x'\nunknown = 1", "name = 'x'\n[server]\nport = 'bad'", "name = \"\\uD800\"", "[server"];
    for text in invalid {
        assert(config::apply_toml(store, text, "bad.toml").len > 0);
        let previous, error = config::get_text(store, "name"); assert(error.len == 0 && previous == "goose");
        let origin, oe = config::source(store, "name"); assert(oe.len == 0 && origin == "app.toml");
    }
    assert(config::apply_toml(store, "", "empty").len == 0);
    assert(config::apply_toml(store, "[server]", "empty table").len == 0);
    assert(config::apply_toml(store, "server = { port = 9000 }", "inline").len == 0);
    assert(config::apply_toml(store, "server.port = 9001\nname = ''", "dotted").len == 0);
    let empty, ee = config::get_text(store, "name"); assert(ee.len == 0 && empty.len == 0);
    boundaries();
    print("toml: OK");
}

fn boundaries() {
    var store = config::Store { .. };
    let schema = [config::Field { "text", config::Kind.Text }, config::Field { "n", config::Kind.Float }, config::Field { "i", config::Kind.Integer }];
    assert(config::init(schema, store).len == 0);
    assert(config::apply_toml(store, "n = 1.7976931348623157e308\ni = -9223372036854775808", "extrema").len == 0);
    let maximum, me = config::get_float(store, "n"); assert(me.len == 0 && maximum == 1.7976931348623157e308);
    let minimum, ie = config::get_integer(store, "i"); assert(ie.len == 0 && minimum == -9223372036854775808);
    assert(config::apply_toml(store, "n = -5e-324\ni = 9223372036854775807", "extrema").len == 0);
    let tiny, te = config::get_float(store, "n"); assert(te.len == 0 && tiny == -5e-324);
    var value = str("text = '");
    for i in config::MAX_VALUE_BYTES { value.push('x'); }
    value.push('\'');
    var origin = str("owned.toml");
    assert(config::apply_toml(store, value, origin).len == 0);
    origin.clear(); value.clear();
    let owned, oe = config::get_text(store, "text"); assert(oe.len == 0 && owned.len == config::MAX_VALUE_BYTES);
    let source, se = config::source(store, "text"); assert(se.len == 0 && source == "owned.toml");
    var big = str("text = '");
    for i in config::MAX_VALUE_BYTES + 1 { big.push('x'); }
    big.push('\'');
    assert(config::apply_toml(store, big, "oversized").len > 0);
    var limit: u8[>..] = [];
    for i in 1048576 { limit.push(' '); }
    assert(config::apply_toml(store, limit, "at parser cap").len == 0);
    limit.push(' ');
    assert(config::apply_toml(store, limit, "over parser cap").len > 0);
    let preserved, pre = config::get_text(store, "text"); assert(pre.len == 0 && preserved.len == config::MAX_VALUE_BYTES);
    var deep = str("i = ");
    for i in 65 { deep.push('['); }
    deep.push('0');
    for i in 65 { deep.push(']'); }
    assert(config::apply_toml(store, deep, "depth").len > 0);
    var numeric = str("n = 1.");
    for i in 126 { numeric.push('0'); }
    assert(config::apply_toml(store, numeric, "128 bytes").len == 0);
    numeric.push('0');
    assert(config::apply_toml(store, numeric, "129 bytes").len > 0);
    var label: u8[>..] = [];
    for i in config::MAX_SOURCE_BYTES { label.push('s'); }
    assert(config::apply_toml(store, "text='ok'", label).len == 0);
    label.push('s');
    assert(config::apply_toml(store, "text='wrong'", label).len > 0);
    var long_key: u8[>..] = [];
    for i in config::MAX_KEY_BYTES { long_key.push('k'); }
    let long_schema = [config::Field { long_key, config::Kind.Text }];
    assert(config::init(long_schema, store).len == 0);
    var document = str(long_key, "='ok'");
    assert(config::apply_toml(store, document, "max key").len == 0);
    document.clear(); document.append(long_key); document.append("k='wrong'");
    assert(config::apply_toml(store, document, "over key").len > 0);
}
