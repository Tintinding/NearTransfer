import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import 'transfer/model.dart';

abstract interface class Discovery {
  Future<void> start(
    Device local,
    List<String> networks,
    void Function(List<Device>) updated,
    void Function(String) failed,
  );
  Future<void> stop();
}

class BonsoirDirectory implements Discovery {
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirBroadcastEvent>? _broadcastEvents;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoveryEvents;

  @override
  Future<void> start(
    Device local,
    List<String> networks,
    void Function(List<Device>) updated,
    void Function(String) failed,
  ) async {
    final broadcast = _broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: 'NearTransfer-${local.id.substring(0, 16)}',
        type: serviceType,
        port: local.port,
        attributes: local.attributes,
      ),
    );
    final discovery = _discovery = BonsoirDiscovery(type: serviceType);
    final peers = <String, Device>{};
    final found = <String>{};
    void publish() {
      final distinct = {for (final peer in peers.values) peer.id: peer};
      updated(
        distinct.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
      );
    }

    void resolved(BonsoirService service) {
      final matches = [
        for (final host in service.hostAddresses)
          if (InternetAddress.tryParse(host) case final ip?
              when networks.any((network) => onIpv4Subnet(ip, network)))
            ip,
      ];
      final peer = matches.isEmpty
          ? null
          : Device.fromDiscovery(
              service.attributes,
              matches.first,
              service.port,
            );
      if (peer == null || peer.id == local.id) {
        peers.remove(service.name);
      } else {
        peers[service.name] = peer;
      }
      publish();
    }

    await broadcast.initialize().timeout(ioTimeout);
    await discovery.initialize().timeout(ioTimeout);
    final advertised = Completer<void>();
    final listening = Completer<void>();
    void fail(Completer<void> startup) {
      if (!startup.isCompleted) {
        startup.completeError(const TransferError('discovery_failed'));
      } else {
        failed('discovery_failed');
      }
    }

    // Event handlers can report failure while the platform start call is pending.
    final started = Future.wait([advertised.future, listening.future]);
    unawaited(started.then<void>((_) {}, onError: (Object _) {}));
    _broadcastEvents = broadcast.eventStream!.listen((event) {
      if (event is BonsoirBroadcastStartedEvent) {
        if (!advertised.isCompleted) advertised.complete();
      } else if (event is BonsoirBroadcastUnknownEvent ||
          event is BonsoirBroadcastStoppedEvent) {
        fail(advertised);
      }
    }, onError: (Object _) => fail(advertised));
    _discoveryEvents = discovery.eventStream!.listen((event) {
      final service = event.service;
      switch (event) {
        case BonsoirDiscoveryStartedEvent():
          if (!listening.isCompleted) listening.complete();
        case BonsoirDiscoveryServiceFoundEvent():
          if (service == null || found.length >= 256) break;
          found.add(service.name);
          if (service.hostAddresses.isEmpty) {
            unawaited(
              service
                  .resolve(discovery.serviceResolver)
                  .catchError((Object _) {}),
            );
          } else {
            resolved(service);
          }
        case BonsoirDiscoveryServiceResolvedEvent() ||
            BonsoirDiscoveryServiceUpdatedEvent():
          if (service == null || !found.contains(service.name)) break;
          resolved(service);
        case BonsoirDiscoveryServiceLostEvent():
          found.remove(service?.name);
          peers.remove(service?.name);
          publish();
        case BonsoirDiscoveryStoppedEvent() || BonsoirDiscoveryUnknownEvent():
          fail(listening);
        default:
          break;
      }
    }, onError: (Object _) => fail(listening));
    await broadcast.start().timeout(ioTimeout);
    await discovery.start().timeout(ioTimeout);
    await started.timeout(ioTimeout);
  }

  @override
  Future<void> stop() async {
    final broadcast = _broadcast, discovery = _discovery;
    _broadcast = null;
    _discovery = null;
    await Future.wait([
      if (broadcast?.isReady == true) _stop(broadcast!.stop),
      if (discovery?.isReady == true) _stop(discovery!.stop),
    ]);
    await _broadcastEvents?.cancel();
    await _discoveryEvents?.cancel();
    _broadcastEvents = null;
    _discoveryEvents = null;
  }

  Future<void> _stop(Future<void> Function() stop) async {
    try {
      await stop().timeout(const Duration(seconds: 3));
    } catch (_) {
      // A network change may already have stopped the native action.
    }
  }
}
