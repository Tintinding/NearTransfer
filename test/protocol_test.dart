import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_transfer/transfer/identity.dart';
import 'package:near_transfer/transfer/model.dart';
import 'package:near_transfer/transfer/receiver.dart';
import 'package:near_transfer/transfer/sender.dart';
import 'package:near_transfer/transfer/transport.dart';

import '../tool/disk_peer.dart';

class MemorySource implements FileSource {
  MemorySource(String name, this.data, {this.gate})
    : spec = FileSpec(randomId(), name, data.length);
  @override
  final FileSpec spec;
  final List<int> data;
  final Completer<void>? gate;
  int opened = 0;

  @override
  Stream<List<int>> open() async* {
    final pass = ++opened;
    for (var i = 0; i < data.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, data.length);
      yield data.sublist(i, end);
      if (pass == 2 && i == 0 && gate != null) await gate!.future;
    }
  }
}

class TestNode {
  TestNode(this.identity, this.directory, this.history, this.name, {this.wait});
  final Identity identity;
  final Directory directory;
  final PeerHistory history;
  final String name;
  final Duration? wait;
  final peers = <String, Device>{};
  late final Receiver receiver;
  late final Sender sender;
  Incoming? offer;
  bool Function(String, String, InternetAddress)? verifyOverride;
  ReceiveStorage? storageOverride;
  Future<void> Function()? afterCommit;

  static Future<TestNode> create(
    Directory root,
    String name, {
    Duration? wait,
  }) async {
    final directory = await Directory('${root.path}/$name').create();
    return TestNode(
      await Identity.load(directory),
      directory,
      await PeerHistory.load(directory),
      name,
      wait: wait,
    );
  }

  Directory get downloads => Directory('${directory.path}/downloads');
  Device get device => Device(
    id: identity.id,
    name: name,
    address: InternetAddress.loopbackIPv4,
    port: receiver.port,
    platform: 'test',
  );

  Future<void> start() async {
    sender = Sender(
      id: identity.id,
      port: () => receiver.port,
      changed: (_) {},
      remember: history.remember,
    );
    receiver = Receiver(
      identity: identity,
      storage: _ObservedStorage(
        storageOverride ?? DiskStorage(downloads),
        () async => await afterCommit?.call(),
      ),
      findPeer: peers.operatorLookup,
      canReceive: () => sender.current?.running != true,
      verifyOutgoing: (id, peer, ip) =>
          (verifyOverride ?? sender.verify)(id, peer, ip),
      changed: (value) => offer = value,
      remember: history.remember,
      wait: wait ?? const Duration(seconds: 5),
    );
    await receiver.start(bind: InternetAddress.loopbackIPv4);
  }
}

class _ObservedStorage implements ReceiveStorage {
  _ObservedStorage(this.storage, this.afterCommit);
  final ReceiveStorage storage;
  final Future<void> Function() afterCommit;

  @override
  Future<PendingFile> create(FileSpec spec) async =>
      _ObservedPending(await storage.create(spec), afterCommit);
}

class _ObservedPending implements PendingFile {
  _ObservedPending(this.target, this.afterCommit);
  final PendingFile target;
  final Future<void> Function() afterCommit;

  @override
  Future<void> write(List<int> bytes) => target.write(bytes);
  @override
  Future<void> rollback() => target.rollback();
  @override
  Future<SavedFile> commit() async {
    final result = await target.commit();
    await afterCommit();
    return result;
  }
}

extension on Map<String, Device> {
  Device? operatorLookup(String id) => this[id];
}

