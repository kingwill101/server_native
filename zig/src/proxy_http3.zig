//! UDP owner for ngtcp2 + nghttp3. One thread owns every connection, timer,
//! TLS session and stream; Dart handlers advance through the shared queue.
const std = @import("std");
const h3 = @import("http3.zig");
const shared = @import("proxy_request.zig");
const c = h3.c;
const backing_allocator = std.heap.c_allocator;
const Budget = @import("memory_budget.zig").Budget;
const max_connections = 128;

const Mutex = struct {
    native: std.c.pthread_mutex_t = .{},
    fn lock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.native) == .SUCCESS);
    }
    fn unlock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.native) == .SUCCESS);
    }
    fn deinit(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_destroy(&self.native) == .SUCCESS);
    }
};

fn now() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
fn selfFrom(comptime T: type, context: ?*anyopaque) *T {
    return @ptrCast(@alignCast(context.?));
}
fn randomBytes(dest: [*c]u8, len: usize, _: [*c]const c.ngtcp2_rand_ctx) callconv(.c) void {
    // BoringSSL terminates on entropy-source failure.
    _ = c.RAND_bytes(dest, len);
}

// RFC 9000 section 10.2: retain routing state for three PTOs while the
// listening socket stays open. Closing replies are rate-limited; draining
// never transmits. The deadline is fixed even when late packets arrive.
const Termination = struct {
    phase: enum { active, closing, draining, discard } = .active,
    deadline: u64 = 0,
    next_reply: u64 = 0,
    interval: u64 = 0,
    received_bytes: u64 = 0,
    replied_bytes: u64 = 0,

    fn begin(self: *Termination, time: u64, pto: u64, draining: bool) void {
        if (self.phase != .active) return;
        self.phase = if (draining) .draining else .closing;
        self.interval = @max(pto, 1);
        self.deadline = time +| (3 *| self.interval);
        self.next_reply = time;
    }
    fn expired(self: Termination, time: u64) bool {
        return self.phase != .active and time >= self.deadline;
    }
    fn reply(self: *Termination, time: u64, received: usize, response: usize) bool {
        if (self.phase != .closing or self.expired(time) or response == 0) return false;
        self.received_bytes +|= received;
        const allowance = (self.received_bytes *| 3) -| self.replied_bytes;
        if (time < self.next_reply or response > allowance) return false;
        self.replied_bytes +|= response;
        self.interval = self.interval *| 2;
        self.next_reply = time +| self.interval;
        return true;
    }
};

fn sameAddress(left: *const c.sockaddr_storage, right: *const c.sockaddr_storage) bool {
    if (left.ss_family != right.ss_family) return false;
    if (left.ss_family == c.AF_INET) {
        const a: *const c.sockaddr_in = @ptrCast(@alignCast(left));
        const b: *const c.sockaddr_in = @ptrCast(@alignCast(right));
        return a.sin_port == b.sin_port and a.sin_addr.s_addr == b.sin_addr.s_addr;
    }
    if (left.ss_family == c.AF_INET6) {
        const a: *const c.sockaddr_in6 = @ptrCast(@alignCast(left));
        const b: *const c.sockaddr_in6 = @ptrCast(@alignCast(right));
        return a.sin6_port == b.sin6_port and a.sin6_scope_id == b.sin6_scope_id and
            std.mem.eql(u8, std.mem.asBytes(&a.sin6_addr), std.mem.asBytes(&b.sin6_addr));
    }
    return false;
}

