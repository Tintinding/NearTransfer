import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'identity.dart';
import 'model.dart';
import 'transport.dart';

class Incoming {
  Incoming(this.requestId, this.peer, List<FileSpec> specs, this.deadline)
    : files = [for (final spec in specs) TransferFile(spec)];

  final String requestId;
  final String id = randomId();
  final Device peer;
  final List<TransferFile> files;
  DateTime deadline;
  final String _token = randomId();
  final _stop = TransferCancellation();
  SessionState state = SessionState.waiting;
  bool _writing = false;
  Future<void>? _upload;

  Json get snapshot => {
    'id': id,
    'state': state.name,
    if (state == SessionState.accepted) 'token': _token,
    'files': [for (final file in files) file.toJson()],
  };
}

class Receiver {
  Receiver({
    required this.identity,
    required this.storage,
    required this.findPeer,
    required this.canReceive,
    required this.verifyOutgoing,
    required this.changed,
    required this.remember,
    this.wait = const Duration(seconds: 90),
    this.acceptedIdle = const Duration(minutes: 10),
  });

  final Identity identity;
  final ReceiveStorage storage;
  final Device? Function(String) findPeer;
  final bool Function() canReceive;
  final bool Function(String request, String receiver, InternetAddress address)
  verifyOutgoing;
  final void Function(Incoming) changed;
  final Future<void> Function(Device) remember;
  final Duration wait, acceptedIdle;
  final _sessions = <String, Incoming>{};
  final _verifying = <String>{};
  HttpServer? _server;
  Timer? _timer;
  int _requests = 0;
  int _port = 0;
  int get port => _port;
  bool get running => _server != null;
  bool get busy => _sessions.values.any((s) => s.state.active || s._writing);

