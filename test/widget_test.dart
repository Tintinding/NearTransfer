import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:near_transfer/android_bridge.dart';
import 'package:near_transfer/controller.dart';
import 'package:near_transfer/discovery.dart';
import 'package:near_transfer/ios_bridge.dart';
import 'package:near_transfer/language.dart';
import 'package:near_transfer/main.dart';
import 'package:near_transfer/platform_bridge.dart';
import 'package:near_transfer/transfer/model.dart';
import 'package:near_transfer/transfer/receiver.dart';
import 'package:near_transfer/windows_bridge.dart';

class TestController extends AppController {
  TestController({bool windows = false, PlatformBridge? bridge})
    : super(
        bridge: bridge ?? (windows ? WindowsBridge() : AndroidBridge()),
        discovery: BonsoirDirectory(),
      );

  final pc = Device(
    id: 'a' * 64,
    name: '附近的电脑',
    address: InternetAddress('192.168.1.12'),
    port: 15555,
    platform: 'windows',
  );
  int sends = 0;
  int downloadsOpened = 0;
  bool? decision;
  SavedFile? opened;
  SavedFile? revealed;
  SavedFile? exported;

  @override
  Future<void> initialize() async {
    ready = true;
    localName = windows ? 'Windows 测试电脑' : 'Android 测试手机';
  }

  void discoverPc() {
    devices = [pc];
    notifyListeners();
  }

  @override
  bool familiar(Device peer) => peer.id == pc.id;

  @override
  Future<void> pick() async {
    files = [
      AndroidSource(FileSpec('b' * 32, '照片.jpg', 1200), 'content://test/image'),
    ];
    notifyListeners();
  }

  @override
  Future<void> send() async {
    sends++;
  }

  void showOffer({int count = 1}) {
    incoming = Incoming('c' * 32, pc, [
      for (var i = 0; i < count; i++)
        FileSpec(
          i.toRadixString(16).padLeft(32, '0'),
          i == 0 ? '照片.jpg' : '文件 $i.jpg',
          1200,
        ),
    ], DateTime.now().add(const Duration(seconds: 90)));
    receiveTab = true;
    notifyListeners();
  }

  @override
  void decide(bool accept) {
    decision = accept;
    incoming!.state = accept ? SessionState.accepted : SessionState.declined;
    notifyListeners();
  }

  @override
  Future<void> open(SavedFile file) async => opened = file;

  @override
  Future<void> reveal(SavedFile file) async => revealed = file;

  @override
  Future<void> downloads() async => downloadsOpened++;

  @override
  Future<void> export(SavedFile file) async => exported = file;

  void expireOffer() {
    incoming!.state = SessionState.expired;
    notifyListeners();
  }

  void finishReceive(SavedFile saved) {
    showOffer();
    incoming!.state = SessionState.completed;
    incoming!.files.single
      ..state = FileState.committed
      ..saved = saved
      ..savedName = saved.name;
    notifyListeners();
  }
}

