import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'discovery.dart';
import 'l10n/generated/app_localizations.dart';
import 'language.dart';
import 'platform_bridge.dart';
import 'transfer/identity.dart';
import 'transfer/model.dart';
import 'transfer/receiver.dart';
import 'transfer/sender.dart';

class AppController extends ChangeNotifier {
  AppController({required this.bridge, required this.discovery});
  final PlatformBridge bridge;
  final Discovery discovery;
  Receiver? _receiver;
  Sender? _sender;
  PeerHistory? _history;
  File? _journal;
  File? _languageFile;
  StreamSubscription<String>? _networks;
  StreamSubscription<FileSelection>? _drops;
  Future<void> _configuration = Future.value();
  Future<void> _journalWrites = Future.value();
  Future<void> _languageWrites = Future.value();
  Future<void>? _sending;
  Future<void>? _shutdown;
  String? _network;
  String? _networkFailure;
  bool _foreground = true;
  bool _disposed = false;
  bool _closing = false;
  bool _initializing = false;
  int _generation = 0;
  bool ready = false;
  bool picking = false;
  bool reconciling = false;
  bool showOutgoing = true;
  bool receiveTab = false;
  String? networkError;
  String Function()? _notice;
  String? get notice => _notice?.call();
  AppLanguage _language = AppLanguage.chinese;
  bool _languageChosen = false;
  AppLanguage get language => _language;
  late AppLocalizations _strings = lookupAppLocalizations(_language.locale);
  AppLocalizations get strings => _strings;
  late String localName = switch (bridge.platform) {
    'windows' => 'Windows',
    'macos' => 'Mac',
    'ios' => 'iOS / iPadOS',
    _ => 'Android',
  };
  List<Device> devices = [];
  List<PlatformSource> files = [];
  String? selected;
  Incoming? incoming;
  Outgoing? get outgoing => _sender?.current;
  bool get busy =>
      outgoing?.running == true || _receiver?.busy == true || reconciling;
  Device? get selectedDevice => _device(selected);
  bool get windows => bridge.platform == 'windows';
  bool get macos => bridge.platform == 'macos';
  bool get desktop => windows || macos;
  bool get ios => bridge.platform == 'ios';

