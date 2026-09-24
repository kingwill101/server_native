import 'dart:io';

import 'package:test/test.dart';

import 'support/udp_binding_probe.dart';

void main() {
  test('UDP release probe rejects a socket retained by this process', () async {
    final socket = await RawDatagramSocket.bind('127.0.0.1', 0);
    final probe = UdpBindingProbe.capture(socket.port);
    try {
      await expectLater(
        probe.rebind('127.0.0.1'),
        throwsA(predicate((error) => '$error'.contains('still owns UDP port'))),
      );
    } finally {
      final closed = socket.drain<void>();
      socket.close();
      await closed;
    }
  }, skip: !Platform.isLinux ? 'Linux descriptor ownership check' : false);

  test(
    'UDP release probe accepts a closed socket and exclusive rebind',
    () async {
      final socket = await RawDatagramSocket.bind('127.0.0.1', 0);
      final probe = UdpBindingProbe.capture(socket.port);
      final closed = socket.drain<void>();
      socket.close();
      await closed;
      final rebound = await probe.rebind('127.0.0.1');
      expect(rebound.port, probe.port);
      final reboundClosed = rebound.drain<void>();
      rebound.close();
      await reboundClosed;
    },
  );
}
