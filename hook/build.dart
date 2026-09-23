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
const _zigLibraryName = 'server_native_zig';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    await PrebuiltCodeAssetBuilder(
      assetName: _assetName,
      libraryStem: 'server_native',
      manifest: serverNativePrebuilts,
      linkModeResolver: (_) => DynamicLoadingBundled(),
      // Source checkouts exercise the current Rust sources. Published packages
      // use native_prebuilt's verified release/cache resolution.
      resolvers: _isSourceCheckout(input.packageRoot)
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

    await const ZigBuilder(
      assetName: _zigAssetName,
      zigDir: 'zig',
      libraryName: _zigLibraryName,
    ).run(input: input, output: output);
  });
}

bool _isSourceCheckout(Uri packageRoot) {
  var directory = Directory.fromUri(packageRoot).absolute;
  while (true) {
    if (File('${directory.path}/.git').existsSync() ||
        Directory('${directory.path}/.git').existsSync()) {
      return true;
    }
    final hasPackages = Directory('${directory.path}/packages').existsSync();
    if (File('${directory.path}/pubspec.yaml').existsSync() && hasPackages) {
      return true;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) return false;
    directory = parent;
  }
}
