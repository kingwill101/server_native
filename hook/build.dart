import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'src/zig_asset.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final sourceCheckout = _isSourceCheckout(input.packageRoot);
    await buildZigAsset(input, output, sourceCheckout: sourceCheckout);
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
