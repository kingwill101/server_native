"""Independent HTTP/3 gate. Run in a venv with aioquic==1.3.0."""
import asyncio
import ssl
import sys

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection
from aioquic.quic.logger import QuicLogger
from aioquic.quic.packet import pull_quic_transport_parameters
from aioquic.quic.events import ConnectionTerminated, StreamDataReceived
from aioquic.buffer import Buffer, BufferReadError


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.peer_parameters = None
        parse_parameters = self._quic._parse_transport_parameters
        def capture_parameters(data, from_session_ticket=False):
            self.peer_parameters = pull_quic_transport_parameters(Buffer(data=data))
            return parse_parameters(data, from_session_ticket=from_session_ticket)
        self._quic._parse_transport_parameters = capture_parameters
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


class DatagramCounter(asyncio.DatagramProtocol):
    def __init__(self):
        self.received = 0

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, address):
        self.received += len(data)


async def address_validation(port):
    # Never deliver a server packet to QUIC, so the peer cannot prove receipt
    # or complete the handshake. Repeat with a token the server did not issue.
    loop = asyncio.get_running_loop()
    for token in (b"", b"untrusted-address-token"):
        config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
        config.token = token
        connection = QuicConnection(configuration=config)
        connection.connect(("127.0.0.1", port), now=loop.time())
        packets = connection.datagrams_to_send(now=loop.time())
        transport, counter = await loop.create_datagram_endpoint(
            DatagramCounter, local_addr=("127.0.0.1", 0))
        try:
            sent = 0
            for _ in range(2):
                for packet, destination in packets:
                    transport.sendto(packet, destination)
                    sent += len(packet)
                await asyncio.sleep(0.6)
                assert 0 < counter.received <= 3 * sent, (sent, counter.received)
        finally:
            transport.close()
    print("aioquic: unvalidated address byte limits passed")


class RebindingRelay(asyncio.DatagramProtocol):
    """Keep the client-facing socket stable while changing the server-side port."""
    def __init__(self, port):
        self.destination = ("127.0.0.1", port)
        self.client = None
        self.upstream = None
        self.sockets = []
        self.first_initial = None
        self.responses = []

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, address):
        self.client = address
        if self.first_initial is None:
            self.first_initial = data
        self.upstream.sendto(data, self.destination)

    async def rebind(self):
        relay = self
        class Upstream(asyncio.DatagramProtocol):
            def datagram_received(self, data, address):
                relay.responses.append(data)
                if relay.client:
                    relay.transport.sendto(data, relay.client)
        transport, _ = await asyncio.get_running_loop().create_datagram_endpoint(
            Upstream, local_addr=("127.0.0.1", 0))
        old = self.upstream
        self.upstream = transport
        self.sockets.append(transport)
        if old:
            assert old.get_extra_info("sockname") != transport.get_extra_info("sockname")
            old.close()

    def close(self):
        self.transport.close()
        for transport in self.sockets:
            transport.close()


async def rebinding(client, relay, logger):
    assert client.peer_parameters.disable_active_migration is True
    assert await client.get("/before-rebind") == b"GET /before-rebind  "
    # Knowing a live destination CID is insufficient to move an authenticated
    # connection. An unrelated socket injects an undecryptable short packet.
    transport, counter = await asyncio.get_running_loop().create_datagram_endpoint(
        DatagramCounter, local_addr=("127.0.0.1", 0))
    try:
        transport.sendto(b"\x40" + client._quic._peer_cid.cid + bytes(64), relay.destination)
        await asyncio.sleep(0.1)
        assert counter.received == 0, "server replied to forged path"
        assert await client.get("/after-forgery") == b"GET /after-forgery  "
    finally:
        transport.close()
    await relay.rebind()
    assert await client.get("/after-rebind", b"x" * 131072) == (
        b"POST /after-rebind  " + b"x" * 131072)
    await asyncio.sleep(0.1)
    frames = [frame for trace in logger.to_dict()["traces"]
              for event in trace["events"] if event["name"] == "transport:packet_received"
              for frame in event["data"].get("frames", [])]
    assert any(frame["frame_type"] == "path_challenge" for frame in frames), frames
    assert await client.get("/validated-path") == b"GET /validated-path  "


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


