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
  final directory = Directory.fromUri(packageRoot).absolute;
  return File('${directory.path}/.git').existsSync() ||
      Directory('${directory.path}/.git').existsSync();
}
