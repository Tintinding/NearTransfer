import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import 'android_bridge.dart';
import 'controller.dart';
import 'discovery.dart';
import 'ios_bridge.dart';
import 'l10n/generated/app_localizations.dart';
import 'language.dart';
import 'macos_bridge.dart';
import 'transfer/model.dart';
import 'transfer/receiver.dart';
import 'windows_bridge.dart';
import 'windows_desktop.dart';

const _green = Color(0xff195640);
const _ink = Color(0xff20352c);
const _muted = Color(0xff586b61);
const _line = Color(0xffdce5dc);
const _background = Color(0xfff5f7f3);
const _light = Color(0xffe8f2eb);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    NearTransferApp(
      controller: AppController(
        bridge: switch (Platform.operatingSystem) {
          'windows' => WindowsBridge(),
          'macos' => MacOSBridge(),
          'ios' => IosBridge(),
          _ => AndroidBridge(),
        },
        discovery: BonsoirDirectory(),
      ),
    ),
  );
}

class NearTransferApp extends StatefulWidget {
  const NearTransferApp({super.key, required this.controller});
  final AppController controller;

  @override
  State<NearTransferApp> createState() => _NearTransferAppState();
}

class _NearTransferAppState extends State<NearTransferApp>
    with WidgetsBindingObserver {
  WindowsDesktop? _desktop;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller.windows) {
      _desktop = WindowsDesktop(widget.controller)..start();
    }
    unawaited(widget.controller.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.controller.windows) return;
    switch (state) {
      case AppLifecycleState.resumed:
        widget.controller.foreground(true);
      case AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached:
        widget.controller.foreground(false);
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await widget.controller.shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _desktop?.dispose();
    widget.controller.dispose();
    super.dispose();
  }

  late final _theme = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: _green)
        .copyWith(primary: _green, onSurface: _ink, surface: Colors.white),
    scaffoldBackgroundColor: _background,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: _line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: widget.controller.strings.appName,
      theme: _theme,
      locale: widget.controller.language.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      home: _Home(widget.controller),
    ),
  );
}

class _Home extends StatefulWidget {
  const _Home(this.app);
  final AppController app;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  AppController get app => widget.app;
  AppLocalizations get t => app.strings;
  Incoming? _dialogOffer;
  DialogRoute<void>? _offerRoute;

  Incoming? get _waitingOffer {
    final offer = app.incoming;
    return offer?.state == SessionState.waiting ? offer : null;
  }