pub fn Runtime(comptime Server: type) type {
    return struct {
        const Self = @This();
        fd: c_int,
        local: c.sockaddr_storage,
        local_len: c.socklen_t,
        tls: h3.TlsContext,
        server: *Server,
        group: *Group,
        started: bool = false,
        peers: std.ArrayList(*Peer) = .empty,
        memory: Budget = .{ .parent = backing_allocator, .limit = 128 * 1024 * 1024 },
        shutdown_requested: std.atomic.Value(bool) = .init(false),
        shutdown_complete: std.atomic.Value(bool) = .init(false),
        shutdown_started: bool = false,
        shutdown_deadline: u64 = 0,

        pub fn create(server: *Server, cert: [:0]const u8, key: [:0]const u8, shared_listener: bool) !*Self {
            var local: c.sockaddr_storage = undefined;
            var len: c.socklen_t = @sizeOf(c.sockaddr_storage);
            if (c.getsockname(server.listener.fd, @ptrCast(&local), &len) != 0) return error.SocketFailed;
            var v6_only: c_int = 0;
            if (local.ss_family == c.AF_INET6) {
                var option_len: c.socklen_t = @sizeOf(c_int);
                if (c.getsockopt(server.listener.fd, c.IPPROTO_IPV6, c.IPV6_V6ONLY, &v6_only, &option_len) != 0) return error.SocketFailed;
            }
            var tls = try h3.TlsContext.initServer();
            errdefer tls.deinit();
            try tls.certificate(cert, key);
            const self = try backing_allocator.create(Self);
            errdefer backing_allocator.destroy(self);
            // Registry -> group is the only lock order. The UDP worker only
            // takes its group lock, never the registry lock.
            registry_mutex.lock();
            defer registry_mutex.unlock();
            var group: ?*Group = null;
            for (groups.items) |candidate| {
                if (sameAddress(&candidate.local, &local) and candidate.v6_only == v6_only) {
                    if (!shared_listener or !candidate.shared_listener) return error.BindFailed;
                    group = candidate;
                    break;
                }
            }
            const created = group == null;
            if (created) {
                group = try Group.create(local, len, v6_only, shared_listener);
                groups.append(backing_allocator, group.?) catch |err| {
                    group.?.destroy();
                    return err;
                };
            }
            const owner = group.?;
            owner.mutex.lock();
            if (owner.members.items.len >= 128) {
                owner.mutex.unlock();
                return error.TooManyListeners;
            }
            self.* = .{ .fd = owner.fd, .local = local, .local_len = len, .tls = tls, .server = server, .group = owner };
            self.memory.parent = owner.memory.allocator();
            owner.members.append(backing_allocator, self) catch |err| {
                owner.mutex.unlock();
                if (created) {
                    _ = groups.pop();
                    if (groups.items.len == 0) {
                        groups.deinit(backing_allocator);
                        groups = .empty;
                    }
                    owner.destroy();
                }
                return err;
            };
            owner.mutex.unlock();
            return self;
        }
        pub fn start(self: *Self) !void {
            self.group.mutex.lock();
            defer self.group.mutex.unlock();
            if (self.group.thread == null) self.group.thread = try std.Thread.spawn(.{}, Group.run, .{self.group});
            self.started = true;
        }
        pub fn beginShutdown(self: *Self) void {
            self.shutdown_requested.store(true, .release);
        }
        pub fn shutdownDone(self: *Self) bool {
            return self.shutdown_complete.load(.acquire);
        }
        pub fn deinit(self: *Self) void {
            registry_mutex.lock();
            defer registry_mutex.unlock();
            const group = self.group;
            group.mutex.lock();
            for (self.peers.items) |peer| {
                peer.beginTermination();
                // Another listener keeps UDP open. Preserve connection IDs and
                // close packets independently of the departing Dart/native owner.
                if (group.members.items.len > 1) group.retain(peer);
                peer.deinit();
            }
            self.peers.deinit(self.memory.allocator());
            self.tls.deinit();
            std.debug.assert(self.memory.used == 0);
            for (group.members.items, 0..) |member, i| {
                if (member == self) {
                    _ = group.members.orderedRemove(i);
                    break;
                }
            }
            const last = group.members.items.len == 0;
            if (last) group.stopped.store(true, .release);
            group.mutex.unlock();
            if (last) {
                for (groups.items, 0..) |candidate, i| {
                    if (candidate == group) {
                        _ = groups.swapRemove(i);
                        break;
                    }
                }
                if (groups.items.len == 0) {
                    groups.deinit(backing_allocator);
                    groups = .empty;
                }
                group.destroy();
            }
            backing_allocator.destroy(self);
        }
        fn tick(self: *Self) void {
            if (self.shutdown_complete.load(.acquire)) return;
            if (self.shutdown_requested.load(.acquire) and !self.shutdown_started) {
                self.shutdown_started = true;
                self.shutdown_deadline = now() +| 2_000_000_000;
                for (self.peers.items) |peer| peer.beginGracefulShutdown();
            }
            if (self.server.stopped.load(.acquire) or
                (self.shutdown_started and (self.peers.items.len == 0 or now() >= self.shutdown_deadline)))
            {
                for (self.peers.items) |peer| peer.beginTermination();
                self.shutdown_complete.store(true, .release);
                return;
            }
            var i: usize = 0;
            while (i < self.peers.items.len) {
                const peer = self.peers.items[i];
                if (peer.termination.phase == .active) {
                    peer.tick() catch {
                        peer.failed = true;
                    };
                    if (peer.failed) peer.beginTermination();
                } else {
                    _ = peer.finishCancelledBodies();
                }
                if (peer.termination.expired(now()) and peer.finishCancelledBodies()) {
                    _ = self.peers.swapRemove(i);
                    peer.deinit();
                } else i += 1;
            }
        }

        var registry_mutex: Mutex = .{};
        var groups: std.ArrayList(*Group) = .empty;

        const Tombstone = struct {
            ids: [17]c.ngtcp2_cid,
            count: usize,
            termination: Termination,
            packet: [1350]u8,
            length: usize,
            remote: c.sockaddr_storage,
            remote_len: c.socklen_t,
            fn matches(self: *const Tombstone, id: []const u8) bool {
                for (self.ids[0..self.count]) |cid| {
                    if (std.mem.eql(u8, cid.data[0..cid.datalen], id)) return true;
                }
                return false;
            }
        };
        const Group = struct {
            fd: c_int,
            local: c.sockaddr_storage,
            v6_only: c_int,
            shared_listener: bool,
            mutex: Mutex = .{},
            thread: ?std.Thread = null,
            stopped: std.atomic.Value(bool) = .init(false),
            members: std.ArrayList(*Self) = .empty,
            next_member: usize = 0,
            memory: Budget = .{ .parent = backing_allocator, .limit = 128 * 1024 * 1024 },
            tombstones: [max_connections]Tombstone = undefined,
            tombstone_count: usize = 0,

            fn create(local: c.sockaddr_storage, len: c.socklen_t, v6_only: c_int, share: bool) !*Group {
                const fd = c.socket(local.ss_family, c.SOCK_DGRAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
                if (fd < 0) return error.SocketFailed;
                errdefer _ = c.close(fd);
                if (local.ss_family == c.AF_INET6 and c.setsockopt(fd, c.IPPROTO_IPV6, c.IPV6_V6ONLY, &v6_only, @sizeOf(c_int)) != 0) return error.SocketFailed;
                if (c.bind(fd, @ptrCast(&local), len) != 0) return error.BindFailed;
                const self = try backing_allocator.create(Group);
                self.* = .{ .fd = fd, .local = local, .v6_only = v6_only, .shared_listener = share };
                return self;
            }
            fn destroy(self: *Group) void {
                if (self.thread) |thread| thread.join();
                self.members.deinit(backing_allocator);
                _ = c.close(self.fd);
                self.mutex.deinit();
                std.debug.assert(self.memory.used == 0);
                backing_allocator.destroy(self);
            }
            fn retain(self: *Group, peer: *Peer) void {
                if (peer.termination.expired(now())) return;
                // Admission counts both live peers and retained IDs, so removal
                // of a live peer always leaves room for its tombstone.
                std.debug.assert(self.tombstone_count < max_connections);
                const saved = &self.tombstones[self.tombstone_count];
                self.tombstone_count += 1;
                saved.* = .{ .ids = undefined, .count = 1, .termination = peer.termination, .packet = peer.close_packet, .length = peer.close_len, .remote = peer.close_remote, .remote_len = peer.close_remote_len };
                saved.ids[0] = peer.original;
                const count = c.ngtcp2_conn_get_scid(peer.quic, null);
                std.debug.assert(count <= 16);
                _ = c.ngtcp2_conn_get_scid(peer.quic, &saved.ids[1]);
                saved.count += count;
            }
            fn purge(self: *Group) void {
                var i: usize = 0;
                while (i < self.tombstone_count) {
                    if (self.tombstones[i].termination.expired(now())) {
                        self.tombstone_count -= 1;
                        self.tombstones[i] = self.tombstones[self.tombstone_count];
                    } else i += 1;
                }
            }
            fn dispatch(self: *Group, packet: []const u8, remote: *c.sockaddr_storage, len: c.socklen_t) void {
                const version = packetVersion(packet) orelse return;
                const id = version.dcid[0..version.dcidlen];
                for (self.tombstones[0..self.tombstone_count]) |*saved| {
                    if (!saved.matches(id)) continue;
                    if (sameAddress(remote, &saved.remote) and saved.termination.reply(now(), packet.len, saved.length)) {
                        _ = c.sendto(self.fd, &saved.packet, saved.length, c.MSG_DONTWAIT, @ptrCast(&saved.remote), saved.remote_len);
                    }
                    return;
                }
                var count = self.tombstone_count;
                for (self.members.items) |member| {
                    count += member.peers.items.len;
                    for (member.peers.items) |peer| {
                        if (peer.matches(id)) {
                            member.receive(packet, remote, len) catch {};
                            return;
                        }
                    }
                }
                if (count >= max_connections) return;
                for (0..self.members.items.len) |_| {
                    self.next_member %= self.members.items.len;
                    const member = self.members.items[self.next_member];
                    self.next_member += 1;
                    if (!member.started or member.server.stopped.load(.acquire) or member.shutdown_requested.load(.acquire)) continue;
                    member.receive(packet, remote, len) catch {};
                    return;
                }
            }
            fn run(self: *Group) void {
                while (!self.stopped.load(.acquire)) {
                    var poll = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
                    _ = std.posix.poll(&poll, 5) catch 0;
                    self.mutex.lock();
                    self.purge();
                    for (0..32) |_| {
                        var packet: [65536]u8 = undefined;
                        var remote: c.sockaddr_storage = undefined;
                        var len: c.socklen_t = @sizeOf(c.sockaddr_storage);
                        const size = c.recvfrom(self.fd, &packet, packet.len, c.MSG_DONTWAIT, @ptrCast(&remote), &len);
                        if (size < 0) break;
                        self.dispatch(packet[0..@intCast(size)], &remote, len);
                    }
                    for (self.members.items) |member| {
                        if (member.started) member.tick();
                    }
                    self.mutex.unlock();
                }
            }
        };
        fn receive(self: *Self, packet: []const u8, remote: *c.sockaddr_storage, remote_len: c.socklen_t) !void {
            const version = packetVersion(packet) orelse return;
            var found: ?*Peer = null;
            for (self.peers.items) |peer| {
                if (peer.matches(version.dcid[0..version.dcidlen])) {
                    found = peer;
                    break;
                }
            }
            if (found == null) {
                if (self.server.stopped.load(.acquire) or self.shutdown_started) return;
                if (self.peers.items.len >= max_connections) return;
                var header: c.ngtcp2_pkt_hd = undefined;
                if (c.ngtcp2_accept(&header, packet.ptr, packet.len) != 0) return;
                if (header.version != c.NGTCP2_PROTO_VER_V1) return;
                const peer = try Peer.create(self, &header, remote, remote_len);
                errdefer peer.deinit();
                try self.peers.append(self.memory.allocator(), peer);
                found = peer;
            }
            const peer = found.?;
            if (peer.termination.phase != .active) {
                if (sameAddress(remote, &peer.close_remote) and peer.termination.reply(now(), packet.len, peer.close_len)) {
                    peer.repeatClose();
                }
                return;
            }
            if (peer.failed) return;
            // Active migration is disabled. Never redirect output to an
            // unauthenticated packet's source address.
            var path = peer.networkPath();
            path.remote = .{ .addr = @ptrCast(remote), .addrlen = remote_len };
            var info = std.mem.zeroes(c.ngtcp2_pkt_info);
            const result = c.ngtcp2_conn_read_pkt(peer.quic, &path, &info, packet.ptr, packet.len, now());
            if (result != 0) {
                peer.failed = true;
                peer.last_error = result;
                peer.silent = switch (result) {
                    c.NGTCP2_ERR_DRAINING, c.NGTCP2_ERR_CLOSING, c.NGTCP2_ERR_DROP_CONN, c.NGTCP2_ERR_RETRY => true,
                    else => false,
                };
            }
        }

        const Stream = struct {
            request: *shared.Request,
            submitted: bool = false,
            blocked: bool = false,
            body: @import("stream_body.zig").Body = .{},
            closed: bool = false,
        };
        const Peer = struct {
            owner: *Self,
            memory: Budget,
            quic_memory: c.ngtcp2_mem = undefined,
            http_memory: c.nghttp3_mem = undefined,
            quic: ?*c.ngtcp2_conn = null,
            codec: ?h3.Connection = null,
            tls: ?h3.TlsSession = null,
            ref: c.ngtcp2_crypto_conn_ref = undefined,
            original: c.ngtcp2_cid,
            remote: c.sockaddr_storage,
            remote_len: c.socklen_t,
            streams: std.AutoHashMap(i64, Stream),
            failed: bool = false,
            silent: bool = false,
            last_error: c_int = 0,
            termination: Termination = .{},
            graceful: bool = false,
            goaway_deadline: u64 = 0,
            goaway_sent: bool = false,
            close_packet: [1350]u8 = undefined,
            close_len: usize = 0,
            close_remote: c.sockaddr_storage = std.mem.zeroes(c.sockaddr_storage),
            close_remote_len: c.socklen_t = 0,

            fn create(owner: *Self, header: *c.ngtcp2_pkt_hd, remote: *c.sockaddr_storage, remote_len: c.socklen_t) !*Peer {
                const self = try owner.memory.allocator().create(Peer);
                self.* = .{
                    .owner = owner,
                    .memory = .{ .parent = owner.memory.allocator(), .limit = 16 * 1024 * 1024 },
                    .original = header.dcid,
                    .remote = remote.*,
                    .remote_len = remote_len,
                    .streams = undefined,
                };
                self.streams = .init(self.memory.allocator());
                self.quic_memory = .{ .user_data = &self.memory, .malloc = Budget.cMalloc, .calloc = Budget.cCalloc, .realloc = Budget.cRealloc, .free = Budget.cFree };
                self.http_memory = .{ .user_data = &self.memory, .malloc = Budget.cMalloc, .calloc = Budget.cCalloc, .realloc = Budget.cRealloc, .free = Budget.cFree };
                errdefer self.deinit();
                self.ref = .{ .get_conn = getConn, .user_data = self };
                var callbacks = std.mem.zeroes(c.ngtcp2_callbacks);
                callbacks.recv_client_initial = c.ngtcp2_crypto_recv_client_initial_cb;
                callbacks.recv_crypto_data = c.ngtcp2_crypto_recv_crypto_data_cb;
                callbacks.encrypt = c.ngtcp2_crypto_encrypt_cb;
                callbacks.decrypt = c.ngtcp2_crypto_decrypt_cb;
                callbacks.hp_mask = c.ngtcp2_crypto_hp_mask_cb;
                callbacks.update_key = c.ngtcp2_crypto_update_key_cb;
                callbacks.delete_crypto_aead_ctx = c.ngtcp2_crypto_delete_crypto_aead_ctx_cb;
                callbacks.delete_crypto_cipher_ctx = c.ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
                callbacks.version_negotiation = c.ngtcp2_crypto_version_negotiation_cb;
                callbacks.get_path_challenge_data = c.ngtcp2_crypto_get_path_challenge_data_cb;
                callbacks.rand = randomBytes;
                callbacks.get_new_connection_id = newCid;
                callbacks.recv_tx_key = txKey;
                callbacks.recv_stream_data = recvStream;
                callbacks.acked_stream_data_offset = acked;
                callbacks.stream_close = quicClosed;
                callbacks.stream_reset = quicReset;
                callbacks.stream_stop_sending = quicStopSending;
                callbacks.extend_max_stream_data = unblocked;
                callbacks.extend_max_remote_streams_bidi = extendedStreams;
                var config = h3.QuicConfig.init(now());
                config.settings.handshake_timeout = 10 * c.NGTCP2_SECONDS;
                config.transport.max_idle_timeout = 30 * c.NGTCP2_SECONDS;
                config.transport.original_dcid = header.dcid;
                config.transport.original_dcid_present = 1;
                var cid = std.mem.zeroes(c.ngtcp2_cid);
                cid.datalen = 16;
                _ = c.RAND_bytes(&cid.data, cid.datalen);
                var path = self.networkPath();
                if (c.ngtcp2_conn_server_new(&self.quic, &header.scid, &cid, &path, header.version, &callbacks, &config.settings, &config.transport, &self.quic_memory, self) != 0) return error.QuicFailed;
                var params: [512]u8 = undefined;
                const encoded = try config.encode(&params);
                self.tls = try owner.tls.session(encoded);
                _ = c.SSL_set_app_data(self.tls.?.native, &self.ref);
                c.ngtcp2_conn_set_tls_native_handle(self.quic, self.tls.?.native);
                return self;
            }
            fn networkPath(self: *Peer) c.ngtcp2_path {
                return .{
                    .local = .{ .addr = @ptrCast(&self.owner.local), .addrlen = self.owner.local_len },
                    .remote = .{ .addr = @ptrCast(&self.remote), .addrlen = self.remote_len },
                    .user_data = null,
                };
            }
            fn matches(self: *Peer, id: []const u8) bool {
                if (std.mem.eql(u8, self.original.data[0..self.original.datalen], id)) return true;
                var ids: [16]c.ngtcp2_cid = undefined;
                const count = c.ngtcp2_conn_get_scid(self.quic, null);
                if (count > ids.len) return false;
                _ = c.ngtcp2_conn_get_scid(self.quic, &ids);
                for (ids[0..count]) |cid| if (std.mem.eql(u8, cid.data[0..cid.datalen], id)) return true;
                return false;
            }
            fn deinit(self: *Peer) void {
                const allocator = self.memory.allocator();
                if (self.codec) |*codec| codec.deinit();
                if (self.quic) |quic| c.ngtcp2_conn_del(quic);
                if (self.tls) |*tls| tls.deinit();
                var it = self.streams.valueIterator();
                while (it.next()) |stream| {
                    if (stream.request.request_id) |id| self.owner.server.discardRequest(id);
                    stream.body.deinit(allocator);
                    stream.request.deinit();
                }
                self.streams.deinit();
                std.debug.assert(self.memory.used == 0);
                self.owner.memory.allocator().destroy(self);
            }
            fn finishCancelledBodies(self: *Peer) bool {
                var ready = true;
                var it = self.streams.valueIterator();
                while (it.next()) |stream| {
                    const finished = shared.finishCancelledRequest(self.owner.server, stream.request) catch false;
                    ready = ready and finished;
                }
                return ready;
            }
            fn beginGracefulShutdown(self: *Peer) void {
                if (self.termination.phase != .active or self.graceful) return;
                self.graceful = true;
                var info: c.ngtcp2_conn_info = undefined;
                c.ngtcp2_conn_get_conn_info(self.quic, &info);
                self.goaway_deadline = now() +| @max(100_000_000, 2 *| info.smoothed_rtt);
                if (self.codec) |codec| {
                    if (c.nghttp3_conn_submit_shutdown_notice(codec.native) != 0) self.failed = true;
                }
            }
            fn beginTermination(self: *Peer) void {
                if (self.termination.phase != .active) return;
                _ = self.finishCancelledBodies();
                if (self.silent and self.last_error != c.NGTCP2_ERR_DRAINING) {
                    self.termination.phase = .discard;
                    return;
                }
                self.termination.begin(now(), c.ngtcp2_conn_get_pto2(self.quic), self.last_error == c.NGTCP2_ERR_DRAINING);
                if (self.termination.phase == .draining) return;
                var error_code: c.ngtcp2_ccerr = undefined;
                c.ngtcp2_ccerr_default(&error_code);
                if (self.codec) |codec| {
                    if (codec.last_error != 0) c.ngtcp2_ccerr_set_application_error(&error_code, c.nghttp3_err_infer_quic_app_error_code(codec.last_error), null, 0);
                }
                if (self.last_error != 0 and error_code.error_code == 0) c.ngtcp2_ccerr_set_liberr(&error_code, self.last_error, null, 0);
                var path = self.networkPath();
                var info = std.mem.zeroes(c.ngtcp2_pkt_info);
                const size = c.ngtcp2_conn_write_connection_close(self.quic, &path, &info, &self.close_packet, self.close_packet.len, &error_code, now());
                if (size <= 0) return;
                self.close_len = @intCast(size);
                self.close_remote_len = path.remote.addrlen;
                @memcpy(std.mem.asBytes(&self.close_remote)[0..path.remote.addrlen], @as([*]const u8, @ptrCast(path.remote.addr))[0..path.remote.addrlen]);
                self.repeatClose();
            }
            fn repeatClose(self: *Peer) void {
                if (self.close_len == 0 or self.termination.phase != .closing) return;
                // Cache the exact terminal packet. No further normal ngtcp2
                // reads/writes occur after a fatal library error.
                _ = c.sendto(self.owner.fd, &self.close_packet, self.close_len, c.MSG_DONTWAIT, @ptrCast(&self.close_remote), self.close_remote_len);
            }
            fn send(self: *Peer, bytes: []const u8, path: *const c.ngtcp2_path) !void {
                const size = c.sendto(self.owner.fd, bytes.ptr, bytes.len, c.MSG_DONTWAIT, path.remote.addr, path.remote.addrlen);
                // UDP loss is recovered by ngtcp2's retransmission timer.
                if (size < 0 and std.posix.errno(size) != .AGAIN) return error.SendFailed;
            }
            fn tick(self: *Peer) !void {
                const allocator = self.memory.allocator();
                if (self.failed) return;
                const time = now();
                if (c.ngtcp2_conn_get_expiry(self.quic) <= time) {
                    const result = c.ngtcp2_conn_handle_expiry(self.quic, time);
                    if (result != 0) {
                        self.last_error = result;
                        self.silent = result == c.NGTCP2_ERR_IDLE_CLOSE;
                        return error.QuicExpired;
                    }
                }
                if (self.codec) |*codec| {
                    if (self.graceful and !self.goaway_sent and time >= self.goaway_deadline) {
                        if (c.nghttp3_conn_shutdown(codec.native) != 0) return error.Http3Failed;
                        self.goaway_sent = true;
                    }
                    var it = self.streams.iterator();
                    var retired: std.ArrayList(i64) = .empty;
                    defer retired.deinit(allocator);
                    while (it.next()) |entry| {
                        const stream = entry.value_ptr;
                        if (stream.closed) {
                            if (!try shared.finishCancelledRequest(self.owner.server, stream.request)) continue;
                            c.ngtcp2_conn_extend_max_offset(self.quic, stream.request.uncredited_body);
                            stream.request.uncredited_body = 0;
                            try retired.append(allocator, entry.key_ptr.*);
                            continue;
                        }
                        const request = stream.request;
                        if (!request.headers_ready) continue;
                        request.response_paused = stream.body.bytes >= 256 * 1024;
                        try shared.progressRequest(allocator, self.owner.server, request);
                        if (request.consumed_body != 0) {
                            self.credit(entry.key_ptr.*, request.consumed_body);
                            request.uncredited_body -= request.consumed_body;
                            request.consumed_body = 0;
                        }
                        if (request.response.body.items.len != 0) {
                            const chunk = try request.response.body.toOwnedSlice(allocator);
                            errdefer allocator.free(chunk);
                            try stream.body.append(allocator, chunk);
                        }
                        if (stream.submitted) {
                            if (stream.blocked and (stream.body.bytes != 0 or request.response_done)) {
                                if (c.nghttp3_conn_resume_stream(codec.native, entry.key_ptr.*) != 0) return error.Http3Failed;
                                stream.blocked = false;
                            }
                        } else {
                            if (!request.response.ready) continue;
                            var status: [3]u8 = undefined;
                            const status_text = try std.fmt.bufPrint(&status, "{d}", .{request.response.status});
                            var fields: std.ArrayList(c.nghttp3_nv) = .empty;
                            defer fields.deinit(allocator);
                            try fields.append(allocator, nv(":status", status_text));
                            for (request.response.headers.items) |header| {
                                if (std.ascii.eqlIgnoreCase(header.name, "connection") or std.ascii.eqlIgnoreCase(header.name, "transfer-encoding") or std.ascii.eqlIgnoreCase(header.name, "keep-alive") or std.ascii.eqlIgnoreCase(header.name, "upgrade")) continue;
                                try fields.append(allocator, nv(header.name, header.value));
                            }
                            var reader: c.nghttp3_data_reader = .{ .read_data = readBody };
                            if (c.nghttp3_conn_submit_response(codec.native, entry.key_ptr.*, fields.items.ptr, fields.items.len, &reader) != 0) return error.Http3Failed;
                            stream.submitted = true;
                        }
                    }
                    for (retired.items) |id| {
                        var stream = self.streams.fetchRemove(id).?.value;
                        if (stream.request.request_id) |request_id| self.owner.server.discardRequest(request_id);
                        stream.body.deinit(allocator);
                        stream.request.deinit();
                    }
                    // Flush the final GOAWAY before terminating on the next tick.
                    if (self.goaway_sent and c.nghttp3_conn_is_drained(codec.native) != 0 and time >= self.goaway_deadline +| 100_000_000) {
                        self.beginTermination();
                        return;
                    }
                }
                // Limit output per connection to preserve fairness.
                for (0..32) |_| {
                    var vectors: [16]c.nghttp3_vec = undefined;
                    var stream: i64 = -1;
                    var fin = false;
                    var count: usize = 0;
                    if (self.codec) |*codec| {
                        const output = try codec.output(&vectors);
                        stream = output.stream;
                        fin = output.fin;
                        count = output.vectors.len;
                    }
                    var path = self.networkPath();
                    var info = std.mem.zeroes(c.ngtcp2_pkt_info);
                    var output: [1350]u8 = undefined;
                    var accepted: c.ngtcp2_ssize = -1;
                    const flags: u32 = if (fin) c.NGTCP2_WRITE_STREAM_FLAG_FIN else 0;
                    const size = c.ngtcp2_conn_writev_stream(self.quic, &path, &info, &output, output.len, &accepted, flags, stream, @as([*c]const c.ngtcp2_vec, @ptrCast(&vectors)), count, time);
                    if (size == c.NGTCP2_ERR_STREAM_DATA_BLOCKED) {
                        if (self.codec) |*codec| c.nghttp3_conn_block_stream(codec.native, stream);
                        continue;
                    }
                    if (size == c.NGTCP2_ERR_STREAM_SHUT_WR) {
                        if (self.codec) |*codec| c.nghttp3_conn_shutdown_stream_write(codec.native, stream);
                        continue;
                    }
                    if (size < 0) {
                        self.last_error = @intCast(size);
                        return error.QuicFailed;
                    }
                    if (accepted >= 0) if (self.codec) |*codec| try codec.wrote(stream, @intCast(accepted));
                    if (size == 0) break;
                    try self.send(output[0..@intCast(size)], &path);
                }
                c.ngtcp2_conn_update_pkt_tx_time(self.quic, time);
            }
            fn nv(name: []const u8, value: []const u8) c.nghttp3_nv {
                return .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = c.NGHTTP3_NV_FLAG_NONE };
            }
            fn getConn(ref: [*c]c.ngtcp2_crypto_conn_ref) callconv(.c) ?*c.ngtcp2_conn {
                return selfFrom(Peer, ref.*.user_data).quic;
            }
            fn newCid(_: ?*c.ngtcp2_conn, cid: [*c]c.ngtcp2_cid, token: [*c]u8, len: usize, _: ?*anyopaque) callconv(.c) c_int {
                cid.*.datalen = len;
                _ = c.RAND_bytes(@ptrCast(&cid.*.data), len);
                _ = c.RAND_bytes(token, c.NGTCP2_STATELESS_RESET_TOKENLEN);
                return 0;
            }
            fn txKey(_: ?*c.ngtcp2_conn, level: c.ngtcp2_encryption_level, context: ?*anyopaque) callconv(.c) c_int {
                if (level != c.NGTCP2_ENCRYPTION_LEVEL_1RTT) return 0;
                const self = selfFrom(Peer, context);
                self.setupHttp3() catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
                return 0;
            }
            fn setupHttp3(self: *Peer) !void {
                if (self.codec != null) return;
                var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
                callbacks.begin_headers = beginHeaders;
                callbacks.recv_header = recvHeader;
                callbacks.acked_stream_data = acknowledgedBody;
                callbacks.end_headers = endHeaders;
                callbacks.recv_data = data;
                callbacks.deferred_consume = consumed;
                callbacks.end_stream = endStream;
                callbacks.stream_close = httpClosed;
                callbacks.stop_sending = stopSending;
                callbacks.reset_stream = resetStream;
                self.codec = try h3.Connection.initServerWithMemory(&callbacks, self, &self.http_memory);
                c.nghttp3_conn_set_max_client_streams_bidi(self.codec.?.native, 100);
                var ids: [3]i64 = undefined;
                for (&ids) |*id| if (c.ngtcp2_conn_open_uni_stream(self.quic, id, null) != 0) return error.StreamLimit;
                try self.codec.?.bindStreams(ids[0], ids[1], ids[2]);
            }
            fn credit(self: *Peer, stream: i64, len: usize) void {
                _ = c.ngtcp2_conn_extend_max_stream_offset(self.quic, stream, len);
                c.ngtcp2_conn_extend_max_offset(self.quic, len);
            }
            fn recvStream(_: ?*c.ngtcp2_conn, flags: u32, stream: i64, _: u64, bytes: [*c]const u8, len: usize, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                if (self.codec) |*codec| {
                    const count = codec.receive(stream, bytes[0..len], flags & c.NGTCP2_STREAM_DATA_FLAG_FIN != 0, now()) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
                    self.credit(stream, count);
                    return 0;
                }
                return c.NGTCP2_ERR_CALLBACK_FAILURE;
            }
            fn acked(_: ?*c.ngtcp2_conn, stream: i64, _: u64, len: u64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                if (self.codec) |*codec| codec.acknowledged(stream, len) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
                return 0;
            }
            fn extendedStreams(_: ?*c.ngtcp2_conn, count: u64, context: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                if (self.codec) |*codec| c.nghttp3_conn_set_max_client_streams_bidi(codec.native, count);
                return 0;
            }
            fn unblocked(_: ?*c.ngtcp2_conn, stream: i64, _: u64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                if (self.codec) |*codec| if (c.nghttp3_conn_unblock_stream(codec.native, stream) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
                return 0;
            }
            fn quicClosed(_: ?*c.ngtcp2_conn, _: u32, stream: i64, code: u64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                if (self.codec) |*codec| {
                    const result = c.nghttp3_conn_close_stream(codec.native, stream, code);
                    if (result != 0 and result != c.NGHTTP3_ERR_STREAM_NOT_FOUND) return c.NGTCP2_ERR_CALLBACK_FAILURE;
                }
                return 0;
            }
            fn quicReset(_: ?*c.ngtcp2_conn, stream: i64, _: u64, _: u64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                if (self.codec) |*codec| if (c.nghttp3_conn_shutdown_stream_read(codec.native, stream) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
                return 0;
            }
            fn quicStopSending(conn: ?*c.ngtcp2_conn, stream: i64, code: u64, context: ?*anyopaque, stream_context: ?*anyopaque) callconv(.c) c_int {
                return quicReset(conn, stream, 0, code, context, stream_context);
            }
            fn beginHeaders(_: ?*c.nghttp3_conn, stream: i64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                const allocator = self.memory.allocator();
                if (self.streams.contains(stream)) return 0;
                if (self.streams.count() >= 100) return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                const request = allocator.create(shared.Request) catch return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                request.* = .{ .allocator = allocator, .protocol = "HTTP/3" };
                self.streams.put(stream, .{ .request = request }) catch {
                    request.deinit();
                    return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                };
                return 0;
            }
            fn recvHeader(_: ?*c.nghttp3_conn, stream: i64, _: i32, name: ?*c.nghttp3_rcbuf, value: ?*c.nghttp3_rcbuf, _: u8, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                const state = self.streams.getPtr(stream) orelse return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                const n = c.nghttp3_rcbuf_get_buf(name);
                const v = c.nghttp3_rcbuf_get_buf(value);
                self.addHeader(state.request, n.base[0..n.len], v.base[0..v.len]) catch return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                return 0;
            }
            fn addHeader(self: *Peer, request: *shared.Request, name: []const u8, value: []const u8) !void {
                const allocator = self.memory.allocator();
                const owned = try allocator.dupe(u8, value);
                errdefer allocator.free(owned);
                const target: ?*[]u8 = if (std.mem.eql(u8, name, ":method")) &request.method else if (std.mem.eql(u8, name, ":scheme")) &request.scheme else if (std.mem.eql(u8, name, ":authority")) &request.authority else if (std.mem.eql(u8, name, ":path")) &request.path else null;
                if (target) |field| {
                    allocator.free(field.*);
                    field.* = owned;
                } else {
                    const owned_name = try allocator.dupe(u8, name);
                    errdefer allocator.free(owned_name);
                    try request.headers.append(allocator, .{ .name = owned_name, .value = owned });
                }
            }
            fn endHeaders(_: ?*c.nghttp3_conn, stream: i64, _: c_int, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                if (self.streams.getPtr(stream)) |state| state.request.headers_ready = true;
                return 0;
            }
            fn acknowledgedBody(_: ?*c.nghttp3_conn, stream: i64, count: u64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                const allocator = self.memory.allocator();
                const state = self.streams.getPtr(stream) orelse return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                state.body.acknowledge(allocator, @intCast(count)) catch return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                return 0;
            }
            fn data(_: ?*c.nghttp3_conn, stream: i64, bytes: [*c]const u8, len: usize, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                const allocator = self.memory.allocator();
                const state = self.streams.getPtr(stream) orelse return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                if (len > 32 * 1024 * 1024 -| state.request.body.items.len) return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                state.request.body.appendSlice(allocator, bytes[0..len]) catch return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                state.request.uncredited_body += len;
                return 0;
            }
            fn consumed(_: ?*c.nghttp3_conn, stream: i64, len: usize, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                selfFrom(Peer, context).credit(stream, len);
                return 0;
            }
            fn endStream(_: ?*c.nghttp3_conn, stream: i64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                if (self.streams.getPtr(stream)) |state| state.request.ended = true;
                return 0;
            }
            fn httpClosed(_: ?*c.nghttp3_conn, stream: i64, _: u64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                if (self.streams.getPtr(stream)) |state| state.closed = true;
                if (stream & 3 == 0) c.ngtcp2_conn_extend_max_streams_bidi(self.quic, 1);
                return 0;
            }
            fn stopSending(_: ?*c.nghttp3_conn, stream: i64, code: u64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                return if (c.ngtcp2_conn_shutdown_stream_read(self.quic, 0, stream, code) == 0) 0 else c.NGHTTP3_ERR_CALLBACK_FAILURE;
            }
            fn resetStream(_: ?*c.nghttp3_conn, stream: i64, code: u64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
                const self = selfFrom(Peer, context);
                return if (c.ngtcp2_conn_shutdown_stream_write(self.quic, 0, stream, code) == 0) 0 else c.NGHTTP3_ERR_CALLBACK_FAILURE;
            }
            fn readBody(_: ?*c.nghttp3_conn, stream: i64, vectors: [*c]c.nghttp3_vec, _: usize, flags: [*c]u32, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c.nghttp3_ssize {
                const self = selfFrom(Peer, context);
                const state = self.streams.getPtr(stream) orelse return c.NGHTTP3_ERR_CALLBACK_FAILURE;
                if (state.body.next()) |body| {
                    vectors[0] = .{ .base = body.ptr, .len = body.len };
                    return 1;
                }
                if (state.request.response_done) {
                    flags.* |= c.NGHTTP3_DATA_FLAG_EOF;
                    return 0;
                }
                state.blocked = true;
                return c.NGHTTP3_ERR_WOULDBLOCK;
            }
        };
    };
}

// Do not let datagram truncation reach the native decoder's preconditions.
fn packetVersion(packet: []const u8) ?c.ngtcp2_version_cid {
    if (packet.len == 0) return null;
    var version: c.ngtcp2_version_cid = undefined;
    if (c.ngtcp2_pkt_decode_version_cid(&version, packet.ptr, packet.len, 16) != 0) return null;
    return version;
}

test "UDP routing rejects empty and truncated datagrams before native assertions" {
    const short = [_]u8{0x40} ++ [_]u8{0} ** 16;
    for (0..short.len) |length| try std.testing.expect(packetVersion(short[0..length]) == null);
    const decoded = packetVersion(&short).?;
    try std.testing.expectEqual(@as(usize, 16), decoded.dcidlen);
    try std.testing.expectEqualSlices(u8, short[1..], decoded.dcid[0..decoded.dcidlen]);
    const invalid_long = [_]u8{0xff} ** 1200;
    try std.testing.expect(packetVersion(&invalid_long) == null);
}

test "QUIC closing retention expires at three PTOs without deadline extension" {
    var state: Termination = .{};
    try std.testing.expect(!state.expired(std.math.maxInt(u64)));
    state.begin(100, 10, false);
    try std.testing.expectEqual(@as(u64, 130), state.deadline);
    try std.testing.expect(state.reply(100, 100, 40));
    try std.testing.expect(!state.reply(119, 100, 40));
    try std.testing.expect(state.reply(120, 100, 40));
    state.begin(120, 50, false);
    try std.testing.expectEqual(@as(u64, 130), state.deadline);
    try std.testing.expect(!state.reply(121, 100, 40));
    try std.testing.expect(!state.expired(129));
    try std.testing.expect(state.expired(130));
    try std.testing.expect(!state.reply(130, 100, 40));
}

test "QUIC draining is silent throughout retention" {
    var state: Termination = .{};
    state.begin(1, 4, true);
    for (0..20) |time| try std.testing.expect(!state.reply(time, 100, 40));
    try std.testing.expect(!state.expired(12));
    try std.testing.expect(state.expired(13));
}

test "QUIC closing arithmetic saturates instead of wrapping deadlines" {
    var state: Termination = .{};
    state.begin(std.math.maxInt(u64) - 2, std.math.maxInt(u64), false);
    try std.testing.expectEqual(std.math.maxInt(u64), state.deadline);
    try std.testing.expect(!state.expired(std.math.maxInt(u64) - 1));
}

test "closing address check ignores padding and rejects a different peer" {
    var first = std.mem.zeroes(c.sockaddr_storage);
    var second = std.mem.zeroes(c.sockaddr_storage);
    const a: *c.sockaddr_in = @ptrCast(@alignCast(&first));
    const b: *c.sockaddr_in = @ptrCast(@alignCast(&second));
    a.sin_family = c.AF_INET;
    a.sin_port = 1234;
    a.sin_addr.s_addr = 0x0100007f;
    b.* = a.*;
    @memset(&b.sin_zero, 255);
    try std.testing.expect(sameAddress(&first, &second));
    b.sin_port += 1;
    try std.testing.expect(!sameAddress(&first, &second));
    b.sin_port = a.sin_port;
    b.sin_addr.s_addr += 1;
    try std.testing.expect(!sameAddress(&first, &second));
}

test "QUIC closing replies enforce a cumulative amplification budget" {
    var state: Termination = .{};
    state.begin(0, 10, false);
    try std.testing.expect(!state.reply(0, 10, 40));
    try std.testing.expect(state.reply(0, 4, 40));
    try std.testing.expect(!state.reply(20, 0, 40));
    try std.testing.expect(state.reply(20, 13, 40));
    try std.testing.expectEqual(@as(u64, 80), state.replied_bytes);
    try std.testing.expectEqual(@as(u64, 27), state.received_bytes);
}

test "retired QUIC IDs match original and rotated IDs without prefix matches" {
    const R = Runtime(struct {});
    var saved = std.mem.zeroes(R.Tombstone);
    saved.count = 2;
    saved.ids[0].datalen = 4;
    @memcpy(saved.ids[0].data[0..4], "orig");
    saved.ids[1].datalen = 7;
    @memcpy(saved.ids[1].data[0..7], "rotated");
    try std.testing.expect(saved.matches("orig"));
    try std.testing.expect(saved.matches("rotated"));
    try std.testing.expect(!saved.matches("ori"));
    try std.testing.expect(!saved.matches("original"));
    try std.testing.expect(!saved.matches(""));
}

test "UDP group purges expired closing IDs while preserving live draining IDs" {
    const R = Runtime(struct {});
    var group: R.Group = .{ .fd = -1, .local = std.mem.zeroes(c.sockaddr_storage), .v6_only = 0, .shared_listener = true };
    defer group.mutex.deinit();
    group.tombstone_count = 3;
    for (group.tombstones[0..3]) |*saved| {
        saved.* = std.mem.zeroes(R.Tombstone);
        saved.termination.phase = .closing;
    }
    group.tombstones[1].termination.phase = .draining;
    group.tombstones[1].termination.deadline = std.math.maxInt(u64);
    group.purge();
    try std.testing.expectEqual(@as(usize, 1), group.tombstone_count);
    try std.testing.expectEqual(Termination{ .phase = .draining, .deadline = std.math.maxInt(u64) }, group.tombstones[0].termination);
    group.tombstones[0].termination.deadline = 0;
    group.purge();
    try std.testing.expectEqual(@as(usize, 0), group.tombstone_count);
}

test "UDP registry mutex serializes native callers" {
    const Counter = struct {
        mutex: Mutex = .{},
        value: usize = 0,
        fn increment(self: *@This()) void {
            for (0..1000) |_| {
                self.mutex.lock();
                self.value += 1;
                self.mutex.unlock();
            }
        }
    };
    var counter: Counter = .{};
    defer counter.mutex.deinit();
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Counter.increment, .{&counter});
        started += 1;
    }
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 4000), counter.value);
}

