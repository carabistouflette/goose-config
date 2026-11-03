#!/usr/bin/env python3
"""Check the pinned compiler preserves borrowed-view and constant contracts."""
from pathlib import Path
import subprocess
import sys
import tempfile

compiler = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent.parent
(root / ".build").mkdir(exist_ok=True)
setup = '''
    var store = config::Store { .. };
    let schema = [config::Field { "name", config::Kind.Text }];
    assert(config::init(schema, store).len == 0);
    let initial = [config::Override { "name", "Goose", "defaults" }];
    assert(config::apply(store, initial).len == 0);
'''
control = setup + '''
    let text, text_error = config::get_text(store, "name");
    let origin, source_error = config::source(store, "name");
    assert(text_error.len == 0 && source_error.len == 0);
    let borrowed = [config::Override { "name", text, origin }];
    assert(config::apply(store, borrowed).len == 0);
    let updated, updated_error = config::get_text(store, "name");
    let updated_origin, updated_source_error = config::source(store, "name");
    assert(updated_error.len == 0 && updated == "Goose");
    assert(updated_source_error.len == 0 && updated_origin == "defaults");
'''
cases = {}
for accessor in ("get_text", "source"):
    for mutation, expression in {
        "apply": 'config::apply(store, [config::Override { "name", "updated", "cli" }])',
        "init": "config::init(schema, store)",
        "toml": "config::apply_toml(store, \"name = 'updated'\", \"config.toml\")",
    }.items():
        cases[f"{accessor}-after-{mutation}"] = (
            "", setup + f'''
            let borrowed, error = config::{accessor}(store, "name");
            assert(error.len == 0);
            assert({expression}.len == 0);
            print(borrowed);
            ''',
            ("borrowed", "still used"),
        )
for accessor in ("get_text", "source"):
    cases[f"{accessor}-escapes-store"] = (
        f'''
        fn escape() -> const u8[:] {{
            {setup}
            let borrowed, error = config::{accessor}(store, "name");
            assert(error.len == 0);
            return borrowed;
        }}
        ''', "print(escape());", ("rooted in store.bytes", "dies with this function"),
    )
for limit in ("MAX_FIELDS", "MAX_KEY_BYTES", "MAX_VALUE_BYTES", "MAX_SOURCE_BYTES", "MAX_NUMBER_BYTES"):
    cases[f"constant-{limit}"] = (
        "fn change(value: i64&) { value = 1000000; }",
        f"change(config::{limit});",
        ("cannot write through this reference", "non-writable provenance"),
    )
cases["read-only-text"] = (
    "", setup + '''
    let borrowed, error = config::get_text(store, "name");
    assert(error.len == 0);
    borrowed[0] = 'X';
    ''', ("cannot assign through this path", "read-only"),
)

with tempfile.TemporaryDirectory(prefix="ownership-", dir=root / ".build") as tmp:
    for name, (helpers, body, expected) in {
        "valid-control": ("", control, ()), **cases
    }.items():
        source = Path(tmp) / f"{name}.goose"
        source.write_text('import config from "../..";\nimport config.toml;\nimport std;\n'
                          + helpers + "\nfn main() {\n" + body + "\n}\n")
        result = subprocess.run([str(compiler), "check", str(source)],
                                capture_output=True, text=True, timeout=30)
        diagnostics = result.stdout + result.stderr
        if name == "valid-control":
            if result.returncode != 0:
                raise SystemExit(f"positive control failed\n{diagnostics}")
            subprocess.run([str(compiler), "run", str(source)], check=True, timeout=30)
            print("positive control: accepted and executed")
            continue
        if result.returncode != 1 or "error:" not in diagnostics:
            raise SystemExit(f"{name}: expected compiler rejection, got "
                             f"{result.returncode}\n{diagnostics}")
        if not all(fragment in diagnostics for fragment in expected):
            raise SystemExit(f"{name}: rejected for an unexpected reason\n{diagnostics}")
        print(f"{name}: rejected")
