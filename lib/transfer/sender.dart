import 'dart:async';
import 'dart:io';

import 'model.dart';
import 'transport.dart';

class Outgoing {
  Outgoing(this.peer, this.sources, {String? restoredRequestId})
    : requestId = restoredRequestId ?? randomId(),
      files = [for (final source in sources) TransferFile(source.spec)];

  final Device peer;
  final List<FileSource> sources;
  final List<TransferFile> files;
  final String requestId;
  final _stop = TransferCancellation();
  String _stopReason = 'canceled';
  String? sessionId;
  String? error;
  SessionState state = SessionState.waiting;
  bool running = true;
  bool unknown = false;
  FileSpec? preparing;
  PinnedClient? _client;
  final _unconfirmed = <String>{};

  Json checkpoint(List<String> handles) => {
    'peer': {
      ...peer.attributes,
      'address': peer.address.address,
      'port': peer.port,
    },
    'requestId': requestId,
    'sessionId': sessionId,
    'state': state.name,
    'error': error,
    'unconfirmed': _unconfirmed.toList(),
    'files': [
      for (var i = 0; i < files.length; i++)
        {
          'spec': files[i].spec.toJson(),
          'handle': handles[i],
          'status': files[i].toJson(),
        },
    ],
  };

  static Outgoing restore(
    Json data,
    FileSource Function(FileSpec, String) source,
  ) {
    final peer = data['peer'] as Json;
    final device = Device.fromDiscovery(
      {
        for (final field in ['v', 'id', 'name', 'platform'])
          field: peer[field] as String,
      },
      InternetAddress(peer['address'] as String),
      peer['port'] as int,
    )!;
    final entries = (data['files'] as List).cast<Json>();
    final specs = parseManifest(entries.map((entry) => entry['spec']).toList());
    final job =
        Outgoing(device, [
            for (var i = 0; i < specs.length; i++)
              source(specs[i], entries[i]['handle'] as String),
          ], restoredRequestId: data['requestId'] as String)
          ..sessionId = data['sessionId'] as String?
          ..state = SessionState.values.byName(data['state'] as String)
          ..error = data['error'] as String?
          ..running = false
          .._unconfirmed.addAll((data['unconfirmed'] as List).cast<String>());
    for (var i = 0; i < specs.length; i++) {
      final file = job.files[i], status = entries[i]['status'] as Json;
      file.state = FileState.values.byName(status['state'] as String);
      file.bytes = status['bytes'] as int;
      file.error = status['error'] as String?;
      file.savedName = status['name'] as String?;
      if (file.state != FileState.committed) {
        file.state = FileState.failed;
        file.error ??= 'interrupted';
      }
    }
    if (job.state.active) {
      job.error ??= 'interrupted';
      job.state = job.files.any((file) => file.state == FileState.committed)
          ? SessionState.partial
          : SessionState.failed;
    }
    job.unknown = job._unconfirmed.isNotEmpty;
    return job;
  }

  Iterable<FileSource> get remaining => sources.where(
    (source) => files.any(
      (f) => f.spec.id == source.spec.id && f.state != FileState.committed,
    ),
  );

  void stop([String reason = 'canceled']) {
    if (_stop.canceled) return;
    _stopReason = reason;
    _stop.cancel();
    _client?.close();
  }
}

class Sender {
  Sender({
    required this.id,
    required this.port,
    required this.changed,
    required this.remember,
    this.checkpoint,
  });

  final String id;
  final int Function() port;
  final void Function(Outgoing) changed;
  final Future<void> Function(Device) remember;
  final Future<void> Function(Outgoing)? checkpoint;

  Outgoing? current;
  bool verify(String requestId, String receiverId, InternetAddress address) {
    final job = current;
    return job != null &&
        job.running &&
        !job._stop.canceled &&
        job.requestId == requestId &&
        job.peer.id == receiverId &&
        job.peer.address.address == address.address;
  }

