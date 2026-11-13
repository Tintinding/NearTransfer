import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'model.dart';

Future<Json> readJson(Stream<List<int>> stream) async {
  final reader = StreamIterator(stream);
  final deadline = Stopwatch()..start();
  final data = BytesBuilder(copy: false);
  try {
    while (await reader.moveNext().timeout(ioTimeout - deadline.elapsed)) {
      if (data.length + reader.current.length > maxControlBytes) {
        throw const TransferError('control_too_large', 413);
      }
      data.add(reader.current);
    }
    final value = jsonDecode(utf8.decode(data.takeBytes()));
    if (value is! Json) throw const TransferError('invalid_json');
    return value;
  } on FormatException {
    throw const TransferError('invalid_json');
  } finally {
    unawaited(reader.cancel().catchError((Object _) {}));
  }
}

class DigestOutput implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class TransferCancellation {
  final _listeners = <void Function()>{};
  bool canceled = false;

  void cancel() {
    if (canceled) return;
    canceled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  Future<T> until<T>(Future<T> operation) {
    final result = Completer<T>();
    void stop() => result.completeError(const TransferError('canceled', 409));
    if (canceled) {
      stop();
    } else {
      _listeners.add(stop);
    }
    operation.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future.whenComplete(() => _listeners.remove(stop));
  }
}

class PinnedClient {
  PinnedClient(this.peer) {
    _client =
        HttpClient(
            context: SecurityContext(withTrustedRoots: false)
              ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2,
          )
          ..connectionTimeout = const Duration(seconds: 5)
          ..autoUncompress = false
          ..findProxy = ((_) => 'DIRECT')
          ..badCertificateCallback = ((cert, _, _) {
            final valid = sha256.convert(cert.der).toString() == peer.id;
            _pinMismatch = !valid;
            return valid;
          });
  }

  final Device peer;
  late final HttpClient _client;
  bool _pinMismatch = false;

  void close() => _client.close(force: true);

  Future<HttpClientRequest> _open(String method, String path) async {
    try {
      final request = await _client
          .openUrl(
            method,
            Uri(
              scheme: 'https',
              host: peer.address.address,
              port: peer.port,
              path: path,
            ),
          )
          .timeout(ioTimeout);
      request.followRedirects = false;
      request.persistentConnection = false;
      // Dart also completes request.done on socket errors during a body write.
      unawaited(request.done.then<void>((_) {}, onError: (Object _) {}));
      return request;
    } on HandshakeException {
      throw TransferError(_pinMismatch ? 'certificate_changed' : 'tls_failed');
    }
  }

  Future<Json> _response(HttpClientRequest request) async {
    final response = await request.close().timeout(ioTimeout);
    final json = await readJson(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TransferError(
        json['error'] is String ? json['error'] as String : 'peer_error',
        response.statusCode,
      );
    }
    return json;
  }

  Future<Json> control(String method, String path, [Json? body]) async {
    final request = await _open(method, path);
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      if (bytes.length > maxControlBytes) {
        request.abort();
        throw const TransferError('control_too_large');
      }
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    } else {
      request.contentLength = 0;
    }
    return _response(request);
  }

  Future<Json> upload(
    String session,
    String token,
    FileSource file,
    String digest,
    void Function(int) progress,
    TransferCancellation stop,
  ) async {
    final request = await _open(
      'PUT',
      '/v1/transfers/$session/files/${file.spec.id}',
    );
    request.bufferOutput = false;
    request.contentLength = file.spec.size;
    request.headers
      ..contentType = ContentType.binary
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set('x-content-sha256', digest);
    var count = 0;
    try {
      await consumeFile(file, stop, (bytes) async {
        request.add(bytes);
        await request.flush().timeout(ioTimeout);
        count += bytes.length;
        progress(count);
      });
      return await _response(request);
    } catch (_) {
      request.abort();
      rethrow;
    }
  }
}

Future<void> consumeFile(
  FileSource source,
  TransferCancellation stop,
  FutureOr<void> Function(List<int>) consume,
) async {
  final reader = StreamIterator(source.open());
  var count = 0;
  try {
    while (await stop.until(reader.moveNext().timeout(ioTimeout))) {
      final bytes = reader.current;
      if (source.spec.size - count < bytes.length) {
        throw const TransferError('source_changed');
      }
      count += bytes.length;
      await consume(bytes);
    }
    if (count != source.spec.size) throw const TransferError('source_changed');
  } finally {
    // Native providers can stall; do not hold the session open waiting for one.
    unawaited(reader.cancel().catchError((Object _) {}));
  }
}

Future<String> hashFile(FileSource source, TransferCancellation stop) async {
  final out = DigestOutput();
  final hash = sha256.startChunkedConversion(out);
  await consumeFile(source, stop, hash.add);
  hash.close();
  return out.value.toString();
}
