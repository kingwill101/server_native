# Native backend ABI compatibility

`NativeProxyServer` is the shared Dart seam for the Rust and Zig transports. Both native assets use the same config layout and proxy operation signatures. Zig prefixes proxy symbols with `server_native_zig_`; the Dart wrapper dispatches to the selected asset.

| Contract | Rust asset (`src/ffi.g.dart`) | Zig asset (`src/zig_ffi.g.dart`) | Required Zig work |
| --- | --- | --- | --- |
| `server_native_transport_version` | Implemented, returns `1` | Implemented, returns `1` | Keep version semantics aligned while ABI grows |
| `server_native_start_proxy_server` | Implemented; returns opaque `ProxyServerHandle*` and writes `u16` port | Implemented for HTTP/1 | Complete protocol and lifecycle parity |
| `server_native_stop_proxy_server` | Implemented; consumes handle and joins runtime | Implemented; consumes handle | Complete shutdown stress coverage |
| `server_native_push_direct_response_frame` | Implemented | Implemented; copies frames by request ID | Complete backpressure parity |
| `server_native_complete_direct_request` | Compatibility alias implemented | Implemented as response submission alias | Keep behavior aligned |
| `server_native_poll_direct_request_frame` | Implemented; copies ownership to caller | Implemented with bounded event queue | Complete wake-up/batch integration |
| `server_native_free_direct_request_payload` | Implemented | Implemented | Free only allocations returned by poll |
| Dart API-DL initialization | Rust callback path currently uses Dart listener callbacks | `server_native_dart_api_initialize` implemented | Initialize once before native-thread port use |
| Dart port wake-up | Not used by Rust proxy ABI | Integer/queue smoke path implemented | Use port as wake-up only; drain payloads through FFI |
| Queue helpers | Internal Rust direct bridge queue | `server_native_zig_queue_*` test scaffold | Replace/underpin shared direct-request queue |

## Shared config layout

`ServerNativeProxyConfig` is currently generated from `native/bindings.h` and contains, in order:

1. nullable `const char* host`
2. `uint16_t port`
3. nullable `const char* backend_host`
4. `uint16_t backend_port`
5. `uint8_t backend_kind`
6. nullable `const char* backend_path`
7. `uint32_t backlog`
8. `uint8_t v6_only`
9. `uint8_t shared`
10. `uint8_t request_client_certificate`
11. `uint8_t http2`
12. `uint8_t http3`
13. nullable `const char* tls_cert_path`
14. nullable `const char* tls_key_path`
15. nullable `const char* tls_cert_password`
16. `uint8_t benchmark_mode`
17. nullable direct callback pointer

The Zig ABI imports the C declaration from `include/server_native_abi.h`, mirroring the field types, order, alignment, and nullability in `native/bindings.h`. Generated Dart bindings may have backend-specific Dart type names, but the transport wrapper must allocate one layout and cast pointers at the call boundary rather than maintaining divergent configuration logic.

## Ownership and lifecycle

- Dart owns UTF-8 config buffers only for the duration of `start`.
- Native start copies all configuration needed by worker threads before returning.
- Native start returns a heap-owned opaque handle or null on failure.
- `stop(null)` is a no-op; a valid handle is consumed exactly once.
- Stop signals listeners and worker threads, prevents new queue entries, wakes blocked pollers, drains/invalidates pending requests, joins workers, then frees the handle.
- Poll returns an allocated payload only on success; Dart copies it before calling the matching free function.
- Response submission copies the input bytes before returning and rejects unknown/closed request IDs.
- Dart API-DL is initialized before any native thread posts to a Dart port. Native shutdown must stop posting before the API/port owner is torn down.
