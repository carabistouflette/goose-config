#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise isolated consumers with a pinned Goose compiler and GCC -O2.

Usage: python3 tests/integration.py /absolute/path/to/goose
Fixtures and executables live under the ignored .build directory. Checks remain
active with Python -O, and every compiler/runtime process has a deadline.
"""
import argparse
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

SETUP = '''
    var store = config::Store { .. };
    let fields = [config::Field { key: "port", kind: config::Kind.Integer, int_min: 1, int_max: 65535 },
                  config::Field { key: "name", kind: config::Kind.Text, required: true }];
    assert(config::init(fields, store).len == 0);
    let defaults = [config::Override { "port", "8080", "defaults" },
                    config::Override { "name", "original", "defaults" }];
    assert(config::apply(store, defaults).len == 0);
    assert(config::validate(store).len == 0);
'''

CORE_BODY = SETUP + '''
    let invalid = [config::Override { "name", "changed", "bad" },
                   config::Override { "port", "0", "bad" }];
    assert(config::apply(store, invalid).len > 0);
    let port, pe = config::get_integer(store, "port");
    let name, ne = config::get_text(store, "name");
    let port_source, pse = config::source(store, "port");
    let name_source, nse = config::source(store, "name");
    assert(pe.len == 0 && port == 8080);
    assert(ne.len == 0 && name == "original");
    assert(pse.len == 0 && port_source == "defaults");
    assert(nse.len == 0 && name_source == "defaults");
'''

TOML_BODY = SETUP + '''
    assert(config::apply_toml(store, "port=9000\\nname='toml'", "settings.toml").len == 0);
    assert(config::apply_toml(store, "port=9001\\nname='changed'\\nunknown=1", "bad.toml").len > 0);
    let port, pe = config::get_integer(store, "port");
    let name, ne = config::get_text(store, "name");
    let port_source, pse = config::source(store, "port");
    let name_source, nse = config::source(store, "name");
    assert(pe.len == 0 && port == 9000);
    assert(ne.len == 0 && name == "toml");
    assert(pse.len == 0 && port_source == "settings.toml");
    assert(nse.len == 0 && name_source == "settings.toml");
    let overrides = [config::Override { "port", "9002", "cli" }];
    assert(config::apply(store, overrides).len == 0);
    let updated, ue = config::get_integer(store, "port");
    let source, se = config::source(store, "port");
    assert(ue.len == 0 && updated == 9002);
    assert(se.len == 0 && source == "cli");
    assert(config::validate(store).len == 0);
'''


def write(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")


def execute(command, cwd, label, timeout):
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                                timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"{label}: exceeded {timeout}s\n{shlex.join(command)}") from error
    except OSError as error:
        raise RuntimeError(f"{label}: cannot execute {shlex.join(command)}: {error}") from error
    if result.returncode != 0:
        raise RuntimeError(f"{label}: exited {result.returncode}\n{shlex.join(command)}\n"
                           f"{result.stdout}{result.stderr}")
    return result.stdout


def check_consumer(compiler, app, name, imports, body):
    marker = f"integration {name}: OK"
    source = app / f"{name}.goose"
    write(source, imports + '\nimport std;\nfn main() {\n' + body
          + f'\n    print("{marker}");\n}}\n')
    executable = app / f"{name}-native"
    run_output = execute([str(compiler), "run", str(source)], app, f"{name} run", 60)
    if run_output.strip() != marker:
        raise RuntimeError(f"{name} run: unexpected output {run_output!r}")
    execute([str(compiler), "build", str(source), "--cc", "gcc", "-O2", "-o", str(executable)],
            app, f"{name} GCC -O2 build", 90)
    native_output = execute([str(executable)], app, f"{name} native", 15)
    if native_output.strip() != marker:
        raise RuntimeError(f"{name} native: unexpected output {native_output!r}")
    print(f"{name}: in-process and GCC -O2 passed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=Path, help="path to the pinned Goose compiler")
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    (ROOT / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="integration consumers ", dir=ROOT / ".build") as tmp:
        base = Path(tmp)
        app = base / "application with spaces"
        package = base / "config package with spaces"
        core = base / "core package with spaces"
        app.mkdir()
        package.mkdir()
        core.mkdir()
        for name in ("config.goose", "toml.goose", "vendor.goose"):
            shutil.copyfile(ROOT / name, package / name)
        # No adapter/parser files exist here: core really works on its own.
        shutil.copyfile(ROOT / "config.goose", core / "config.goose")

        local_imports = ""
        local_checks = ""
        package_imports = ""
        package_checks = ""
        for index, name in enumerate(("vendor", "toml", "config"), start=101):
            write(app / f"{name}.goose",
                  f"namespace application_{name};\nfn sentinel() -> i64 {{ {index} }}\n")
            local_imports += f"import .{name};\n"
            local_checks += f"    assert(application_{name}::sentinel() == {index});\n"
        for index, name in enumerate(("vendor", "toml"), start=201):
            write(base / f"{name} package" / f"{name}.goose",
                  f"namespace package_{name};\nfn sentinel() -> i64 {{ {index} }}\n")
            package_imports += f'import {name} from "../{name} package";\n'
            package_checks += f"    assert(package_{name}::sentinel() == {index});\n"

        config_import = 'import config from "../config package with spaces";\n'
        adapter_imports = config_import + "import config.toml;\n"
        write(base / "dependency package" / "dependency.goose",
              "import config;\nimport config.toml;\nimport std;\nnamespace dependency;\n"
              + "fn verify() {\n" + TOML_BODY + "\n}\n"
              + "fn sentinel() -> i64 { 301 }\n")
        dependency_import = 'import dependency from "../dependency package";\n'
        dependency_body = "    assert(dependency::sentinel() == 301);\n    dependency::verify();\n"
        cases = [
            ("core-only", 'import config from "../core package with spaces";\n', CORE_BODY),
            ("adapter", adapter_imports, TOML_BODY),
            ("local-modules-first", local_imports + adapter_imports, local_checks + TOML_BODY),
            ("local-modules-last", adapter_imports + local_imports, local_checks + TOML_BODY),
            ("other-packages-first", package_imports + adapter_imports, package_checks + TOML_BODY),
            ("other-packages-last", adapter_imports + package_imports, package_checks + TOML_BODY),
            ("dependency-first", dependency_import + config_import, dependency_body),
            ("dependency-last", config_import + dependency_import, dependency_body),
        ]
        for name, imports, body in cases:
            check_consumer(compiler, app, name, imports, body)
        print(f"integration: {len(cases)} isolated consumers passed in both modes")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        raise SystemExit(f"integration: {error}") from error
