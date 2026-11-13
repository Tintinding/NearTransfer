import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:near_transfer/controller.dart';
import 'package:near_transfer/discovery.dart';
import 'package:near_transfer/macos_bridge.dart';
import 'package:near_transfer/main.dart';
import 'package:near_transfer/transfer/model.dart';
import 'package:near_transfer/transfer/receiver.dart';

class _MacController extends AppController {
  _MacController()
    : super(bridge: MacOSBridge(), discovery: BonsoirDirectory());

  final peer = Device(
    id: 'a' * 64,
    name: '附近的 Mac',
    address: InternetAddress('192.168.1.12'),
    port: 15555,
    platform: 'macos',
  );
  int refreshes = 0;
  int downloadsOpened = 0;
  SavedFile? opened;
  SavedFile? revealed;

  @override
  Future<void> initialize() async {}

  @override
  void refresh() => refreshes++;

  @override
  Future<void> open(SavedFile file) async => opened = file;

  @override
  Future<void> reveal(SavedFile file) async => revealed = file;

  @override
  Future<void> downloads() async => downloadsOpened++;

  void failDiscovery() {
    networkError = 'discovery_failed';
    notifyListeners();
  }

  void discoverPeer() {
    networkError = null;
    ready = true;
    devices = [peer];
    notifyListeners();
  }

  void finishReceive(SavedFile saved) {
    final offer = Incoming('b' * 32, peer, [
      FileSpec('c' * 32, saved.name, 10),
    ], DateTime.now())..state = SessionState.completed;
    offer.files.single
      ..state = FileState.committed
      ..saved = saved
      ..savedName = saved.name;
    incoming = offer;
    receiveTab = true;
    notifyListeners();
  }
}

void main() {
  testWidgets('macOS startup offers permission help and discovery recheck', (
    tester,
  ) async {
    final controller = _MacController();
    await tester.pumpWidget(NearTransferApp(controller: controller));
    final help = find.textContaining('系统设置 → 隐私与安全性 → 本地网络');
    expect(help, findsOneWidget);
    controller.failDiscovery();
    await tester.pump();
    expect(help, findsOneWidget);
    await tester.tap(find.text('重新检查'));
    expect(controller.refreshes, 1);

    controller.discoverPeer();
    await tester.pumpAndSettle();
    expect(help, findsNothing);
    expect(find.text('附近的 Mac'), findsOneWidget);
    expect(find.text('macOS'), findsOneWidget);
  });

  testWidgets('macOS uses desktop layout and Finder file actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(920, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _MacController()..discoverPeer();
    await tester.pumpWidget(NearTransferApp(controller: controller));
    final files = find.text('待发送文件');
    final nearby = find.text('附近设备');
    expect(tester.getTopLeft(files).dy, tester.getTopLeft(nearby).dy);
    expect(tester.getTopLeft(files).dx, lessThan(tester.getTopLeft(nearby).dx));
    expect(find.text('使用系统文件选择器，支持多选'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(400, 440));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(files).dy, lessThan(tester.getTopLeft(nearby).dy));
    expect(tester.takeException(), isNull);

    const saved = SavedFile('照片.txt', '/Users/test/Downloads/照片.txt');
    controller.finishReceive(saved);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('打开 照片.txt'));
    await tester.tap(find.byTooltip('在访达中定位 照片.txt'));
    await tester.tap(find.text('打开下载目录'));
    expect(controller.opened, saved);
    expect(controller.revealed, saved);
    expect(controller.downloadsOpened, 1);
  });
}
