"""Independent HTTP/3 gate. Run in a venv with aioquic==1.3.0."""
import asyncio
import ssl
import sys

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.pending = {}
        self.bodies = {}

    def quic_event_received(self, event):
        for response in self.http.handle_event(event):
            if not isinstance(response, (DataReceived, HeadersReceived)):
                continue
            stream = response.stream_id
            if stream not in self.pending:
                continue
            if isinstance(response, DataReceived):
                self.bodies[stream].extend(response.data)
            if response.stream_ended:
                self.pending.pop(stream).set_result(bytes(self.bodies.pop(stream)))

    def request(self, path, body=None):
        stream = self._quic.get_next_available_stream_id()
        future = asyncio.get_running_loop().create_future()
        self.pending[stream] = future
        self.bodies[stream] = bytearray()
        self.http.send_headers(stream, [
            (b":method", b"GET" if body is None else b"POST"),
            (b":scheme", b"https"),
            (b":authority", b"localhost"),
            (b":path", path.encode()),
        ], end_stream=body is None)
        if body is not None:
            self.http.send_data(stream, body, end_stream=True)
        self.transmit()
        return stream, future

    async def get(self, path, body=None):
        _, future = self.request(path, body)
        return await asyncio.wait_for(future, 5)

    def cancel(self, stream):
        self._quic.reset_stream(stream, 0x10c)
        self._quic.stop_stream(stream, 0x10c)
        self.pending.pop(stream).cancel()
        self.bodies.pop(stream)
        self.transmit()


async def main(port):
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.verify_mode = ssl.CERT_NONE  # Local test certificate only.
    async with connect("127.0.0.1", port, configuration=config,
                       create_protocol=Client) as client:
        assert await client.get("/echo?q=value", b"x" * 131072) == (
            b"POST /echo q=value " + b"x" * 131072
        )
        slow, _ = client.request("/slow")
        assert await client.get("/barrier") == b"entered"
        assert await client.get("/fast") == b"GET /fast  "
        client.cancel(slow)
        assert await client.get("/release") == b"released"
        assert await client.get("/after-reset") == b"GET /after-reset  "
        # Exceed the initial MAX_STREAMS allowance on the same connection.
        for _ in range(125):
            assert await client.get("/reuse") == b"GET /reuse  "
        print("aioquic: upload, concurrent streams, reset, late reply and reuse passed")


asyncio.run(main(int(sys.argv[1])))