  void _updateOfferDialog() {
    if (!mounted) return;
    final offer = _waitingOffer;
    if (identical(offer, _dialogOffer)) return;
    final oldRoute = _offerRoute;
    if (oldRoute != null && oldRoute.isActive) {
      oldRoute.navigator!.removeRoute(oldRoute);
    }
    _dialogOffer = offer;
    _offerRoute = null;
    if (offer == null) return;
    final route = _offerRoute = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(AppLocalizations.of(context).incomingRequest),
          scrollable: true,
          content: _offerDetails(offer),
          actions: _offerActions(offer),
        ),
      ),
    );
    unawaited(Navigator.of(context, rootNavigator: true).push(route));
  }

  @override
  Widget build(BuildContext context) {
    if (app.ios && !identical(_waitingOffer, _dialogOffer)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateOfferDialog());
    }
    final showTask =
        !app.receiveTab && app.showOutgoing && app.outgoing != null;
    final networkError = app.networkError;
    final macNetworkHelp = app.macos && (!app.ready || app.devices.isEmpty);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: app.desktop || app.ios ? 1080 : 600,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const _Tile(Icons.swap_horiz_rounded, brand: true),
                          const SizedBox(width: 10),
                          Flexible(
                            flex: 2,
                            child: Text(
                              t.appName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              app.localName,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: const TextStyle(color: _muted),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.circle,
                            size: 8,
                            color: app.ready ? const Color(0xff379368) : _muted,
                          ),
                          const SizedBox(width: 8),
                          PopupMenuButton<AppLanguage>(
                            tooltip: t.language,
                            borderRadius: BorderRadius.circular(9),
                            position: PopupMenuPosition.under,
                            initialValue: app.language,
                            onSelected: app.setLanguage,
                            itemBuilder: (_) => [
                              for (final language in AppLanguage.values)
                                CheckedPopupMenuItem(
                                  value: language,
                                  checked: language == app.language,
                                  child: Text(language.label),
                                ),
                            ],
                            child: Ink(
                              decoration: BoxDecoration(
                                color: _light,
                                border: Border.all(color: _line),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  child: Center(
                                    widthFactor: 1,
                                    heightFactor: 1,
                                    child: Text(
                                      'ZH ⇄ EN',
                                      style: TextStyle(
                                        color: _green,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: _light,
                          border: Border.all(color: _line),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Row(
                            children: [
                              _tab(t.sendFiles, Icons.send_outlined, false),
                              _tab(
                                t.receiveFiles,
                                Icons.file_download_outlined,
                                true,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    key: ValueKey((app.receiveTab, showTask)),
                    padding: const EdgeInsets.fromLTRB(16, 21, 16, 14),
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          app.receiveTab ? t.receiveFiles : t.sendFiles,
                          style: const TextStyle(
                            fontSize: 29,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      _Hint(app.receiveTab ? t.receiveHint : t.sendHint),
                      const SizedBox(height: 15),
                      if (networkError != null || macNetworkHelp)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _Panel(
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _Hint(
                                  networkError == null
                                      ? t.macLocalNetworkHint
                                      : app.message(networkError),
                                ),
                                if (!app.busy &&
                                    (networkError != null || app.ready))
                                  TextButton(
                                    onPressed: app.refresh,
                                    child: Text(t.recheck),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      if (app.notice case final message?)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Semantics(
                            liveRegion: true,
                            child: _Hint(message),
                          ),
                        ),
                      if (app.receiveTab)
                        _receive(context)
                      else if (showTask)
                        _sendTask(context)
                      else
                        _sendDraft(),
                    ],
                  ),
                ),
                if (!app.receiveTab && !showTask) _sendBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(String title, IconData icon, bool receive) {
    final selected = app.receiveTab == receive;
    return Expanded(
      child: Semantics(
        selected: selected,
        child: TextButton.icon(
          onPressed: () => app.tab(receive),
          style: TextButton.styleFrom(
            backgroundColor: selected ? Colors.white : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
          ),
          icon: Icon(icon, size: 17),
          label: Text(
            receive && app.incoming?.state == SessionState.waiting
                ? '$title · 1'
                : title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  Widget _sendDraft() => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= 680) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: _draft()),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: _devices()),
          ],
        );
      }
      return Column(
        children: [_draft(), const SizedBox(height: 11), _devices()],
      );
    },
  );

  Widget _draft() {
    final files = app.files;
    return _Panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelTitle(
            t.filesToSend,
            files.isEmpty ? '' : _summary(files.map((file) => file.spec)),
          ),
          const SizedBox(height: 10),
          if (files.isEmpty)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xfff5faf5),
                  side: const BorderSide(color: Color(0xff9dbda9)),
                  minimumSize: const Size(0, 133),
                ),
                onPressed: app.picking || app.busy ? null : app.pick,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _Tile(Icons.folder_open_outlined),
                    const SizedBox(height: 7),
                    Text(
                      app.picking ? t.choosing : t.chooseFiles,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    _Hint(
                      app.windows
                          ? t.chooseWindowsHint
                          : t.chooseSystemFilesHint,
                    ),
                  ],
                ),
              ),
            )
          else ...[
            for (final file in files)
              _fileRow(
                file.spec,
                trailing: IconButton(
                  onPressed: app.busy || (app.ios && app.picking)
                      ? null
                      : () => app.remove(file),
                  tooltip: t.removeFile(file.spec.name),
                  icon: const Icon(Icons.close, size: 19),
                ),
              ),
            OutlinedButton.icon(
              onPressed: app.picking || app.busy ? null : app.pick,
              icon: const Icon(Icons.add, size: 18),
              label: Text(app.ios && app.picking ? t.choosing : t.addFiles),
            ),
          ],
        ],
      ),
    );
  }

  Widget _devices() => _Panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelTitle(t.nearbyDevices, t.onlineCount(app.devices.length)),
        const SizedBox(height: 10),
        if (app.devices.isEmpty)
          _Hint(t.noPeers)
        else
          for (final peer in app.devices) _deviceCard(peer),
      ],
    ),
  );

  Widget _deviceCard(Device peer) {
    final selected = app.selected == peer.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: selected ? const Color(0xffedf7ef) : const Color(0xfffbfcfa),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? const Color(0xff5e9e7a) : _line),
        ),
        child: Semantics(
          selected: selected,
          child: ListTile(
            onTap: app.busy ? null : () => app.choose(peer),
            minVerticalPadding: 7,
            leading: _Tile(switch (peer.platform) {
              'android' || 'harmonyos' => Icons.phone_android,
              'ios' => Icons.phone_iphone,
              _ => Icons.desktop_windows_outlined,
            }),
            title: Text(
              peer.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Wrap(
              spacing: 7,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Hint(switch (peer.platform) {
                  'android' => 'Android',
                  'ios' => 'iOS / iPadOS',
                  'windows' => 'Windows',
                  'macos' => 'macOS',
                  'harmonyos' => 'HarmonyOS',
                  _ => t.localDevice,
                }),
                if (app.familiar(peer))
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      color: _light,
                      borderRadius: BorderRadius.all(Radius.circular(5)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        t.knownDevice,
                        style: const TextStyle(color: _green, fontSize: 11),
                      ),
                    ),
                  ),
              ],
            ),
            trailing: Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? _green : _muted,
              size: 21,
            ),
          ),
        ),
      ),
    );
  }

  Widget _sendBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: _Panel(
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.files.isEmpty
                      ? t.noFiles
                      : _summary(app.files.map((file) => file.spec)),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                _Hint(
                  app.selectedDevice == null
                      ? t.noRecipient
                      : t.sendTo(app.selectedDevice!.name),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed:
                app.ready &&
                    !app.busy &&
                    !app.picking &&
                    app.files.isNotEmpty &&
                    app.selectedDevice != null
                ? app.send
                : null,
            icon: const Icon(Icons.send_outlined, size: 17),
            label: Text(t.send),
          ),
        ],
      ),
    ),
  );

  Widget _receive(BuildContext context) {
    final incoming = app.incoming;
    if (incoming == null) {
      return _Panel(
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              children: [
                const _Tile(Icons.file_download_outlined),
                const SizedBox(height: 10),
                Text(
                  app.ready ? t.awaitingOffers : t.receiverOffline,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                _Hint(t.offerHint),
              ],
            ),
          ),
        ),
      );
    }
    final files = incoming.files;
    if (incoming.state == SessionState.waiting) {
      if (app.ios) return const SizedBox.shrink();
      return _Panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.incomingRequest,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
            ),
            _offerDetails(incoming),
            _actions(_offerActions(incoming)),
          ],
        ),
      );
    }
    return _task(
      title: _title(incoming.state, sending: false),
      subtitle: t.receivedFrom(incoming.peer.name),
      files: files,
      progress: incoming.state == SessionState.accepted,
      actions: [
        if (incoming.state == SessionState.accepted)
          OutlinedButton(
            onPressed: app.cancelIncoming,
            child: Text(t.cancelTransfer),
          ),
        if (files.any((file) => file.saved != null))
          OutlinedButton.icon(
            onPressed: app.desktop
                ? app.downloads
                : () => _showLocation(context, files),
            icon: const Icon(Icons.folder_outlined),
            label: Text(app.desktop ? t.openDownloads : t.savedLocation),
          ),
      ],
    );
  }

  Widget _offerDetails(Incoming offer) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Hint(
        t.incomingOffer(
          offer.peer.name,
          _summary(offer.files.map((file) => file.spec)),
        ),
      ),
      const SizedBox(height: 10),
      for (final file in offer.files) _fileRow(file.spec),
    ],
  );

  List<Widget> _offerActions(Incoming offer) {
    void decide(bool accept) {
      if (identical(_waitingOffer, offer)) app.decide(accept);
    }

    return [
      OutlinedButton(onPressed: () => decide(false), child: Text(t.decline)),
      FilledButton(onPressed: () => decide(true), child: Text(t.accept)),
    ];
  }

  Widget _sendTask(BuildContext context) {
    final task = app.outgoing!;
    final detail = task.preparing == null
        ? t.sendTo(task.peer.name)
        : t.checkingFile(task.preparing!.name);
    return _task(
      title: task.unknown && !task.running
          ? t.unknownResult
          : _title(task.state, sending: true),
      subtitle: !task.running && task.unknown
          ? t.unknownResultHint
          : !task.running &&
                task.error != null &&
                task.state != SessionState.completed
          ? app.message(task.error!)
          : detail,
      files: task.files,
      progress: task.running && task.state == SessionState.accepted,
      actions: [
        if (task.running)
          OutlinedButton(
            onPressed: app.cancelOutgoing,
            child: Text(t.cancelTransfer),
          )
        else ...[
          TextButton(
            onPressed: app.busy ? null : app.newDraft,
            child: Text(t.sendOtherFiles),
          ),
          if (task.unknown)
            OutlinedButton(
              onPressed: app.busy ? null : () => app.checkResult(),
              child: Text(t.checkResult),
            ),
          if (task.remaining.isNotEmpty)
            FilledButton(
              onPressed: app.busy || !app.ready
                  ? null
                  : task.unknown
                  ? () => _confirmRetry(context)
                  : () => app.retry(),
              child: Text(t.retryFiles),
            ),
        ],
      ],
    );
  }

  Widget _task({
    required String title,
    required String subtitle,
    required List<TransferFile> files,
    required List<Widget> actions,
    required bool progress,
  }) {
    final size = files.fold(0, (total, file) => total + file.spec.size);
    final transferred = files.fold(0, (total, file) => total + file.bytes);
    final committed = files
        .where((file) => file.state == FileState.committed)
        .length;
    return _Panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Tile(
                committed == files.length
                    ? Icons.check
                    : progress
                    ? Icons.swap_horiz
                    : Icons.schedule,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    _Hint(subtitle),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (progress) ...[
            _panelTitle(t.progress, '${_size(transferred)} / ${_size(size)}'),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: size == 0 ? null : transferred / size,
              minHeight: 7,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
          _Hint(t.savedCount(committed, files.length)),
          const SizedBox(height: 6),
          for (final file in files)
            _fileRow(
              file.spec,
              name: file.savedName,
              detail: switch (file.state) {
                FileState.pending => t.filePending,
                FileState.uploading =>
                  '${_size(file.bytes)} / ${_size(file.spec.size)}',
                FileState.committed => t.fileSaved(_size(file.spec.size)),
                FileState.failed => app.message(file.error ?? 'interrupted'),
              },
              trailing: switch (file.saved) {
                final saved? => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: () => app.open(saved),
                      tooltip: t.openFile(saved.name),
                      icon: const Icon(Icons.open_in_new, size: 18),
                    ),
                    if (app.desktop)
                      IconButton(
                        onPressed: () => app.reveal(saved),
                        tooltip: app.macos
                            ? t.macRevealFile(saved.name)
                            : t.revealFile(saved.name),
                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                      ),
                    if (app.ios)
                      IconButton(
                        onPressed: () => app.export(saved),
                        tooltip: t.exportFile(saved.name),
                        icon: const Icon(Icons.ios_share, size: 18),
                      ),
                  ],
                ),
                null => null,
              },
            ),
          _actions(actions),
        ],
      ),
    );
  }

  Future<void> _confirmRetry(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.retryConfirmTitle),
        content: Text(t.retryConfirmHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.back),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.retryConfirmed),
          ),
        ],
      ),
    );
    if (confirmed == true) await app.retry(checkedManually: true);
  }

  Future<void> _showLocation(BuildContext context, List<TransferFile> files) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(app.ios ? t.savedLocation : t.downloads),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Hint(app.ios ? t.iosReceivedPath : t.downloadsPath),
                const SizedBox(height: 8),
                for (final file in files)
                  if (file.saved case final saved?) Text(saved.name),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.close),
            ),
            if (!app.ios)
              FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  unawaited(app.downloads());
                },
                child: Text(t.openDownloads),
              ),
          ],
        ),
      );
  String _title(SessionState state, {required bool sending}) => switch (state) {
    SessionState.waiting => t.waitingConsent,
    SessionState.accepted => sending ? t.sending : t.receiving,
    SessionState.declined => sending ? t.recipientDeclined : t.offerDeclined,
    SessionState.canceled => t.transferCanceled,
    SessionState.expired => t.transferExpired,
    SessionState.completed => sending ? t.sendComplete : t.receiveComplete,
    SessionState.partial => t.partlySaved,
    SessionState.failed => t.transferFailed,
  };

  String _summary(Iterable<FileSpec> specs) =>
      '${t.fileCount(specs.length)} · ${_size(specs.fold(0, (total, file) => total + file.size))}';

  String _size(int bytes) => _formatSize(bytes, t.localeName);
}

