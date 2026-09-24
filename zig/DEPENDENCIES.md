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

`src/lib.zig` exposes `http2` and `http3` to Zig code only. Internal C exports
coordinate asynchronous shutdown; the public Dart protocol API is unchanged.
The existing listener dispatches HTTP/2 connections to the internal session adapter.
For TLS listeners with the existing `http3` option enabled, `proxy_http3.zig`
binds UDP on the same port and drives the internal HTTP/3 adapter.

`http2.Session` owns an nghttp2 server session at a stable allocation address.
It accepts fragmented input, emits borrowed header/DATA/lifecycle events,
serializes output, copies finite response bodies into bounded storage, and
supports stream reset and GOAWAY. The application explicitly calls `consume`
after consuming request DATA to return flow-control credit. Sink callbacks must
copy retained data and must not reenter the session. Sink failure terminates
the connection; it is not a queue-full retry mechanism. Runtime producers defer
response DATA until Dart supplies more chunks, and resume the affected stream
without blocking other streams.

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
over cleartext and TLS. It does not require h2spec. `http2_streaming_test.dart`
checks progressive 5 MiB echoes in all four modes. Headers dispatch before upload
EOF. Direct-mode DATA credit returns when Dart delivers a chunk to the request
stream listener (or discards input after its handler completes), with at most
64 KiB outstanding per request. Bridge-mode credit follows socket handoff;
pausing the Dart request stream pauses bridge reads and propagates socket pressure.
Direct responses wait asynchronously for native queue capacity through API-DL
notifications. Queue payloads are limited to 16 MiB per server and 256 KiB per
stream, plus a single larger legacy frame on an otherwise empty stream. Frame
counts are bounded independently, including empty frames.

## HTTP/3 runtime status

The runtime uses one native UDP thread per bound address/port to own ngtcp2 connections,
BoringSSL sessions, nghttp3 streams, expiry processing and response progress.
It accepts QUIC v1, routes connection IDs, opens control/QPACK streams, returns
flow-control credit, tracks accepted and acknowledged output, and releases UDP
when the last listener closes. Admission is limited to 128 connections per UDP
group (including retained closed IDs), with 100 simultaneous
request streams per connection. Handshakes time out after 10 seconds; idle
connections after 30 seconds. Active migration is disabled in transport
parameters. HTTP/1 and HTTP/2 advertise a live listener through Alt-Svc.

The address-validation policy currently uses handshake proof; the listener issues
neither Retry nor NEW_TOKEN and does not treat client-supplied tokens as proof.
ngtcp2 enforces the pre-validation three-times amplification limit. Independent
tests withhold every handshake response, replay an Initial, and repeat with an
untrusted token, checking cumulative UDP byte counts. Connection admission,
handshake deadlines, and allocator budgets bound native state, but stateless
Retry under connection-flood load remains a possible future policy.

