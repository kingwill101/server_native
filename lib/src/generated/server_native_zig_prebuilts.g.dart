// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: constant_identifier_names, depend_on_referenced_packages

import 'package:native_prebuilt/native_prebuilt.dart';

const server_nativePrebuilts = PrebuiltManifest(
  schemaVersion: 2,
  release: GitHubReleaseSource(
    owner: 'kingwill101',
    repository: 'server_native',
    tag: 'server-native-prebuilt-v1.0.0-dev',
  ),
  artifacts: {
    'linux-x64': PrebuiltArtifact(
      archiveName: 'server_native-zig-linux-x64.tar.gz',
      archiveSha256:
          '391d21374e94476e9df8e677a2a9241060dfa2e811bbde7a7d202d62850020eb',
      payloadSha256:
          '41cd7ebc787d1ab1e450c6c162b010b2268611617af454ee07689cb717528ecf',
      payload: DynamicLibraryPayload(
        libraryStem: 'server_native_zig',
        acceptVersionedNames: true,
      ),
    ),
    'linux-arm64': PrebuiltArtifact(
      archiveName: 'server_native-zig-linux-arm64.tar.gz',
      archiveSha256:
          'dda80f6fb4e75f3b3a222d403e36d9034c6bf1a06a75ae1b9b6c44bfc6619720',
      payloadSha256:
          '29a795bce5b35f6912f3ca4572219e4c3123fabdb3962a6dfaf5859a35005729',
      payload: DynamicLibraryPayload(
        libraryStem: 'server_native_zig',
        acceptVersionedNames: true,
      ),
    ),
  },
);
