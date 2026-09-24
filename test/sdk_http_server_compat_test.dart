import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

/// Parity checks ported from Dart SDK standalone IO tests:
/// - tests/standalone/io/http_server_test.dart
/// - tests/standalone/io/http_bind_test.dart
/// - tests/standalone/io/http_connection_header_test.dart
/// - tests/standalone/io/http_content_length_test.dart

enum _Backend {
  dartIo('dart:io'),
  native('server_native direct'),
  bridge('server_native bridge');

  const _Backend(this.label);
  final String label;
}

Future<HttpServer> _bindServer(
  _Backend backend,
  dynamic address,
  int port, {
  int backlog = 0,
  bool v6Only = false,
  bool shared = false,
}) {
  switch (backend) {
    case _Backend.dartIo:
      return HttpServer.bind(
        address,
        port,
        backlog: backlog,
        v6Only: v6Only,
        shared: shared,
      );
    case _Backend.native:
    case _Backend.bridge:
      return NativeHttpServer.bind(
        address,
        port,
        backlog: backlog,
        v6Only: v6Only,
        shared: shared,
        http3: false,
        nativeCallback: backend == _Backend.native,
      );
  }
}

Future<bool> _supportsIPv6() async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<(int statusCode, HttpHeaders headers, List<int> bodyBytes)> _requestOnce(
  HttpServer server,
) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    final response = await request.close();
    final bodyBytes = await response.fold<List<int>>(
      <int>[],
      (list, chunk) => list..addAll(chunk),
    );
    return (response.statusCode, response.headers, bodyBytes);
  } finally {
    client.close(force: true);
  }
}

Future<HttpHeaders> _fetchHeadersSnapshot(
  _Backend backend, {
  bool clearDefaultHeaders = false,
  Map<String, String>? addDefaultHeaders,
}) async {
  final server = await _bindServer(backend, InternetAddress.loopbackIPv4, 0);
  final sub = server.listen((request) async {
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  });
  try {
    if (clearDefaultHeaders) {
      server.defaultResponseHeaders.clear();
    }
    addDefaultHeaders?.forEach(server.defaultResponseHeaders.set);
    final result = await _requestOnce(server);
    expect(result.$1, HttpStatus.ok);
    return result.$2;
  } finally {
    await sub.cancel();
    await server.close(force: true);
  }
}

Future<List<int>> _fetchBodyBytes(
  _Backend backend, {
  required bool clearDefaultHeaders,
  required String body,
}) async {
  final server = await _bindServer(backend, InternetAddress.loopbackIPv4, 0);
  if (clearDefaultHeaders) {
    server.defaultResponseHeaders.clear();
  }
  final sub = server.listen((request) async {
    request.response.write(body);
    await request.response.close();
  });
  try {
    final result = await _requestOnce(server);
    expect(result.$1, HttpStatus.ok);
    return result.$3;
  } finally {
    await sub.cancel();
    await server.close(force: true);
  }
}

void _setConnectionHeaders(HttpHeaders headers) {
  headers.add(HttpHeaders.connectionHeader, 'my-connection-header1');
  headers.add('My-Connection-Header1', 'some-value1');
  headers.add(HttpHeaders.connectionHeader, 'my-connection-header2');
  headers.add('My-Connection-Header2', 'some-value2');
}

void _checkExpectedConnectionHeaders(
  HttpHeaders headers,
  bool persistentConnection,
) {
  expect(headers.value('My-Connection-Header1'), 'some-value1');
  expect(headers.value('My-Connection-Header2'), 'some-value2');

  final connection = headers[HttpHeaders.connectionHeader] ?? const <String>[];
  expect(
    connection.any((value) => value.toLowerCase() == 'my-connection-header1'),
    isTrue,
  );
  expect(
    connection.any((value) => value.toLowerCase() == 'my-connection-header2'),
    isTrue,
  );

  if (persistentConnection) {
    expect(connection.length, 2);
  } else {
    expect(connection.length, 3);
    expect(connection.any((value) => value.toLowerCase() == 'close'), isTrue);
  }
}

