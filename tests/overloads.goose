// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.toml;
import std;

// Consumer overloads must never erase validation errors or alter numeric bounds.
// These signatures previously intercepted the generic str builtin in diagnostics.
fn str(a: const u8[:]) -> u8[>..] { [] }
fn str(a: const u8[:], b: const u8[:], c: const u8[:], d: const u8[:],
       e: const u8[:], f: const u8[:], g: const u8[:]) -> u8[>..] { [] }
fn str(a: const u8[:], b: const u8[:], c: const u8[:], d: i64,
       e: const u8[:], f: i64, g: const u8[:], h: i64, i: const u8[:]) -> u8[>..] { [] }

// The library must specify the standard integer parser's base explicitly.
fn parse_int(text: const u8[:]) -> i64, bool { return 123, true; }
// These global names must not replace the library's namespaced validators.
fn finite(value: f64) -> bool { true }
fn decimal(text: const u8[:], floating: bool) -> bool { true }
fn valid_key(text: const u8[:]) -> bool { true }
fn min(a: i64, b: i64) -> i64 { a }
fn max(a: i64, b: i64) -> i64 { 16 }
fn copy(value: u8[>..]&) -> u8[>..] { [] }
fn copy(value: i64[>..]&) -> i64[>..] { [] }

fn main() {
    var store = config::Store { .. };
    let schema = [config::Field { "i", config::Kind.Integer },
                  config::Field { "f", config::Kind.Float }];
    assert(config::init(schema, store).len == 0);
    let initial = [config::Override { "i", "42", "initial" },
                   config::Override { "f", "1.5", "initial" }];
    assert(config::apply(store, initial).len == 0);
    let integer, ie = config::get_integer(store, "i");
    assert(ie.len == 0 && integer == 42);
    let invalid_integer = ["oops", "9223372036854775808", "1.0", "1e2"];
    for value in invalid_integer {
        let inputs = [config::Override { "i", value, "untrusted" }];
        assert(config::apply(store, inputs).len > 0);
    }
    let invalid_float = ["nan", "inf", "1e99999", "1.", ".5"];
    for value in invalid_float {
        let inputs = [config::Override { "f", value, "untrusted" }];
        assert(config::apply(store, inputs).len > 0);
    }
    let invalid_schema = [config::Field { "bad..key", config::Kind.Integer }];
    assert(config::init(invalid_schema, store).len > 0);
    let unchanged, ue = config::get_integer(store, "i");
    assert(ue.len == 0 && unchanged == 42);

    // Suppressing vendor diagnostics formerly allowed malformed scalar tokens
    // through, or erased preflight errors before a document root was created.
    assert(config::apply_toml(store, "i = 01", "bad.toml").len > 0);
    assert(config::apply_toml(store, "i = 9223372036854775808", "bad.toml").len > 0);
    var invalid_utf8: u8[>..] = [];
    invalid_utf8.push(0xff);
    assert(config::apply_toml(store, invalid_utf8, "bad.toml").len > 0);
    let preserved, pe = config::get_integer(store, "i");
    assert(pe.len == 0 && preserved == 42);
    // Index growth and parser error propagation must not call consumer copy/max.
    let keys = ["k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8", "k9",
                "k10", "k11", "k12", "k13", "k14", "k15", "k16", "k17", "k18", "k19"];
    var wide_schema: config::Field[>..] = [];
    var document:    u8[>..]            = [];
    for key in keys {
        wide_schema.push(config::Field { key, config::Kind.Integer });
        document.append(key); document.append("=1\n");
    }
    assert(config::init(wide_schema, store).len == 0);
    assert(config::apply_toml(store, document, "wide.toml").len == 0);
    document.append("k0=2\n");
    assert(config::apply_toml(store, document, "duplicate.toml").len > 0);
    let first, first_error = config::get_integer(store, "k0");
    assert(first_error.len == 0 && first == 1);
    print("consumer overload regression tests passed");
}
