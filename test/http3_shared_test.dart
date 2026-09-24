import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

import 'support/udp_binding_probe.dart';

Future<void> listener((SendPort, String, int, bool) args) async {
  final (parent, name, port, direct) = args;
  final commands = ReceivePort();
  NativeHttpServer? server;
  try {
    server = await NativeHttpServer.bindSecure(
      '127.0.0.1',
      port,
      certificatePath: 'zig/src/testdata/tls-cert.pem',
      keyPath: 'zig/src/testdata/tls-key.pem',
      shared: true,
      http3: true,
      nativeCallback: direct,
    );
    final active = server;
    server.listen((request) async {
      request.response.write(name);
      await request.response.close();
      if (request.uri.path == '/shutdown') {
        Timer(const Duration(milliseconds: 100), () async {
          await active.close(
            force: request.uri.queryParameters['graceful'] != 'true',
          );
        });
      }
    });
    parent.send((server.port, commands.sendPort));
    await commands.first;
  } catch (error, stack) {
    parent.send('$error\n$stack');
  } finally {
    await server?.close(force: true);
    commands.close();
    parent.send('closed');
  }
}

void main() {
  final python = Platform.environment['AIOQUIC_PYTHON'];
  for (final isolated in [false, true]) {
    for (final reverse in [false, true]) {
      test(
        'HTTP/3 shared UDP across isolates=$isolated reverse/graceful=$reverse',
        () async {
          final first = ReceivePort();
          final second = ReceivePort();
          final one = StreamIterator<dynamic>(first);
          final two = StreamIterator<dynamic>(second);
          SendPort? stopOne;
          SendPort? stopTwo;
          Future<void> start((SendPort, String, int, bool) args) async {
            if (isolated) {
              await Isolate.spawn(listener, args);
            } else {
              unawaited(listener(args));
            }
          }

          try {
            await start((first.sendPort, 'one', 0, false));
            expect(await one.moveNext(), isTrue);
            expect(one.current, isA<(int, SendPort)>());
            final (port, stop) = one.current as (int, SendPort);
            stopOne = stop;
            final binding = UdpBindingProbe.capture(port);
            await start((second.sendPort, 'two', port, true));
            expect(await two.moveNext(), isTrue);
            expect(two.current, isA<(int, SendPort)>());
            stopTwo = (two.current as (int, SendPort)).$2;
            final result = await Process.run(python!, [
              'tool/http3_aioquic_client.py',
              '$port',
              reverse ? 'shared-reverse-graceful' : 'shared',
            ]).timeout(const Duration(seconds: 30));
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
            stopOne.send(null);
            stopOne = null;
            stopTwo.send(null);
            stopTwo = null;
            expect(await one.moveNext(), isTrue);
            expect(one.current, 'closed');
            expect(await two.moveNext(), isTrue);
            expect(two.current, 'closed');
            final rebound = await binding.rebind('127.0.0.1');
            rebound.close();
          } finally {
            stopOne?.send(null);
            stopTwo?.send(null);
            await one.cancel();
            await two.cancel();
            first.close();
            second.close();
          }
        },
        skip: python == null ? 'Set AIOQUIC_PYTHON (aioquic==1.3.0)' : false,
        timeout: const Timeout(Duration(seconds: 45)),
      );
    }
  }
}