  String message(String code) {
    if (macos) {
      switch (code) {
        case 'network_permission' || 'discovery_failed':
          return strings.macLocalNetworkHint;
        case 'no_network':
          return strings.macNoNetwork;
        case 'offline' ||
            'sender_not_discovered' ||
            'unverified_sender' ||
            'interrupted':
          return strings.macOffline;
      }
    }
    return (ios ? _iosErrorMessage(strings, code) : null) ??
        _errorMessage(strings, code, windows: windows);
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_closing) return;
    _languageChosen = true;
    if (_language != language) _applyLanguage(language);
    await _saveLanguage(language);
  }

  void _applyLanguage(AppLanguage language) {
    _language = language;
    _strings = lookupAppLocalizations(language.locale);
    _notify();
  }

  Future<void> _loadLanguage(Directory directory) async {
    if (_languageFile != null) return;
    final file = File('${directory.path}/language.json');
    var saved = AppLanguage.chinese;
    try {
      if (await file.exists()) {
        saved = AppLanguage.fromCode(jsonDecode(await file.readAsString()));
      }
    } on FileSystemException {
      // A missing or unreadable preference keeps the default.
    } on FormatException {
      // A malformed preference keeps the default.
    }
    if (_closing) return;
    _languageFile = file;
    if (_languageChosen) {
      await _saveLanguage(_language);
    } else if (_language != saved) {
      _applyLanguage(saved);
    }
  }

  Future<void> _saveLanguage(AppLanguage language) {
    final file = _languageFile;
    if (file == null) return Future.value();
    return _languageWrites = _languageWrites.then((_) async {
      try {
        await atomicJson(file, language.code);
      } on FileSystemException {
        if (_language == language) {
          _setNotice(() => strings.languageSaveFailed);
        }
      }
    });
  }

  bool familiar(Device peer) => _history?.contains(peer.id) ?? false;
  Device? _device(String? id) =>
      devices.where((peer) => peer.id == id).firstOrNull;

  Future<void> initialize() async {
    if (_initializing || _receiver != null || _closing) return;
    _initializing = true;
    networkError = null;
    _notify();
    try {
      final info = await bridge.info();
      await _loadLanguage(info.directory);
      await bridge.cleanup();
      final identity = await Identity.load(info.directory);
      final history = _history = await PeerHistory.load(info.directory);
      _journal = File('${info.directory.path}/outgoing.json');
      if (_closing) return;
      localName = info.name;
      Future<void> remember(Device peer) async {
        await history.remember(peer);
        _notify();
      }

      final sender = _sender = Sender(
        id: identity.id,
        port: () => _receiver!.port,
        changed: (_) => _notify(),
        remember: remember,
        checkpoint: _checkpoint,
      );
      if (await _journal!.exists()) {
        try {
          sender.current = Outgoing.restore(
            jsonDecode(await _journal!.readAsString()) as Json,
            bridge.restore,
          );
        } catch (_) {
          _notice = () => strings.restoreFailed;
        }
      }
      await _retain();
      if (_closing) return;
      _receiver = Receiver(
        identity: identity,
        storage: bridge,
        findPeer: _device,
        canReceive: () => _foreground && !busy && !(ios && picking),
        verifyOutgoing: sender.verify,
        changed: (offer) {
          incoming = offer;
          if (offer.state == SessionState.waiting) receiveTab = true;
          _notify();
        },
        remember: remember,
      );
      _networks = bridge.network.listen(
        (network) {
          if (_network == network) return;
          _network = network;
          _networkFailure = null;
          _reconfigure(interrupt: true);
        },
        onError: (Object error) {
          _network = null;
          _networkFailure = switch (error) {
            PlatformException(code: 'discovery_failed') => 'discovery_failed',
            _ => 'network_permission',
          };
          _reconfigure(interrupt: true);
        },
      );
      _drops = bridge.drops.listen(
        _drop,
        onError: (Object error) {
          if (!_closing) _setNotice(() => message(_selectionError(error)));
        },
      );
    } on PlatformException catch (error) {
      networkError = error.code == 'already_running'
          ? error.code
          : 'startup_failed';
    } catch (_) {
      networkError = 'startup_failed';
    } finally {
      _initializing = false;
      _notify();
    }
  }

  void foreground(bool active) {
    if (active == _foreground || _closing) return;
    _foreground = active;
    _reconfigure(interrupt: !active);
  }

  void refresh() {
    if (_closing) return;
    if (_receiver == null) {
      unawaited(initialize());
    } else if (!busy) {
      _reconfigure();
      if (_network?.isNotEmpty != true) {
        unawaited(bridge.refreshNetwork().catchError((Object _) {}));
      }
    }
  }

  void _reconfigure({bool interrupt = false}) {
    final receiver = _receiver;
    if (receiver == null) return;
    final generation = ++_generation;
    ready = false;
    devices = [];
    selected = null;
    if (interrupt && outgoing?.running == true) outgoing!.stop('interrupted');
    if (interrupt && incoming?.state.active == true) {
      unawaited(receiver.cancel(incoming!));
    }
    networkError = _networkFailure ?? (_network == '' ? 'no_network' : null);
    _notify();
    _configuration = _configuration
        .then((_) async {
          await discovery.stop();
          if (interrupt || !_foreground) await receiver.stop();
          if (_closing ||
              !_foreground ||
              generation != _generation ||
              _network == null ||
              _network!.isEmpty) {
            return;
          }
          try {
            final networks = _network!.split(':').last.split(',');
            final address = desktop
                ? InternetAddress.anyIPv4
                : InternetAddress(networks.first.split('/').first);
            await receiver.start(bind: address);
            if (generation != _generation) return;
            await discovery.start(
              Device(
                id: receiver.identity.id,
                name: localName,
                port: receiver.port,
                address: address,
                platform: bridge.platform,
              ),
              networks,
              (items) {
                if (_generation != generation) return;
                devices = items;
                if (selectedDevice == null) selected = null;
                _notify();
                final job = outgoing;
                final peer = _device(job?.peer.id);
                if (ready &&
                    job?.unknown == true &&
                    job?.running == false &&
                    peer != null) {
                  unawaited(checkResult(quiet: true));
                }
              },
              (code) {
                if (_generation != generation) return;
                ready = false;
                devices = [];
                networkError = code;
                _notify();
              },
            );
            if (generation != _generation) return;
            ready = true;
            if (outgoing?.unknown == true &&
                _device(outgoing?.peer.id) != null) {
              unawaited(checkResult(quiet: true));
            }
          } catch (_) {
            await discovery.stop();
            await receiver.stop();
            if (generation != _generation) return;
            networkError = 'discovery_failed';
          }
          _notify();
        })
        .catchError((Object _) {
          if (generation == _generation) {
            networkError = 'discovery_failed';
            _notify();
          }
        });
  }

  void tab(bool receive) {
    receiveTab = receive;
    _notice = null;
    _notify();
  }

  Future<void> pick() async {
    if (picking || busy || _closing) return;
    picking = true;
    _notice = null;
    _notify();
    try {
      final selection = await bridge.pick();
      if (!_closing) _add(selection, dropped: false);
    } catch (error) {
      _notice = () => message(_selectionError(error));
    } finally {
      picking = false;
      await _retain();
      _notify();
    }
  }

  void _drop(FileSelection selection) {
    if (_closing) return;
    if (picking || busy) {
      _setNotice(
        picking ? () => strings.dropWhilePicking : () => strings.dropWhileBusy,
      );
      return;
    }
    try {
      _add(selection, dropped: true);
    } on TransferError catch (error) {
      _notice = () => message(error.code);
    }
    _notify();
  }

  void _add(FileSelection selection, {required bool dropped}) {
    if (selection.files.isNotEmpty) {
      final startDraft = dropped && showOutgoing && outgoing != null;
      final unique = {
        for (final file in [if (!startDraft) ...files, ...selection.files])
          bridge.selectionKey(file): file,
      }.values.toList();
      if (unique.length > maxFiles) throw const TransferError('too_many_files');
      parseManifest(unique.map((file) => file.spec.toJson()).toList());
      files = unique;
      if (dropped) receiveTab = false;
      if (startDraft) {
        showOutgoing = false;
        selected = null;
      }
    }
    final issues = selection.issues;
    _notice = issues.isEmpty
        ? (selection.files.isEmpty && !dropped
              ? () => strings.selectionCanceled
              : null)
        : () => [
            for (final issue in issues.take(3))
              '${issue.name} · ${message(issue.code)}',
            if (issues.length > 3) strings.moreIssues(issues.length - 3),
          ].join('\n');
  }

  String _selectionError(Object error) => switch (error) {
    PlatformException() => error.code,
    TransferError() => error.code,
    _ => 'source_unreadable',
  };

  void remove(PlatformSource file) {
    final key = bridge.selectionKey(file);
    files = files.where((item) => bridge.selectionKey(item) != key).toList();
    unawaited(_retain());
    _notify();
  }

  void choose(Device peer) {
    selected = peer.id;
    _notify();
  }

  void newDraft() {
    if (busy) return;
    showOutgoing = false;
    files = [];
    selected = null;
    _notice = null;
    unawaited(_retain());
    _notify();
  }

  Future<void> send() async {
    final peer = selectedDevice;
    if (!ready || busy || picking || peer == null || files.isEmpty) return;
    await _send(Outgoing(peer, List.of(files)));
  }

  Future<void> _send(Outgoing job) async {
    showOutgoing = true;
    _notice = null;
    try {
      await (_sending = _sender!.send(job));
    } on TransferError catch (error) {
      _notice = () => message(error.code);
    } finally {
      await _retain();
      _notify();
    }
  }

  void decide(bool accept) {
    final offer = incoming;
    if (offer != null) _receiver?.decide(offer, accept);
  }

  void cancelOutgoing() => outgoing?.stop();
  Future<void> cancelIncoming() async {
    final offer = incoming;
    if (offer != null) await _receiver?.cancel(offer);
  }

  Future<bool> checkResult({bool quiet = false}) async {
    final job = outgoing;
    if (job == null || busy) return false;
    final peer = _device(job.peer.id);
    if (peer == null) {
      if (!quiet) _setNotice(() => message('offline'));
      return false;
    }
    reconciling = true;
    _notify();
    try {
      final checked = await _sender!.reconcile(job, peer);
      await _checkpoint(job).catchError((Object _) {});
      if (!checked && !quiet) _setNotice(() => strings.resultUnavailable);
      return checked;
    } finally {
      reconciling = false;
      _notify();
    }
  }

  Future<void> retry({bool checkedManually = false}) async {
    final previous = outgoing;
    if (previous == null || busy || !ready) return;
    final peer = _device(previous.peer.id);
    if (peer == null) {
      _setNotice(() => message('offline'));
      return;
    }
    if (previous.unknown &&
        !await checkResult(quiet: true) &&
        !checkedManually) {
      _setNotice(() => strings.checkBeforeRetry);
      return;
    }
    if (busy || !ready) return;
    final remaining = previous.remaining.toList();
    if (remaining.isEmpty) return;
    await _send(Outgoing(peer, remaining));
  }

  Future<void> open(SavedFile file) async {
    try {
      await bridge.open(file.location);
    } catch (error) {
      _setNotice(
        () => switch (bridge.platform) {
          'windows' => strings.openFailedWindows,
          'macos' => strings.macOpenFailed,
          'ios'
              when error is PlatformException &&
                  error.code == 'preview_unsupported' =>
            strings.previewUnsupported,
          'ios' => strings.openFailedIos,
          _ => strings.openFailedAndroid,
        },
      );
    }
  }

  Future<void> export(SavedFile file) async {
    try {
      await bridge.export(file.location);
    } catch (_) {
      _setNotice(() => strings.exportFailed);
    }
  }

  Future<void> reveal(SavedFile file) async {
    try {
      await bridge.reveal(file.location);
    } catch (_) {
      _setNotice(() => macos ? strings.macRevealFailed : strings.revealFailed);
    }
  }

  Future<void> downloads() async {
    try {
      await bridge.downloads();
    } catch (_) {
      _setNotice(
        () => switch (bridge.platform) {
          'windows' => strings.downloadsFailedWindows,
          'macos' => strings.macDownloadsFailed,
          _ => strings.downloadsFailedAndroid,
        },
      );
    }
  }

  Future<void> _retain() => bridge
      .retain([...files, ...?outgoing?.remaining.whereType<PlatformSource>()])
      .catchError((Object _) {});

  Future<void> _checkpoint(Outgoing job) {
    final snapshot = job.checkpoint(
      job.sources.cast<PlatformSource>().map((file) => file.handle).toList(),
    );
    return _journalWrites = _journalWrites
        .catchError((Object _) {})
        .then((_) => atomicJson(_journal!, snapshot));
  }

  void _setNotice(String Function() message) {
    _notice = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> shutdown() => _shutdown ??= _stop();

  Future<void> _stop() async {
    _closing = true;
    _foreground = false;
    if (outgoing?.running == true) outgoing!.stop();
    _reconfigure(interrupt: true);
    await _networks?.cancel();
    await _drops?.cancel();
    await _configuration;
    await _sending?.catchError((Object _) {});
    await _journalWrites.catchError((Object _) {});
    await _languageWrites;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}

String? _iosErrorMessage(AppLocalizations t, String code) => switch (code) {
  'network_permission' => t.errorNetworkPermissionIos,
  'no_network' => t.errorNoNetworkWindows,
  'discovery_failed' => t.errorDiscoveryIos,
  'no_space' => t.errorNoSpaceIos,
  'storage_failed' => t.errorSaveIos,
  _ => null,
};

String _errorMessage(
  AppLocalizations t,
  String code, {
  required bool windows,
}) => switch (code) {
  'already_running' => t.errorAlreadyRunning,
  'network_permission' =>
    windows ? t.errorNetworkPermissionWindows : t.errorNetworkPermissionAndroid,
  'startup_failed' => t.errorStartup,
  'no_network' => windows ? t.errorNoNetworkWindows : t.errorNoNetworkAndroid,
  'discovery_failed' =>
    windows ? t.errorDiscoveryWindows : t.errorDiscoveryAndroid,
  'offline' || 'sender_not_discovered' || 'unverified_sender' =>
    windows ? t.errorOfflineWindows : t.errorOfflineAndroid,
  'certificate_changed' || 'tls_failed' => t.errorCertificate,
  'picker_failed' => windows ? t.errorPicker : t.pickerFailedSystem,
  'folder_unsupported' => t.errorFolder,
  'source_missing' => t.errorSourceMissing,
  'source_permission' => t.errorSourcePermission,
  'unknown_size' ||
  'source_unreadable' ||
  'source_changed' => t.errorSourceRead,
  'invalid_manifest' ||
  'control_too_large' ||
  'too_many_files' => t.errorFileLimit,
  'no_space' => t.errorNoSpace,
  'storage_failed' => t.errorSave,
  'digest_mismatch' || 'length_mismatch' => t.errorIntegrity,
  'busy' => t.errorBusy,
  'timeout' || 'expired' => t.errorTimeout,
  'canceled' => t.errorCanceled,
  'declined' => t.errorDeclined,
  _ => t.errorTransfer,
};
