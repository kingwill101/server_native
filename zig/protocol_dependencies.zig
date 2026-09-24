const std = @import("std");
const sources = @import("protocol_sources.zig");

/// Attach the pinned protocol libraries and crypto adapter to a consumer.
/// BoringSSL supplies TLS and the ngtcp2 crypto adapter.
pub fn attach(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const *std.Build.Step.Compile {
    var libraries: std.ArrayList(*std.Build.Step.Compile) = .empty;
    inline for (.{ "nghttp2", "ngtcp2", "nghttp3" }, .{ "1.70.0", "1.25.0", "1.18.0" }, .{ "0x014600", "0x011900", "0x011200" }) |name, version, number| {
        if (b.lazyDependency(name, .{})) |dep| {
            const lib = b.addLibrary(.{ .name = name, .linkage = .static, .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .pic = true,
            }) });
            const header = if (comptime std.mem.eql(u8, name, "nghttp2")) "nghttp2ver.h" else "version.h";
            const config_path = comptime "lib/includes/" ++ name ++ "/" ++ header ++ ".in";
            const config = b.addConfigHeader(.{
                .style = .{ .cmake = dep.path(config_path) },
                .include_path = comptime name ++ "/" ++ header,
            }, .{ .PACKAGE_VERSION = version, .PACKAGE_VERSION_NUM = number });
            lib.root_module.addConfigHeader(config);
            mod.addConfigHeader(config);
            lib.root_module.addIncludePath(dep.path("lib/includes"));
            mod.addIncludePath(dep.path("lib/includes"));
            configureC(lib.root_module, target);
            lib.root_module.addCMacro("BUILDING_" ++ comptime upper(name), "1");
            lib.root_module.addCMacro(comptime upper(name) ++ "_STATICLIB", "1");
            mod.addCMacro(comptime upper(name) ++ "_STATICLIB", "1");
            lib.root_module.addCSourceFiles(.{ .root = dep.path("lib"), .files = @field(sources, name), .flags = &.{"-std=c11"} });
            mod.linkLibrary(lib);
            libraries.append(b.allocator, lib) catch @panic("OOM");
        }
    }
    if (b.lazyDependency("ngtcp2", .{})) |dep| {
        configureC(mod, target);
        mod.addIncludePath(dep.path("lib"));
        mod.addIncludePath(dep.path("crypto"));
        mod.addIncludePath(dep.path("crypto/includes"));
        mod.addCSourceFiles(.{ .root = dep.path("crypto"), .files = &.{ "boringssl/boringssl.c", "shared.c" }, .flags = &.{"-std=c11"} });
    }
    if (b.lazyDependency("boringssl", .{ .target = target, .optimize = optimize })) |dep| {
        inline for (.{ "ssl", "crypto", "bcm" }) |name| {
            const artifact = dep.artifact(name);
            artifact.root_module.pic = true;
            mod.linkLibrary(artifact);
            libraries.append(b.allocator, artifact) catch @panic("OOM");
        }
        mod.addIncludePath(dep.namedLazyPath("ssl_include"));
    }
    return libraries.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn configureC(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .windows => {
            inline for (.{ "WIN32", "HAVE_WINDOWS_H", "HAVE_GETTICKCOUNT64" }) |name| mod.addCMacro(name, "1");
        },
        else => {
            inline for (.{ "HAVE_ARPA_INET_H", "HAVE_NETINET_IN_H", "HAVE_CLOCK_GETTIME", "HAVE_DECL_CLOCK_MONOTONIC" }) |name| mod.addCMacro(name, "1");
            if (target.result.os.tag == .linux) mod.addCMacro("_DEFAULT_SOURCE", "1");
        },
    }
    if (target.result.cpu.arch.endian() == .big) mod.addCMacro("WORDS_BIGENDIAN", "1");
}

fn upper(comptime name: []const u8) []const u8 {
    comptime var result: [name.len]u8 = undefined;
    inline for (name, 0..) |char, i| result[i] = std.ascii.toUpper(char);
    return &result;
}
