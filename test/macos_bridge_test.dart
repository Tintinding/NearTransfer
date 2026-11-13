import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_transfer/controller.dart';
import 'package:near_transfer/discovery.dart';
import 'package:near_transfer/macos_bridge.dart';
import 'package:near_transfer/transfer/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('near_transfer/macos');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root, downloads;
  late MacOSBridge bridge;
  late List<Map<String, String>> picked;
  late Map<String, String> bookmarks;
  late List<String> released;
  late List<MethodCall> shellCalls;
  String? commitError;
  var accessCount = 0;
  var needsScope = true;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('near-transfer-mac-');
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
    downloads = await Directory('${root.path}/Downloads').create();
    bridge = MacOSBridge();
    picked = [];
    bookmarks = {};
    released = [];
    shellCalls = [];
    commitError = null;
    accessCount = 0;
    needsScope = true;
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'info':
          return {'directory': '${root.path}/state', 'name': '测试 Mac'};
        case 'network':
          return 'en0,en1:192.168.1.12/24,10.0.0.12/24';
        case 'pick':
          return picked;
        case 'startAccess':
          final path = bookmarks[call.arguments];
          if (path == null) throw PlatformException(code: 'source_missing');
          if (!needsScope) return {'path': path};
          return {'path': path, 'token': 'read-${++accessCount}'};
        case 'stopAccess':
          released.add(call.arguments as String);
          return null;
        case 'downloadsPath':
          return downloads.path;
        case 'open':
        case 'reveal':
          shellCalls.add(call);
          return null;
        case 'commit':
          if (commitError case final code?) throw PlatformException(code: code);
          final from = call.arguments['from'] as String;
          final to = call.arguments['to'] as String;
          if (FileSystemEntity.typeSync(to, followLinks: false) !=
              FileSystemEntityType.notFound) {
            return false;
          }
          File(from).renameSync(to);
          return true;
        default:
          throw MissingPluginException(call.method);
      }
    });
    await bridge.info();
  });

  test(
    'reads the device name and IPv4 interface snapshot from the runner',
    () async {
      expect(bridge.platform, 'macos');
      expect((await bridge.info()).name, '测试 Mac');
      expect(
        await bridge.network.first,
        'en0,en1:192.168.1.12/24,10.0.0.12/24',
      );
    },
  );

  test(
    'restored sources stream through the bookmark and release it on cancel',
    () async {
      final bytes = List<int>.generate(256 * 1024, (i) => i % 256);
      final file = await File('${root.path}/照片.bin').writeAsBytes(bytes);
      final empty = await File('${root.path}/空文件.txt').create();
      final denied = await File('${root.path}/无权限.txt').create();
      picked = [
        {'path': file.path, 'bookmark': 'photo-bookmark'},
        {'path': empty.path, 'bookmark': 'empty-bookmark'},
        {'path': denied.path},
      ];
      bookmarks = {'photo-bookmark': file.path, 'empty-bookmark': empty.path};

      final selection = await bridge.pick();
      expect(selection.files.map((source) => source.spec.name), [
        '照片.bin',
        '空文件.txt',
      ]);
      expect(selection.files.map((source) => source.spec.size), [
        bytes.length,
        0,
      ]);
      expect(selection.issues, [(name: '无权限.txt', code: 'source_permission')]);
      final source = selection.files.first;
      final restored = MacOSBridge().restore(source.spec, source.handle);
      expect(await sha256.bind(restored.open()).single, sha256.convert(bytes));
      final stream = StreamIterator(restored.open());
      expect(await stream.moveNext(), isTrue);
      expect(stream.current.length, lessThan(bytes.length));
      await stream.cancel();
      expect(released, ['read-1', 'read-2']);
      needsScope = false;
      expect(await sha256.bind(restored.open()).single, sha256.convert(bytes));
      expect(released, ['read-1', 'read-2']);
      bookmarks.remove('photo-bookmark');
      await expectLater(
        restored.open(),
        emitsError(
          isA<TransferError>().having(
            (error) => error.code,
            'code',
            'source_missing',
          ),
        ),
      );
      expect(released, ['read-1', 'read-2']);
    },
  );

  test(
    'reselecting a path with a new bookmark updates the draft entry',
    () async {
      final file = await File('${root.path}/照片.txt').writeAsString('test');
      final controller = AppController(
        bridge: bridge,
        discovery: BonsoirDirectory(),
      );
      addTearDown(controller.dispose);
      picked = [
        {'path': file.path, 'bookmark': 'first'},
      ];
      await controller.pick();
      final first = controller.files.single;
      picked = [
        {'path': file.path, 'bookmark': 'second'},
      ];
      await controller.pick();
      expect(controller.files.single.handle, isNot(first.handle));
      controller.remove(controller.files.single);
      expect(controller.files, isEmpty);
    },
  );

  test(
    'commits chunks under the next available name and passes Finder paths',
    () async {
      final existing = await File('${downloads.path}/报告.txt')
          .writeAsString('existing');
      await Directory('${downloads.path}/报告 (1).txt').create();
      final target = await bridge.create(FileSpec('a' * 32, '报告.txt', 3));
      await target.write([1, 2]);
      await target.write([3]);
      expect(
        await downloads
            .list()
            .where((item) => item.path.endsWith('.part'))
            .length,
        1,
      );
      final saved = await target.commit();
      expect(saved.name, '报告 (2).txt');
      expect(await File(saved.location).readAsBytes(), [1, 2, 3]);
      expect(await existing.readAsString(), 'existing');
      expect(
        await downloads.list().any((item) => item.path.endsWith('.part')),
        isFalse,
      );
      await bridge.open(saved.location);
      await bridge.reveal(saved.location);
      await bridge.downloads();
      expect(shellCalls.map((call) => (call.method, call.arguments)), [
        ('open', saved.location),
        ('reveal', saved.location),
        ('open', downloads.path),
      ]);
    },
  );

  test(
    'rolls back failed commits and cleans up this installation’s partial files',
    () async {
      final target = await bridge.create(FileSpec('a' * 32, '中断.txt', 2));
      await target.write([1]);
      final scratch = (await downloads.list().single) as File;
      commitError = 'no_space';
      await expectLater(
        target.commit(),
        throwsA(
          isA<TransferError>().having(
            (error) => error.code,
            'code',
            'no_space',
          ),
        ),
      );
      await target.rollback();
      expect(await downloads.list().isEmpty, isTrue);
      commitError = null;

      await scratch.create();
      final unrelated = await File(
        '${downloads.path}/.neartransfer-${'b' * 32}.part',
      ).create();
      final scratchName = scratch.uri.pathSegments.last;
      final next = await bridge.create(FileSpec('c' * 32, scratchName, 0));
      final saved = await next.commit();
      expect(saved.name, '_$scratchName');
      await bridge.cleanup();
      expect(await scratch.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      expect(await File(saved.location).exists(), isTrue);
    },
  );
}
