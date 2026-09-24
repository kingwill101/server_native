# Zig backend plan for `server_native`

## Context

The package already contains a Rust transport and an initial Zig experiment. The existing public boot APIs (`serveNative*`, `NativeHttpServer`, and direct-handler modes) all converge on `_startNativeProxy`, which creates a `NativeProxyServer` and then routes either bridge-socket frames or direct request frames through Dart. This makes `NativeProxyServer` the correct compatibility seam for backend dispatch. The goal is to complete the existing `zig/` implementation as a Zig-backed server while keeping the Rust backend available at the same time. Rust remains the default until Zig is stable; Zig is then promoted deliberately. Both backends must satisfy the same `NativeProxyServer` contract so callers and higher-level server APIs do not need to restart their migration.

Initial scan found:
- Dart native wrapper: `lib/src/native/server_native_transport.dart`
- Native build hook: `hook/build.dart`
- Existing Rust backend: `native/`
- Existing Zig scaffold: `zig/build.zig`, `zig/src/lib.zig`, `zig/src/bridge_protocol.zig`, `zig/src/event_queue.zig`
- Existing generated bindings: `lib/src/ffi.g.dart`, `lib/src/zig_ffi.g.dart`; the hook already builds separate Rust (`server_native`) and Zig (`server_native_zig`) assets, so coexistence is already structurally supported
- Existing compatibility, lifecycle, bridge, HTTP, and Zig tests under `test/`; `test/zig_dart_api_test.dart` currently validates only the API-DL/queue scaffold.
- Existing test coverage already distinguishes bridge socket mode from native callback/direct mode, so Zig parity must cover both paths rather than only a health endpoint.
- Existing prebuilt/release workflows: `native_prebuilt.yaml`, `.github/workflows/`, `tool/generate_prebuilt_release.dart`

## Approach

1. Treat dart:io HttpServer as the compatibility baseline. Run the same cases against Rust and Zig; a failure shared by both native backends is still a compatibility bug.
2. Evolve the existing Zig scaffold into a complete backend behind a backend-neutral Dart transport interface.
3. Keep Rust and Zig assets/build paths side by side, with an explicit selector and Rust fallback; do not expose a second public server class. Resolve `SERVER_NATIVE_BACKEND=zig|rust` at runtime first, then `--define=server_native.backend=zig|rust`, then Rust as the default. Invalid explicit values fail clearly; an explicitly selected Zig backend must not silently fall back to Rust.
4. Port the protocol in three gated milestones—HTTP/1, HTTP/2, HTTP/3—after first proving shared lifecycle, ABI, and request/response framing.
5. Reuse the existing Dart bridge codecs, public server APIs, tests, benchmarks, and prebuilt conventions wherever possible.
6. Add differential tests so the same Dart-facing scenarios run against Rust and Zig.

## Files to modify

- `PLAN.md`
- `hook/build.dart`
- `lib/src/native/server_native_transport.dart` and a backend-neutral internal dispatch layer
- New internal selector/ABI adapter under `lib/src/native/` for runtime environment and compile-time define precedence
- `lib/src/ffi.g.dart`, `lib/src/zig_ffi.g.dart`, and their generator inputs
- `zig/src/abi.zig` (or equivalent) defining the C-compatible config/handle ABI shared with Rust
- `zig/build.zig`
- `zig/src/lib.zig`
- `zig/src/bridge_protocol.zig`
- `zig/src/event_queue.zig`
- New Zig runtime modules under `zig/src/`, for example `abi.zig`, `dart_port.zig`, `bridge_codec.zig`, `http1.zig`, `http2_nghttp2.zig`, `http3_ngtcp2.zig`, and `tls.zig`
- `zig/build.zig.zon` and vendored/fetchable native protocol dependency declarations as needed
- Backend-selection and parity tests under `test/`
- CI/prebuilt configuration under `.github/workflows/`, `native_prebuilt.yaml`, and related tooling

## Reuse

- Reuse the current Dart API and validation/lifecycle semantics in `lib/src/native/server_native_transport.dart`; preserve its config validation, opaque-handle lifecycle, direct frame methods, and retained callback safety behavior.
- Keep backend selection below the public `serveNative*`/`NativeHttpServer` APIs. The implementation should resolve Rust by default and opt into Zig at the `NativeProxyServer` transport seam, so higher-level callers keep the same API.
- Reuse the existing Rust-compatible frame definitions and codec behavior represented by `lib/src/bridge/bridge_runtime_frame_codec.dart`, request/response codecs, and `zig/src/bridge_protocol.zig`.
- Reuse the existing queue ownership/backpressure tests in `zig/src/event_queue.zig`.
- Reuse `ZigBuilder` already wired in `hook/build.dart`; it already emits a distinct `server_native_zig` asset alongside the Rust `server_native` asset. Extend its exported ABI and binding generation rather than adding a second unrelated build mechanism.
- Reuse existing compatibility suites: `test/sdk_http_server_compat_test.dart`, `test/bridge_runtime_test.dart`, `test/serve_ffi*_test.dart`, and `test/zig_dart_api_test.dart`.
- Reuse current prebuilt manifest and release automation patterns rather than changing distribution behavior prematurely.

