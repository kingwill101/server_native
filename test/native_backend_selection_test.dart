import 'package:server_native/src/native/server_native_transport.dart';
import 'package:test/test.dart';

void main() {
  test('selected backend exposes a compatible transport ABI', () {
    expect(transportAbiVersion(), greaterThanOrEqualTo(1));
  });
}
