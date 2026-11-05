// SPDX-License-Identifier: Apache-2.0
import config from "..";
import config.bindings;
import worker_settings;
import std;
import os;
const SAMPLES = 7;
inline fn manual_env() -> config::Binding[6] {
    [config::Binding { "worker.name", "GOOSE_WORKER_NAME" }, config::Binding { "worker.prefix", "GOOSE_WORKER_PREFIX" },
     config::Binding { "worker.queues", "GOOSE_WORKER_QUEUES", "," }, config::Binding { "worker.min_bytes", "GOOSE_WORKER_MIN_BYTES" },
     config::Binding { "worker.max_bytes", "GOOSE_WORKER_MAX_BYTES" }, config::Binding { "worker.enabled", "GOOSE_WORKER_ENABLED" }]
}
inline fn manual_cli() -> config::Binding[6] {
    [config::Binding { "worker.name", "name" }, config::Binding { "worker.prefix", "prefix" }, config::Binding { "worker.queues", "queue" },
     config::Binding { "worker.min_bytes", "min-bytes" }, config::Binding { "worker.max_bytes", "max-bytes" }, config::Binding { "worker.enabled", "enabled" }]
}
fn compare(a: config::Binding[:], b: config::Binding[:]) {
    assert(a.len == b.len);
    for item, i in a { assert(item.key == b[i].key && item.name == b[i].name && item.separator == b[i].separator); }
}
fn scenario<Env, Cli>(name: const u8[:], count: i64, mode: i64) {
    let fields = worker_settings::schema(); var store = config::Store { .. };
    let values = [config::EnvValue { "GOOSE_WORKER_NAME", "demo" }, config::EnvValue { "GOOSE_WORKER_PREFIX", "E:" },
                  config::EnvValue { "GOOSE_WORKER_QUEUES", "default,priority" }, config::EnvValue { "GOOSE_WORKER_MIN_BYTES", "2" },
                  config::EnvValue { "GOOSE_WORKER_MAX_BYTES", "9" }, config::EnvValue { "GOOSE_WORKER_ENABLED", "false" }];
    let arguments = ["--name=demo", "--prefix=C:", "--queue=default", "--queue=priority", "--min-bytes=2", "--max-bytes=9", "--enabled=false"];
    var samples: f64[SAMPLES] = [0.0; SAMPLES]; var checksum: i64 = 0;
    for sample in SAMPLES {
        let start = clock_ns();
        for i in count {
            let environment = Env(); let cli = Cli();
            if mode == 0 {
                let at = (i * 5) % 6;
                checksum += environment[at].key.len + environment[at].name.len + environment[at].separator.len + cli[at].name.len;
            } else {
                assert(config::init(fields, store).len == 0);
                if mode == 1 { assert(config::apply_env_values(store, environment, values).len == 0); }
                else { assert(config::apply_cli(store, cli, arguments).len == 0); }
                let maximum, error = config::get_integer(store, "worker.max_bytes"); assert(error.len == 0); checksum += maximum;
            }
        }
        samples[sample] = (clock_ns() - start) / (count as f64);
    }
    if mode > 0 {
        var settings = worker_settings::Settings { .. }; assert(worker_settings::load(store, settings).len == 0);
        assert(settings.name == "demo" && settings.prefix == (if mode == 1 { "E:" } else { "C:" }) && settings.minimum == 2 && settings.maximum == 9 && !settings.enabled);
        assert(settings.queues.len == 2); for item, i in settings.queues { assert(item == (if i == 0 { "default" } else { "priority" })); }
        assert(settings.prefix_source == (if mode == 1 { "GOOSE_WORKER_PREFIX" } else { "--prefix" }));
        assert(settings.maximum_source == (if mode == 1 { "GOOSE_WORKER_MAX_BYTES" } else { "--max-bytes" }));
    }
    print(name, " samples_ns=", samples, " checksum=", checksum);
}
fn main() {
    let arguments = args(); assert(arguments.len == 3); let count, ok = parse_int(arguments[1], 10); assert(ok && count > 0 && count <= 100000);
    let generated = arguments[2] == "generated"; assert(generated || arguments[2] == "reference");
    let environment = worker_settings::env_bindings(); let cli = worker_settings::cli_bindings(); let old_env = manual_env(); let old_cli = manual_cli();
    compare(environment, old_env); compare(cli, old_cli);
    let names = ["construct", "environment", "cli"];
    for name, mode in names {
        if generated { scenario(name, count, mode, worker_settings::env_bindings, worker_settings::cli_bindings); }
        else { scenario(name, count, mode, manual_env, manual_cli); }
    }
}
