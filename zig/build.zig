const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });

    const protocol_libraries = @import("protocol_dependencies.zig").attach(b, root_module, target, optimize);

    root_module.addIncludePath(b.path("include"));
    root_module.addCSourceFile(.{
        .file = b.path("include/dart_api_dl.c"),
        .flags = &.{"-fPIC"},
    });

    const dynamic_lib = b.addLibrary(.{
        .name = "server_native_zig",
        .linkage = .dynamic,
        .root_module = root_module,
    });
    b.installArtifact(dynamic_lib);

    const static_lib = b.addLibrary(.{
        .name = "server_native_zig",
        .linkage = .static,
        .root_module = root_module,
    });
    // Zig does not embed linked static libraries into another static library.
    // Flatten their object members into the distributed archive using Zig's ar.
    const bundle = b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "qcLs" });
    const bundled_archive = bundle.addOutputFileArg(static_lib.out_filename);
    bundle.addFileArg(static_lib.getEmittedBin());
    for (protocol_libraries) |library| bundle.addFileArg(library.getEmittedBin());
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(bundled_archive, .lib, static_lib.out_filename).step);

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_tests.step);

    const static_test_module = b.createModule(.{
        .root_source_file = b.path("src/static_link_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    static_test_module.addObjectFile(bundled_archive);
    const static_tests = b.addTest(.{ .root_module = static_test_module });
    test_step.dependOn(&b.addRunArtifact(static_tests).step);
}
