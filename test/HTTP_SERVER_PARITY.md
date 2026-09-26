# HttpServer compatibility status

Zig is the sole native backend. Run the same scenarios against dart:io and Zig
in direct and bridge modes:

```sh
dart test test/sdk_http_server_edge_cases_test.dart test/sdk_http_server_fixtures_test.dart
```

## Coverage

The edge suite has 22 scenarios per mode (66 tests): URI/authority semantics,
repeated headers, transfer coding, delayed GET bodies, response persistence,
shutdown, and WebSocket heartbeat/close behavior. Raw wire fixtures avoid
HttpClient rewriting input. Fixture provenance and expected rejection semantics
are documented in `fixtures/http_server/README.md`.

The fixture suite adds repeated headers and encoded URLs, chunk extensions,
invalid framing, fragment rejection, streaming upload with a paused reader,
application-written raw responses, slow-reader lossless delivery and drain
deadlines, and detached raw/WebSocket lifetime across
graceful and forced HTTP listener closure.

## Zig-only cutover validation

- 188 Dart tests passed: fixtures, edge cases, SDK compatibility, HTTP/direct
  serving, bridge runtime, native transport contract, and default backend ABI.
- 24 protocol/lifecycle tests passed; 18 h2spec/aioquic cases skipped because
  external clients were not configured. HTTP/3 curl cases passed.
- `zig build test` passed.
- `dart analyze`: 26 existing informational lints, no errors or warnings.
- Binding generation from the Zig header, workflow YAML parsing, and
  `git diff --check` passed. No Cargo build or Rust dependency remains.

## Slow-reader fix validation

Direct tunnel forwarding now splits coalesced socket reads into 16 KiB frames,
awaits native queue capacity, and treats rejected output as a closed tunnel.
Previously, reads above the native frame-size limit could be silently discarded,
allowing the local writer to appear drained while the remote peer had stalled.

- 36 fixture tests pass across dart:io, Zig direct, and Zig bridge, including
  byte-for-byte 32 MiB delivery and a 64 MiB flood with a drain deadline.
- 133 existing SDK/edge/HTTP/direct regression tests pass.
- All 8 Relic RC `hijack_shutdown_test.dart` cases pass, including the previously
  failing slow-reader drain deadline. The full framework suite was not rerun.
- Analysis still reports only the existing 26 informational lints.

## HTTP/1 framing and TLS review fixes

`http1_framing_regression_test.dart` checks pipelined requests, empty chunked
bodies, chunk data resembling a terminator, stalled TLS-client isolation,
shutdown with a pending handshake, and handshake expiry. The shared cases run
against dart:io, Zig direct, and Zig bridge. Native scanner tests exercise every
split point, pipelined trailing bytes, malformed delimiters and size overflow.

TLS handshakes run in connection workers with a five-second monotonic deadline.
HTTP/1 retains unread bytes across requests and parses chunk sizes to locate
body completion.

Validation: 190 Dart regression tests passed, including all 13 new cases;
`zig build test` and `zig build test -Doptimize=ReleaseSafe` passed. Analysis
reports the existing 26 informational lints, with no errors or warnings.

## Evidence before the Zig-only cutover

Dart 3.13.4, Linux x64:

- Edge suite: SDK, Zig direct and Zig bridge each passed all 22 scenarios.
- Zig SDK/HTTP/direct/bridge regression run: 151 passed.
- Zig native tests: 159 passed in Debug and ReleaseSafe.
- Relic 2.0.0-rc.1 full run: relic_core 1039 passed/3 skipped; relic_io 193
  passed; relic 2650 passed/3 failed/4 skipped.
- New fixture run before the additional manual-response case: 27 passed.
- Pre-fix targeted Relic shutdown run: 7 passed/1 failed. The original three
  detached-socket ownership failures passed after separating listener shutdown
  from detached tunnel lifetime. The slow-reader failure
  from that run is fixed by the bounded-frame change validated above.

These are scoped prior results, not a claim that every test passes after the
cutover. Rust is removed and is no longer a validation target.

## Framework scope and remaining limits

Only Relic 2 RC and later are supported by the framework harness. It pins
`v2.0.0-rc.1` at `7054fe9817d88b8e4295c70295b88e6a90e4cd59`. The adapter changes
plaintext bindings; secure framework tests still use dart:io, while package
TLS tests exercise Zig directly. Framework CI remains allowed to fail.

Relic's isolated 5 ms heartbeat test can also fail on the SDK from a cold start;
both full relic_io runs passed it. The edge suite uses 200 ms and does not prove
parity at 5 ms. Timeouts bound hangs, rather than serving as latency benchmarks.

Linux ARM64 native execution, other platform ports, and published-prebuilt
consumer validation remain separate release gates. Removing Rust does not prove
universal dart:io parity or release readiness.
