# Native protocol dependencies

`build.zig.zon` pins source archives by version or commit and Zig content hash.
The normal `zig build` resolves and compiles nghttp2, ngtcp2, nghttp3, BoringSSL,
and ngtcp2's BoringSSL crypto adapter. They are attached to both the static and
shared `server_native_zig` outputs and the runtime test build. Source archives
are cached under `zig-pkg/`, which is ignored by Git.

The Dart `hook/build.dart` already invokes `ZigBuilder`, so package builds use
this same dependency graph automatically. No manual CMake step is needed for
the normal build. AWS-LC remains a lazy source dependency for future comparison.

```sh
cd zig
zig build
zig build test
```

The build makes the libraries and C headers available to the Zig runtime.
HTTP/2 runtime integration and TLS HTTP/1 support are implemented. An initial
HTTP/3 UDP listener is integrated; its production milestone remains open. Unused archive members can be omitted by
the linker until the runtime references them. To prefetch every
pinned dependency, including AWS-LC, use `zig build --fetch=all`.

| Dependency | Pin | Packaging | Intended use |
| --- | --- | --- | --- |
| `nghttp2` | 1.70.0 | Upstream C sources | HTTP/2 sessions and flow control |
| `ngtcp2` | 1.25.0 | Upstream C sources | QUIC transport |
| `nghttp3` | 1.18.0 | Official release tarball including sfparse | HTTP/3 streams and QPACK |
| `boringssl` | allyourcodebase commit `1908fc17e8f24e29088b527ab476396981aecbab` | Zig 0.16 build package, BoringSSL 0.20260526.0 | TLS/ALPN and QUIC TLS candidate |
| `aws_lc` | 5.10.0 | Upstream C/C++ sources | Alternative TLS candidate |

## Build integration