## Steps

- [x] Select backend through runtime `SERVER_NATIVE_BACKEND` or compile-time `server_native.backend`, with Rust as the default and no new public server class/API.
- [x] Map the current Rust ABI, Dart wrapper, generated bindings, and Zig exports into a compatibility matrix: both backends expose the proxy operations; Zig uses server_native_zig_* symbols to keep the native assets distinct.
- [x] Keep the C layout identical across both generated binding sets; use a shared ABI adapter/casts in Dart so one `NativeProxyServer` implementation can invoke either asset without duplicating public lifecycle logic.
- [x] Define the Zig ABI and lifecycle ownership rules, including `Dart_InitializeApiDL`, opaque handles, start/stop idempotence, direct request polling, response submission, allocation ownership, and shutdown ordering.
- [x] Add backend-neutral `NativeProxyServer` dispatch with runtime-env > compile-time-define > Rust-default precedence; invalid values fail clearly and explicit Zig selection never silently falls back.
- [x] Complete Zig queue notification and batched request/response FFI paths, replacing the current test-only `server_native_zig_queue_*` surface with the shared `server_native_*` proxy ABI where appropriate.
- [x] Port bridge transport behavior and frame compatibility, including TCP/Unix modes, length-prefix framing, tokenized headers, streaming request/response bodies, backpressure, and tunnel frames.
- [x] Milestone 1 / HTTP/1: implement Zig TCP/Unix listeners and HTTP/1 parsing/writing, starting with `/health`, then parity for bridge/direct modes, keep-alive, chunked bodies, WebSocket upgrades, graceful shutdown, IPv6/shared binding, and TLS HTTP/1.
- [x] Gate HTTP/1 on the existing Dart/framework suites, direct/bridge differential tests, curl interoperability, and shutdown stress tests.
- [x] Milestone 2 / HTTP/2: integrate `nghttp2` through Zig C interop, add TLS/ALPN, map streams to the shared frame model, implement flow-control backpressure, cancellation, and concurrent streams, then validate with curl and `h2spec`.
- [ ] Milestone 3 / HTTP/3: integrate `ngtcp2` + `nghttp3` with the selected QUIC-capable TLS provider, add Alt-Svc, UDP lifecycle, stream reset, graceful close, and independent curl/QUIC interoperability tests.
  - [x] Initial UDP/ngtcp2/BoringSSL/nghttp3 runtime, shared bridge/direct requests, Alt-Svc, curl and independent aioquic interoperability.
  - [x] Deterministic bidirectional loss/delay/duplication, lost close recovery, and silent draining replay gates.
  - [x] Retain closing/draining connection IDs for three PTOs with bounded close replies and no deadline extension.
  - [x] Progressive request/response streaming in bridge/direct modes with ACK-retained QUIC response chunks.
  - [x] Staged GOAWAY, bounded asynchronous application shutdown, blackholed-path and Dart responsiveness gates.
  - [x] Bound native HTTP/3 connection/listener allocations and direct response queues; verify paused upload/download backpressure with independent aioquic clients in bridge/direct modes.
  - [ ] Migration-disabled path tests, address-validation/Retry policy, IPv6/shared UDP routing, and sustained resource stress (including TLS/Dart allocations outside native budgets).
- [ ] Extend prebuilt artifacts and CI for both libraries and all supported targets, keeping Rust release artifacts unchanged while adding a separate verified Zig asset/manifest path.
- [ ] Make Zig selectable/default only after all required stability gates; preserve Rust fallback and document the transition.

## Verification

- Zig unit tests for codec, queue, ABI validation, and lifecycle.
- Dart unit/integration tests run once with Rust and once with Zig.
- Existing HTTP/framework compatibility suites and benchmarks compared across backends.
- Native-thread notification and shutdown stress tests, including late event/callback cases.
- HTTP/1 interoperability tests first; later `curl`/`h2spec`/independent HTTP/3 interoperability tests.
- CI matrix validates Zig 0.16 builds, both backend assets, generated bindings, prebuilt artifacts, selector precedence, and identical tests for Rust and Zig; retain a compatibility check for the currently supported Zig toolchain transition if needed.