  Future<void> send(Outgoing job) async {
    if (current?.running == true) throw const TransferError('busy');
    parseManifest(job.sources.map((source) => source.spec.toJson()).toList());
    current = job;
    changed(job);
    final client = PinnedClient(job.peer);
    job._client = client;
    Json? offeredBody;
    try {
      await checkpoint?.call(job);
      _checkStop(job);
      final body = {
        'requestId': job.requestId,
        'senderId': id,
        'senderPort': port(),
        'files': [for (final source in job.sources) source.spec.toJson()],
      };
      offeredBody = body;
      Json status;
      try {
        status = await client.control('POST', '/v1/offers', body);
      } on TransferError {
        rethrow;
      } catch (_) {
        // The server may have accepted the offer but lost its response.
        _checkStop(job);
        status = await client.control('POST', '/v1/offers', body);
      }
      final sessionId = status['id'];
      if (sessionId is! String || !idPattern.hasMatch(sessionId)) {
        throw const TransferError('invalid_status');
      }
      job.sessionId = sessionId;
      final path = '/v1/transfers/$sessionId';
      var snapshot = status;
      _apply(job, snapshot);
      final waiting = Stopwatch()..start();
      while (job.state == SessionState.waiting) {
        if (waiting.elapsed > const Duration(seconds: 100)) {
          throw const TransferError('timeout');
        }
        await job._stop.until(
          Future<void>.delayed(const Duration(milliseconds: 700)),
        );
        _checkStop(job);
        snapshot = await client.control('GET', path);
        _apply(job, snapshot);
      }
      if (job.state != SessionState.accepted) return;
      final token = snapshot['token'];
      if (token is! String || !idPattern.hasMatch(token)) {
        throw const TransferError('invalid_status');
      }
      for (var i = 0; i < job.sources.length; i++) {
        _checkStop(job);
        final source = job.sources[i], file = job.files[i];
        job.preparing = source.spec;
        changed(job);
        String digest;
        try {
          digest = await hashFile(source, job._stop);
        } catch (error) {
          _checkStop(job);
          file.state = FileState.failed;
          file.error = error is TransferError
              ? error.code
              : 'source_unreadable';
          continue;
        } finally {
          job.preparing = null;
        }
        _checkStop(job);
        file.state = FileState.uploading;
        job._unconfirmed.add(file.spec.id);
        changed(job);
        try {
          await checkpoint?.call(job);
          _checkStop(job);
          final receipt = await client.upload(
            sessionId,
            token,
            source,
            digest,
            (count) {
              file.bytes = count;
              changed(job);
            },
            job._stop,
          );
          if (receipt['id'] != file.spec.id ||
              receipt['state'] != 'committed' ||
              receipt['name'] is! String ||
              receipt['bytes'] != file.spec.size) {
            throw const TransferError('invalid_status');
          }
          _markCommitted(job, file, receipt['name'] as String);
        } on TransferError catch (error) {
          if (!{
            'digest_mismatch',
            'length_mismatch',
            'storage_failed',
            'no_space',
            'source_unreadable',
            'source_changed',
          }.contains(error.code)) {
            rethrow;
          }
          // A local source failure can leave a PUT in flight. Settle it via
          // the same status reconciliation used for a dropped connection.
          if (error.code.startsWith('source_')) rethrow;
          job._unconfirmed.remove(file.spec.id);
          file.state = FileState.failed;
          file.error = error.code;
        }
      }
      _checkStop(job);
      if (!await reconcile(job, job.peer)) {
        throw const TransferError('interrupted');
      }
    } catch (error) {
      job.error = job._stop.canceled
          ? job._stopReason
          : error is TransferError
          ? error.code
          : 'interrupted';
      if (job.sessionId == null &&
          job.error == 'canceled' &&
          offeredBody != null) {
        // The initial request may have reached the peer just before cancel.
        // Reverse verification now fails unless this offer already exists.
        final cleanup = PinnedClient(job.peer);
        try {
          final status = await cleanup.control(
            'POST',
            '/v1/offers',
            offeredBody,
          );
          final id = status['id'];
          if (id is String && idPattern.hasMatch(id)) job.sessionId = id;
        } catch (_) {
          // A waiting offer cannot upload and will expire automatically.
        } finally {
          cleanup.close();
        }
      }
      if (job.sessionId != null) await reconcile(job, job.peer);
      if (job.state.active) {
        job.state = job.error == 'canceled'
            ? SessionState.canceled
            : _result(job);
      }
    } finally {
      client.close();
      job._client = null;
      job.unknown = job._unconfirmed.isNotEmpty;
      for (final file in job.files.where(
        (file) => file.state != FileState.committed,
      )) {
        file.state = FileState.failed;
        file.error ??= job.error ?? job.state.name;
      }
      if (job.files.any((file) => file.state == FileState.committed)) {
        await remember(job.peer).catchError((Object _) {});
      }
      await checkpoint?.call(job).catchError((Object _) {});
      job.running = false;
      changed(job);
    }
  }

