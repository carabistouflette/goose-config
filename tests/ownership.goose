// SPDX-License-Identifier: Apache-2.0
// Inputs may borrow old storage solely until the next transaction copies them.
import config from "..";
import config.toml;
import std;
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
    print("aliasing: OK");
}