  Future<void> start({InternetAddress? bind}) async {
    if (running) return;
    final address = bind ?? InternetAddress.anyIPv4;
    final context = identity.serverContext();
    try {
      _server = await HttpServer.bindSecure(
        address,
        _port,
        context,
        backlog: 32,
      );
    } on SocketException {
      if (_port == 0) rethrow;
      _server = await HttpServer.bindSecure(address, 0, context, backlog: 32);
    }
    _port = _server!.port;
    _server!.idleTimeout = ioTimeout;
    _server!.listen(_handle, onError: (Object _) {});
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _expire());
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _timer?.cancel();
    final stopping = [
      for (final session in _sessions.values)
        if (session.state.active || session._writing) cancel(session),
    ];
    await server?.close(force: true);
    await Future.wait(stopping);
  }

  void decide(Incoming session, bool accept) {
    _expire();
    if (!running || session.state != SessionState.waiting) return;
    session.state = accept ? SessionState.accepted : SessionState.declined;
    session.deadline = DateTime.now().add(acceptedIdle);
    changed(session);
  }

  Future<void> cancel(Incoming session) async {
    if (session.state.active) _stopSession(session, SessionState.canceled);
    await session._upload;
  }

  void _stopSession(Incoming session, SessionState state, {String? fileError}) {
    session.state = state;
    session.deadline = DateTime.now();
    session._stop.cancel();
    for (final file in session.files.where(
      (f) => f.state == FileState.pending,
    )) {
      file.state = FileState.failed;
      file.error = fileError ?? state.name;
    }
    changed(session);
  }

  void _expire() {
    final now = DateTime.now();
    for (final session in _sessions.values) {
      if (session.state.active &&
          !session._writing &&
          now.isAfter(session.deadline)) {
        _stopSession(session, SessionState.expired);
      }
    }
    _sessions.removeWhere(
      (_, session) =>
          !session.state.active &&
          !session._writing &&
          now.difference(session.deadline) > const Duration(minutes: 20),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response
      ..persistentConnection = false
      ..headers.contentType = ContentType.json;
    unawaited(response.done.then<void>((_) {}, onError: (Object _) {}));
    Json? output;
    if (_requests >= 32) {
      response.statusCode = 503;
      output = {'error': 'busy'};
    } else {
      _requests++;
      try {
        _expire();
        output = await _route(request);
      } on TransferError catch (error) {
        response.statusCode = error.status;
        output = {'error': error.code};
      } on TimeoutException {
        response.statusCode = 408;
        output = {'error': 'timeout'};
      } catch (_) {
        response.statusCode = 500;
        output = {'error': 'peer_error'};
      } finally {
        _requests--;
      }
    }
    try {
      response.write(jsonEncode(output));
      await response.close().timeout(ioTimeout);
    } catch (_) {
      // The peer disconnected. Session status still records any commit.
    }
  }

  Future<Json> _route(HttpRequest request) async {
    if (!running) throw const TransferError('offline', 503);
    final path = request.uri.pathSegments;
    final address = request.connectionInfo?.remoteAddress;
    if (address == null || path.isEmpty || path.first != 'v1') {
      throw const TransferError('not_found', 404);
    }
    if (path.length == 2 && request.method == 'POST') {
      if (path[1] == 'offers') return _offer(request, address);
      if (path[1] == 'verify-offer') {
        final body = await readJson(request);
        final id = body['requestId'], receiver = body['receiverId'];
        return {
          'verified':
              id is String &&
              receiver is String &&
              verifyOutgoing(id, receiver, address),
        };
      }
    }
    if (path.length >= 3 && path[1] == 'transfers') {
      final session = _sessions[path[2]];
      // The random session ID is a bearer capability; the upload token is separate.
      if (session == null) throw const TransferError('session_unknown', 404);
      if (path.length == 3 && request.method == 'GET') {
        if (!session.state.active) await session._upload;
        return session.snapshot;
      }
      if (path.length == 4 && path[3] == 'cancel' && request.method == 'POST') {
        await cancel(session);
        return session.snapshot;
      }
      if (path.length == 5 && path[3] == 'files' && request.method == 'PUT') {
        return _uploadFile(request, session, path[4]);
      }
    }
    throw const TransferError('not_found', 404);
  }

  Future<Json> _offer(HttpRequest request, InternetAddress address) async {
    final body = await readJson(request);
    final id = body['requestId'], sender = body['senderId'];
    if (id is! String ||
        !idPattern.hasMatch(id) ||
        sender is! String ||
        !digestPattern.hasMatch(sender)) {
      throw const TransferError('invalid_manifest');
    }
    final files = parseManifest(body['files']);
    final key = '$sender:$id';
    final peer = findPeer(sender);
    if (peer == null ||
        peer.address.address != address.address ||
        peer.port != body['senderPort']) {
      throw const TransferError('sender_not_discovered', 403);
    }
    if (_verifying.contains(key) || _verifying.length >= 4) {
      throw const TransferError('busy', 503);
    }
    final existing = _sessions.values
        .where((s) => s.requestId == id && s.peer.id == sender)
        .firstOrNull;
    if (existing != null) return existing.snapshot;
    if (busy || !canReceive() || _sessions.length >= 128) {
      throw const TransferError('busy', 503);
    }
    _verifying.add(key);
    final client = PinnedClient(peer);
    try {
      final reply = await client.control('POST', '/v1/verify-offer', {
        'requestId': id,
        'receiverId': identity.id,
      });
      if (reply['verified'] != true) {
        throw const TransferError('unverified_sender', 403);
      }
      if (!running || busy || !canReceive()) {
        throw const TransferError('busy', 503);
      }
      final session = Incoming(id, peer, files, DateTime.now().add(wait));
      _sessions[session.id] = session;
      changed(session);
      return session.snapshot;
    } on TransferError {
      rethrow;
    } catch (_) {
      throw const TransferError('unverified_sender', 403);
    } finally {
      _verifying.remove(key);
      client.close();
    }
  }

  Future<Json> _uploadFile(
    HttpRequest request,
    Incoming session,
    String id,
  ) async {
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer ${session._token}') {
      throw const TransferError('invalid_token', 403);
    }
    final file = session.files.where((f) => f.spec.id == id).firstOrNull;
    if (file == null) throw const TransferError('file_unknown', 404);
    if (file.state == FileState.committed) return file.toJson();
    if (session.state != SessionState.accepted ||
        file.state != FileState.pending ||
        session._writing) {
      throw const TransferError('upload_not_allowed', 409);
    }
    final digest = request.headers.value('x-content-sha256');
    if (request.contentLength != file.spec.size ||
        digest == null ||
        !digestPattern.hasMatch(digest) ||
        request.headers.value('content-encoding') != null) {
      throw const TransferError('invalid_file_headers');
    }
    file.state = FileState.uploading;
    session._writing = true;
    changed(session);
    final write = _write(request, session, file, digest);
    session._upload = write.then<void>((_) {}, onError: (Object _) {});
    try {
      return await write;
    } finally {
      session._writing = false;
      session._upload = null;
      session.deadline = DateTime.now().add(acceptedIdle);
      if (session.state == SessionState.accepted &&
          file.error == 'interrupted') {
        final saved = session.files.any((f) => f.state == FileState.committed);
        _stopSession(
          session,
          saved ? SessionState.partial : SessionState.failed,
          fileError: 'interrupted',
        );
      }
      if (session.state == SessionState.accepted &&
          session.files.every(
            (f) =>
                f.state == FileState.failed || f.state == FileState.committed,
          )) {
        final count = session.files
            .where((f) => f.state == FileState.committed)
            .length;
        session.state = count == session.files.length
            ? SessionState.completed
            : count == 0
            ? SessionState.failed
            : SessionState.partial;
      }
      changed(session);
    }
  }

  Future<Json> _write(
    HttpRequest request,
    Incoming session,
    TransferFile file,
    String digest,
  ) async {
    PendingFile? target;
    final reader = StreamIterator(request);
    try {
      if (session._stop.canceled) throw const TransferError('canceled', 409);
      target = await storage.create(file.spec);
      final output = DigestOutput();
      final hash = sha256.startChunkedConversion(output);
      while (!session._stop.canceled &&
          await session._stop.until(reader.moveNext().timeout(ioTimeout))) {
        final bytes = reader.current;
        if (file.spec.size - file.bytes < bytes.length) {
          throw const TransferError('length_mismatch', 422);
        }
        await target.write(bytes);
        hash.add(bytes);
        file.bytes += bytes.length;
        changed(session);
      }
      if (session._stop.canceled) throw const TransferError('canceled', 409);
      hash.close();
      if (file.bytes != file.spec.size) {
        throw const TransferError('length_mismatch', 422);
      }
      if (output.value.toString() != digest) {
        throw const TransferError('digest_mismatch', 422);
      }
      // No await between the cancellation check and entering commit. A cancel
      // arriving during commit waits for it and reports the committed file.
      file.saved = await target.commit();
      file.savedName = file.saved!.name;
      file.state = FileState.committed;
      target = null;
      await remember(session.peer).catchError((Object _) {});
      return file.toJson();
    } catch (error) {
      file.state = FileState.failed;
      file.error = session._stop.canceled
          ? 'canceled'
          : switch (error) {
              TransferError() => error.code,
              TimeoutException() ||
              HttpException() ||
              SocketException() => 'interrupted',
              _ => 'storage_failed',
            };
      throw TransferError(file.error!, file.error == 'interrupted' ? 408 : 422);
    } finally {
      unawaited(reader.cancel().catchError((Object _) {}));
      try {
        await target?.rollback();
      } catch (_) {
        // Android keeps the URI in its cleanup journal if deletion fails.
      }
    }
  }
}