The [allyourcodebase repository catalog](https://github.com/orgs/allyourcodebase/repositories)
was checked for existing build packages. Its
[BoringSSL package](https://github.com/allyourcodebase/boringssl/tree/1908fc17e8f24e29088b527ab476396981aecbab)
provides `ssl`, `crypto`, and `bcm` artifacts plus the named path `ssl_include`.
It does not provide a ready-made Zig binding module. Use generated C bindings
against those headers when implementing the TLS adapter. Its upstream source,
patch tooling, NASM, and GoogleTest dependencies are pinned by its own manifest.

`protocol_dependencies.zig` is the shared build adapter used by the normal
runtime and its tests. It compiles the pinned protocol source
lists, generates version headers, supplies platform feature macros, and links
ngtcp2's crypto adapter with BoringSSL. All protocol and BoringSSL archives use
PIC so they can be linked into the shared Dart native asset. Target and
optimization settings are forwarded from the parent build. The shared asset
links these archives normally; `zig ar` flattens their members into the installed
static archive so static consumers do not need separate protocol/TLS archives.
Static consumers still need the target C/C++ runtime libraries.

BoringSSL is the integrated build provider. AWS-LC is not linked into the
normal build. The target matrix has not
yet been validated beyond Linux x86_64; in particular the upstream BoringSSL
wrapper's Windows limitations still apply. Keep each library's license with
redistributed source or binary artifacts.

## Internal Zig adapters

`src/lib.zig` exposes `http2` and `http3` to Zig code only. No new C exports,
Dart bindings, or Dart configuration options are added, and the existing
listener dispatches HTTP/2 connections to the internal session adapter.
For TLS listeners with the existing `http3` option enabled, `proxy_http3.zig`
binds UDP on the same port and drives the internal HTTP/3 adapter.

`http2.Session` owns an nghttp2 server session at a stable allocation address.
It accepts fragmented input, emits borrowed header/DATA/lifecycle events,
serializes output, copies finite response bodies into bounded storage, and
supports stream reset and GOAWAY. The application explicitly calls `consume`
after consuming request DATA to return flow-control credit. Sink callbacks must
copy retained data and must not reenter the session. Sink failure terminates
the connection; it is not a queue-full retry mechanism. The future transport
must pause socket reads when its bounded event queue is full. Response bodies
are currently submitted whole, not as asynchronous streaming producers.

`http3.Connection` wraps an nghttp3 server connection, validates server control
stream IDs, accepts stream bytes, exposes output vectors, and tracks bytes
accepted/acknowledged by QUIC. Fatal receive/output failures prevent further
operations. Its receive return value is flow-control credit and excludes DATA
reported through nghttp3 callbacks. Borrowed output must be passed to QUIC
before another connection operation.

`http3.QuicConfig` provides bounded transport defaults with active migration
disabled and serializes transport parameters through ngtcp2. Server CID-specific
parameters must be populated per connection. `http3.TlsContext` owns a BoringSSL
QUIC context, selects h3 ALPN, loads PEM credentials, and creates owned TLS
sessions. The connection owner must attach `ngtcp2_crypto_conn_ref` before
driving a handshake. `proxy_http3.zig` supplies UDP sockets, the connection
driver, timer processing, TLS handshakes and request/frame mapping. These
owning values must not be copied or shared concurrently between threads.

## Tests

Run `zig build test`. The suite covers the cases below on Linux x86_64.
`zig build test install` also verifies both library outputs. Coverage includes:

- Pinned library versions.
- HTTP/2 fragmentation boundaries, negotiated concurrency limits, stream churn,
  aggregate response budgets, copied body/header ownership, peer cancellation,
  invalid input, callback failures, and receive/send flow-control stalls.
- Allocation-failure injection across Zig session/response, queue, and descriptor
  ownership paths; native C-library allocation failures are not injected.
- HTTP/3 one-byte QPACK request decoding, callback failure, partial output
  accounting, critical and unknown stream closure, duplicate control streams,
  and QUIC stream-ID bounds.
- Transport-parameter varint boundaries, exact output-buffer sizes, ALPN offer
  matrices, TLS lifetimes, and matching/mismatched PEM credential fixtures.
- Queue wraparound, byte/slot limits, and four concurrent producers delivering
  800 events exactly once while preserving each producer's ordering.
- Deterministic randomized binary frame round trips, truncated descriptors,
  hostile lengths/counts, and tokenized-header size accounting.
- Linking the runtime and protocol/TLS APIs using only the bundled static
  archive and the target C/C++ runtime libraries.

Validation is on Linux x86_64 with Zig 0.16. HTTP/2 has curl and h2spec gates
in addition to codec tests. HTTP/3 now has curl and independent aioquic gates.
The complete release target matrix remains unverified.
AWS-LC remains pinned as an alternative source dependency with no active build
adapter; the earlier standalone validation scripts were removed.

The initial nghttp3 GitHub tag archive omitted `lib/sfparse`, a required git
submodule. Compilation exposed that gap; the manifest now pins the official
release tarball, which includes the source. Preserve that packaging choice on
updates unless sfparse is separately pinned and wired into the build.

## Updating pins

Choose an explicit upstream release or wrapper commit, run `zig fetch <url>`
from this directory, and update both `.url` and `.hash`. Review wrapper manifests
for transitive source/version changes. Then run `zig build --fetch=all`,
`zig build` and `zig build test`, plus protocol interop checks as those are added.
Do not replace pins with moving branch URLs or alter the package fingerprint when updating dependencies.

## HTTP/2 conformance gate

The HTTP/2 runtime is in `src/proxy_http2.zig`; HTTP/1 and HTTP/2 share
`src/bridge_io.zig`. Run the external gate against real Dart handlers with:

```sh
H2SPEC=/path/to/h2spec SERVER_NATIVE_BACKEND=zig \
  dart test test/http2_runtime_test.dart
```

This runs h2spec in bridge/direct modes over prior-knowledge cleartext and TLS
ALPN, followed by curl upload/query checks. It requires h2spec and a curl build
with HTTP/2 support. The tests are explicitly skipped when H2SPEC is unset.

The adapter keeps bounded recent peer-closed stream IDs, validates legacy
PRIORITY control frames, and turns stream-window overflow into RST_STREAM
without closing unrelated streams. HPACK and general frame validation remain
owned by nghttp2. Control inspection must not bypass CONTINUATION requirements.
Connection teardown follows nghttp2's read/write interest after output is flushed.
Passing h2spec alone does not prove cancellation while a Dart handler is pending,
concurrent handler progress, or streaming/backpressure parity for the runtime.

## Handler scheduling and Dart wake-ups

The HTTP/2 connection thread owns its nghttp2 session and advances each request
independently. Backend writes are nonblocking; bridge replies and direct replies
are polled with bounded work per stream. A pending Dart handler therefore does
not prevent another stream, PING, or RST_STREAM from progressing. Reset streams
release their backend connection or native request ID, and late replies cannot
be submitted to a different stream.

The Zig proxy queue posts an API-DL integer notification on empty-to-nonempty
transitions. Registering a port also wakes it if work is already queued. Dart
uses that notification to drain FFI frames in batches of up to 64 before yielding,
and waits on the port when idle. The port carries no request bodies. Shutdown
detaches the notifier before stopping the native producer and closing the port.
Rust retains its existing polling fallback.

`test/http2_concurrency_test.dart` holds a Dart handler open while checking a
second stream, PING, cancellation, and a late response in bridge/direct modes
over cleartext and TLS. It does not require h2spec. Request bodies are still
buffered before dispatch (32 MiB limit); responses are buffered (4 MiB limit).
Streaming body parity and broader memory/backpressure limits need further work.

## HTTP/3 runtime status

The initial runtime uses one native UDP thread to own ngtcp2 connections,
BoringSSL sessions, nghttp3 streams, expiry processing and response progress.
It accepts QUIC v1, routes connection IDs, opens control/QPACK streams, returns
flow-control credit, tracks accepted and acknowledged output, and releases UDP
on shutdown. Admission is limited to 128 connections with 100 simultaneous
request streams per connection. Handshakes time out after 10 seconds; idle
connections after 30 seconds. Active migration is disabled in transport
parameters. HTTP/1 and HTTP/2 advertise a live listener through Alt-Svc.

HTTP/2 and HTTP/3 share `proxy_request.zig`, preserving the frame codec and
asynchronous bridge/direct handler progress. Requests remain buffered up to
32 MiB and responses up to 4 MiB. These are per-stream limits, not a global
memory budget.

Run the independent client gate explicitly (Python dependency is test-only):

```sh
python3 -m venv /tmp/server-native-quic-client
/tmp/server-native-quic-client/bin/pip install aioquic==1.3.0
AIOQUIC_PYTHON=/tmp/server-native-quic-client/bin/python SERVER_NATIVE_BACKEND=zig dart test test/http3_runtime_test.dart
```

Curl must support HTTP/3. The aioquic cases are reported as skipped when
`AIOQUIC_PYTHON` is absent. The tests cover uploads, concurrent handler progress,
reset and late replies, reuse beyond the initial stream allowance, malformed
UDP input, Alt-Svc, and UDP release in bridge/direct modes. A deterministic
loopback relay drops the first handshake datagrams and every seventeenth
packet, delays every eleventh packet, and duplicates every twenty-third packet
in both directions. Each impairment must occur for the test to pass.

Additional gates drop the first server CONNECTION_CLOSE packet and replay an
Initial during draining. The former checks recovery of the HTTP/3 error code;
the latter checks that the server stays silent rather than starting another
handshake. These are local fault-injection checks, not WAN load testing.

While the UDP listener remains open, terminal connections retain routing state
for three probe-timeout intervals, following
[RFC 9000 section 10.2](https://www.rfc-editor.org/rfc/rfc9000.html#section-10.2).
Closing repeats the cached close packet only to the original close destination,
with increasing time between replies and a cumulative three-to-one byte budget.
Draining emits no packets. Late packets do not extend the retention deadline.
Incomplete direct request bodies receive their terminal queue frame. If Dart's
queue is full, cleanup retries without blocking the UDP thread and retains the
request even after the protocol retention deadline until that frame is queued.
Forced listener shutdown can still release all retained state immediately.

**Step 11 remains open.** Remaining production gates include migration-disabled
path tests, staged HTTP/3 GOAWAY and graceful application shutdown,
address-validation/Retry policy, aggregate memory/backpressure budgets, full
streaming bodies, IPv6/shared UDP routing, and sustained lifecycle/resource
stress. Forced listener shutdown emits CONNECTION_CLOSE and closes the UDP
socket, so it releases retained connections immediately.
