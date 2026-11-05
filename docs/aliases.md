# Direct key aliases

An alias maps an additional key to a field in the schema. Register aliases with
`init(schema, store, aliases)` or `reload(schema, layers, store, aliases)`:

```goose
let schema = [config::Field { "server.timeout", config::Kind.Duration }];
let aliases = [config::Alias { "server.old_timeout", "server.timeout" }];
var store = config::Store { .. };
assert(config::init(schema, store, aliases).len == 0);
assert(config::apply(store, [config::Override {
    "server.old_timeout", "1s", "cli" }]).len == 0);
let value, error = config::get_duration(store, "server.timeout");
assert(error.len == 0 && value.nanoseconds == 1000000000);
```

Aliases work with getters, source lookup, scalar and list updates, JSON/TOML,
environment/CLI bindings, and reload. Values, types, ranges, requiredness, and
source labels belong to the canonical field. An alias does not create a second
setting or change layer precedence.

There may be at most 256 aliases. Each key and target is limited to 256 bytes.
Targets must name fields in the new schema. Alias chains, self-aliases, unknown
targets, duplicate names, and leaf-prefix conflicts are rejected. Several
aliases may point to one field, but one layer cannot set the same field through
both its canonical key and an alias. Shared table prefixes such as
`old.timeout` and `old.tags` are allowed.

Initialization validates the schema and aliases before replacing the store. A
successful `init` clears old values. Reload builds a new store, so callers must
pass the aliases again on every reload. Omitting them removes existing aliases
on a successful reload. A rejected update or reload preserves the old values,
sources, and aliases.

Aliases are fixed at initialization; they are not dynamic registration or a
deprecation-warning system. Alias lookup and storage have a bounded cost; see
the [measured results](alias-performance.md) and
[validation details](alias-validation.md).
