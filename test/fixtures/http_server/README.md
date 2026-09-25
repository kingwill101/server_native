# HTTP/1 wire fixtures

These are synthetic, reviewed protocol examples, not captured production traffic.
`sdk_http_server_fixtures_test.dart` replays each request against the SDK server
and native direct/bridge modes with the same handler. Zig is the sole native backend. No fixture contains account data or credentials.

The fixture schema records wire bytes, expected handler-visible target/body/
repeated headers, and response status. `reject: true` permits either a 400 or
connection closure, but forbids dispatch to the handler. This accommodates the
SDK's malformed-framing rejection without weakening successful-request checks.
The fragment fixture uses a handler that rejects URI fragments; parsers may
reject the request earlier.

The accompanying live cases exercise chunked uploads with a paused response
reader, raw binary detachment, WebSocket echo, listener closure, and owner-driven
WebSocket close handshakes. Both graceful and forced listener closure must leave
detached sockets usable. Timeouts bound hangs; they are not performance targets.

To add a regression, first reproduce it with the SDK baseline, then use the
same input and assertions for both native modes. Preserve meaningful byte/header
order; normalize only dynamic values such as ports or dates. Do not update
expectations solely to match a native failure.
