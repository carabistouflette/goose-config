# Live-reloading job worker

[The worker](../examples/worker.goose) is a runnable application that processes
jobs using goose-config. It reads actual TOML/JSON files, environment variables
and CLI options, then turns validated settings into an owned application policy.
Each job uses that policy without configuration parsing or getters. This is a
serial stdin worker, with no network listener or background file watcher.

Its schema is [declarative JSON](../schemas/worker.json), compiled into
[owned typed settings](../examples/worker_settings.goose) by the optional
[generator](typed-settings.md). Env and CLI mappings come from that same schema
through its [generated binding helpers](generated-bindings.md). The worker passes its readonly business validator
to the generated loader, which stages and publishes the complete policy.
`make generated-check` verifies the committed source; `make generated` updates it.

## Build and run

The optional example adds a pinned Apache-2.0
[goose-fs dependency](https://github.com/carabistouflette/goose-fs/tree/1c0deb1779181ecb5ef3b5af1de78f93b65e086b)
for bounded regular-file reads. Its native code requires 64-bit Linux, Linux
development headers and a C compiler. The first build needs GitHub access to
fetch the full pinned commit. The core library and ordinary examples do not
depend on goose-fs. Use the compiler pinned in `GOOSE_REVISION`.

```sh
make setup
mkdir -p .build
.toolchain/goose/build/goose build examples/worker.goose --cc gcc -O2 -o .build/worker
printf 'status\njob priority hello\nquit\n' | \
  .build/worker "$PWD/examples/worker.toml" "$PWD/examples/worker.json" --prefix=CLI:
```

With the `GOOSE_WORKER_*` variables unset, output is:

```text
ready generation=1
status generation=1 worker=demo min=1 max=32 enabled=true prefix-source=--prefix max-source=worker.toml
done generation=1 worker=demo queue=priority CLI:hello
bye
```

For an interactive session, run the last command without the `printf` pipe.
Enter `job priority hello`, change a file, then enter `reload` and submit another
job. Use `-` in either file position to explicitly disable that layer. A selected
file that is missing or unreadable is an error, both at startup and reload.
Paths are absolute, with no symlinks, repeated/trailing separators, NUL, `.` or
`..` components, following goose-fs's documented path rules.

## Settings and input precedence

The application applies defaults, TOML, JSON, registered process environment,
then CLI arguments, in that order. Every layer must pass schema/type/range
checks even when a later layer overrides it. Application rules validate the
final merged policy. Lists replace the prior list; repeated CLI queue flags
accumulate one new list. All settings are in the `worker` table/object.

| Setting | Default | Application contract | Environment | CLI |
| --- | --- | --- | --- | --- |
| `name` | Required | 1–32 ASCII letters/digits/`_`/`-` | `GOOSE_WORKER_NAME` | `--name` |
| `prefix` | `done:` | 0–64 printable ASCII bytes | `GOOSE_WORKER_PREFIX` | `--prefix` |
| `queues` | `["default"]` | 1–16 distinct names using the same grammar as `name` | `GOOSE_WORKER_QUEUES` | Repeated `--queue` |
| `min_bytes` | `1` | Integer 1–4096, no greater than `max_bytes` | `GOOSE_WORKER_MIN_BYTES` | `--min-bytes` |
| `max_bytes` | `256` | Integer 1–4096 | `GOOSE_WORKER_MAX_BYTES` | `--max-bytes` |
| `enabled` | `true` | Boolean | `GOOSE_WORKER_ENABLED` | `--enabled` |

Environment queues are comma-separated without trimming or escaping. CLI
queues use `--queue first --queue second`; `--enabled=false` disables work.
The same invocation arguments are replayed on every reload. Environment reads
observe this process's environment; editing a parent shell later cannot change
an already running worker's environment. See [binding contracts](common-features.md).

## Work and reload behavior

The operator protocol accepts one command per line:

- `job QUEUE PAYLOAD`: process a permitted queue's printable ASCII payload,
  whose byte length must lie within the inclusive configured bounds. Success
  prints its generation, worker, queue and prefixed payload. Disabled workers
  and invalid jobs return a rejection without processing work.
- `status`: print the active generation, name, byte limits, enabled state and
  prefix/max-byte source labels. Labels identify the application layer, rather
  than the actual file path. Names, prefixes, queues and job payloads are public
  application output fields.
- `reload`: reread the selected files and replay all current layers. Success
  publishes a new policy and increments the generation, including when values
  are unchanged. Failure prints `reload rejected` and preserves the old policy
  and generation. Processing can continue immediately.
- `quit`: acknowledge and exit. EOF also exits cleanly.

Startup failures exit nonzero before printing readiness or processing jobs.
Diagnostics omit raw configuration values, parser details and file paths.
The optional example intentionally uses a generic failure message; it does not
offer an administrative configuration dump.

The candidate Store exists only during a reload attempt. Schema checks run
first, followed by application rules such as `min_bytes <= max_bytes` and
nonempty/distinct valid queues. Only after all checks pass does the worker copy
Text, list contents and provenance into its owned policy. A schema-valid but
application-invalid file cannot replace any active fields. No borrowed config
view escapes and no internal Store fields or publication helpers are used.
Policy replacement and job processing run on the same thread; a concurrent
application would need its own synchronization and publication strategy.

## I/O boundaries and validation

Each selected file is read through goose-fs with a 65,536-byte limit, before
parsing. Directories, symlinks and larger files are rejected. File I/O has no
deadline. Operator-selected paths must refer to trusted local storage. Two files
are read separately; there is no filesystem snapshot or cross-file generation
guarantee. Replace each file atomically to avoid partially written documents;
use a single document when a coherent single-file update is required.

Stdin is a trusted local operator pipe. Goose's `read_line` allocates a complete
line before the application's 8,192-byte command check, so this is not a bounded
untrusted network input layer. The same consideration applies to process argv
and environment ingestion. Retained runtime pages follow the
[memory audit's limits](memory-and-fallback-audit.md).

`make worker` builds and exercises optimized GCC/Clang and GCC/Clang ASan/UBSan
variants. The acceptance suite uses paths with spaces and live file replacement;
it checks precedence, required settings, exact file/job size bounds, disabled
work, strict schemas, application-rule rejection, read failures and source/key
removal. Rejected reloads preserve job behavior and generation. Separate harness
regressions verify partial stdin writes and deadline/child cleanup without
fetching optional dependencies. Sanitizers retain the Goose runtime limitations
documented in [SECURITY.md](../SECURITY.md). Sustained coverage-guided testing
remains incomplete; see the [release status](release.md).