test "QUIC peer address identity includes IPv6 scope and ignores flow labels" {
    var first = std.mem.zeroes(c.sockaddr_storage);
    var second = std.mem.zeroes(c.sockaddr_storage);
    const a: *c.sockaddr_in6 = @ptrCast(@alignCast(&first));
    const b: *c.sockaddr_in6 = @ptrCast(@alignCast(&second));
    a.sin6_family = c.AF_INET6;
    a.sin6_port = 443;
    a.sin6_scope_id = 2;
    @memset(std.mem.asBytes(&a.sin6_addr), 0x12);
    b.* = a.*;
    b.sin6_flowinfo = 999;
    try std.testing.expect(sameAddress(&first, &second));
    b.sin6_scope_id = 3;
    try std.testing.expect(!sameAddress(&first, &second));
    b.* = a.*;
    b.sin6_port += 1;
    try std.testing.expect(!sameAddress(&first, &second));
    b.* = a.*;
    std.mem.asBytes(&b.sin6_addr)[15] ^= 1;
    try std.testing.expect(!sameAddress(&first, &second));
    b.* = a.*;
    b.sin6_family = c.AF_INET;
    try std.testing.expect(!sameAddress(&first, &second));
    first.ss_family = c.AF_UNSPEC;
    second.ss_family = c.AF_UNSPEC;
    try std.testing.expect(!sameAddress(&first, &second));
}

