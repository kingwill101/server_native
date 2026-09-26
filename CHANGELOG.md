# Changelog

All notable changes to `server_native` will be documented in this file.

## 1.0.0-dev

### Breaking changes

- Zig 0.16 replaces the Rust runtime, Cargo toolchain, bindings, and artifacts.
- Supported native targets are Linux x64 and ARM64. This prerelease does not
  support the other platforms previously served by Rust.
- Requires Dart 3.13 or later. The public Dart HTTP server API is retained;
  legacy Rust backend selectors no longer select a runtime.

### Protocols and compatibility

- Added Zig HTTP/1.1 and TLS, HTTP/2 through nghttp2, and HTTP/3 through
  ngtcp2/nghttp3 with BoringSSL.
- Added incremental responses, keep-alive and pipelining, chunked bodies,
  TCP/Unix bridge modes, and direct Dart-port request handling.
- Preserved WebSocket upgrades and detached sockets across HTTP server close;
  bounded tunnel frames prevent byte loss with slow readers.
- Fixed truncated-response handling, TLS handshake isolation, and shutdown
  without an active request listener.
- Added HTTP/3 streaming, cancellation, flow control, graceful shutdown, and
  independent curl/aioquic interoperability coverage.
- Expanded dart:io, Shelf, and Relic 2 RC compatibility tests and wire fixtures.

### Runtime and distribution

- Added Firehose PR release validation and tag-triggered pub.dev publishing.

- Added bounded native queues, Dart API-DL wake notifications, and parking
  mutexes to avoid spinning under worker contention.
- Added verified Linux x64/ARM64 prebuilt release packaging with archive and
  library checksums, architecture validation, and a Zig source-build fallback.
- Moved package and binary-release metadata to the standalone server_native
  repository. Updated the setup utility to use the pinned verified manifest.

## 0.1.3+1

- Port tokenized request-start and header encoding to the Zig bridge protocol.

- Add the first Zig bridge-protocol parity layer with bounded frame encoding and decoding.

- Fixed native-callback direct frame handling in `server_boot_proxy_direct.dart` to avoid routing single-frame direct requests through the stream path, improving shelf compatibility stability under repeated request/response cycles.
- Added loopback bind retry handling for transient dual-stack ephemeral `EADDRINUSE` collisions, including wrapped native bind error detection.
- Updated HTTP/3 integration CI to install a pinned static curl build with guaranteed HTTP/3 support and checksum verification, so HTTP/3 integration tests run deterministically instead of being skipped based on runner curl capabilities.
- Fixed native shelf/relic compatibility for empty `Connection` header values by preserving empty connection header semantics across sanitize/rewrite/bridge encoding paths.
- Fixed native response `contentLength` close parity for `HEAD`, `1xx`, `204`, and `304` responses to match `dart:io` behavior.
- Added Rust and Dart regression coverage for empty/sanitized connection header preservation and `HEAD` content-length close behavior.

## 0.1.3

- Fixed native callback websocket tunnel stability by switching direct frame polling to a non-blocking fair scheduling loop.
- Added and expanded framework compatibility tooling (`tool/framework_compat.dart`) and deterministic patch sets for `shelf` and `relic`.
- Added CI workflow for framework compatibility coverage (`.github/workflows/server_native_framework_compat.yml`).
- Updated framework compatibility CI to build the local Rust native library before native-mode runs (instead of relying on downloaded prebuilts).
- Fixed framework compatibility CI artifact upload path so per-matrix JSON reports are always collected.
- Added `relic` A/B parity regression coverage for transfer-encoding handling, websocket ping interval behavior, graceful close, malformed host/url handling, and `connectionsInfo`.
- Added native transfer-encoding regression tests to lock behavior across lenient `GET`/`HEAD` and chunked edge-cases.
- Improved `HttpRequest` URI reconstruction and malformed-target handling parity with `dart:io`.
- Improved bridge-mode `HttpRequest`/`HttpResponse` compatibility across default headers, streaming start timing, and detach/hijack flows.
- Stabilized native callback detach/hijack handling and direct stream lifecycle cleanup under shutdown and tunnel-close races.

## 0.1.2

- Split large Dart runtime files into focused modules for server boot, proxy runtime, direct path, and bridge codec/request/response layers.
- Added extensive Dart and Rust internal documentation across hot-path runtime code and protocol helpers.
- Fixed `NativeMultiServer.bind` to consistently forward the `http2` flag.
- Fixed `NativeHttpServer.connectionsInfo()` tracking in native callback mode by wiring request/socket lifecycle counters on the direct callback path.
- Added callback-free direct frame polling mode for native direct transport to avoid Rust->Dart callback teardown races.
- Fixed `NativeHttpServer.close(force: true)` shutdown hangs by cancelling active Rust connection tasks during shutdown.
- Added explicit regression tests for `NativeHttpServer.close(force: true)` in both bridge and native-callback modes.
- Reduced runtime log noise by silencing expected shutdown cancellation/tunnel teardown messages by default.
- Added `server_native.verbose_logs` toggle for opt-in verbose runtime diagnostics (including non-TLS HTTP/3 downgrade notices).
- Split native binary publishing to dedicated prebuilt release tags (`server-native-prebuilt-v*`) independent from Dart package tags.
- Updated `server_native:setup` to resolve latest prebuilt-specific release tags instead of generic repository latest release.
- Added generated prebuilt release metadata (`lib/src/generated/prebuilt_release.g.dart`) sourced from `pubspec.yaml` version.
- Updated hooks/setup to use versioned prebuilt paths (`.dart_tool/server_native/prebuilt/<tag>/<platform>/`) with legacy path fallback.
- Updated prebuilt CI workflow to auto-derive release tags from package version when no tag input is provided.
- Removed `save_to_repo` prebuilt commit path from CI to avoid drift from release source-of-truth.
- Updated hook prebuilt lookup priority to prefer downloaded versioned prebuilts over packaged fallback binaries.
- Switched setup/hook cache path from `.prebuilt/...` to `.dart_tool/server_native/prebuilt/...`.
- Removed checked-in native prebuilt binaries from the repository; GitHub binary releases are now the source-of-truth.
- Added hook-level prebuilt auto-download from versioned GitHub release assets when no local prebuilt is found.
- Regenerated `native/bindings.h` and `lib/src/ffi.g.dart` to keep generated FFI artifacts in sync with native source updates.

## 0.1.1

- Reduced packaged prebuilt binary sizes for pub.dev publish limits.
- Updated prebuilt CI flow to strip artifacts and skip `ios-sim-x64` in repo prebuilts.

## 0.1.0

- Initial release of `server_native`.
- Added `NativeHttpServer` with `HttpServer`-style bind/loopback APIs.
- Added multi-bind helpers: `NativeMultiServer` and `NativeServerBind`.
- Added native callback and direct-request server modes.
- Added framework and transport benchmark harnesses and documentation.
