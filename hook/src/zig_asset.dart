import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_prebuilt/hooks.dart';
import 'package:native_toolchain_zig/native_toolchain_zig.dart';
import 'package:server_native/src/generated/server_native_zig_prebuilts.g.dart'
    as zig_prebuilt;

const _zigAssetName = 'src/zig_ffi.g.dart';
const _zigLibraryName = 'server_native_zig';

Future<void> buildZigAsset(
  BuildInput input,
  BuildOutputBuilder output, {
  required bool sourceCheckout,
}) async {
  await PrebuiltCodeAssetBuilder(
    assetName: _zigAssetName,
    libraryStem: _zigLibraryName,
    manifest: zig_prebuilt.server_nativePrebuilts,
    linkModeResolver: (_) => DynamicLoadingBundled(),
    resolvers: sourceCheckout ? const <PrebuiltResolver>[] : null,
    sourceFallback: SourceFallback(
      sources: const [
        LocalSource(paths: <String>['.']),
      ],
      builder: HookBuilderSourceBuilder.factory(
        (_, _) => const ZigBuilder(
          assetName: _zigAssetName,
          zigDir: 'zig',
          libraryName: _zigLibraryName,
        ),
      ),
    ),
  ).run(input: input, output: output, logger: null);
}
