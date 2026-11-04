# Configuration library comparison

Reviewed 2026-11-04. goose-config is not feature-equivalent to Viper or Koanf.
The comparisons below distinguish shipped APIs from work delegated to callers.
Performance on a shared subset cannot establish full feature parity.

Primary references: [Viper documentation](https://github.com/spf13/viper),
[Viper API](https://pkg.go.dev/github.com/spf13/viper),
[Koanf documentation](https://github.com/knadh/koanf),
[Koanf API](https://pkg.go.dev/github.com/knadh/koanf/v2).
The executable comparison pins Viper 1.21.0 and Koanf 2.4.1; see
[the adapter module](../bench/competitors/go.mod) for all dependency versions.

| Capability | goose-config | Viper | Koanf |
| --- | --- | --- | --- |
| Defaults and layers | Explicit, ordered atomic scalar batches | Fixed source priorities | Caller load order |
| TOML | Strict scalar adapter | Supported | Optional parser |
| JSON / YAML | Missing | Supported | Optional parsers |
| INI | Missing | Supported | No bundled parser documented |
| Environment / flags | Caller constructs overrides | Native bindings | Providers |
| Nested paths | Declared dotted scalar leaves | Supported | Configurable paths |
| Lists and map values | Missing | Supported | Supported |
| Duration interpretation | Missing | Getter | Getter |
| Key aliases | Missing | Native API | No native API documented |
| File discovery / reading | Caller-owned | Native | Provider |
| Watch / source reload | Missing | File watching | Provider callbacks |
| Remote configuration | Missing | Remote integration | Optional providers |
| Struct decoding | Missing | Unmarshal | Unmarshal |
| Serialization / writeback | Missing | Write APIs | Marshal; caller writes |
| Extension interfaces | Callers can produce overrides | Codec registry/hooks | Provider/parser interfaces |

Absence of a documented/bundled API is not a claim that no third-party
implementation exists. Default/env/CLI examples in goose-config do not count
as shipped source bindings. Storing a duration as Text does not implement a
duration parser. Reading dotted leaves does not implement map/list values.

## Implementation priorities and contract decisions

The common-application expansion is: optional environment/CLI binding adapters,
JSON parsing, list values with explicit ownership and merge rules, duration
helpers, and source-replacement orchestration. File watching and remote
providers depend on that orchestration. Additional formats, aliases, struct
mapping and export/writeback follow the chosen parity target.

This is a gap list, not an implemented-feature claim. Full Viper parity also
requires deciding whether to adopt its case-insensitive keys, coercions, fixed
source precedence and live bindings. Those choices differ from the current
strict API. Koanf's arbitrary key delimiters also exceed our key grammar.

Reload must rebuild and validate a fresh effective store from current sources.
Calling `apply_toml` on an edited file alone retains values removed from that
file. Such a call must not be advertised as complete reload support.

## Reproducible shared-workload measurements

```sh
python3 bench/compare.py --goose /absolute/path/to/pinned/goose \
  --iterations 10000 --rounds 3 --cpu 4 \
  --output bench/results/competitors.json
```

This requires Go (with module downloads), GCC and Linux `taskset`. It builds
Goose from the requested exact Git revision, and copies the pinned Go adapter
sources into a private build snapshot. The four matching fixtures run in the
same order: small first-key lookup, wide mixed lookup, wide last-key lookup,
and two-setting TOML parse/merge/get. All use matching payloads, iteration
counts and checksums; each process reports seven samples. Library process
order rotates each round. Setup and final checks are outside the timers.
Viper lookups use explicit `Set` overrides, its first priority tier.

Raw records include source hashes, versions, flags, CPU affinity and every
sample. Frequency, thermals and unrelated host load are uncontrolled. No
dedicated warmup occurs. Go garbage collection and the C/Go runtimes differ.
These are cross-language end-to-end microbenchmarks, not parser-only numbers,
allocation measurements, production throughput or universal rankings.

Goose validates schemas and strict types, commits rejected layers atomically,
and tracks setting sources. The competitor adapter paths do not supply that
same contract. Their larger feature sets also do work absent from our core.
Only present matching-type values are used, so differing missing/error/coercion
semantics are not timed. Values are views/strings, not copied byte throughput.
