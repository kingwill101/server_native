# Zig test coverage

Run from `zig/` with Zig 0.16:

```sh
zig build test -j4 --summary all
zig build test -Doptimize=ReleaseSafe -j4 --summary all
zig build -j4
```

The test step runs three executables: the runtime unit suite, the build-adapter
suite, and a consumer linked only against the installed static archive plus the
C/C++ runtimes. Tests use fixed wire fixtures, real local sockets, deterministic
operation sequences, and injected allocation failures. Socket tests bind
loopback port zero or use Unix socket pairs; they do not require Dart or external
HTTP clients. Tests that load certificates run with `zig/` as their working
directory, as configured by `zig build test`.

## File-by-file coverage

| File | Checks |
| --- | --- |
| `src/abi.zig` | Imported configuration layout plus independent frozen field offsets, size and alignment for the compiled pointer width. |
| `src/lib.zig` | Null FFI arguments, invalid queue capacities/descriptors, binary API-DL message shape and signed IDs, transferred polling ownership, unchanged outputs on an empty poll. API-DL callbacks are replaced only during the test and restored afterward. |
| `src/event_queue.zig` | FIFO, ownership, capacity/byte limits, wraparound, concurrent producers, notifier registration/replacement, OOM cleanup, deterministic model comparison. |
| `src/bridge_protocol.zig` | Fixed Dart/Rust-compatible frame bytes, all tags, truncation/forged lengths, descriptor allocation failures, header normalization, exact output sizing and guard bytes around undersized buffers. |
| `src/bridge_io.zig` | Owned token/literal headers and binary response bodies, all truncated prefixes, trailing bytes, version/token/count limits, progressive chunks/EOF, consecutive wire frames and mid-frame peer EOF. |
| `src/http1.zig` | Platform dispatch facade; its POSIX exports are exercised through the socket and protocol tests below. The Windows implementation remains unsupported. |
| `src/http1_posix.zig` | Ephemeral TCP bind/connect/accept, timeout versus EOF, half-close, idempotent descriptor close, non-consuming HTTP/2 preface detection, nonblocking socket pressure/recovery, invalid descriptors/Unix paths, TLS ALPN and certificate errors. |
| `src/proxy_http1.zig` | Transfer coding/content length, chunk extensions/binary bodies, malformed chunk cleanup, keep-alive/upgrade tokens, emitted response bytes, raw invalid requests rejected before Dart dispatch, body/header bounds, response allocation/socket failures. |
| `src/http2.zig` | Fragmentation, concurrent stream/window limits, protocol errors, response ownership/budgets, cancellation, OOM, deferred streaming resumption and sibling progress, no callbacks after producer cancellation. |
| `src/proxy_http2.zig` | Request-event assembly, pseudo-header replacement, owned fields/body, header/EOF/cancellation transitions, unknown streams, allocation failures, partial response reads and final EOF. |
| `src/http3.zig` | Control/QPACK stream IDs and closures, transport parameters, TLS lifecycle/ALPN/certificates, fragmented headers, allocation budgets, duplicate SETTINGS, terminal failure state, output retained until QUIC accepts it. |
| `src/proxy_http3.zig` | Short/long packet routing, CID matching, IPv4/IPv6 address identity including scope, retained closing/draining state, PTO/overflow boundaries, amplification/rate limits, tombstone expiry, native mutex concurrency. |
| `src/proxy_request.zig` | Shared HTTP/2–3 framing, query/default fields, progressive queue pressure and credits, cancellation framing, Alt-Svc override/ownership/OOM. |
| `src/proxy.zig` | Configuration rejection, lifecycle, response ownership/byte/slot limits, 4096-request admission and recovery, per-request isolation, tunnel retention, clamped upload credits. |
| `src/memory_budget.zig` | Hierarchical limits, allocation/resize/remap rollback, shrinking/reuse, C allocation alignment/overflow/zeroing/realloc ownership. |
| `src/stream_body.zig` | Stable ACK-retained chunks, partial/combined ACKs, cancellation, empty chunks, unoffered-data rejection, OOM ownership at every allocation. |
| `src/protocol_test.zig` | Linked library version strings/numbers and unsupported ABI version rejection. |
| `src/static_link_test.zig` | Standalone archive resolves runtime, protocol, TLS and API-DL symbols; queue behavior works without a Dart VM. |
| `protocol_sources.zig` | Source lists are nonempty, unique relative C paths without traversal; actual source existence/compilation is checked by building the libraries. |
| `protocol_dependencies.zig` | Static-library macro names, source-manifest tests, and dependency wiring through runtime/static-link tests. |
| `build.zig` | Executes all three suites and builds both artifacts; build-adapter tests target the build host. |

## Scope

Test counts describe cases, not line or branch coverage. The POSIX runtime tests
are verified on Linux x64. The ABI offset expectations also describe 32-bit
layout, but only the layout for the target being compiled is exercised.

Native tests complement the Dart `HttpServer` compatibility suites, independent
curl/aioquic/h2spec interoperability gates, and the isolated HTTP/3 RSS/descriptor
soak. They do not replace those gates or establish support for untested platforms.
See [DEPENDENCIES.md](DEPENDENCIES.md) for those commands and resource limits.
