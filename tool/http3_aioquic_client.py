"""Independent HTTP/3 gate. Run in a venv with aioquic==1.3.0."""
import asyncio
import ssl
import sys

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, StreamDataReceived
from aioquic.buffer import Buffer, BufferReadError


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.pending = {}
        self.bodies = {}
        self.chunks = {}
        self.control = {}
        self.goaways = []
        self.terminated = asyncio.get_running_loop().create_future()

    def quic_event_received(self, event):
        if isinstance(event, StreamDataReceived) and event.stream_id % 4 == 3:
            data = self.control.setdefault(event.stream_id, bytearray())
            data.extend(event.data)
            buf = Buffer(data=bytes(data))
            try:
                if buf.pull_uint_var() == 0:  # Server control stream.
                    found = []
                    while not buf.eof():
                        kind, length = buf.pull_uint_var(), buf.pull_uint_var()
                        payload = buf.pull_bytes(length)
                        if kind == 7:
                            found.append(Buffer(data=payload).pull_uint_var())
                    self.goaways = found
            except BufferReadError:
                pass  # The next QUIC fragment will complete the frame.
        if isinstance(event, ConnectionTerminated) and not self.terminated.done():
            self.terminated.set_result(event)
        for response in self.http.handle_event(event):
            if not isinstance(response, (DataReceived, HeadersReceived)):
                continue
            stream = response.stream_id
            if stream not in self.pending:
                continue
            if isinstance(response, DataReceived):
                self.bodies[stream].extend(response.data)
                if stream in self.chunks:
                    self.chunks[stream].put_nowait(response.data)
            if response.stream_ended:
                self.pending.pop(stream).set_result(bytes(self.bodies.pop(stream)))

    def request(self, path, body=None, end=True):
        stream = self._quic.get_next_available_stream_id()
        future = asyncio.get_running_loop().create_future()
        self.pending[stream] = future
        self.bodies[stream] = bytearray()
        self.http.send_headers(stream, [
            (b":method", b"GET" if body is None else b"POST"),
            (b":scheme", b"https"),
            (b":authority", b"localhost"),
            (b":path", path.encode()),
        ], end_stream=body is None and end)
        if body is not None:
            self.http.send_data(stream, body, end_stream=end)
        self.transmit()
        return stream, future

    async def get(self, path, body=None):
        _, future = self.request(path, body)
        return await asyncio.wait_for(future, 10)

    def cancel(self, stream):
        self._quic.reset_stream(stream, 0x10c)
        self._quic.stop_stream(stream, 0x10c)
        self.pending.pop(stream).cancel()
        self.bodies.pop(stream)
        self.transmit()


class Relay(asyncio.DatagramProtocol):
    """Deterministic impairment on loopback, without privileged network changes."""
    def __init__(self, port, loss):
        self.upstream = ("127.0.0.1", port)
        self.client = None
        self.loss = loss
        self.counts = [0, 0]
        self.dropped = [0, 0]
        self.delayed = [0, 0]
        self.duplicated = [0, 0]
        self.drop_next_server = 0
        self.blackhole = False
        self.handles = []
        self.first_initial = None
        self.probe_close = False
        self.replayed = False

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, address):
        direction = int(address == self.upstream)
        if direction == 0:
            self.client = address
            if self.first_initial is None:
                self.first_initial = data
            if self.probe_close:
                self.probe_close = False
                # Let the native thread process CONNECTION_CLOSE first, then
                # replay the original Initial within the draining interval.
                def replay():
                    self.replayed = True
                    self.transport.sendto(self.first_initial, self.upstream)
                self.handles.append(
                    asyncio.get_running_loop().call_later(0.015, replay))
        target = self.client if direction else self.upstream
        if target is None:
            return
        self.counts[direction] += 1
        count = self.counts[direction]
        if self.blackhole:
            return
        if direction and self.drop_next_server:
            self.drop_next_server -= 1
            self.dropped[direction] += 1
            return
        if self.loss and (count == 1 or count % 17 == 0):
            self.dropped[direction] += 1
            return
        if self.loss and count % 11 == 0:
            self.delayed[direction] += 1
            self.handles.append(asyncio.get_running_loop().call_later(
                0.025, self.transport.sendto, data, target))
            return
        self.transport.sendto(data, target)
        if self.loss and count % 23 == 0:
            self.duplicated[direction] += 1
            self.transport.sendto(data, target)

    def close(self):
        for handle in self.handles:
            handle.cancel()
        self.transport.close()


