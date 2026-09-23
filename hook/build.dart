import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_prebuilt/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';
import 'package:native_toolchain_zig/native_toolchain_zig.dart';
import 'package:server_native/src/generated/server_native_prebuilts.g.dart';

const _assetName = 'src/ffi.g.dart';
const _cratePath = 'native';
const _zigAssetName = 'src/zig_ffi.g.dart';
const _zigDir = 'zig';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    await PrebuiltCodeAssetBuilder(
      assetName: _assetName,
      libraryStem: 'server_native',
      manifest: serverNativePrebuilts,
      linkModeResolver: (_) => DynamicLoadingBundled(),
      // A workspace checkout must exercise the current Rust sources. Published
      // packages use native_prebuilt's verified release/cache resolution.
      resolvers: _isWorkspaceCheckout(input.packageRoot)
          ? const <PrebuiltResolver>[]
          : null,
      sourceFallback: SourceFallback(
        sources: const [
          LocalSource(paths: <String>['.']),
        ],
        builder: HookBuilderSourceBuilder.factory(
          (_, _) =>
              const RustBuilder(assetName: _assetName, cratePath: _cratePath),
        ),
      ),
    ).run(input: input, output: output, logger: null);

    await ZigBuilder(
      assetName: _zigAssetName,
      zigDir: _zigDir,
    ).run(input: input, output: output, logger: null);
  });
}

bool _isWorkspaceCheckout(Uri packageRoot) {
  final packageDirectory = Directory.fromUri(packageRoot).absolute;
  final hasGitMetadata =
      Directory('${packageDirectory.path}/.git').existsSync() ||
      File('${packageDirectory.path}/.git').existsSync();
  if (hasGitMetadata &&
      File('${packageDirectory.path}/native/Cargo.toml').existsSync()) {
    return true;
  }

  var directory = packageDirectory;
  while (true) {
    final hasPackages = Directory('${directory.path}/packages').existsSync();
    if (File('${directory.path}/pubspec.yaml').existsSync() && hasPackages) {
      return true;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) return false;
    directory = parent;
  }
}
