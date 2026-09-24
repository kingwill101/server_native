import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

/// Checks actual descriptor release before retrying a transient Linux UDP bind.
/// A concurrent fork can retain a CLOEXEC descriptor until the child execs.
final class UdpBindingProbe {
  UdpBindingProbe._(this.port, this._inodes);

  factory UdpBindingProbe.capture(int port) {
    if (!Platform.isLinux) return UdpBindingProbe._(port, const {});
    final own = _socketInodes();
    final matching = <String>{};
    final hexPort = port.toRadixString(16).toUpperCase().padLeft(4, '0');
    for (final table in ['udp', 'udp6']) {
      for (final row in File('/proc/net/$table').readAsLinesSync().skip(1)) {
        final fields = row.trim().split(RegExp(r'\s+'));
        if (fields.length > 9 &&
            fields[1].split(':').last == hexPort &&
            own.contains(fields[9])) {
          matching.add(fields[9]);
        }
      }
    }
    expect(matching, isNotEmpty, reason: 'No owned UDP socket for port $port');
    return UdpBindingProbe._(port, matching);
  }

  final int port;
  final Set<String> _inodes;

  static Set<String> _socketInodes() {
    final result = <String>{};
    for (final entry in Directory(
      '/proc/self/fd',
    ).listSync(followLinks: false)) {
      try {
        final target = Link(entry.path).targetSync();
        if (target.startsWith('socket:[') && target.endsWith(']')) {
          result.add(target.substring(8, target.length - 1));
        }
      } on FileSystemException {
        // Descriptors can disappear while enumerating them.
      }
    }
    return result;
  }

  Future<RawDatagramSocket> rebind(Object address) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      if (Platform.isLinux) {
        expect(
          _socketInodes().intersection(_inodes),
          isEmpty,
          reason:
              'close completed while this process still owns UDP port $port',
        );
      }
      try {
        return await RawDatagramSocket.bind(address, port, reuseAddress: false);
      } on SocketException catch (error) {
        if (!Platform.isLinux ||
            error.osError?.errorCode != 98 ||
            elapsed.elapsed >= const Duration(seconds: 2)) {
          rethrow;
        }
        // Do not hide a leaked native descriptor: ownership is rechecked on
        // every attempt. CLOEXEC does not release a child's pre-exec copy yet.
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }
}
