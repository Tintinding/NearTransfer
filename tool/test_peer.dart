import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mdns_dart/mdns_dart.dart';
import 'package:near_transfer/transfer/identity.dart';
import 'package:near_transfer/transfer/model.dart';
import 'package:near_transfer/transfer/receiver.dart';
import 'package:near_transfer/transfer/sender.dart';

import 'disk_peer.dart';

Future<void> main(List<String> args) async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  final ip = args.isEmpty ? null : InternetAddress.tryParse(args.first);
  final adapter = interfaces
      .where(
        (iface) =>
            iface.addresses.any((address) => address.address == ip?.address),
      )
      .firstOrNull;
  if (ip == null || adapter == null || args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/test_peer.dart <LAN IPv4> <test folder>',
    );
    for (final iface in interfaces) {
      stderr.writeln(
        '${iface.name}: ${iface.addresses.map((a) => a.address).join(', ')}',
      );
    }
    exitCode = 2;
    return;
  }

  final root = Directory(args[1]).absolute;
  final private = Directory('${root.path}/peer-state');
  final identity = await Identity.load(private);
  final history = await PeerHistory.load(private);
  final downloads = Directory('${root.path}/received');
  final peers = <String, Device>{};
  late final Receiver receiver;
  Incoming? incoming;
  SessionState? lastIncoming, lastOutgoing;
  int lastReceived = 0, lastSent = 0;
  var closing = false;

  final sender = Sender(
    id: identity.id,
    port: () => receiver.port,
    remember: history.remember,
    changed: (job) {
      final sent = job.files
          .where((f) => f.state == FileState.committed)
          .length;
      if (job.state != lastOutgoing || sent != lastSent || !job.running) {
        stdout.writeln(
          'Send: ${job.state.name} ($sent/${job.files.length})'
          '${job.unknown ? " · result unknown" : ""}${job.error == null ? "" : " · ${job.error}"}',
        );
      }
      lastOutgoing = job.state;
      lastSent = sent;
    },
  );
  receiver = Receiver(
    identity: identity,
    storage: DiskStorage(downloads),
    findPeer: (id) => peers[id],
    canReceive: () => !closing && sender.current?.running != true,
    verifyOutgoing: sender.verify,
    remember: history.remember,
    changed: (job) {
      incoming = job;
      final received = job.files
          .where((f) => f.state == FileState.committed)
          .length;
      if (job.state != lastIncoming || received != lastReceived) {
        stdout.writeln(
          'Receive: ${job.state.name} ($received/${job.files.length})',
        );
        if (job.state == SessionState.waiting) {
          stdout.writeln('From ${job.peer.name}:');
          for (final file in job.files) {
            stdout.writeln('  ${file.spec.name} · ${file.spec.size} bytes');
          }
          stdout.writeln('Type accept or decline.');
        }
        if (received > lastReceived) {
          stdout.writeln('Files saved under ${downloads.path}');
        }
      }
      lastIncoming = job.state;
      lastReceived = received;
    },
  );
  await receiver.start(bind: ip);
  final local = Device(
    id: identity.id,
    name: 'Windows 测试端',
    address: ip,
    port: receiver.port,
    platform: 'windows',
  );
  final tag = 'NearTransfer-${identity.id.substring(0, 16)}';
  final zone = await MDNSService.create(
    instance: tag,
    service: serviceType,
    hostName: '$tag.local.',
    port: local.port,
    ips: [ip],
    txt: [
      for (final entry in local.attributes.entries)
        // mdns_dart stores the TXT octets as one code unit per byte.
        String.fromCharCodes(utf8.encode('${entry.key}=${entry.value}')),
    ],
  );
  final mdns = MDNSServer(
    MDNSServerConfig(zone: zone, networkInterface: adapter),
  );

  Future<void> browse() async {
    while (!closing) {
      try {
        final services = await MDNSClient.discover(
          serviceType,
          networkInterface: adapter,
          wantUnicastResponse: true,
        );
        final found = <String, Device>{};
        for (final item in services) {
          final address = item.addrV4;
          if (address == null) continue;
          final peer = Device.fromDiscovery(
            MDNSService.parseTXTRecords([
              for (final field in item.infoFields)
                utf8.decode(field.codeUnits, allowMalformed: true),
            ]),
            address,
            item.port,
          );
          if (peer != null && peer.id != identity.id) found[peer.id] = peer;
        }
        peers
          ..clear()
          ..addAll(found);
      } catch (error) {
        stderr.writeln('Discovery unavailable: ${error.runtimeType}');
      }
      if (!closing) await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  try {
    await mdns.start();
    stdout.writeln(
      'Listening on ${ip.address}:${receiver.port}. '
      'Allow Dart TCP and mDNS on the private LAN if Windows prompts.',
    );
    stdout.writeln(
      'Commands: list · send <number> ["path"] · accept · decline · cancel · retry · quit',
    );
    final scanning = browse();
    List<Device> listed = [];
    Future<void>? sending;
    await for (final raw
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final line = raw.trim();
      if (line == 'quit') break;
      try {
        if (line == 'list') {
          listed = peers.values.toList()
            ..sort((a, b) => a.name.compareTo(b.name));
          for (var index = 0; index < listed.length; index++) {
            final peer = listed[index];
            stdout.writeln(
              '${index + 1}. ${peer.name} (${peer.address.address})'
              '${history.contains(peer.id) ? " · 传过文件" : ""}',
            );
          }
          if (listed.isEmpty) stdout.writeln('No nearby devices yet.');
        } else if ((line == 'accept' || line == 'decline') &&
            incoming != null) {
          receiver.decide(incoming!, line == 'accept');
        } else if (line == 'cancel') {
          if (sender.current?.running == true) {
            sender.current!.stop();
          } else if (incoming != null) {
            await receiver.cancel(incoming!);
          }
        } else if (line.startsWith('send ') &&
            !receiver.busy &&
            sender.current?.running != true) {
          final match = RegExp(r'^send (\d+) (\[.*\])$').firstMatch(line);
          if (match == null) {
            throw const FormatException('Use send <number> ["path"]');
          }
          final peer = peers[listed[int.parse(match[1]!) - 1].id];
          if (peer == null) throw const TransferError('offline');
          final files = (jsonDecode(match[2]!) as List).cast<String>();
          sending = sender
              .send(
                Outgoing(peer, [
                  for (final file in files) await DiskSource.select(file),
                ]),
              )
              .catchError(
                (Object error) => stderr.writeln('Send failed: $error'),
              );
        } else if (line == 'retry' &&
            !receiver.busy &&
            sender.current?.running == false) {
          final previous = sender.current!;
          final peer = peers[previous.peer.id];
          if (peer == null) throw const TransferError('offline');
          if (previous.unknown && !await sender.reconcile(previous, peer)) {
            stdout.writeln(
              'Result unknown; check the receiver before sending again.',
            );
          } else if (previous.remaining.isNotEmpty) {
            sending = sender.send(Outgoing(peer, previous.remaining.toList()));
          }
        } else {
          stdout.writeln(
            'Unknown command or no matching transfer. Type list to refresh devices.',
          );
        }
      } catch (error) {
        stderr.writeln(error);
      }
    }
    closing = true;
    sender.current?.stop();
    await sending;
    await scanning;
  } finally {
    closing = true;
    await mdns.stop();
    await receiver.stop();
  }
}
