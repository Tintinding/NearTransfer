import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_transfer/controller.dart';
import 'package:near_transfer/discovery.dart';
import 'package:near_transfer/ios_bridge.dart';
import 'package:near_transfer/language.dart';
import 'package:near_transfer/transfer/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('near_transfer/ios');
  const events = EventChannel('near_transfer/ios/network');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late IosBridge bridge;
  late Directory support, sources, received, scratch;
  late List<MethodCall> calls;
  late List<Map<String, Object>> picked, issues;
  String? commitError;

  setUp(() async {
    final root = await Directory.systemTemp.createTemp('near-transfer-ios-');
    addTearDown(() => root.delete(recursive: true));
    support = Directory('${root.path}/state');
    sources = await Directory('${support.path}/Outgoing')
        .create(recursive: true);
    received = Directory('${root.path}/Documents/Received');
    scratch = Directory('${root.path}/Caches/Incoming');
    calls = [];
    picked = [];
    issues = [];
    commitError = null;
    bridge = IosBridge();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'info':
          return {
            'directory': support.path,
            'name': 'iPad',
            'received': received.path,
            'scratch': scratch.path,
          };
        case 'pick':
          return {'files': picked, 'issues': issues};
        case 'retain':
        case 'open':
        case 'export':
        case 'refreshNetwork':
          return null;
        case 'commit':
          if (commitError case final error?) {
            throw PlatformException(code: error);
          }
          final paths = (call.arguments as Map).cast<String, String>();
          final to = paths['to']!;
          if (FileSystemEntity.typeSync(to, followLinks: false) !=
              FileSystemEntityType.notFound) {
            return false;
          }
          File(paths['from']!).renameSync(to);
          return true;
        default:
          throw MissingPluginException(call.method);
      }
    });
    await bridge.info();
    await bridge.cleanup();
  });

  test('multi-select returns issues and reopenable private copies', () async {
    final photo = 'a' * 32, empty = 'b' * 32;
    final bytes = Uint8List.fromList(
      List.generate(chunkSize + 3, (index) => index % 256),
    );
    await File('${sources.path}/$photo').writeAsBytes(bytes);
    await File('${sources.path}/$empty').create();
    picked = [
      {'name': '照片.jpg', 'size': bytes.length, 'handle': photo},
      {'name': '空文件.txt', 'size': 0, 'handle': empty},
    ];
    issues = [
      {'name': '文件夹', 'code': 'folder_unsupported'},
    ];

    final selection = await bridge.pick();
    expect(calls.last.arguments, {'limit': maxFiles});
    expect(selection.files.map((file) => file.spec.name), [
      '照片.jpg',
      '空文件.txt',
    ]);
    expect(selection.issues, [(name: '文件夹', code: 'folder_unsupported')]);
    final source = selection.files.first;
    expect(source.spec.size, bytes.length);
    expect(await source.open().expand((chunk) => chunk).toList(), bytes);
    expect(
      await bridge
          .restore(source.spec, source.handle)
          .open()
          .expand((chunk) => chunk)
          .toList(),
      bytes,
    );
    expect(
      await selection.files.last.open().expand((chunk) => chunk).toList(),
      isEmpty,
    );
    expect(
      () => bridge.restore(source.spec, '../identity.pem'),
      throwsA(isA<TransferError>()),
    );
    await bridge.retain([source, source, selection.files.last]);
    expect(calls.last.arguments, {
      'handles': [photo, empty],
    });
    picked = [];
    issues = [];
    final canceled = await bridge.pick();
    expect(canceled.files, isEmpty);
    expect(canceled.issues, isEmpty);
  });

  test('picker metadata preserves file sizes above 2 GiB', () async {
    const size = (1 << 31) + 1;
    picked = [
      {'name': '视频.mov', 'size': size, 'handle': 'a' * 32},
    ];
    final selection = await bridge.pick();
    expect(selection.files.single.spec.size, size);
  });

  test(
    'publish numbers file and directory collisions without overwriting',
    () async {
      final existing = await File('${received.path}/照片.jpg')
          .writeAsString('original');
      await Directory('${received.path}/照片 (1).jpg').create();
      final spec = FileSpec('c' * 32, '照片.jpg', 3);
      final first = await bridge.create(spec);
      final second = await bridge.create(spec);
      await first.write([1]);
      await first.write([2, 3]);
      await second.write([4, 5, 6]);
      expect(await scratch.list().length, 2);
      expect(await received.list().length, 2);
      final saved = await Future.wait([first.commit(), second.commit()]);
      expect(
        saved.map((file) => file.name),
        unorderedEquals(['照片 (2).jpg', '照片 (3).jpg']),
      );
      expect(await File(saved.first.location).readAsBytes(), [1, 2, 3]);
      expect(await File(saved.last.location).readAsBytes(), [4, 5, 6]);
      expect(await existing.readAsString(), 'original');
      expect(await scratch.list().isEmpty, isTrue);
      await bridge.open(saved.first.location);
      await bridge.export(saved.last.location);
      expect(
        calls.reversed.take(2).map((call) => (call.method, call.arguments)),
        [('export', saved.last.location), ('open', saved.first.location)],
      );
    },
  );

  test(
    'rollback and relaunch remove parts and preserve received files',
    () async {
      final spec = FileSpec('d' * 32, '.照片.jpg', 2);
      final canceled = await bridge.create(spec);
      await canceled.write([1]);
      await canceled.rollback();
      expect(await scratch.list().isEmpty, isTrue);

      final failed = await bridge.create(spec);
      await failed.write([1, 2]);
      commitError = 'no_space';
      await expectLater(
        failed.commit(),
        throwsA(
          isA<TransferError>().having(
            (error) => error.code,
            'code',
            'no_space',
          ),
        ),
      );
      await failed.rollback();
      expect(await scratch.list().isEmpty, isTrue);

      commitError = null;
      final saved = await (await bridge.create(
        FileSpec('e' * 32, '../.空文件.txt', 0),
      )).commit();
      expect(saved.name, allOf(isNot(startsWith('.')), isNot(contains('/'))));
      final orphan = await File('${scratch.path}/${'f' * 32}.part').create();
      await bridge.cleanup();
      expect(await orphan.exists(), isFalse);
      expect(await File(saved.location).length(), 0);
    },
  );

  test(
    'restores the selected language from the iOS private directory',
    () async {
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
      final controller = AppController(
        bridge: bridge,
        discovery: _RecordingDiscovery(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.setLanguage(AppLanguage.french);
      await controller.shutdown();

      final reopened = AppController(
        bridge: IosBridge(),
        discovery: _RecordingDiscovery(),
      );
      addTearDown(() async {
        await reopened.shutdown();
        reopened.dispose();
      });
      await reopened.initialize();
      expect(reopened.language, AppLanguage.french);
      expect(reopened.strings.chooseFiles, 'Choisir des fichiers');
    },
  );

  test('LAN denial is shown until Bonjour permission recovers', () async {
    final listening = Completer<MockStreamHandlerEventSink>();
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          expect(arguments, serviceType);
          listening.complete(sink);
        },
      ),
    );
    final discovery = _RecordingDiscovery();
    final controller = AppController(bridge: bridge, discovery: discovery);
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
    });
    await controller.initialize();
    final sink = await listening.future.timeout(const Duration(seconds: 3));
    sink.error(code: 'network_permission');
    await _when(
      controller,
      () => controller.networkError == 'network_permission',
    );
    expect(controller.ready, isFalse);
    expect(discovery.published, isNull);
    await controller.setLanguage(AppLanguage.english);
    expect(
      controller.message(controller.networkError!),
      contains('Local Network'),
    );
    controller.refresh();
    expect(controller.networkError, 'network_permission');
    await Future<void>.delayed(Duration.zero);
    expect(calls.any((call) => call.method == 'refreshNetwork'), isTrue);

    sink.success('127.0.0.1/8');
    await _when(controller, () => controller.ready);
    expect(controller.networkError, isNull);
    expect(discovery.published?.platform, 'ios');
    expect(discovery.published?.name, 'iPad');

    controller.foreground(false);
    expect(controller.ready, isFalse);
    controller.foreground(true);
    await _when(controller, () => controller.ready);
  });
}

class _RecordingDiscovery implements Discovery {
  Device? published;

  @override
  Future<void> start(
    Device local,
    List<String> networks,
    void Function(List<Device>) updated,
    void Function(String) failed,
  ) async {
    published = local;
  }

  @override
  Future<void> stop() async => published = null;
}

Future<void> _when(AppController controller, bool Function() condition) async {
  if (condition()) return;
  final done = Completer<void>();
  void listen() {
    if (condition() && !done.isCompleted) done.complete();
  }

  controller.addListener(listen);
  try {
    await done.future.timeout(const Duration(seconds: 5));
  } finally {
    controller.removeListener(listen);
  }
}
