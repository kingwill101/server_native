# Zig binding generator

Run `python3 tool/generate_zig_bindings.py` from the repository root. The script
resolves this tool package and regenerates `lib/src/zig_ffi.g.dart` from exported
Zig signatures using the vendored Dart API-DL header.

The published `native_toolchain_zig` 0.2.0 builder supports the package build,
but its binding generator still uses Zig 0.15 APIs and lacks `--link-libc`.
This private development package pins the Zig 0.16 generator to the previously
used upstream commit. The main package retains its hosted build dependency;
consumers do not need this Git dependency to build or run the library.

The lockfile here is committed for reproducible generation. Remove this separate
tool package when a released generator supports our Zig version and arguments.