test "QUIC long header routing extracts exact destination and source IDs" {
    const packet = [_]u8{ 0xc0, 0, 0, 0, 1, 4, 'd', 'e', 's', 't', 3, 's', 'r', 'c' };
    for (0..packet.len) |length| try std.testing.expect(packetVersion(packet[0..length]) == null);
    const version = packetVersion(&packet).?;
    try std.testing.expectEqual(@as(u32, 1), version.version);
    try std.testing.expectEqualStrings("dest", version.dcid[0..version.dcidlen]);
    try std.testing.expectEqualStrings("src", version.scid[0..version.scidlen]);
}

test "QUIC zero PTO still has bounded retention and zero replies spend no budget" {
    var state: Termination = .{};
    try std.testing.expect(!state.reply(0, 10, 3));
    state.begin(10, 0, false);
    try std.testing.expectEqual(@as(u64, 13), state.deadline);
    try std.testing.expect(!state.reply(10, 100, 0));
    try std.testing.expectEqual(@as(u64, 0), state.received_bytes);
    try std.testing.expect(state.reply(10, 1, 3));
    try std.testing.expect(!state.reply(11, 1, 3));
    try std.testing.expect(state.reply(12, 1, 3));
    try std.testing.expect(!state.reply(13, 1000, 3));
    state.begin(100, 100, true);
    try std.testing.expectEqual(@as(u64, 13), state.deadline);
}