Future<int> _singleRequestStatus(String host, int port) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      'GET',
      Uri.parse('http://${host.contains(':') ? '[$host]' : host}:$port/'),
    );
    final response = await request.close();
    final statusCode = response.statusCode;
    await response.drain<void>();
    return statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<List<String>> _captureEmptyConnectionHeaderValues(
  _Backend backend,
) async {
  final observed = Completer<List<String>>();
  final server = await _bindServer(backend, InternetAddress.loopbackIPv4, 0);
  final sub = server.listen((request) async {
    observed.complete(
      request.headers[HttpHeaders.connectionHeader] ?? const <String>[],
    );
    request.response.headers.set(HttpHeaders.connectionHeader, 'close');
    await request.response.close();
  });

  final socket = await Socket.connect('127.0.0.1', server.port);
  try {
    socket.add(
      ascii.encode(
        'GET / HTTP/1.1\r\n'
        'Host: localhost\r\n'
        'Connection: \r\n'
        '\r\n',
      ),
    );
    await socket.flush();
    await socket.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    return await observed.future.timeout(const Duration(seconds: 3));
  } finally {
    await socket.close();
    await sub.cancel();
    await server.close(force: true);
  }
}

Future<bool> _headCloseCompletesWithContentLengthError(_Backend backend) async {
  final completion = Completer<Object?>();
  final server = await _bindServer(backend, InternetAddress.loopbackIPv4, 0);
  final sub = server.listen((request) async {
    if (request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    request.response.contentLength = 1;
    request.response.done
        .then((_) {
          if (!completion.isCompleted) {
            completion.complete(null);
          }
        })
        .catchError((error) {
          if (!completion.isCompleted) {
            completion.complete(error);
          }
        });

    try {
      await request.response.close();
      if (!completion.isCompleted) {
        completion.complete(null);
      }
    } catch (error) {
      if (!completion.isCompleted) {
        completion.complete(error);
      }
    }
  });

  final client = HttpClient();
  try {
    final request = await client.openUrl(
      'HEAD',
      Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    final response = await request.close();
    await response.drain<void>();
    final outcome = await completion.future.timeout(const Duration(seconds: 3));
    return outcome is HttpException;
  } finally {
    client.close(force: true);
    await sub.cancel();
    await server.close(force: true);
  }
}

void main() {
  group('SDK HttpServer compatibility', () {
    for (final backend in _Backend.values) {
      test(
        '${backend.label}: streamed upload and response preserve metadata',
        () async {
          final server = await _bindServer(
            backend,
            InternetAddress.loopbackIPv4,
            0,
          );
          final sub = server.listen((request) async {
            expect(request.method, 'POST');
            expect(request.uri.path, '/a%20b');
            expect(request.uri.queryParametersAll['q'], ['one', 'two']);
            expect(request.headers['x-test'], ['first, second']);
            expect(request.cookies.single.name, 'session');
            expect(request.cookies.single.value, 'abc');
            final body = await utf8.decoder.bind(request).join();
            request.response.cookies.add(
              Cookie('result', 'ok')..httpOnly = true,
            );
            await request.response.addStream(
              Stream.fromIterable([
                utf8.encode('received:'),
                utf8.encode(body),
              ]),
            );
            await request.response.close();
          });
          final client = HttpClient();
          try {
            final request = await client.postUrl(
              Uri.parse('http://127.0.0.1:${server.port}/a%20b?q=one&q=two'),
            );
            request.headers.add('x-test', 'first');
            request.headers.add('x-test', 'second');
            request.cookies.add(Cookie('session', 'abc'));
            await request.addStream(
              Stream.fromIterable([utf8.encode('hello '), utf8.encode('世界')]),
            );
            final response = await request.close();
            expect(
              await utf8.decoder.bind(response).join(),
              'received:hello 世界',
            );
            expect(response.cookies.single.name, 'result');
            expect(response.cookies.single.httpOnly, isTrue);
          } finally {
            client.close(force: true);
            await sub.cancel();
            await server.close(force: true);
          }
        },
      );

      test(
        '${backend.label}: bodyless responses do not corrupt keep-alive',
        () async {
          final server = await _bindServer(
            backend,
            InternetAddress.loopbackIPv4,
            0,
          );
          final ports = <int>[];
          final sub = server.listen((request) async {
            if (request.method == 'HEAD') {
              request.response.contentLength = 123;
            } else if (request.uri.path == '/204') {
              request.response.statusCode = 204;
            } else if (request.uri.path == '/304') {
              request.response.statusCode = 304;
            } else {
              request.response.write('still alive');
            }
            await request.response.close();
          });
          final client = HttpClient()..maxConnectionsPerHost = 1;
          try {
            for (final entry in [
              ('HEAD', '/', 200),
              ('GET', '/204', 204),
              ('GET', '/304', 304),
              ('GET', '/final', 200),
            ]) {
              final request = await client.openUrl(
                entry.$1,
                Uri.parse('http://127.0.0.1:${server.port}${entry.$2}'),
              );
              final response = await request.close();
              ports.add(response.connectionInfo!.localPort);
              expect(response.statusCode, entry.$3);
              expect(
                await utf8.decoder.bind(response).join(),
                entry.$2 == '/final' ? 'still alive' : '',
              );
            }
            expect(ports.toSet(), hasLength(1));
          } finally {
            client.close(force: true);
            await sub.cancel();
            await server.close(force: true);
          }
        },
      );

      test(
        '${backend.label}: redirect preserves status and location',
        () async {
          final server = await _bindServer(
            backend,
            InternetAddress.loopbackIPv4,
            0,
          );
          final sub = server.listen((request) async {
            await request.response.redirect(
              Uri.parse('/next?q=value'),
              status: 307,
            );
          });
          final client = HttpClient();
          try {
            final request = await client.getUrl(
              Uri.parse('http://127.0.0.1:${server.port}/'),
            );
            request.followRedirects = false;
            final response = await request.close();
            expect(response.statusCode, 307);
            expect(response.headers.value('location'), '/next?q=value');
            expect(
              await response.fold<int>(0, (size, bytes) => size + bytes.length),
              0,
            );
          } finally {
            client.close(force: true);
            await sub.cancel();
            await server.close(force: true);
          }
        },
      );

      test(
        '${backend.label}: graceful close completes with idle keep-alive client',
        () async {
          final server = await _bindServer(
            backend,
            InternetAddress.loopbackIPv4,
            0,
          );
          server.listen((request) async {
            request.response.write('ok');
            await request.response.close();
          });
          final client = HttpClient();
          try {
            final request = await client.getUrl(
              Uri.parse('http://127.0.0.1:${server.port}/'),
            );
            final response = await request.close();
            expect(await utf8.decoder.bind(response).join(), 'ok');
            // Keep the client open while awaiting close: destroying it first
            // would hide a native thread blocked reading the next request.
            await server.close().timeout(const Duration(seconds: 3));
          } finally {
            client.close(force: true);
            await server.close(force: true);
          }
        },
      );

      test('${backend.label}: default response headers', () async {
        final headers = await _fetchHeadersSnapshot(backend);
        expect(
          headers[HttpHeaders.contentTypeHeader],
          equals(const <String>['text/plain; charset=utf-8']),
        );
        expect(
          headers['x-frame-options'],
          equals(const <String>['SAMEORIGIN']),
        );
        expect(
          headers['x-content-type-options'],
          equals(const <String>['nosniff']),
        );
        expect(
          headers['x-xss-protection'],
          equals(const <String>['1; mode=block']),
        );
      });

      test('${backend.label}: cleared default response headers', () async {
        final headers = await _fetchHeadersSnapshot(
          backend,
          clearDefaultHeaders: true,
        );
        expect(headers[HttpHeaders.contentTypeHeader], isNull);
        expect(headers['x-frame-options'], isNull);
        expect(headers['x-content-type-options'], isNull);
        expect(headers['x-xss-protection'], isNull);
      });

      test(
        '${backend.label}: cleared + custom default response headers',
        () async {
          final headers = await _fetchHeadersSnapshot(
            backend,
            clearDefaultHeaders: true,
            addDefaultHeaders: const <String, String>{'a': 'b'},
          );
          expect(headers[HttpHeaders.contentTypeHeader], isNull);
          expect(headers['x-frame-options'], isNull);
          expect(headers['x-content-type-options'], isNull);
          expect(headers['x-xss-protection'], isNull);
          expect(headers['a'], equals(const <String>['b']));
        },
      );

      test(
        '${backend.label}: response.write uses UTF-8 with default content-type',
        () async {
          final bytes = await _fetchBodyBytes(
            backend,
            clearDefaultHeaders: false,
            body: 'æøå',
          );
          expect(bytes, equals(const <int>[195, 166, 195, 184, 195, 165]));
        },
      );

      test(
        '${backend.label}: response.write uses latin1 when content-type is absent',
        () async {
          final bytes = await _fetchBodyBytes(
            backend,
            clearDefaultHeaders: true,
            body: 'æøå',
          );
          expect(bytes, equals(const <int>[230, 248, 229]));
        },
      );

      for (final clientPersistentConnection in <bool>[false, true]) {
        test(
          '${backend.label}: connection headers/persistentConnection '
          '(clientPersistentConnection=$clientPersistentConnection)',
          () async {
            final server = await _bindServer(
              backend,
              InternetAddress.loopbackIPv4,
              0,
            );
            final handled = Completer<void>();
            final sub = server.listen((request) async {
              expect(request.persistentConnection, clientPersistentConnection);
              expect(
                request.response.persistentConnection,
                clientPersistentConnection,
              );
              _checkExpectedConnectionHeaders(
                request.headers,
                request.persistentConnection,
              );

              if (request.persistentConnection) {
                request.response.persistentConnection = false;
              }
              _setConnectionHeaders(request.response.headers);
              await request.response.close();
              handled.complete();
            });

            final client = HttpClient();
            try {
              final req = await client.getUrl(
                Uri.parse('http://127.0.0.1:${server.port}/'),
              );
              _setConnectionHeaders(req.headers);
              req.persistentConnection = clientPersistentConnection;
              final response = await req.close();
              expect(response.persistentConnection, isFalse);
              _checkExpectedConnectionHeaders(
                response.headers,
                response.persistentConnection,
              );
              await response.drain<void>();
              await handled.future.timeout(const Duration(seconds: 3));
            } finally {
              client.close(force: true);
              await sub.cancel();
              await server.close(force: true);
            }
          },
        );
      }

      test(
        '${backend.label}: response.done errors when content-length is 0 and body is written',
        () async {
          final doneError = Completer<Object>();
          final server = await _bindServer(
            backend,
            InternetAddress.loopbackIPv4,
            0,
          );
          final sub = server.listen((request) async {
            request.response.contentLength = 0;
            request.response.done.catchError((error) {
              if (!doneError.isCompleted) {
                doneError.complete(error);
              }
            });
            try {
              request.response.write('x');
            } catch (error) {
              if (!doneError.isCompleted) {
                doneError.complete(error);
              }
            }
            try {
              await request.response.close();
            } catch (error) {
              if (!doneError.isCompleted) {
                doneError.complete(error);
              }
            }
          });

          final client = HttpClient();
          try {
            final req = await client.getUrl(
              Uri.parse('http://127.0.0.1:${server.port}/'),
            );
            try {
              final response = await req.close();
              await response.drain<void>();
            } catch (_) {}
            final error = await doneError.future.timeout(
              const Duration(seconds: 3),
            );
            expect(error, isA<HttpException>());
          } finally {
            client.close(force: true);
            await sub.cancel();
            await server.close(force: true);
          }
        },
      );

      test(
        '${backend.label}: response.done errors when content-length is greater than body',
        () async {
          final doneError = Completer<Object>();
          final server = await _bindServer(
            backend,
            InternetAddress.loopbackIPv4,
            0,
          );
          final sub = server.listen((request) async {
            request.response.contentLength = 5;
            request.response.done.catchError((error) {
              if (!doneError.isCompleted) {
                doneError.complete(error);
              }
            });
            try {
              request.response.write('x');
              await request.response.close();
            } catch (error) {
              if (!doneError.isCompleted) {
                doneError.complete(error);
              }
            }
          });

          final client = HttpClient();
          try {
            final req = await client.getUrl(
              Uri.parse('http://127.0.0.1:${server.port}/'),
            );
            try {
              final response = await req.close();
              await response.drain<void>();
            } catch (_) {}
            final error = await doneError.future.timeout(
              const Duration(seconds: 3),
            );
            expect(error, isA<HttpException>());
          } finally {
            client.close(force: true);
            await sub.cancel();
            await server.close(force: true);
          }
        },
      );

      test('${backend.label}: empty Connection header has no values', () async {
        final values = await _captureEmptyConnectionHeaderValues(backend);
        expect(values, isEmpty);
      });

      test(
        '${backend.label}: HEAD close does not fail when content-length exceeds body bytes',
        () async {
          final hasError = await _headCloseCompletesWithContentLengthError(
            backend,
          );
          expect(hasError, isFalse);
        },
      );
    }

    test('v6Only wildcard binding matches dart:io', () async {
      if (!await _supportsIPv6()) {
        markTestSkipped('IPv6 unavailable');
        return;
      }
      for (final backend in _Backend.values) {
        for (final v6Only in [false, true]) {
          final server = await _bindServer(
            backend,
            InternetAddress.anyIPv6,
            0,
            v6Only: v6Only,
          );
          server.listen((request) async {
            request.response.statusCode = 204;
            await request.response.close();
          });
          try {
            expect(await _singleRequestStatus('::1', server.port), 204);
            if (v6Only) {
              final ipv4 = await ServerSocket.bind(
                InternetAddress.anyIPv4,
                server.port,
              );
              await ipv4.close();
            } else {
              expect(await _singleRequestStatus('127.0.0.1', server.port), 204);
            }
          } finally {
            await server.close(force: true);
          }
        }
      }
    });

    test('bind(shared:true) parity on IPv4/IPv6 loopback', () async {
      final hosts = <String>['127.0.0.1'];
      if (await _supportsIPv6()) {
        hosts.add('::1');
      }

      for (final backend in _Backend.values) {
        for (final host in hosts) {
          for (final v6Only in <bool>[false, true]) {
            final server1 = await _bindServer(
              backend,
              host,
              0,
              v6Only: v6Only,
              shared: true,
            );
            final port = server1.port;
            expect(port, greaterThan(0));

            final server2 = await _bindServer(
              backend,
              host,
              port,
              v6Only: v6Only,
              shared: true,
            );
            expect(server2.port, port);
            expect(server2.address.address, server1.address.address);

            final sub1 = server1.listen((request) async {
              request.response.statusCode = 501;
              await request.response.close();
            });
            final status1 = await _singleRequestStatus(host, port);
            expect(status1, 501);
            await sub1.cancel();
            await server1.close(force: true);

            final sub2 = server2.listen((request) async {
              request.response.statusCode = 502;
              await request.response.close();
            });
            final status2 = await _singleRequestStatus(host, port);
            expect(status2, 502);
            await sub2.cancel();
            await server2.close(force: true);
          }
        }
      }
    });
  });
}