  void _checkStop(Outgoing job) {
    if (job._stop.canceled) throw const TransferError('canceled');
  }

  SessionState _result(Outgoing job) {
    final count = job.files
        .where((file) => file.state == FileState.committed)
        .length;
    return count == job.files.length
        ? SessionState.completed
        : count == 0
        ? SessionState.failed
        : SessionState.partial;
  }

  /// Reads the receipt first. If the previous session is still open, cancels
  /// it and waits for its in-flight commit or rollback before allowing retry.
  Future<bool> reconcile(Outgoing job, Device peer) async {
    final sessionId = job.sessionId;
    if (sessionId == null || peer.id != job.peer.id) return false;
    final path = '/v1/transfers/$sessionId';
    final client = PinnedClient(peer);
    try {
      _apply(job, await client.control('GET', path));
      if (job.state.active) {
        _apply(job, await client.control('POST', '$path/cancel'));
      }
      return !job.state.active;
    } catch (_) {
      return false;
    } finally {
      client.close();
      job.unknown = job._unconfirmed.isNotEmpty;
      changed(job);
    }
  }

  void _apply(Outgoing job, Json snapshot) {
    final state = SessionState.values
        .where((s) => s.name == snapshot['state'])
        .firstOrNull;
    final files = snapshot['files'];
    if (snapshot['id'] != job.sessionId ||
        state == null ||
        files is! List ||
        files.length != job.files.length) {
      throw const TransferError('invalid_status');
    }
    final seen = <String>{};
    for (final value in files) {
      if (value is! Json) throw const TransferError('invalid_status');
      final file = job.files.where((f) => f.spec.id == value['id']).firstOrNull;
      final fileState = FileState.values
          .where((s) => s.name == value['state'])
          .firstOrNull;
      final bytes = value['bytes'];
      if (file == null ||
          fileState == null ||
          !seen.add(file.spec.id) ||
          bytes is! int ||
          bytes < 0 ||
          bytes > file.spec.size ||
          (fileState == FileState.committed &&
              (bytes != file.spec.size || value['name'] is! String))) {
        throw const TransferError('invalid_status');
      }
      if (fileState == FileState.committed) {
        _markCommitted(job, file, value['name'] as String);
      } else if (file.state != FileState.committed) {
        if (fileState == FileState.failed || !state.active) {
          job._unconfirmed.remove(file.spec.id);
        }
        if (file.error == null) {
          file.state = fileState;
          file.bytes = bytes;
          final error = value['error'];
          if (error is String) file.error = error;
        }
      }
    }
    job.state = state;
    if (state == SessionState.canceled &&
        job.error != 'canceled' &&
        job.files.any((file) => file.state == FileState.committed) &&
        job.files.any(
          (file) => file.error != null && file.error != 'canceled',
        )) {
      job.state = SessionState.partial;
    }
    changed(job);
  }

  void _markCommitted(Outgoing job, TransferFile file, String name) {
    file.state = FileState.committed;
    file.bytes = file.spec.size;
    file.error = null;
    file.savedName = name;
    job._unconfirmed.remove(file.spec.id);
    unawaited(remember(job.peer).catchError((Object _) {}));
  }
}
