# goose-config

Pure, schema-driven configuration for the Goose language. Apache-2.0.
Experimental API; no release yet.

Explicit layers of defaults, TOML, environment values and CLI overrides; strict
Text/Integer/Float/Boolean types, numeric ranges, required settings, owned
values and provenance. Applications own all I/O. Later successful layers win;
a failed layer changes nothing. No environment name normalization or hidden
process access. The TOML adapter is optional.

See CONTRIBUTING.md for development standards and vendor/README.md for the
fixed, licensed TOML dependency. Full API documentation follows implementation.
