# Direct key aliases

`Alias { key, target }` maps an additional setting name to a declared canonical
schema field. Both strings use the ordinary bounded dotted-key grammar. Register
aliases with the additional final argument to `init(schema, store, aliases)` or
`reload(schema, layers, store, aliases)`. Existing calls remain valid.

There are at most `MAX_ALIASES=256` aliases, with keys and targets at most 256
bytes. Targets must exist in the new canonical schema. Alias chains, self-aliases,
unknown targets, duplicate names and any leaf-prefix collision with another
alias or canonical field are rejected. Multiple aliases may target one field.
Shared table prefixes are allowed, for example `old.timeout` and `old.tags`.

Initialization validates and copies the full schema and aliases before changing
the previous Store. Target IDs refer to that staged schema, never the previous
field order. Keys are independently owned and sorted; alias resolution uses a
bounded binary search after canonical lookup misses. Canonical hits retain the
existing lookup algorithm. This does not promise zero runtime/memory cost.

Getters, source lookup, textual overrides, lists, JSON/TOML nested paths, explicit
environment/CLI bindings and replacement reload all resolve the same identity.
Types, ranges, required fields and values belong to the canonical field. Source
labels retain their ordinary layer/binding origin. Aliases do not create extra
values or change source precedence. An alias plus its canonical name, or two
aliases to the same field, in one layer is a duplicate error even for identical
values. Binding descriptors must also target distinct resolved fields, including
when their external names are absent. Repeated list flags on one binding retain
their normal accumulation behavior.

Staged binding and reload publication copy alias metadata with the Store. A late
failure preserves all previous values, sources and aliases. List getter results
remain independently owned. As with canonical schemas, a successful `init`
clears old values. Replacement reload constructs a fresh schema: **callers must
resupply aliases on every reload**. Omitting the final argument means no aliases;
a successful canonical-only reload removes previous aliases. A rejected reload
preserves them. Aliases are not dynamic registration or a deprecation-warning API.

No compiler, native dependency or vendored parser change is required. The
[sustained-fuzz release gate](release.md) remains open; no release tag is implied.
See [validation](alias-validation.md) and [measured costs and controls](alias-performance.md).

```goose
let schema = [config::Field { "server.timeout", config::Kind.Duration }];
let aliases = [config::Alias { "server.old_timeout", "server.timeout" }];
var store = config::Store { .. };
assert(config::init(schema, store, aliases).len == 0);
assert(config::apply(store, [config::Override { "server.old_timeout", "1s", "cli" }]).len == 0);
let timeout, error = config::get_duration(store, "server.timeout");
assert(error.len == 0 && timeout.nanoseconds == 1000000000);
```
