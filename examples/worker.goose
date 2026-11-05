// SPDX-License-Identifier: Apache-2.0
// Optional Linux application: trusted operator stdin, bounded regular files.
import config from "..";
import config.reload;
import worker_settings;
import fs from "carabistouflette/goose-fs@1c0deb1779181ecb5ef3b5af1de78f93b65e086b";
import std;
import os;

const FILE_BYTES = 65536;
fn identifier(text: const u8[:]) -> bool {
    if text.len == 0 || text.len > 32 { return false; }
    for c in text {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || c == '_' || c == '-') { return false; }
    }
    true
}
fn printable(text: const u8[:]) -> bool {
    for c in text { if c < 32 || c > 126 { return false; } }
    true
}
fn snapshot(path: const u8[:], bytes: u8[>..]&) -> bool {
    // '-' explicitly disables a file. Missing selected files are errors.
    if path == "-" { return true; }
    fs::read(path, FILE_BYTES, bytes).error == fs::Error.None
}
fn refresh(toml_path: const u8[:], json_path: const u8[:], arguments: const (const u8[:])[:], active: worker_settings::Settings&) -> bool {
    var toml: u8[>..] = []; var json: u8[>..] = [];
    // Each read is bounded. The two files are not captured as one snapshot.
    if !snapshot(toml_path, toml) || !snapshot(json_path, json) { return false; }
    let schema = worker_settings::schema();
    let defaults = [config::Override { "worker.prefix", "done:", "defaults" },
                    config::Override { "worker.min_bytes", "1", "defaults" },
                    config::Override { "worker.max_bytes", "256", "defaults" },
                    config::Override { "worker.enabled", "true", "defaults" }];
    let queues = ["default"];
    let list_defaults = [config::ListOverride { "worker.queues", queues, "defaults" }];
    let environment = [config::Binding { key: "worker.name", name: "GOOSE_WORKER_NAME" },
                       config::Binding { key: "worker.prefix", name: "GOOSE_WORKER_PREFIX" },
                       config::Binding { key: "worker.queues", name: "GOOSE_WORKER_QUEUES", separator: "," },
                       config::Binding { key: "worker.min_bytes", name: "GOOSE_WORKER_MIN_BYTES" },
                       config::Binding { key: "worker.max_bytes", name: "GOOSE_WORKER_MAX_BYTES" },
                       config::Binding { key: "worker.enabled", name: "GOOSE_WORKER_ENABLED" }];
    let cli = [config::Binding { key: "worker.name", name: "name" },
               config::Binding { key: "worker.prefix", name: "prefix" },
               config::Binding { key: "worker.queues", name: "queue" },
               config::Binding { key: "worker.min_bytes", name: "min-bytes" },
               config::Binding { key: "worker.max_bytes", name: "max-bytes" },
               config::Binding { key: "worker.enabled", name: "enabled" }];
    var layers: config::Layer[>..] = [];
    layers.push(config::Layer { kind: config::LayerKind.Values, overrides: defaults, .. });
    layers.push(config::Layer { kind: config::LayerKind.Lists, lists: list_defaults, .. });
    if toml_path != "-" { layers.push(config::Layer { kind: config::LayerKind.Toml, text: toml, source: "worker.toml", .. }); }
    if json_path != "-" { layers.push(config::Layer { kind: config::LayerKind.Json, text: json, source: "worker.json", .. }); }
    layers.push(config::Layer { kind: config::LayerKind.ProcessEnvironment, bindings: environment, .. });
    layers.push(config::Layer { kind: config::LayerKind.CommandLine, bindings: cli, arguments: arguments, .. });
    // Candidate Store is private to this attempt. Application rules run before
    // changing the active policy, even when schema validation succeeds.
    var candidate = config::Store { .. };
    if config::reload(schema, layers, candidate, worker_settings::aliases()).len > 0 { return false; }
    worker_settings::load(candidate, active, validate_policy).len == 0
}
fn validate_policy(candidate: const worker_settings::Settings&) -> u8[>..] {
    var error: u8[>..] = [];
    if !identifier(candidate.name) || candidate.prefix.len > 64 || !printable(candidate.prefix) ||
       candidate.minimum > candidate.maximum || candidate.queues.len == 0 || candidate.queues.len > 16 {
        error.append("worker policy rejected"); return error;
    }
    for queue, i in candidate.queues {
        if !identifier(queue) { error.append("worker policy rejected"); return error; }
        for other, j in candidate.queues {
            if j < i && queue == other { error.append("worker policy rejected"); return error; }
        }
    }
    []
}

fn job(line: const u8[:], policy: worker_settings::Settings&, generation: i64) {
    var separator = 4;
    while separator < line.len && line[separator] != ' ' { separator++; }
    if separator == line.len { print("job rejected syntax"); return; }
    let queue = line[4..separator]; let payload = line[separator + 1..];
    if !identifier(queue) || !printable(payload) { print("job rejected syntax"); return; }
    if !policy.enabled { print("job rejected disabled"); return; }
    var accepted = false;
    for allowed in policy.queues { if queue == allowed { accepted = true; } }
    if !accepted { print("job rejected queue"); return; }
    if payload.len < policy.minimum || payload.len > policy.maximum { print("job rejected size"); return; }
    print("done generation=", generation, " worker=", policy.name, " queue=", queue, " ", policy.prefix, payload);
}
fn main() {
    let argv = args();
    if argv.len < 3 {
        write_stderr("usage: worker TOML_PATH_OR_- JSON_PATH_OR_- [--name NAME ...]\n"); exit(2);
    }
    var arguments: const u8[:][>..] = [];
    for i in 3..argv.len { arguments.push(argv[i]); }
    var policy = worker_settings::Settings { .. };
    if !refresh(argv[1], argv[2], arguments, policy) {
        write_stderr("worker: startup configuration rejected\n"); exit(1);
    }
    var generation: i64 = 1;
    print("ready generation=", generation); flush_stdout();
    // Local operator pipe, not an untrusted network protocol: read_line grows
    // its buffer before this application can check the command length.
    var line: u8[>..] = [];
    while read_line(line) {
        if line.len > 8192 { print("command rejected size"); }
        else if line == "quit" { print("bye"); flush_stdout(); return; }
        else if line == "reload" {
            if generation < 9223372036854775807 && refresh(argv[1], argv[2], arguments, policy) { generation++; print("reloaded generation=", generation); }
            else { print("reload rejected"); }
        } else if line == "status" {
            print("status generation=", generation, " worker=", policy.name, " min=", policy.minimum,
                  " max=", policy.maximum, " enabled=", policy.enabled, " prefix-source=", policy.prefix_source,
                  " max-source=", policy.maximum_source);
        } else if line.len >= 4 && line[..4] == "job " { job(line, policy, generation); }
        else { print("command rejected syntax"); }
        flush_stdout(); line.clear();
    }
}
