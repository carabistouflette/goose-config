# Security policy

## Reporting

Report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/carabistouflette/goose-config/security/advisories/new).
Please avoid opening a public issue with exploit details before a fix is available.
Include a minimal reproducer, the goose-config commit, `GOOSE_REVISION`, execution
mode, C compiler and platform, and the expected and observed behavior. Remove
credentials and personal configuration data from reports.

## Scope and maintenance

The API is experimental and has no tagged release. Security fixes are maintained
on the latest default-branch commit; use a full commit pin and review updates.
No response-time or long-term support guarantee is made.

Untrusted configuration is supported within the documented input, work and
storage limits. Applications own file I/O, reload triggers, source-label contents,
application-specific validation and concurrent use. Resource limits are not an
exact allocator budget or a wall-clock deadline. Allocation failure follows
Goose's runtime behavior. Direct mutation of Store internals is unsupported.

Optional bindings read explicitly registered process environment names or
supplied argument/value snapshots. The native environment getter copies a value
before its size can be checked; the documented logical payload limit is not a
preallocation limit on that runtime I/O. Supplied snapshots can be bounded by
the application before use. Reload validates an independent store before
publication; it provides no concurrent/lock-free access or file watching.

The optional [worker application](docs/worker.md) uses bounded goose-fs reads
and a trusted operator stdin pipe. Its line reader allocates before the command
size check, file reads have no deadline, and separate files are not captured
atomically. Application rules validate a private candidate before policy
publication. These application boundaries do not extend the core's guarantees.

ASan/UBSan checks complement the language's ownership and bounds checks. Goose
uses mmap-backed data stacks; sanitizer instrumentation does not establish
object-boundary or lifetime coverage for every allocation on those stacks.
Passing sanitizer suites is not proof of memory safety or exhaustive testing.

The compiler revision and vendored TOML source are pinned. Reports that depend
on compiler behavior should identify the tested revision and native/debug mode.
The vendored parser's origin, license and local modifications are recorded in
[vendor/README.md](vendor/README.md) and [third-party notices](THIRD_PARTY_NOTICES.md).
