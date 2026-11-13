import 'dart:async';

import 'package:flutter/services.dart';

import 'controller.dart';
import 'language.dart';
import 'transfer/model.dart';
import 'transfer/receiver.dart';

class WindowsDesktop {
  WindowsDesktop(this.app);

  static const _channel = MethodChannel('near_transfer/windows/desktop');
  final AppController app;
  Incoming? _pending;
  String? _actionId;
  AppLanguage? _language;

  void start() {
    _channel.setMethodCallHandler(_handle);
    app.addListener(_syncOffer);
    _syncOffer();
  }

  void dispose() {
    app.removeListener(_syncOffer);
    _channel.setMethodCallHandler(null);
  }

  void _syncOffer() {
    final languageChanged = _language != app.language;
    final t = app.strings;
    if (languageChanged) {
      _language = app.language;
      unawaited(
        _channel
            .invokeMethod<void>('setLanguage', {
              'appName': t.appName,
              'open': t.trayOpen,
              'pick': t.trayPick,
              'receive': t.trayReceive,
              'downloads': t.openDownloads,
              'exit': t.trayExit,
              'pickerTitle': t.pickerTitle,
              'offerTitle': t.incomingRequest,
              'view': t.viewOffer,
              'accept': t.popupAccept,
              'close': t.closePopup,
            })
            .catchError((Object _) {}),
      );
    }
    final offer = app.incoming;
    final pending = offer?.state == SessionState.waiting ? offer : null;
    if (identical(pending, _pending)) {
      if (!languageChanged || pending == null) return;
    } else {
      _pending = pending;
      // The popup receives a local action ID instead of a protocol ID.
      _actionId = pending == null ? null : randomId();
    }
    unawaited(
      _channel
          .invokeMethod<void>(
            'pendingOffer',
            pending == null
                ? null
                : [
                    _actionId,
                    t.incomingOffer(
                      pending.peer.name,
                      t.fileCount(pending.files.length),
                    ),
                    pending.deadline.millisecondsSinceEpoch,
                  ],
          )
          .catchError((Object _) {}),
    );
  }

  Future<void> _handle(MethodCall call) async {
    switch (call.method) {
      case 'pick':
        if (app.busy) {
          app.tab(app.incoming?.state.active == true);
          return;
        }
        app.tab(false);
        if (app.showOutgoing && app.outgoing != null) app.newDraft();
        await app.pick();
      case 'receive':
        app.tab(true);
      case 'downloads':
        await app.downloads();
      case 'viewOffer' || 'acceptOffer':
        final offer = _pending;
        if (offer == null ||
            call.arguments != _actionId ||
            !identical(app.incoming, offer) ||
            offer.state != SessionState.waiting ||
            !DateTime.now().isBefore(offer.deadline)) {
          return;
        }
        app.tab(true);
        if (call.method == 'acceptOffer') app.decide(true);
    }
  }
}
