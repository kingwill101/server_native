import 'dart:io';

import 'package:ffigen/ffigen.dart';

/// Generate the configuration layout from the Zig runtime's C ABI header.
Future<void> main() async {
  final packageRoot = Platform.script.resolve('../');
  FfiGenerator(
    headers: Headers(
      entryPoints: [packageRoot.resolve('zig/include/server_native_abi.h')],
    ),
    output: Output(
      dartFile: packageRoot.resolve('lib/src/native/proxy_config.g.dart'),
    ),
    functions: Functions.includeSet({}),
    structs: Structs.includeSet({'ServerNativeProxyConfig'}),
  ).generate();
}
