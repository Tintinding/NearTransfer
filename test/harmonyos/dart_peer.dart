import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:near_transfer/transfer/identity.dart';
import 'package:near_transfer/transfer/model.dart';
import 'package:near_transfer/transfer/receiver.dart';
import 'package:near_transfer/transfer/sender.dart';

import '../../tool/disk_peer.dart';

void event(Json body) => stdout.writeln(jsonEncode(body));

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('Usage: dart_peer.dart <directory> <peer SHA-256> <port>');
    exitCode = 2;
    return;
  }
  stdout.encoding = utf8;
  final local = await Identity.generate();
  final address = InternetAddress.loopbackIPv4;
  final remote = Device(
    id: args[1],
    name: 'HarmonyOS protocol host',
    address: address,
    port: int.parse(args[2]),
    platform: 'harmonyos',
  );
  late final Receiver receiver;
  Incoming? incoming;
  SessionState? reportedState;
  String? reportedId;
  final sender = Sender(
    id: local.id,
    port: () => receiver.port,
    changed: (job) {
      if (job.running) return;
      event({
        'event': 'sent',
        'state': job.state.name,
        'error': job.error,
        'unknown': job.unknown,
        'files': job.files.map((file) => file.toJson()).toList(),
      });
    },
    remember: (_) async {},
  );
  receiver = Receiver(
    identity: local,
    storage: DiskStorage(Directory(args[0])),
    findPeer: (id) => id == remote.id ? remote : null,
    canReceive: () => sender.current?.running != true,
    verifyOutgoing: sender.verify,
    changed: (session) {
      incoming = session;
      if (reportedId == session.id && reportedState == session.state) return;
      reportedId = session.id;
      reportedState = session.state;
      event({
        'event': 'incoming',
        'id': session.id,
        'state': session.state.name,
        'files': session.files.map((file) => file.toJson()).toList(),
      });
    },
    remember: (_) async {},
  );
  await receiver.start(bind: address);
  event({'event': 'ready', 'id': local.id, 'port': receiver.port});
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final command = jsonDecode(line) as Json;
      if (command['action'] == 'quit') break;
      if (command['action'] == 'send') {
        final paths = (command['paths'] as List).cast<String>();
        final files = await Future.wait(paths.map(DiskSource.select));
        unawaited(sender.send(Outgoing(remote, files)));
      } else if (incoming != null && command['action'] == 'accept') {
        receiver.decide(incoming!, true);
      } else if (incoming != null && command['action'] == 'decline') {
        receiver.decide(incoming!, false);
      }
    }
  } finally {
    sender.current?.stop();
    await receiver.stop();
  }
}