async def pressure(client):
    # Keep the initial advertised receive window fixed. aioquic normally grows
    # it independently of application consumption; this simulates a slow reader.
    client._quic._write_stream_limits = lambda *args, **kwargs: None
    download, _ = client.request("/download")
    async def received_window():
        while len(client.bodies.get(download, b"")) < 30000:
            await asyncio.sleep(0.01)
    await asyncio.wait_for(received_window(), 5)
    await asyncio.sleep(0.3)
    before = int(await client.get("/progress"))
    await asyncio.sleep(0.3)
    after = int(await client.get("/progress"))
    assert before == after, (before, after)
    assert 0 < after < 4 * 1024 * 1024, after
    assert await client.get("/fast") == b"fast"
    client.cancel(download)

    upload, done = client.request("/upload", b"u" * (8 * 1024 * 1024))
    await asyncio.sleep(0.3)
    sent = client._quic._streams[upload].sender.highest_offset
    await asyncio.sleep(0.3)
    later = client._quic._streams[upload].sender.highest_offset
    assert sent == later and 0 < sent < 4 * 1024 * 1024, (sent, later)
    assert await client.get("/fast") == b"fast"
    assert await client.get("/release") == b"released"
    assert await asyncio.wait_for(done, 15) == b"uploaded"


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


async def lifecycle_stress(port):
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.verify_mode = ssl.CERT_NONE
    async def worker(index):
        async with connect("127.0.0.1", port, configuration=config,
                           create_protocol=Client) as client:
            payload = bytes([index]) * 16384
            for _ in range(8):
                assert await client.get("/echo", payload) == payload
            stream, _ = client.request("/abandoned", payload, end=False)
            await asyncio.sleep(0.01)
            client.cancel(stream)
            assert await client.get("/echo", b"alive") == b"alive"
    await asyncio.gather(*(worker(i) for i in range(8)))
    print("aioquic: lifecycle batch passed")


async def shared_listeners(port, reverse=False):
    from contextlib import AsyncExitStack
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.verify_mode = ssl.CERT_NONE
    relays = []
    try:
        async with AsyncExitStack() as stack:
            clients = []
            owners = []
            for _ in range(2):
                _, relay = await asyncio.get_running_loop().create_datagram_endpoint(
                    lambda: RebindingRelay(port), local_addr=("127.0.0.1", 0))
                await relay.rebind()
                relays.append(relay)
                client = await stack.enter_async_context(connect(
                    "127.0.0.1", relay.transport.get_extra_info("sockname")[1],
                    configuration=config, create_protocol=Client))
                clients.append(client)
                owners.append(await client.get("/id"))
            assert set(owners) == {b"one", b"two"}, owners
            for i, client in enumerate(clients):
                for _ in range(4):
                    assert await client.get("/id") == owners[i]
                await relays[i].rebind()
                assert await client.get("/id") == owners[i], "rebinding changed owner"
            if reverse:
                clients.reverse()
                owners.reverse()
                relays.reverse()
            shutdown = "/shutdown?graceful=true" if reverse else "/shutdown"
            assert await clients[0].get(shutdown) == owners[0]
            # aioquic delivers ConnectionTerminated only after its own draining
            # timeout. Replay while the server must still retain the closed ID.
            async with asyncio.timeout(5):
                while clients[0]._quic._close_event is None:
                    await asyncio.sleep(0.001)
            relays[0].responses.clear()
            relays[0].upstream.sendto(relays[0].first_initial, relays[0].destination)
            await asyncio.sleep(0.02)
            assert not any(data[0] & 0x80 for data in relays[0].responses), (
                "departed listener's Initial started a new handshake")
            for _ in range(8):
                async with connect("127.0.0.1", port, configuration=config,
                                   create_protocol=Client) as fresh:
                    assert await fresh.get("/id") == owners[1]
            assert await clients[1].get("/id") == owners[1]
        print("aioquic: shared listeners preserve ownership, rebinding and close isolation")
    finally:
        for relay in relays:
            relay.close()


async def main(port, mode):
    if mode == "lifecycle-stress":
        await lifecycle_stress(port)
        return
    if mode in ("shared", "shared-reverse-graceful"):
        await shared_listeners(port, reverse=mode != "shared")
        return
    if mode == "address-validation":
        await address_validation(port)
        return
    relay = None
    if mode == "rebinding":
        _, relay = await asyncio.get_running_loop().create_datagram_endpoint(
            lambda: RebindingRelay(port), local_addr=("127.0.0.1", 0))
        await relay.rebind()
        port = relay.transport.get_extra_info("sockname")[1]
    if mode in ("loss", "close-loss", "drain-replay", "shutdown-loss"):
        _, relay = await asyncio.get_running_loop().create_datagram_endpoint(
            lambda: Relay(port, mode == "loss"), local_addr=("127.0.0.1", 0))
        port = relay.transport.get_extra_info("sockname")[1]
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    if mode == "pressure":
        config.max_stream_data = 32768
    if mode == "rebinding":
        config.quic_logger = QuicLogger()
    config.verify_mode = ssl.CERT_NONE  # Local test certificate only.
    try:
        async with connect("127.0.0.1", port, configuration=config,
                           create_protocol=Client) as client:
            if mode == "rebinding":
                await rebinding(client, relay, config.quic_logger)
            elif mode == "pressure":
                await pressure(client)
            elif mode in ("shutdown", "shutdown-loss"):
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