The migration test checks the advertised `disable_active_migration` parameter,
injects an undecryptable packet with a live connection ID from another socket,
and then changes the legitimate client's source port. The established connection
must remain usable and the client must observe a PATH_CHALLENGE. NAT rebinding
still requires path validation when active migration is disabled; see
[RFC 9000 sections 8–9](https://www.rfc-editor.org/rfc/rfc9000.html#section-8).

HTTP/2 and HTTP/3 share `proxy_request.zig`, preserving the frame codec and
asynchronous bridge/direct handler progress. Requests and responses stream
incrementally. The aioquic streaming gate echoes 6 MiB in segments, waiting for
each response segment before sending the next upload segment, without upload FIN.
QUIC response chunks retain stable storage until nghttp3 reports acknowledgement.
Response draining pauses at a 256 KiB transport watermark; one incoming frame
can exceed that watermark. The 32 MiB request buffer and 4 MiB response frame
limits are supplemented by hierarchical allocation limits: 16 MiB per QUIC
connection and 128 MiB per UDP group, shared across its listeners. These cover Zig-owned peer/stream data
and ngtcp2/nghttp3 heaps, including allocation metadata. Allocation failure
terminates the affected protocol operation; release restores capacity. BoringSSL
heaps, kernel socket buffers, and Dart application buffers are outside these
limits. In particular, synchronous response `add` calls and automatic compression
can still buffer in Dart; use awaited `addStream`/`flush` for producer pressure.

`http3_backpressure_test.dart` fixes the independent client receive window,
checks that a 32 MiB response producer stops making progress, cancels that stream,
then pauses an 8 MiB upload at the Dart handler and checks that its wire offset
stops increasing. Other streams must remain responsive, and the upload must
finish after consumption resumes. Both bridge and direct modes are covered.

Run the independent client gate explicitly (Python dependency is test-only):

```sh
python3 -m venv /tmp/server-native-quic-client
/tmp/server-native-quic-client/bin/pip install aioquic==1.3.0
AIOQUIC_PYTHON=/tmp/server-native-quic-client/bin/python SERVER_NATIVE_BACKEND=zig dart test test/http3_runtime_test.dart test/http3_shutdown_test.dart test/http3_backpressure_test.dart test/http3_ipv6_test.dart test/http3_shared_test.dart --concurrency=1
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
When the final listener shuts down, closing UDP permits immediate release of
all retained state. With another shared listener still active, compact records
retain the original and issued connection IDs, termination deadline, destination,
and cached close packet after the departing owner is freed.

Graceful HTTP/3 shutdown sends a notice, waits at least two measured RTTs,
then sends final GOAWAY and rejects new streams. A two-second listener deadline
forces close even when cancellation events cannot enter a full Dart queue.
Dart keeps processing handlers while polling completion asynchronously and joins
native teardown on a worker isolate. Forced shutdown skips the grace period.
`http3_shutdown_test.dart` verifies both GOAWAY frames, a blackholed path, and
Dart timer progress during close in bridge and direct modes.

TCP applies the requested IPv6-only option and UDP inherits it explicitly.
`http3_ipv6_test.dart` checks IPv6 and IPv4-mapped QUIC traffic, IPv4 port
availability for IPv6-only listeners, and UDP release in bridge/direct modes.
The shared HttpServer compatibility suite checks the TCP behavior against dart:io.

Shared listeners in one process use a single UDP socket and dispatcher, matching
[Dart shared binding across isolates](https://api.dart.dev/dart-io/HttpServer/bind.html).
New connections are distributed among active listeners; original and issued
connection IDs route established connections regardless of source-port changes.
Each listener keeps its own TLS configuration, backend, Dart port, and shutdown
state. Native registry/group locks serialize registration and teardown with the
UDP owner; request handling and port notifications remain asynchronous.
`http3_shared_test.dart` combines bridge/direct listeners within one isolate and
across isolates, changes source ports, closes one listener, replays its Initial,
and checks that the survivor accepts new connections, covering both listener
orders and forced/graceful close. Independent OS processes
are not joined into this registry.

`http3_lifecycle_stress_test.dart` repeatedly starts a listener, runs eight
concurrent independent clients with uploads and incomplete-stream cancellation,
closes the listener, and rebinds UDP. On Linux it compares descriptor counts
after warm-up and sixteen cycles per backend mode. Native teardown also asserts
that all budgeted allocations have been returned. Run it separately, because
file-descriptor counts are process-wide:

```sh
AIOQUIC_PYTHON=/tmp/server-native-quic-client/bin/python SERVER_NATIVE_BACKEND=zig dart test test/http3_lifecycle_stress_test.dart --concurrency=1
```

Set `HTTP3_STRESS_ROUNDS` for longer runs. These checks do not establish whole-
process memory stability under sustained production load: BoringSSL, kernel,
and Dart application allocations remain outside the native allocator accounting.
The HTTP/3 CI command runs test files serially; each file still exercises
concurrent clients and streams. A parallel local suite, run alongside a native
ReleaseSafe dependency rebuild, intermittently observed `EADDRINUSE` on immediate
UDP rebinding. The socket was gone by inspection, and targeted/serial runs and
standalone Dart/libc probes did not reproduce it. This remains an unresolved
load-related validation case, not a proven native leak or a completed gate.
**Step 11 remains open** for sustained-load and parallel rebind validation.

## Zig prebuilt release gate

`zig_prebuilt.yaml` describes the separate Linux x64 artifact. The build hook
uses its generated manifest with checksum verification and Zig source fallback.
The checked-in manifest intentionally has no artifacts until an actual release
has been verified; it does not invent hashes or reuse Rust artifact hashes.
The release workflow packages the Zig library with `native_prebuilt`, generates
archive/payload checksums and a Dart manifest, and uploads that metadata alongside
the archive. Import the verified release manifest into
`lib/src/generated/server_native_zig_prebuilts.g.dart` before enabling release
artifact selection. Other targets and published-archive consumer tests remain
release gates. Local source checkouts always compile current sources.

Regenerate internal ABI bindings with `python3 tool/generate_zig_bindings.py`.
It derives signatures from `src/lib.zig` and invokes the toolchain generator;
protocol C headers are not needed for ABI discovery.
