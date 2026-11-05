# Feature comparison

goose-config provides a small, explicit set of configuration features. It is
not feature-equivalent to Viper or Koanf. This table was checked on 2026-11-05
against [Viper 1.21.0](https://github.com/spf13/viper/releases/tag/v1.21.0)
and [Koanf 2.4.1](https://github.com/knadh/koanf/releases/tag/v2.4.1). Their
APIs and provider ecosystems can change.

| Capability | goose-config | [Viper](https://github.com/spf13/viper) | [Koanf](https://github.com/knadh/koanf) |
| --- | --- | --- | --- |
| Defaults and layers | Caller-defined order; failed layers preserve the old store | Built-in source priorities | Caller-defined load order |
| JSON and TOML | Strict scalar and homogeneous-list values | Supported | Optional parser packages |
| YAML | Not included | Supported | Optional parser |
| INI | Not included | Supported | No bundled parser listed |
| Environment and CLI | Explicit names mapped to schema keys | Environment and flag bindings | Optional providers |
| Nested keys | Declared dotted scalar/list paths | Supported | Configurable delimiters |
| Maps and object lists | Not supported | Supported | Supported |
| Durations | Strict scalar/list parser with typed nanoseconds | Duration getter | Provider/parser-dependent |
| Key aliases | Direct, bounded aliases to declared keys | Native API | No native alias API documented |
| File reads and watching | Application-owned | Native support | Provider-dependent |
| Remote sources | Not included | Integrations available | Optional providers |
| Typed application structs | Optional generated Goose `Settings` | Decode/unmarshal | Decode/unmarshal |
| Writeback | Not included | Supported | Marshal support |

Absence from this table means goose-config does not include that capability; it
does not rule out third-party extensions. For exact limits and behavior, see the
[API contract](api.md), [common application features](common-features.md),
[aliases](aliases.md), [durations](durations.md), and
[typed settings](typed-settings.md).

The [archived comparison measurements](comparison-performance-history.md) use
older Goose source revisions and do not rank current main. The
[performance status page](performance-status.md) identifies the results whose
source hashes still match the current implementation.