void main() {
  const layouts = [
    ('Windows narrow window', 'windows', Size(400, 440)),
    ('Android phone', 'android', Size(360, 800)),
    ('iPhone', 'ios', Size(320, 640)),
    ('iPad landscape', 'ios', Size(1024, 768)),
    ('iPad narrow split view', 'ios', Size(320, 500)),
  ];
  for (final (layout, platform, size) in layouts) {
    testWidgets('language menu switches all five languages on $layout', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = TestController(
        windows: platform == 'windows',
        bridge: platform == 'ios' ? IosBridge() : null,
      );
      await tester.pumpWidget(NearTransferApp(controller: controller));
      const choices = [
        ('语言', 'English', 'Choose files', AppLanguage.english),
        ('Language', '日本語', 'ファイルを選択', AppLanguage.japanese),
        ('言語', 'Français', 'Choisir des fichiers', AppLanguage.french),
        ('Langue', 'Español', 'Elegir archivos', AppLanguage.spanish),
        ('Idioma', '简体中文', '选择文件', AppLanguage.chinese),
      ];
      final menu = find.widgetWithText(PopupMenuButton<AppLanguage>, 'ZH ⇄ EN');
      for (final (tooltip, option, chooseFiles, language) in choices) {
        expect(menu.hitTestable(), findsOneWidget);
        expect(tester.getSize(menu).height, greaterThanOrEqualTo(48));
        expect(find.byTooltip(tooltip), findsOneWidget);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        final entries = tester.widgetList<CheckedPopupMenuItem<AppLanguage>>(
          find.byType(CheckedPopupMenuItem<AppLanguage>),
        );
        expect(entries.map((item) => item.value), const [
          AppLanguage.english,
          AppLanguage.chinese,
          AppLanguage.japanese,
          AppLanguage.french,
          AppLanguage.spanish,
        ]);
        expect(
          entries.singleWhere((item) => item.checked).value,
          controller.language,
        );
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<AppLanguage>, option),
        );
        await tester.pumpAndSettle();
        expect(controller.language, language);
        final choice = find.text(chooseFiles);
        await tester.scrollUntilVisible(choice, 80);
        expect(choice, findsOneWidget);
        expect(menu, findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('nearby Apple and HarmonyOS peers can be selected', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TestController(windows: true)
      ..devices = [
        Device(
          id: '1' * 64,
          name: '测试 iPad',
          address: InternetAddress('192.168.1.20'),
          port: 15555,
          platform: 'ios',
        ),
        Device(
          id: '2' * 64,
          name: '测试 Mac',
          address: InternetAddress('192.168.1.21'),
          port: 15555,
          platform: 'macos',
        ),
        Device(
          id: '3' * 64,
          name: '测试鸿蒙手机',
          address: InternetAddress('192.168.1.22'),
          port: 15555,
          platform: 'harmonyos',
        ),
      ];
    await tester.pumpWidget(NearTransferApp(controller: controller));

    for (final label in ['iOS / iPadOS', 'macOS', 'HarmonyOS']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final peer in controller.devices) {
      await tester.tap(find.text(peer.name));
      await tester.pumpAndSettle();
      expect(controller.selectedDevice?.id, peer.id);
    }
  });

  testWidgets(
    'send requires selecting a file and online device, then an explicit tap',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = TestController();
      await tester.pumpWidget(NearTransferApp(controller: controller));
      expect(find.text('请确认两台设备都已打开近传，并连接同一局域网。'), findsOneWidget);
      final send = find.widgetWithText(FilledButton, '发送');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.tap(find.text('选择文件'));
      await tester.pumpAndSettle();
      expect(find.text('照片.jpg'), findsOneWidget);
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      controller.discoverPc();
      await tester.pumpAndSettle();
      expect(find.text('传过文件'), findsOneWidget);
      await tester.tap(find.text('附近的电脑'));
      await tester.pumpAndSettle();
      expect(find.text('发送至 附近的电脑'), findsOneWidget);
      expect(controller.sends, 0);
      await tester.tap(send);
      expect(controller.sends, 1);
    },
  );

  testWidgets(
    'incoming offer shows peer, file, total and distinct accept and decline actions',
    (tester) async {
      final controller = TestController();
      await tester.pumpWidget(NearTransferApp(controller: controller));
      controller.showOffer();
      await tester.pumpAndSettle();
      expect(find.text('收到文件请求'), findsOneWidget);
      expect(find.text('附近的电脑 想发送 1 个文件 · 1.2 KB'), findsOneWidget);
      expect(find.text('照片.jpg'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
      expect(controller.decision, isNull);
      await tester.tap(find.text('接受'));
      await tester.pump();
      expect(controller.decision, isTrue);
      expect(find.text('正在接收'), findsOneWidget);
      expect(find.text('取消传输'), findsOneWidget);
    },
  );

  testWidgets(
    'Windows lays out both panels and exposes distinct file actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = TestController(windows: true);
      await tester.pumpWidget(NearTransferApp(controller: controller));
      final files = find.text('待发送文件');
      final nearby = find.text('附近设备');
      expect(tester.getTopLeft(files).dy, tester.getTopLeft(nearby).dy);
      expect(
        tester.getTopLeft(files).dx,
        lessThan(tester.getTopLeft(nearby).dx),
      );
      expect(find.text('支持多选，也可从资源管理器拖入文件'), findsOneWidget);

      await tester.binding.setSurfaceSize(const Size(400, 440));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(files).dy,
        lessThan(tester.getTopLeft(nearby).dy),
      );
      expect(tester.takeException(), isNull);

      const saved = SavedFile('照片 (1).jpg', r'D:\Downloads\照片 (1).jpg');
      controller.finishReceive(saved);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('打开 照片 (1).jpg'));
      expect(controller.opened, saved);
      await tester.tap(find.byTooltip('定位 照片 (1).jpg'));
      expect(controller.revealed, saved);
    },
  );

  testWidgets('Windows tray commands reuse send, receive and Downloads', (
    tester,
  ) async {
    final controller = TestController(windows: true);
    await tester.pumpWidget(NearTransferApp(controller: controller));
    await _desktopCommand(tester, 'receive');
    expect(controller.receiveTab, isTrue);
    await _desktopCommand(tester, 'downloads');
    expect(controller.downloadsOpened, 1);
    await _desktopCommand(tester, 'pick');
    expect(controller.receiveTab, isFalse);
    expect(controller.files.single.spec.name, '照片.jpg');
    expect(controller.sends, 0);
  });

  testWidgets(
    'Windows request popup accepts only the current waiting request',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_desktop, (
        call,
      ) async {
        if (call.method == 'pendingOffer') calls.add(call);
        return null;
      });
      final controller = TestController(windows: true);
      await tester.pumpWidget(NearTransferApp(controller: controller));
      controller.showOffer();
      await tester.pump();
      final first = (calls.single.arguments as List).first;
      expect(calls.single.method, 'pendingOffer');
      expect(first, isNot(controller.incoming!.id));
      expect(calls.single.arguments[1], '附近的电脑 想发送 1 个文件');
      expect(controller.decision, isNull);
      controller.discoverPc();
      await tester.pump();
      expect(calls, hasLength(1));

      controller.showOffer();
      await tester.pump();
      final current = (calls.last.arguments as List).first;
      expect(current, isNot(first));
      await controller.setLanguage(AppLanguage.french);
      await tester.pump();
      expect(calls.last.arguments[0], current);
      expect(calls.last.arguments[1], '附近的电脑 souhaite envoyer 1 fichier');
      await _desktopCommand(tester, 'acceptOffer', first);
      await _desktopCommand(tester, 'viewOffer', current);
      expect(controller.decision, isNull);
      await _desktopCommand(tester, 'acceptOffer', current);
      expect(controller.decision, isTrue);
      expect(calls.last.arguments, isNull);

      controller.decision = null;
      controller.showOffer();
      await tester.pump();
      final expired = (calls.last.arguments as List).first;
      controller.incoming!.deadline = DateTime.now().subtract(
        const Duration(seconds: 1),
      );
      await _desktopCommand(tester, 'acceptOffer', expired);
      expect(controller.decision, isNull);
      controller.incoming!.state = SessionState.expired;
      controller.discoverPc();
      await tester.pump();
      expect(calls.last.method, 'pendingOffer');
      expect(calls.last.arguments, isNull);
      await _desktopCommand(tester, 'acceptOffer', expired);
      expect(controller.decision, isNull);
    },
  );

  testWidgets(
    'iPad landscape and split view retain file and device selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = TestController(bridge: IosBridge());
      await tester.pumpWidget(NearTransferApp(controller: controller));
      controller.discoverPc();
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('附近的电脑'));
      await tester.pumpAndSettle();
      final files = find.text('待发送文件');
      final nearby = find.text('附近设备');
      expect(tester.getTopLeft(files).dy, tester.getTopLeft(nearby).dy);
      expect(
        tester.getTopLeft(files).dx,
        lessThan(tester.getTopLeft(nearby).dx),
      );

      await tester.binding.setSurfaceSize(const Size(360, 510));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(files).dy,
        lessThan(tester.getTopLeft(nearby).dy),
      );
      expect(find.text('照片.jpg'), findsOneWidget);
      expect(find.text('发送至 附近的电脑'), findsOneWidget);
      expect(controller.selectedDevice, controller.pc);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('iOS confirmation stays usable as the window narrows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TestController(bridge: IosBridge());
    await tester.pumpWidget(NearTransferApp(controller: controller));
    controller.showOffer(count: 30);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.text('附近的电脑 想发送 30 个文件 · 36.0 KB'), findsOneWidget);
    expect(controller.decision, isNull);

    await tester.binding.setSurfaceSize(const Size(320, 430));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('文件 29.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('文件 29.jpg').hitTestable(), findsOneWidget);
    expect(find.text('接受').hitTestable(), findsOneWidget);
    expect(find.text('拒绝').hitTestable(), findsOneWidget);
    await tester.tapAt(const Offset(3, 3));
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    expect(tester.takeException(), isNull);

    controller.expireOffer();
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(controller.decision, isNull);
    controller.showOffer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(controller.decision, isFalse);
    expect(dialog, findsNothing);
    await controller.setLanguage(AppLanguage.english);
    controller.showOffer();
    await tester.pumpAndSettle();
    expect(find.text('Incoming file request'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pump();
    expect(controller.decision, isTrue);
  });

  testWidgets('iOS exposes preview, export and the Files location', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TestController(bridge: IosBridge());
    await tester.pumpWidget(NearTransferApp(controller: controller));
    const saved = SavedFile('照片 (1).jpg', '/Documents/Received/照片 (1).jpg');
    await controller.setLanguage(AppLanguage.english);
    controller.finishReceive(saved);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open 照片 (1).jpg'));
    expect(controller.opened, saved);
    await tester.tap(find.byTooltip('Export 照片 (1).jpg'));
    expect(controller.exported, saved);
    await tester.tap(find.text('Show save location'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('On My iPhone or On My iPad › 近传 › Received'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

const _desktop = MethodChannel('near_transfer/windows/desktop');

Future<void> _desktopCommand(
  WidgetTester tester,
  String method, [
  Object? arguments,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    _desktop.name,
    _desktop.codec.encodeMethodCall(MethodCall(method, arguments)),
    (reply) => _desktop.codec.decodeEnvelope(reply!),
  );
  await tester.pump();
}
