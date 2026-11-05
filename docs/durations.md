# Duration settings

The core import provides `Kind.Duration`, `Kind.DurationList`, and the value
`Duration { nanoseconds: i64 = 0 }`. Values are parsed and range-checked when a
layer is applied, then stored as integer nanoseconds. Getters do not reparse.
No time-library or native dependency is added. `Duration` is a CONFIG value type;
interoperation with another library requires an explicit nanosecond conversion.

```goose
let schema = [config::Field {
    key: "timeout", kind: config::Kind.Duration,
    required: true, int_min: 0, int_max: 30000000000
}];
var store = config::Store { .. };
assert(config::init(schema, store).len == 0);
assert(config::apply(store, [config::Override { "timeout", "250ms", "defaults" }]).len == 0);
let timeout, error = config::get_duration(store, "timeout");
assert(error.len == 0 && timeout.nanoseconds == 250000000);
```

The complete runnable [example](../examples/durations.goose) also uses JSON.
As elsewhere, `assert` keeps examples short; applications handle returned errors.

## Grammar and exact arithmetic

An optional leading `+` or `-` applies to the entire duration. A duration is one
or more decimal-number/unit components with no separators, such as `250ms`,
`1m30s`, `-1.5h`, `.5s` or `1.s`. At least one digit is required in each
component. Units are case-sensitive: `ns`, `us`, `µs` (U+00B5), `μs` (U+03BC),
`ms`, `s`, `m`, `h`, `d`. A day is exactly 24 hours, not a calendar/DST operation.
Repeated units and any ordering are accepted (`1s2s`, `1ms1s`). The standalone
spelling `0`, including `+0`/`-0`, is accepted; other unitless numbers are not.
Whitespace, internal signs, exponent notation, unknown units, malformed Unicode,
ISO-8601 notation and implicit numeric units are rejected.

Each component's fractional nanoseconds truncate toward zero **before summing**:
`0.9ns0.9ns` is zero; `1.0000000009s` is 1,000,000,000 nanoseconds. The parser
uses exact integer arithmetic, including arbitrarily long fractions within the
byte cap, without floating-point rounding. This may differ from parsers that
use floating intermediates at precision boundaries.

The final magnitude must fit signed i64 nanoseconds, including
`9223372036854775807ns` and `-9223372036854775808ns`. Digit accumulation, scaling
and component summation reject overflow before arithmetic. Each input token is
at most `MAX_DURATION_BYTES=128` UTF8 bytes, including signs, dots and units.
The parser is linear in this bounded length and does not allocate token storage.
Errors are owned, omit raw values, and use the existing bounded/escaped labels.
Discard the returned value when the error is nonempty.

## APIs and layers

```text
parse_duration(text: const u8[:]) -> Duration, error
get_duration(store: Store&, key: const u8[:]) -> Duration, error
get_duration_list(store: Store&, key: const u8[:]) -> Duration[>..], error
```

`parse_duration` applies grammar and i64 limits without a schema. In a Store,
`Field.int_min`/`int_max` additionally constrain nanoseconds inclusively, for both
a scalar and every list item, after fractional truncation. An Integer getter
cannot read a Duration, and vice versa. A Duration list getter returns an
independent owner that survives store replacement. Zero and empty lists are
present values and satisfy `required`.

All textual overrides, registered supplied/native environment values and CLI
bindings use the same parser. Negative CLI values may use `--delay=-1s` or a
separate `--delay -1s`; ordinary binding rules still apply. Duration lists use
`ListOverride`, environment separators and repeated CLI flags just like other
numeric lists. Empty environment text clears a list, whereas empty scalar text
is invalid. Each list has at most256 items, each capped at128 bytes: at most
32,768 decoded duration-token bytes. The4,096 aggregate retained-Text limit does
not apply to numeric duration payloads. Environment/CLI value caps and the JSON/
TOML document, work, depth and node limits still apply before/while parsing.

JSON and TOML require **strings**, including for zero:

```json
{"timeout":"250ms","retries":["1s","2s"]}
```

```toml
timeout = "250ms"
retries = ["1s", "2s"]
```

Numeric, boolean, null and nested-array values are not coerced into durations.
Decoded tokens are discarded after parsing; source labels and canonical numbers
follow the existing Store ownership contract. Every adapter stages an entire
layer before publication. A malformed/overflowing/out-of-range late value leaves
all previous values and sources intact. Replacement reload validates all layers
and required fields before publishing the new snapshot.

The previous selected common-application scope remains supported. Duration is an
additive extension; it does not establish complete Viper/Koanf feature parity.
The [sustained-fuzz release gate](release.md) remains incomplete and no v0.1.0
release is implied by this feature.