Widget _panelTitle(String title, String detail) => Row(
  children: [
    Expanded(
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    if (detail.isNotEmpty) Flexible(child: _Hint(detail)),
  ],
);

Widget _actions(List<Widget> items) => items.isEmpty
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 9),
        child: Align(
          alignment: Alignment.centerRight,
          child: Wrap(spacing: 7, children: items),
        ),
      );

Widget _fileRow(
  FileSpec spec, {
  String? name,
  String? detail,
  Widget? trailing,
}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 5),
  child: Row(
    children: [
      const _Tile(Icons.insert_drive_file_outlined),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name ?? spec.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            _FileSize(spec.size, detail),
          ],
        ),
      ),
      ?trailing,
    ],
  ),
);

class _Panel extends StatelessWidget {
  const _Panel(this.child);
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(13),
    ),
    child: child,
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(color: _muted, fontSize: 13, height: 1.45),
  );
}

class _Tile extends StatelessWidget {
  const _Tile(this.icon, {this.brand = false});
  final IconData icon;
  final bool brand;
  @override
  Widget build(BuildContext context) => Container(
    width: brand ? 35 : 39,
    height: brand ? 35 : 39,
    decoration: BoxDecoration(
      color: brand ? _green : _light,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon, size: 21, color: brand ? Colors.white : _green),
  );
}

class _FileSize extends StatelessWidget {
  const _FileSize(this.bytes, this.detail);
  final int bytes;
  final String? detail;

  @override
  Widget build(BuildContext context) => _Hint(
    detail ?? _formatSize(bytes, AppLocalizations.of(context).localeName),
  );
}

String _formatSize(int bytes, String locale) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB', 'EB'];
  var size = bytes / 1000;
  for (final unit in units) {
    if (size < 1000 || unit == units.last) {
      return '${NumberFormat('0.0', locale).format(size)} $unit';
    }
    size /= 1000;
  }
  return '$bytes B';
}
