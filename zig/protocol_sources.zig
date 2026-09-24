// Source lists from the pinned upstream lib/CMakeLists.txt files.
pub const nghttp2 = &[_][]const u8{
    "nghttp2_pq.c",
    "nghttp2_map.c",
    "nghttp2_queue.c",
    "nghttp2_frame.c",
    "nghttp2_buf.c",
    "nghttp2_stream.c",
    "nghttp2_outbound_item.c",
    "nghttp2_session.c",
    "nghttp2_submit.c",
    "nghttp2_helper.c",
    "nghttp2_alpn.c",
    "nghttp2_hd.c",
    "nghttp2_hd_huffman.c",
    "nghttp2_hd_huffman_data.c",
    "nghttp2_version.c",
    "nghttp2_priority_spec.c",
    "nghttp2_option.c",
    "nghttp2_callbacks.c",
    "nghttp2_mem.c",
    "nghttp2_http.c",
    "nghttp2_rcbuf.c",
    "nghttp2_extpri.c",
    "nghttp2_ratelim.c",
    "nghttp2_time.c",
    "nghttp2_debug.c",
    "sfparse.c",
};
pub const ngtcp2 = &[_][]const u8{
    "ngtcp2_pkt.c",
    "ngtcp2_conv.c",
    "ngtcp2_str.c",
    "ngtcp2_vec.c",
    "ngtcp2_buf.c",
    "ngtcp2_conn.c",
    "ngtcp2_mem.c",
    "ngtcp2_pq.c",
    "ngtcp2_map.c",
    "ngtcp2_rob.c",
    "ngtcp2_ppe.c",
    "ngtcp2_crypto.c",
    "ngtcp2_err.c",
    "ngtcp2_range.c",
    "ngtcp2_acktr.c",
    "ngtcp2_rtb.c",
    "ngtcp2_frame_chain.c",
    "ngtcp2_strm.c",
    "ngtcp2_idtr.c",
    "ngtcp2_gaptr.c",
    "ngtcp2_ringbuf.c",
    "ngtcp2_log.c",
    "ngtcp2_qlog.c",
    "ngtcp2_cid.c",
    "ngtcp2_ksl.c",
    "ngtcp2_cc.c",
    "ngtcp2_bbr.c",
    "ngtcp2_addr.c",
    "ngtcp2_path.c",
    "ngtcp2_pv.c",
    "ngtcp2_pmtud.c",
    "ngtcp2_version.c",
    "ngtcp2_rst.c",
    "ngtcp2_wf.c",
    "ngtcp2_opl.c",
    "ngtcp2_balloc.c",
    "ngtcp2_objalloc.c",
    "ngtcp2_unreachable.c",
    "ngtcp2_transport_params.c",
    "ngtcp2_settings.c",
    "ngtcp2_callbacks.c",
    "ngtcp2_dcidtr.c",
    "ngtcp2_pcg.c",
    "ngtcp2_ratelim.c",
    "ngtcp2_conn_info.c",
    "ngtcp2_fmt.c",
};
pub const nghttp3 = &[_][]const u8{
    "nghttp3_rcbuf.c",
    "nghttp3_mem.c",
    "nghttp3_str.c",
    "nghttp3_conv.c",
    "nghttp3_buf.c",
    "nghttp3_ringbuf.c",
    "nghttp3_pq.c",
    "nghttp3_map.c",
    "nghttp3_ksl.c",
    "nghttp3_qpack.c",
    "nghttp3_qpack_huffman.c",
    "nghttp3_qpack_huffman_data.c",
    "nghttp3_err.c",
    "nghttp3_debug.c",
    "nghttp3_conn.c",
    "nghttp3_stream.c",
    "nghttp3_frame.c",
    "nghttp3_tnode.c",
    "nghttp3_vec.c",
    "nghttp3_gaptr.c",
    "nghttp3_idtr.c",
    "nghttp3_range.c",
    "nghttp3_http.c",
    "nghttp3_version.c",
    "nghttp3_balloc.c",
    "nghttp3_opl.c",
    "nghttp3_objalloc.c",
    "nghttp3_unreachable.c",
    "nghttp3_settings.c",
    "nghttp3_callbacks.c",
    "nghttp3_ratelim.c",
    "sfparse/sfparse.c",
};

test "protocol source manifests contain unique relative C files" {
    const std = @import("std");
    inline for (.{ nghttp2, ngtcp2, nghttp3 }) |files| {
        var seen = std.StringHashMap(void).init(std.testing.allocator);
        defer seen.deinit();
        try std.testing.expect(files.len > 0);
        for (files) |path| {
            try std.testing.expect(std.mem.endsWith(u8, path, ".c"));
            try std.testing.expect(!std.fs.path.isAbsolute(path));
            var components = std.mem.splitScalar(u8, path, '/');
            while (components.next()) |component| {
                try std.testing.expect(component.len != 0 and !std.mem.eql(u8, component, ".."));
            }
            try std.testing.expect(!(try seen.getOrPut(path)).found_existing);
        }
    }
}
