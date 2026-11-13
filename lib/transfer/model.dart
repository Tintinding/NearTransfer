import 'dart:convert';
import 'dart:io';
import 'dart:math';

const serviceType = '_neartransfer._tcp';
const maxFiles = 128;
const maxControlBytes = 128 * 1024;
const chunkSize = 128 * 1024;
const maxInt64 = 0x7fffffffffffffff;
const ioTimeout = Duration(seconds: 15);
final idPattern = RegExp(r'^[a-f0-9]{32}$');
final digestPattern = RegExp(r'^[a-f0-9]{64}$');
final _random = Random.secure();

String randomId() => List.generate(
  16,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

bool onIpv4Subnet(InternetAddress peer, String cidr) {
  final parts = cidr.split('/');
  if (parts.length != 2 || peer.type != InternetAddressType.IPv4) return false;
  final local = InternetAddress.tryParse(parts.first);
  final prefix = int.tryParse(parts.last);
  if (local?.type != InternetAddressType.IPv4 ||
      prefix == null ||
      prefix < 1 ||
      prefix > 32) {
    return false;
  }
  int number(InternetAddress address) =>
      address.rawAddress.fold(0, (value, octet) => (value << 8) | octet);
  final shift = 32 - prefix;
  return (number(peer) >> shift) == (number(local!) >> shift);
}

typedef Json = Map<String, dynamic>;

class TransferError implements Exception {
  const TransferError(this.code, [this.status = 400]);
  final String code;
  final int status;

  @override
  String toString() => code;
}

class Device {
  const Device({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.platform,
  });

  final String id;
  final String name;
  final InternetAddress address;
  final int port;
  final String platform;

  Map<String, String> get attributes => {
    'v': '1',
    'id': id,
    'name': name,
    'platform': platform,
  };

  static Device? fromDiscovery(
    Map<String, String> attributes,
    InternetAddress address,
    int port,
  ) {
    final id = attributes['id'] ?? '';
    final name = attributes['name'] ?? '';
    if (attributes['v'] != '1' ||
        !digestPattern.hasMatch(id) ||
        name.trim().isEmpty ||
        utf8.encode(name).length > 120 ||
        port < 1 ||
        port > 65535 ||
        address.type != InternetAddressType.IPv4 ||
        address.isMulticast ||
        address.isLoopback ||
        address.address.startsWith('0.') ||
        address.address == '255.255.255.255') {
      return null;
    }
    return Device(
      id: id,
      name: name,
      address: address,
      port: port,
      platform: attributes['platform'] ?? '',
    );
  }
}

class FileSpec {
  const FileSpec(this.id, this.name, this.size);
  final String id;
  final String name;
  final int size;

  Json toJson() => {'id': id, 'name': name, 'size': size};

  factory FileSpec.fromJson(Json json) {
    final id = json['id'], name = json['name'], size = json['size'];
    if (id is! String ||
        !idPattern.hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        utf8.encode(name).length > 1024 ||
        size is! int ||
        size < 0) {
      throw const TransferError('invalid_manifest');
    }
    return FileSpec(id, name, size);
  }
}

List<FileSpec> parseManifest(Object? value) {
  if (value is! List || value.isEmpty || value.length > maxFiles) {
    throw const TransferError('invalid_manifest');
  }
  final files = <FileSpec>[];
  final ids = <String>{};
  var total = 0;
  for (final raw in value) {
    if (raw is! Json) throw const TransferError('invalid_manifest');
    final file = FileSpec.fromJson(raw);
    if (!ids.add(file.id) || maxInt64 - total < file.size) {
      throw const TransferError('invalid_manifest');
    }
    total += file.size;
    files.add(file);
  }
  return files;
}

enum SessionState {
  waiting,
  accepted,
  declined,
  canceled,
  expired,
  completed,
  partial,
  failed;

  bool get active => this == waiting || this == accepted;
}

enum FileState { pending, uploading, committed, failed }

class SavedFile {
  const SavedFile(this.name, this.location);
  final String name;
  final String location;
}

class TransferFile {
  TransferFile(this.spec);
  final FileSpec spec;
  FileState state = FileState.pending;
  int bytes = 0;
  String? error;
  String? savedName;
  SavedFile? saved;

  Json toJson() => {
    'id': spec.id,
    'state': state.name,
    'bytes': bytes,
    if (error != null) 'error': error,
    if (savedName != null) 'name': savedName,
  };
}

abstract interface class FileSource {
  FileSpec get spec;

  /// Opens a fresh stream on each call. Cancellation must close the handle.
  Stream<List<int>> open();
}

abstract interface class PendingFile {
  Future<void> write(List<int> bytes);
  Future<SavedFile> commit();
  Future<void> rollback();
}

abstract interface class ReceiveStorage {
  Future<PendingFile> create(FileSpec spec);
}

String safeFileName(String input) {
  var name = input
      .replaceAll(
        RegExp(r'[<>:"/\\|?*\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]'),
        '_',
      )
      .trim()
      .replaceFirst(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') name = '文件';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]) *(\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  // Leave space for a numeric suffix and keep a usable extension.
  final dot = name.lastIndexOf('.');
  final extension = dot > 0 && utf8.encode(name.substring(dot)).length <= 30
      ? name.substring(dot)
      : '';
  final stem = name.substring(0, name.length - extension.length);
  final safe = StringBuffer();
  var length = utf8.encode(extension).length;
  for (final rune in stem.runes) {
    final character = String.fromCharCode(rune);
    length += utf8.encode(character).length;
    if (length > 220) break;
    safe.write(character);
  }
  return '$safe$extension';
}

String numberedName(String name, int number) {
  if (number == 0) return name;
  final dot = name.lastIndexOf('.');
  return dot > 0
      ? '${name.substring(0, dot)} ($number)${name.substring(dot)}'
      : '$name ($number)';
}
