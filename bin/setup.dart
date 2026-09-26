/// Downloads and verifies the package-matched Linux prebuilt library.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:native_prebuilt/native_prebuilt.dart';
import 'package:server_native/src/generated/server_native_zig_prebuilts.g.dart';

Future<void> main(List<String> args) async {
  String? platform;
  final release = server_nativePrebuilts.release as GitHubReleaseSource;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--help' || '-h':
        stdout.writeln(
          'Usage: dart run server_native:setup '
          '[--platform linux-x64|linux-arm64]\n'
          'Downloads checksum-verified artifacts for ${release.tag}.\n'
          'Published-package build hooks also download them automatically.',
        );
        return;
      case '--platform' || '-p':
        if (++i >= args.length) throw ArgumentError('Missing platform');
        platform = args[i];
      case '--tag' || '-t':
        if (++i >= args.length || args[i] != release.tag) {
          throw ArgumentError(
            'Only the package-pinned tag ${release.tag} is '
            'supported; other releases do not match its verified manifest.',
          );
        }
      default:
        throw ArgumentError('Unknown option: ${args[i]}');
    }
  }
  platform ??= switch (Abi.current()) {
    Abi.linuxX64 => 'linux-x64',
    Abi.linuxArm64 => 'linux-arm64',
    _ => throw UnsupportedError('Only Linux x64 and ARM64 are supported'),
  };
  final architecture = switch (platform) {
    'linux-x64' => Architecture.x64,
    'linux-arm64' => Architecture.arm64,
    _ => throw ArgumentError('Unsupported platform: $platform'),
  };
  final library =
      await ArtifactCache(
        cacheDir: Directory('.dart_tool/server_native/prebuilt'),
      ).resolve(
        manifest: server_nativePrebuilts,
        target: NativeTarget(os: OS.linux, architecture: architecture),
        libraryStem: 'server_native_zig',
        payload: const DynamicLibraryPayload(libraryStem: 'server_native_zig'),
      );
  if (library == null) throw StateError('No verified prebuilt for $platform');
  final destination = Directory('.prebuilt/$platform');
  await destination.create(recursive: true);
  final installed = await library.copy(
    '${destination.path}/libserver_native_zig.so',
  );
  stdout.writeln('Verified ${release.tag}: ${installed.path}');
}
