# server_native

[![pub package](https://img.shields.io/pub/v/server_native.svg)](https://pub.dev/packages/server_native)
[![pub points](https://img.shields.io/pub/points/server_native)](https://pub.dev/packages/server_native/score)
[![popularity](https://img.shields.io/pub/popularity/server_native)](https://pub.dev/packages/server_native/score)
[![likes](https://img.shields.io/pub/likes/server_native)](https://pub.dev/packages/server_native/score)
[![server_native CI](https://github.com/kingwill101/server_native/actions/workflows/server_native_ci.yml/badge.svg?branch=main)](https://github.com/kingwill101/server_native/actions/workflows/server_native_ci.yml)
[![framework compat](https://github.com/kingwill101/server_native/actions/workflows/server_native_framework_compat.yml/badge.svg?branch=main)](https://github.com/kingwill101/server_native/actions/workflows/server_native_framework_compat.yml)

`server_native` provides a Zig-backed HTTP server runtime for Dart with a
`dart:io`-like programming model.
`NativeHttpServer` implements `HttpServer`, allowing existing `HttpRequest` and
`HttpResponse` handlers to run on the native transport. Version **1.0.0-dev.1** is
a prerelease; compatibility is tested against `dart:io`, but is not complete.

## Native Runtime Status

Zig is the sole native backend. No backend environment variable or compile-time
switch is needed. Rust source, toolchain, bindings and release artifacts have
been removed. Current supported targets are **Linux x64 and ARM64**; the old
Rust-supported platforms are not supported by this version.

Zig serves HTTP/1.1 with TLS, HTTP/2, and HTTP/3 through the existing Dart API.
HTTP/2 uses nghttp2; HTTP/3 uses ngtcp2 and nghttp3; TLS uses BoringSSL.
See [compatibility and limits](#compatibility-and-limits) before migrating.

Linux artifacts are configured in `zig_prebuilt.yaml`. Release packages use a
checksum-pinned manifest to download matching Linux x64/ARM64 libraries. Prebuilts
require glibc 2.28 or later. Source builds require Zig 0.16 on PATH; Cargo is not
required. Dart **3.13 or later** is required. macOS, Windows, mobile platforms,
and Linux musl distributions are outside the supported prebuilt targets.

## Table Of Contents

- [Install](#install)
- [Native Runtime Status](#native-runtime-status)
- [Quick Start (`HttpServer` Style)](#quick-start-httpserver-style)
- [Migrating from `HttpServer`](#migrating-from-httpserver)
- [Compatibility and Limits](#compatibility-and-limits)
- [Protocol Support (HTTP/1.1, HTTP/2, HTTP/3)](#protocol-support-http11-http2-http3)
- [Address Semantics](#address-semantics)
- [Multi-Server Binding (`NativeHttpServer.loopback`)](#multi-server-binding-nativehttpserverloopback)
- [Multi-Server Binding Shortcut (`localhost` / `any`)](#multi-server-binding-shortcut-localhost--any)
- [Callback Multi-Server Binding (`NativeMultiServer`)](#callback-multi-server-binding-nativemultiserver)
- [Explicit Multi-Bind List (`NativeServerBind`)](#explicit-multi-bind-list-nativeserverbind)
- [TLS / HTTPS (Optional HTTP/3)](#tls--https-optional-http3)
- [Callback API (`HttpRequest`)](#callback-api-httprequest)
- [Direct Handler API (`NativeDirectRequest`)](#direct-handler-api-nativedirectrequest)
- [Graceful Shutdown](#graceful-shutdown)
- [DevTools Profiling Example](#devtools-profiling-example)
- [Framework Benchmarks](#framework-benchmarks)
- [Framework Compatibility Suites (Local + CI)](#framework-compatibility-suites-local--ci)
- [Dart SDK `HttpServer` Compatibility Tests](#dart-sdk-httpserver-compatibility-tests)
- [Native Bindings](#native-bindings)
- [Prebuilt Native Artifacts](#prebuilt-native-artifacts)
- [Troubleshooting](#troubleshooting)

Release maintainers: see [publishing with Firehose](doc/publishing.md).

## Install

```yaml
dependencies:
  server_native: ^1.0.0-dev.1
```

For an AOT deployment, build a CLI bundle so Dart includes the native library:

```sh
dart build cli --target bin/server.dart
./build/cli/linux_x64/bundle/bin/server
```

Replace the entry point and architecture directory as appropriate. Deploy the
entire `bundle` directory, including `lib/`. Plain `dart compile exe` does not
bundle code assets. `dart run` resolves them automatically during development.

## Quick Start (`HttpServer` Style)

```dart
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  final server = await NativeHttpServer.bind('127.0.0.1', 8080, http3: false);

  await for (final request in server) {
    if (request.uri.path == '/health') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{"ok":true}');
      await request.response.close();
      continue;
    }

    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.contentType = ContentType.text
      ..write('Not Found');
    await request.response.close();
  }
}
```

## Migrating from `HttpServer`

For plaintext servers, change the binding call and retain your request handler.
Run your application tests against both implementations before switching:

- before: `HttpServer.bind(...)`
- after: `NativeHttpServer.bind(...)`

```dart
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  final HttpServer server = await NativeHttpServer.bind('127.0.0.1', 8080);
  await for (final request in server) {
    request.response
      ..statusCode = HttpStatus.ok
      ..write('native server ok');
    await request.response.close();
  }
}
```

## Protocol Support (HTTP/1.1, HTTP/2, HTTP/3)

The public server boot APIs use these defaults:

| Protocol | Default | How it is served |
| --- | --- | --- |
| HTTP/1.1 | Enabled | Plain TCP or TLS |
| HTTP/2 | `http2: false` | Enable explicitly; plaintext prior knowledge or TLS ALPN `h2` |
| HTTP/3 | `http3: true` on secure boots | QUIC over UDP; disabled automatically without TLS |

For TLS with HTTP/1.1 only, set both `http2: false` and `http3: false`.
With HTTP/3 enabled, allow UDP traffic on the listener port as well as TCP.
HTTP/1.1 and HTTP/2 responses advertise the live HTTP/3 listener with `Alt-Svc`.

## Compatibility and Limits

- Tested behavior includes HTTP/1 framing and persistence, streaming bodies,
  response headers, shared binding, IPv6, HTTP/1 WebSocket upgrades, detached
  sockets, slow readers, and listener shutdown in direct and bridge modes.
- `bindSecure` takes `certificatePath` and `keyPath`, rather than the SDK's
  `SecurityContext` argument. The Zig runtime does not currently implement the
  `requestClientCertificate` option; do not use it for client-certificate
  authentication.
- Framework validation covers Shelf and a pinned Relic 2 RC release. The framework
  adapters replace plaintext bindings; their secure tests still use `dart:io`.
  Package-level TLS tests exercise Zig separately. Relic CI is currently advisory
  (`continue-on-error`), while Shelf CI is required.
- HTTP/3 currently accepts QUIC v1, disables active migration, and uses handshake
  proof for address validation without issuing Retry or NEW_TOKEN. Native memory
  budgets exclude BoringSSL, kernel, and Dart application buffers. Use awaited
  `addStream`/`flush` when producing large responses; synchronous writes can buffer
  in Dart. See the [HTTP/3 runtime limits](zig/DEPENDENCIES.md#http3-runtime-status).
- [Compatibility findings](test/HTTP_SERVER_PARITY.md) record historical scoped
  runs. They are not a certification of every SDK behavior or platform.

The Linux x64 and ARM64 release libraries passed native and Dart integration
checks on their respective architectures. Automatic prebuilt installation and
AOT bundle execution were also verified on Linux x64 for `1.0.0-dev`.

## Address Semantics

`NativeHttpServer.bind()` supports `HttpServer`-style address values:

- `'127.0.0.1'`, `'::1'`, or any explicit host/IP
- `'localhost'` (loopback convenience)
- `'any'` (bind all interfaces)

You can also use:

- `NativeHttpServer.loopback(...)`
- `NativeHttpServer.bindSecure(...)`
- `NativeHttpServer.loopbackSecure(...)`

## Multi-Server Binding (`NativeHttpServer.loopback`)

Bind one logical server across all loopback interfaces (`127.0.0.1` and `::1`
when available) with a single `HttpServer` stream:

```dart
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  final server = await NativeHttpServer.loopback(8080, http3: false);

  await for (final request in server) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write('loopback multi-server ok');
    await request.response.close();
  }
}
```

## Multi-Server Binding Shortcut (`localhost` / `any`)

Use `bind()` with `localhost` (loopback interfaces) or `any` (all interfaces)
to get multi-interface binding through a single `HttpServer`:

```dart
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  final server = await NativeHttpServer.bind('localhost', 8080, http3: false);
  // Equivalent patterns:
  // final server = await NativeHttpServer.bind('any', 8080, http3: false);
  // final server = await NativeHttpServer.loopback(8080, http3: false);

  await for (final request in server) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write('localhost multi-server ok');
    await request.response.close();
  }
}
```

## Callback Multi-Server Binding (`NativeMultiServer`)

Use `NativeMultiServer` when you want callback-style routing and
`http_multi_server`-style bind semantics:

```dart
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  await NativeMultiServer.bind(
    (request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.text
        ..write('native multi bind ok');
      await request.response.close();
    },
    'localhost',
    8080,
    http3: false,
  );
}
```

## Explicit Multi-Bind List (`NativeServerBind`)

Use `NativeServerBind` with `serveNativeMulti`/`serveSecureNativeMulti` for
fully explicit listener lists:

```dart
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  await serveNativeMulti(
    (request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.text
        ..write('explicit binds ok');
      await request.response.close();
    },
    binds: const <NativeServerBind>[
      NativeServerBind(host: '127.0.0.1', port: 8080),
      NativeServerBind(host: '::1', port: 8080),
    ],
    http3: false,
  );
}
```

## TLS / HTTPS (Optional HTTP/3)

```dart
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  final server = await NativeHttpServer.bindSecure(
    '127.0.0.1',
    8443,
    certificatePath: 'cert.pem',
    keyPath: 'key.pem',
    http2: true,
    http3: true,
  );

  await for (final request in server) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write('secure ok');
    await request.response.close();
  }
}
```

## Callback API (`HttpRequest`)

If you prefer a callback instead of a server stream:

```dart
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  await serveNativeHttp((request) async {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write('hello');
    await request.response.close();
  }, host: '127.0.0.1', port: 8080, http3: false);
}
```

`nativeCallback` defaults to `true` for `NativeHttpServer` and `serveNative*`
`HttpRequest` APIs. Despite the option name, the Zig runtime uses a native event
queue with Dart API-DL port notifications; Dart drains events through FFI. Set
`nativeCallback: false` to use the socket/frame bridge. HTTP/1 WebSocket upgrades
are covered in both modes.

## Direct Handler API (`NativeDirectRequest`)

This mode gives direct method/path/header/body access without `HttpRequest`.

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  await serveNativeDirect((request) async {
    if (request.method == 'GET' && request.path == '/health') {
      return NativeDirectResponse.bytes(
        headers: const [
          MapEntry(HttpHeaders.contentTypeHeader, 'application/json'),
        ],
        bodyBytes: Uint8List.fromList(utf8.encode('{"ok":true}')),
      );
    }

    final body = await utf8.decoder.bind(request.body).join();
    return NativeDirectResponse.bytes(
      status: HttpStatus.ok,
      headers: const [
        MapEntry(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8'),
      ],
      bodyBytes: Uint8List.fromList(utf8.encode('echo: $body')),
    );
  }, host: '127.0.0.1', port: 8080, http3: false);
}
```

`serveNativeDirect` defaults to the socket bridge (`nativeDirect: false`).
Set `nativeDirect: true` to use the native event queue and bypass that bridge:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  await serveNativeDirect((request) async {
    return NativeDirectResponse.bytes(
      status: HttpStatus.ok,
      headers: const [
        MapEntry(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8'),
      ],
      bodyBytes: Uint8List.fromList('ok'.codeUnits),
    );
  }, host: '127.0.0.1', port: 8080, nativeDirect: true);
}
```

## Graceful Shutdown

All boot helpers accept `shutdownSignal`.

```dart
import 'dart:async';
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  final shutdown = Completer<void>();
  final serveFuture = serveNativeHttp((request) async {
    request.response
      ..statusCode = HttpStatus.ok
      ..write('bye');
    await request.response.close();
  }, host: '127.0.0.1', port: 8080, shutdownSignal: shutdown.future);

  // Call this from your signal handler / lifecycle hook.
  shutdown.complete();
  await serveFuture;
}
```

## DevTools Profiling Example

Use the included profiling target:

```bash
dart --observe example/devtools_profile_server.dart --mode=direct --port=8080
```

Modes:

- `--mode=direct` for direct handler path
- `--mode=http` for `HttpRequest` path

## Framework Benchmarks

The current CI benchmark compares the Zig transport with `dart:io` over HTTP/1:

```sh
dart run tool/benchmark_transport.dart \
  --requests=2500 --concurrency=64 --warmup=300 --iterations=3 --json
```

CI requires a throughput ratio of at least 0.70 and a p95 latency ratio of at most
1.60 relative to its reference case. Passing this regression gate is not a claim
that Zig is faster for every workload. It does not benchmark HTTP/2 or HTTP/3.
Use the JSON results from a consistent machine and workload for comparisons.

The separate framework benchmark in `benchmark/` still has historical Rust
results and older development dependencies. Those results do not describe the
published Zig runtime or the Relic 2 RC compatibility matrix.

## Framework Compatibility Suites (Local + CI)

Use the compatibility harness to clone/update external frameworks, apply
`server_native` integration patches, and run their full test suites in both
transport modes:

- `SERVER_NATIVE_COMPAT=false` (`io`): framework binds with `dart:io` `HttpServer`
- `SERVER_NATIVE_COMPAT=true` (`native`): framework binds with `NativeHttpServer`

The harness pins Relic **v2.0.0-rc.1** for reproducibility. The intended scope is
Relic 2 RC and later; newer releases need their own validation. Relic 1.x is
outside this matrix.

Run locally from repo root:

```bash
dart run tool/framework_compat.dart \
  --framework=all \
  --mode=both \
  --fresh \
  --json-output=.dart_tool/server_native/framework_compat/report.json
```

Run a single framework:

```bash
dart run tool/framework_compat.dart --framework=shelf --mode=both --fresh
```

CI workflow:

- `.github/workflows/server_native_framework_compat.yml`

The workflow runs the same harness command and uploads a JSON result artifact.

## Dart SDK `HttpServer` Compatibility Tests

`server_native` includes a Dart SDK-derived compatibility suite in:

- `test/sdk_http_server_compat_test.dart`

Run it directly:

```bash
dart test test/sdk_http_server_compat_test.dart
```

The SDK-derived suite covers headers, charset encoding, connection persistence,
content-length errors, shared binding, and other server semantics. Additional
wire fixtures and edge cases compare `dart:io`, Zig direct, and Zig bridge:

```sh
dart test test/sdk_http_server_compat_test.dart \
  test/sdk_http_server_edge_cases_test.dart \
  test/sdk_http_server_fixtures_test.dart \
  test/http1_framing_regression_test.dart
```

Independent protocol checks live in `test/http2_runtime_test.dart` and
`test/http3_runtime_test.dart`. External-client cases require their configured
clients (for example `H2SPEC` and `AIOQUIC_PYTHON`) and may otherwise skip. See
[protocol testing instructions](zig/TESTING.md) and the
[dependency/runtime guide](zig/DEPENDENCIES.md) for prerequisites.

## Native Bindings

Generate exported Zig bindings and the C configuration layout with:

```bash
python3 tool/generate_zig_bindings.py
dart run tool/generate_ffi.dart
```

The configuration source is `zig/include/server_native_abi.h`; neither generator
requires Cargo or cbindgen.

## Prebuilt Native Artifacts

`.github/workflows/server_native_prebuilt.yml` builds and tests Linux x64 and
ARM64 artifacts on their native architectures. Archives are named
`server_native-zig-<platform>.tar.gz`, with `server-native-prebuilt-v*` release tags.
The release workflow generates archive and library checksums from the tested
binaries. Commit that generated manifest as described in the
[release guide](doc/publishing.md); published packages pin a specific binary
release rather than downloading an arbitrary latest build.

The build hook prefers verified release/cache artifacts for published packages
and falls back to Zig source compilation. Workspace checkouts build current
sources. The optional `dart run server_native:setup` utility downloads Zig
archives for Linux x64 or ARM64 into
`.prebuilt/<platform>/` after checksum and architecture verification. Setup uses
only the package-pinned release; arbitrary tags and `--tag latest` are not
supported. Git checkouts build source unless `hooks.user_defines.server_native.prebuilt_path` explicitly selects a library for testing.

## Troubleshooting

If you see:

`File modified during build. Build must be rerun.`

Run the same command again once. This can happen on first native asset build.
