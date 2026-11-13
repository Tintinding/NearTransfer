import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:near_transfer/controller.dart';
import 'package:near_transfer/discovery.dart';
import 'package:near_transfer/language.dart';
import 'package:near_transfer/transfer/model.dart';
import 'package:near_transfer/windows_bridge.dart';

class _WindowsBridgeWithoutNetwork extends WindowsBridge {
  @override
  Stream<String> get network => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('near_transfer/windows');
  const drops = EventChannel('near_transfer/windows/drops');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root, downloads;
  late WindowsBridge bridge;
  late List<String> picked;
  late List<MethodCall> shellCalls;
  String? commitError;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('near-transfer-win-');
    addTearDown(() => root.delete(recursive: true));
    downloads = await Directory('${root.path}\\重定向下载').create();
    bridge = _WindowsBridgeWithoutNetwork();
    picked = [];
    shellCalls = [];
    commitError = null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'info':
          return {'directory': '${root.path}\\state', 'name': 'Test Windows'};
        case 'downloadsPath':
          return downloads.path;
        case 'pick':
          return picked;
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

  test('language preference persists across controllers and falls back for invalid values', () async {
    final info = await bridge.info();
    final preference = File('${info.directory.path}/language.json');
    AppController create() =>
        AppController(bridge: bridge, discovery: BonsoirDirectory());
    final first = create();
    await first.initialize();
    expect(first.language, AppLanguage.chinese);
    await first.setLanguage(AppLanguage.french);
    final writes = [
      first.setLanguage(AppLanguage.japanese),
      first.setLanguage(AppLanguage.spanish),
    ];
    await Future.wait(writes);
    await first.shutdown();
    first.dispose();

    final second = create();
    await second.initialize();
    expect(second.language, AppLanguage.spanish);
    expect(second.message('source_missing'), contains('eliminó'));
    await second.shutdown();
    second.dispose();

    await preference.writeAsString('"unsupported"');
    final fallback = create();
    await fallback.initialize();
    expect(fallback.language, AppLanguage.chinese);
    await fallback.shutdown();
    fallback.dispose();
  }, skip: !Platform.isWindows);

  test(
    'picker and Explorer drops share a draft and report rejected paths',
    () async {
      final first = await File('${root.path}\\照片.txt').writeAsString('hello');
      final second = await File('${root.path}\\空文件.txt').create();
      final missing = '${root.path}\\已移动.txt';
      picked = [first.path, downloads.path, missing];
      final sink = Completer<MockStreamHandlerEventSink>();
      messenger.setMockStreamHandler(
        drops,
        MockStreamHandler.inline(
          onListen: (_, events) => sink.complete(events),
        ),
      );
      final controller = AppController(
        bridge: bridge,
        discovery: BonsoirDirectory(),
      );
      addTearDown(() async {
        await controller.shutdown();
        controller.dispose();
      });
      await controller.initialize();
      final drop = await sink.future;
      await controller.pick();
      expect(controller.files.single.spec.name, '照片.txt');
      expect(controller.files.single.spec.size, 5);
      expect(controller.notice, allOf(contains('文件夹'), contains('已移动或删除')));
      final source = controller.files.single;
      expect(
        await bridge
            .restore(source.spec, source.handle)
            .open()
            .expand((chunk) => chunk)
            .toList(),
        'hello'.codeUnits,
      );

      controller.tab(true);
      final added = Completer<void>();
      controller.addListener(() {
        if (controller.files.length == 2 && !added.isCompleted) {
          added.complete();
        }
      });
      drop.success([first.path, second.path]);
      await added.future.timeout(const Duration(seconds: 3));
      expect(controller.files.map((file) => file.spec.name), [
        '照片.txt',
        '空文件.txt',
      ]);
      expect(controller.receiveTab, isFalse);
      expect(controller.notice, isNull);
      controller.remove(controller.files.first);
      expect(controller.files.single.spec.size, 0);
    },
    skip: !Platform.isWindows,
  );

  test('streamed downloads commit to the current known folder without replacing collisions', () async {
    downloads = await Directory('${root.path}\\新下载目录').create();
    final existing = await File('${downloads.path}\\报告.txt')
        .writeAsString('existing');
    await Directory('${downloads.path}\\报告 (1).txt').create();
    final spec = FileSpec('a' * 32, '报告.txt', 3);
    final first = await bridge.create(spec);
    final second = await bridge.create(spec);
    await first.write([1, 2]);
    await first.write([3]);
    await second.write([4, 5, 6]);
    expect(
      await downloads
          .list()
          .where((file) => file.path.endsWith('.part'))
          .length,
      2,
    );
    final saved = await Future.wait([first.commit(), second.commit()]);
    expect(
      saved.map((file) => file.name),
      unorderedEquals(['报告 (2).txt', '报告 (3).txt']),
    );
    expect(await File(saved.first.location).readAsBytes(), [1, 2, 3]);
    expect(await File(saved.last.location).readAsBytes(), [4, 5, 6]);
    expect(await existing.readAsString(), 'existing');
    expect(
      await downloads
          .list()
          .where((file) => file.path.endsWith('.part'))
          .isEmpty,
      isTrue,
    );
    await bridge.open(saved.first.location);
    await bridge.reveal(saved.last.location);
    await bridge.downloads();
    expect(shellCalls.map((call) => (call.method, call.arguments)), [
      ('open', saved.first.location),
      ('reveal', saved.last.location),
      ('open', downloads.path),
    ]);
  }, skip: !Platform.isWindows);

  test(
    'safe Windows names retain usable extensions and stay in Downloads',
    () async {
      final reserved = await bridge.create(
        FileSpec('b' * 32, r'CONIN$.txt', 0),
      );
      final longName = await bridge.create(
        FileSpec('c' * 32, '../${'照片' * 75}.jpg', 0),
      );
      final first = await reserved.commit();
      final second = await longName.commit();
      expect(first.name, r'_CONIN$.txt');
      expect(
        second.name,
        allOf(endsWith('.jpg'), isNot(contains('/')), hasLength(lessThan(100))),
      );
      expect(File(second.location).parent.path, downloads.path);
    },
    skip: !Platform.isWindows,
  );

  test('rollback and startup cleanup remove only this installation’s partial files', () async {
    final pending = await bridge.create(FileSpec('d' * 32, '中断.txt', 2));
    await pending.write([1]);
    final scratch = (await downloads.list().single) as File;
    commitError = 'no_space';
    await expectLater(
      pending.commit(),
      throwsA(isA<TransferError>().having((e) => e.code, 'code', 'no_space')),
    );
    await pending.rollback();
    expect(await downloads.list().isEmpty, isTrue);
    commitError = null;

    await scratch.writeAsBytes([1]);
    final unrelated = await File(
      '${downloads.path}\\.neartransfer-${'e' * 32}.part',
    ).create();
    final appName = scratch.uri.pathSegments.last;
    final received = await bridge.create(FileSpec('f' * 32, appName, 0));
    final saved = await received.commit();
    expect(saved.name, '_$appName');
    await bridge.cleanup();
    expect(await scratch.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
    expect(await File(saved.location).exists(), isTrue);
  }, skip: !Platform.isWindows);
}