Future<void> until(bool Function() condition) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    if (timer.elapsed > const Duration(seconds: 6)) {
      fail('Timed out waiting for test state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Matcher errorCode(String code) =>
    isA<TransferError>().having((e) => e.code, 'code', code);

void main() {
  late Directory root;
  late TestNode a, b;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('near-transfer-test-');
    a = await TestNode.create(root, 'Android');
    b = await TestNode.create(
      root,
      'Windows',
      wait: const Duration(seconds: 2),
    );
    await a.start();
    await b.start();
    a.peers[b.device.id] = b.device;
    b.peers[a.device.id] = a.device;
  });
  tearDown(() async {
    await a.receiver.stop();
    await b.receiver.stop();
    await root.delete(recursive: true);
  });

  test('two directions: confirmation, Unicode, duplicates, empty and streamed content', () async {
    final data = Uint8List.fromList(List.generate(600000, (i) => i % 251));
    final first = MemorySource('照片.jpg', data);
    final second = MemorySource('照片.jpg', [5, 6]);
    final empty = MemorySource('空文件.txt', []);
    final outgoing = Outgoing(b.device, [first, second, empty]);
    final send = a.sender.send(outgoing);
    await until(() => b.offer?.state == SessionState.waiting);
    expect(first.opened, 0);
    expect(await b.downloads.exists(), isFalse);
    b.receiver.decide(b.offer!, true);
    await send;
    expect(outgoing.state, SessionState.completed, reason: outgoing.error);
    expect(first.opened, 2);
    expect(outgoing.files.map((file) => file.savedName), [
      '照片.jpg',
      '照片 (1).jpg',
      '空文件.txt',
    ]);
    final saved = await sha256
        .bind(File('${b.downloads.path}/照片.jpg').openRead())
        .first;
    expect(saved, sha256.convert(data));
    expect(await File('${b.downloads.path}/照片 (1).jpg').readAsBytes(), [5, 6]);
    expect(await File('${b.downloads.path}/空文件.txt').length(), 0);
    await a.history.remember(b.device);
    await b.history.remember(a.device);
    expect((await PeerHistory.load(a.directory)).contains(b.device.id), isTrue);
    expect((await PeerHistory.load(b.directory)).contains(a.device.id), isTrue);
    expect((await Identity.load(a.directory)).id, a.device.id);

    final reply = Outgoing(a.device, [
      MemorySource('回传.txt', [4, 2]),
    ]);
    final reverse = b.sender.send(reply);
    await until(() => a.offer?.state == SessionState.waiting);
    a.receiver.decide(a.offer!, true);
    await reverse;
    expect(reply.state, SessionState.completed, reason: reply.error);
    expect(await File('${a.downloads.path}/回传.txt').readAsBytes(), [4, 2]);
  });

  test('reject, timeout and sender cancel never open the source or create downloads', () async {
    for (final expected in [
      SessionState.declined,
      SessionState.expired,
      SessionState.canceled,
    ]) {
      final source = MemorySource('never.txt', [1]);
      final job = Outgoing(b.device, [source]);
      final send = a.sender.send(job);
      await until(
        () => b.offer?.state == SessionState.waiting && job.sessionId != null,
      );
      if (expected == SessionState.declined) b.receiver.decide(b.offer!, false);
      if (expected == SessionState.canceled) job.stop();
      await send;
      expect(job.state, expected, reason: job.error);
      expect(source.opened, 0);
      expect(await b.downloads.exists(), isFalse);
    }
  });

  test('receiver cancel during second upload keeps first file, retry only remaining', () async {
    final gate = Completer<void>();
    final first = MemorySource('first.txt', [1]);
    final second = MemorySource(
      'second.bin',
      Uint8List(chunkSize * 3),
      gate: gate,
    );
    final job = Outgoing(b.device, [first, second]);
    final send = a.sender.send(job);
    try {
      await until(() => b.offer?.state == SessionState.waiting);
      b.receiver.decide(b.offer!, true);
      await until(() => b.offer!.files[1].bytes > 0);
      await b.receiver.cancel(b.offer!);
      await send;
      expect(job.state, SessionState.canceled, reason: job.error);
      expect(job.remaining, [second]);
      expect(
        (await b.downloads.list().toList()).map(
          (item) => item.uri.pathSegments.last,
        ),
        ['first.txt'],
      );
      final retry = Outgoing(b.device, job.remaining.toList());
      final sendingAgain = a.sender.send(retry);
      await until(() => b.offer?.state == SessionState.waiting);
      expect(b.offer!.files.single.spec.id, second.spec.id);
      expect(b.offer!.requestId, isNot(job.requestId));
      b.receiver.decide(b.offer!, true);
      await sendingAgain;
      expect(retry.state, SessionState.completed, reason: retry.error);
    } finally {
      gate.complete();
    }
  });

  test(
    'wrong TLS fingerprint and unverifiable sender are rejected before consent',
    () async {
      final wrong = Device(
        id: a.identity.id,
        name: b.name,
        address: b.device.address,
        port: b.device.port,
        platform: 'test',
      );
      final wrongClient = PinnedClient(wrong);
      try {
        await expectLater(
          wrongClient.control('POST', '/v1/offers', {}),
          throwsA(errorCode('certificate_changed')),
        );
      } finally {
        wrongClient.close();
      }
      a.verifyOverride = (_, _, _) => false;
      final job = Outgoing(b.device, [
        MemorySource('unverified.txt', [1]),
      ]);
      await a.sender.send(job);
      expect(job.error, 'unverified_sender');
      expect(b.offer, isNull);
      expect(await b.downloads.exists(), isFalse);
    },
  );

  test(
    'disconnect mid batch, reconnect and reconcile the previous session',
    () async {
      final gate = Completer<void>();
      final first = MemorySource('already.txt', [7]);
      final second = MemorySource(
        'interrupted.bin',
        Uint8List(chunkSize * 3),
        gate: gate,
      );
      final job = Outgoing(b.device, [first, second]);
      final send = a.sender.send(job);
      try {
        await until(() => b.offer?.state == SessionState.waiting);
        b.receiver.decide(b.offer!, true);
        await until(() => b.offer!.files[1].bytes > 0);
        await b.receiver.stop();
        gate.complete();
        await send;
        expect(job.unknown, isTrue);
        expect(job.remaining, [second]);
        expect(await b.downloads.list().length, 1);
        await b.receiver.start(bind: InternetAddress.loopbackIPv4);
        expect(await a.sender.reconcile(job, b.device), isTrue);
        expect(job.unknown, isFalse);
        expect(job.remaining, [second]);
        expect(await File('${b.downloads.path}/already.txt').readAsBytes(), [
          7,
        ]);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test('wire invariants: no early upload, SHA mismatch rollback and idempotent commit', () async {
    final bad = MemorySource('../坏文件.bin', [1, 2]);
    final good = MemorySource('正常.txt', [3, 4]);
    final requestId = randomId();
    a.verifyOverride = (id, receiver, _) =>
        id == requestId && receiver == b.identity.id;
    final client = PinnedClient(b.device);
    final body = {
      'requestId': requestId,
      'senderId': a.identity.id,
      'senderPort': a.receiver.port,
      'files': [bad.spec.toJson(), good.spec.toJson()],
    };
    try {
      final first = await client.control('POST', '/v1/offers', body);
      final duplicate = await client.control('POST', '/v1/offers', body);
      expect(first['id'], duplicate['id']);
      expect(first, isNot(contains('token')));
      final session = first['id'] as String;
      final stop = TransferCancellation();
      await expectLater(
        client.upload(
          session,
          randomId(),
          bad,
          sha256.convert(bad.data).toString(),
          (_) {},
          stop,
        ),
        throwsA(errorCode('invalid_token')),
      );
      expect(await b.downloads.exists(), isFalse);

      b.receiver.decide(b.offer!, true);
      final status = await client.control('GET', '/v1/transfers/$session');
      final token = status['token'] as String;
      await expectLater(
        client.upload(
          session,
          token,
          bad,
          sha256.convert([]).toString(),
          (_) {},
          stop,
        ),
        throwsA(errorCode('digest_mismatch')),
      );
      expect(await b.downloads.list().isEmpty, isTrue);
      final goodHash = sha256.convert(good.data).toString();
      final saved = await client.upload(
        session,
        token,
        good,
        goodHash,
        (_) {},
        stop,
      );
      final query = await client.control('GET', '/v1/transfers/$session');
      expect(query['state'], 'partial');
      expect((query['files'] as List).last, saved);
      expect(
        await client.upload(session, token, good, goodHash, (_) {}, stop),
        saved,
      );
      expect(await b.downloads.list().length, 1);
    } finally {
      client.close();
    }
  });

  test('lost upload reply: status returns the committed receipt without a duplicate', () async {
    final file = MemorySource('回执.txt', [1, 3, 5]);
    final requestId = randomId();
    a.verifyOverride = (id, receiver, _) =>
        id == requestId && receiver == b.identity.id;
    final client = PinnedClient(b.device);
    final recovery = PinnedClient(b.device);
    b.afterCommit = () async => client.close();
    try {
      final offered = await client.control('POST', '/v1/offers', {
        'requestId': requestId,
        'senderId': a.identity.id,
        'senderPort': a.receiver.port,
        'files': [file.spec.toJson()],
      });
      final id = offered['id'] as String;
      b.receiver.decide(b.offer!, true);
      final status = await client.control('GET', '/v1/transfers/$id');
      final token = status['token'] as String;
      final digest = sha256.convert(file.data).toString();
      await expectLater(
        client.upload(id, token, file, digest, (_) {}, TransferCancellation()),
        throwsA(anything),
      );
      await until(() => b.offer?.state == SessionState.completed);
      final result = await recovery.control('GET', '/v1/transfers/$id');
      expect(result['state'], 'completed');
      final receipt = await recovery.upload(
        id,
        token,
        file,
        digest,
        (_) {},
        TransferCancellation(),
      );
      expect(receipt, (result['files'] as List).single);
      expect(await b.downloads.list().length, 1);
    } finally {
      client.close();
      recovery.close();
    }
  });

  test('restoring interrupted result retains committed files and explicit unknown status', () async {
    final original = Outgoing(
      Device(
        id: b.identity.id,
        name: 'Windows',
        address: InternetAddress('192.168.10.20'),
        port: b.receiver.port,
        platform: 'windows',
      ),
      [
        MemorySource('已保存.txt', [1]),
        MemorySource('待确认.txt', [2]),
      ],
    );
    original.state = SessionState.accepted;
    original.files.first
      ..bytes = 1
      ..state = FileState.committed
      ..savedName = '已保存.txt';
    original.files.last.state = FileState.uploading;
    final serialized = original.checkpoint(['one', 'two']);
    serialized['unconfirmed'] = [original.files.last.spec.id];
    final restored = Outgoing.restore(
      serialized,
      (spec, _) => DiskSource(File(spec.name), spec),
    );
    expect(restored.state, SessionState.partial);
    expect(restored.unknown, isTrue);
    expect(restored.remaining.single.spec.name, '待确认.txt');
    expect(onIpv4Subnet(restored.peer.address, '192.168.10.2/24'), isTrue);
    expect(onIpv4Subnet(restored.peer.address, '192.168.11.2/24'), isFalse);
  });

  test(
    'supports sizes over 2 GiB and prevents manifest overflow or unsafe names',
    () {
      final large = FileSpec(randomId(), '视频.mp4', 3 * 1024 * 1024 * 1024);
      expect(parseManifest([large.toJson()]).single.size, large.size);
      expect(
        () => parseManifest([
          large.toJson(),
          FileSpec(randomId(), 'x', maxInt64).toJson(),
        ]),
        throwsA(errorCode('invalid_manifest')),
      );
      expect(
        () => parseManifest([large.toJson(), large.toJson()]),
        throwsA(errorCode('invalid_manifest')),
      );
      expect(safeFileName(r'..\文件/图.jpg'), '.._文件_图.jpg');
      expect(safeFileName('CON.txt'), '_CON.txt');
      expect(safeFileName('a\u0000b'), 'a_b');
    },
  );
}