async def streaming(client):
    stream, done = client.request("/stream", b"", end=False)
    chunks = client.chunks[stream] = asyncio.Queue()
    # Each upload segment waits for its echo before sending the next. Neither
    # upload FIN nor response EOF can hide whole-body buffering.
    for index in range(96):
        expected = bytes([index]) * 65536
        client.http.send_data(stream, expected, end_stream=False)
        client.transmit()
        received = bytearray()
        while len(received) < len(expected):
            received.extend(await asyncio.wait_for(chunks.get(), 5))
        assert received == expected
        assert not done.done(), "response ended before upload FIN"
    client.http.send_data(stream, b"", end_stream=True)
    client.transmit()
    result = await asyncio.wait_for(done, 5)
    assert len(result) == 96 * 65536
    del client.chunks[stream]


async def exercise(client):
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


async def main(port, mode):
    relay = None
    if mode in ("loss", "close-loss", "drain-replay", "shutdown-loss"):
        _, relay = await asyncio.get_running_loop().create_datagram_endpoint(
            lambda: Relay(port, mode == "loss"), local_addr=("127.0.0.1", 0))
        port = relay.transport.get_extra_info("sockname")[1]
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.verify_mode = ssl.CERT_NONE  # Local test certificate only.
    try:
        async with connect("127.0.0.1", port, configuration=config,
                           create_protocol=Client) as client:
            if mode in ("shutdown", "shutdown-loss"):
                assert await client.get("/shutdown") == b"closing"
                if relay:
                    relay.blackhole = True
                    await asyncio.sleep(3)
                else:
                    await asyncio.wait_for(client.terminated, 3)
                    assert len(client.goaways) >= 2, client.goaways
                    assert client.goaways[0] == (1 << 62) - 4, client.goaways
                    assert client.goaways[-1] < client.goaways[0], client.goaways
            elif mode == "streaming":
                await streaming(client)
            elif mode == "drain-replay":
                assert await client.get("/ready") == b"GET /ready  "
                # Drain the handshake/ACK flight before measuring silence.
                await asyncio.sleep(0.1)
                before = relay.counts[1]
                relay.probe_close = True
                client.close()
                await asyncio.sleep(0.05)
                assert relay.replayed
                assert relay.counts[1] == before, "server replied while draining"
            elif mode == "close-loss":
                assert await client.get("/ready") == b"GET /ready  "
                # Duplicate SETTINGS on the already-open control stream causes
                # H3_FRAME_UNEXPECTED. A fourth unidirectional stream would
                # instead be blocked by the peer's stream limit.
                # Drop the first close packet; PTO traffic must recover it.
                relay.drop_next_server = 1
                client._quic.send_stream_data(
                    client.http._local_control_stream_id, b"\x04\x00")
                client.transmit()
                event = await asyncio.wait_for(client.terminated, 5)
                assert event.error_code == 0x105, event
                assert relay.drop_next_server == 0
            else:
                await exercise(client)
        if mode == "loss":
            assert all(relay.dropped), relay.dropped
            assert all(relay.delayed), relay.delayed
            assert all(relay.duplicated), relay.duplicated
            print("impairments:", relay.dropped, relay.delayed, relay.duplicated)
        print("aioquic:", mode, "passed")
    finally:
        if relay:
            relay.close()


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else "aioquic"))
