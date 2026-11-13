import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import 'model.dart';

class Identity {
  Identity._(this.certificate, this.privateKey)
    : id = sha256
          .convert(CryptoUtils.getBytesFromPEMString(certificate))
          .toString();

  final String certificate;
  final String privateKey;
  final String id;

  static Future<Identity> load(Directory directory) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/identity.json');
    if (await file.exists()) {
      final json = jsonDecode(await file.readAsString()) as Json;
      return Identity._(json['cert'] as String, json['key'] as String);
    }
    final identity = await generate();
    await atomicJson(file, {
      'cert': identity.certificate,
      'key': identity.privateKey,
    });
    return identity;
  }

  static Future<Identity> generate() => Isolate.run(() {
    final pair = CryptoUtils.generateEcKeyPair();
    final privateKey = pair.privateKey as ECPrivateKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'Near Transfer'},
      privateKey,
      pair.publicKey as ECPublicKey,
    );
    final cert = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      3650,
      serialNumber: '0x1${randomId()}',
      notBefore: DateTime.now().subtract(const Duration(days: 1)),
    );
    return Identity._(cert, CryptoUtils.encodeEcPrivateKeyToPem(privateKey));
  });

  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
    ..useCertificateChainBytes(ascii.encode(certificate))
    ..usePrivateKeyBytes(ascii.encode(privateKey));
}

Future<void> atomicJson(File file, Object value) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(jsonEncode(value), flush: true);
  await temporary.rename(file.path);
}

class PeerHistory {
  PeerHistory._(this._file, this._records);
  final File _file;
  final Map<String, String> _records;
  Future<void> _writes = Future.value();

  static Future<PeerHistory> load(Directory directory) async {
    final file = File('${directory.path}/history.json');
    final data = await file.exists()
        ? Map<String, String>.from(jsonDecode(await file.readAsString()) as Map)
        : <String, String>{};
    return PeerHistory._(file, data);
  }

  bool contains(String id) => _records.containsKey(id);

  Future<void> remember(Device peer) {
    if (contains(peer.id)) return _writes;
    if (_records.length >= 256) _records.remove(_records.keys.first);
    _records[peer.id] = peer.name;
    final snapshot = Map.of(_records);
    return _writes = _writes
        .catchError((Object _) {})
        .then((_) => atomicJson(_file, snapshot));
  }
}
