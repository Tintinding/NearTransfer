import 'dart:io';

import 'package:flutter/services.dart';

import 'platform_bridge.dart';
import 'transfer/model.dart';

class IosBridge extends PlatformBridge {
  static const _methods = MethodChannel('near_transfer/ios');
  static const _network = EventChannel('near_transfer/ios/network');
  late Directory _data;
  late Directory _received;
  late Directory _scratch;
  bool _picking = false;

  @override
  String get platform => 'ios';

  @override
  Stream<String> get network =>
      _network.receiveBroadcastStream(serviceType).cast<String>();

  @override
  Future<void> refreshNetwork() =>
      _methods.invokeMethod<void>('refreshNetwork');

  @override
  Future<({Directory directory, String name})> info() async {
    final info = (await _methods.invokeMapMethod<String, String>('info'))!;
    _data = Directory(info['directory']!);
    _received = Directory(info['received']!);
    _scratch = Directory(info['scratch']!);
    return (directory: _data, name: info['name']!);
  }

  @override
  Future<FileSelection> pick() async {
    _picking = true;
    try {
      final selection = (await _methods.invokeMapMethod<String, List>('pick', {
        'limit': maxFiles,
      }))!;
      return (
        files: [
          for (final file in selection['files']!.cast<Map>())
            restore(
              FileSpec(randomId(), file['name'] as String, file['size'] as int),
              file['handle'] as String,
            ),
        ],
        issues: [
          for (final issue in selection['issues']!.cast<Map>())
            (name: issue['name'] as String, code: issue['code'] as String),
        ],
      );
    } finally {
      _picking = false;
    }
  }

  @override
  PlatformSource restore(FileSpec spec, String handle) {
    if (!idPattern.hasMatch(handle)) {
      throw const TransferError('source_unreadable');
    }
    return _IosSource(spec, handle, File('${_data.path}/Outgoing/$handle'));
  }

  @override
  Future<void> retain(Iterable<PlatformSource> files) async {
    // The controller retains the new selection once it has adopted the files.
    if (_picking) return;
    await _methods.invokeMethod<void>('retain', {
      'handles': files.map((file) => file.handle).toSet().toList(),
    });
  }

  @override
  Future<void> cleanup() async {
    await _received.create(recursive: true);
    await _scratch.create(recursive: true);
    final partName = RegExp(r'^[a-f0-9]{32}\.part$');
    await for (final entry in _scratch.list(followLinks: false)) {
      if (entry is File && partName.hasMatch(entry.uri.pathSegments.last)) {
        await entry.delete().catchError((Object _) => entry);
      }
    }
  }

  @override
  Future<PendingFile> create(FileSpec spec) async {
    try {
      await _received.create(recursive: true);
      await _scratch.create(recursive: true);
      final scratch = File('${_scratch.path}/${randomId()}.part');
      await scratch.create(exclusive: true);
      try {
        final output = await scratch.open(mode: FileMode.write);
        final name = safeFileName(spec.name);
        return _IosDownload(
          scratch,
          output,
          _received,
          name.startsWith('.') ? '_$name' : name,
        );
      } on FileSystemException {
        await scratch.delete().catchError((Object _) => scratch);
        rethrow;
      }
    } on FileSystemException catch (error) {
      throw _writeError(error);
    }
  }

  @override
  Future<void> open(String location) =>
      _methods.invokeMethod<void>('open', location);

  @override
  Future<void> export(String location) =>
      _methods.invokeMethod<void>('export', location);

  @override
  Future<void> downloads() async =>
      throw UnsupportedError('Open the received folder in Files');
}

class _IosSource implements PlatformSource {
  const _IosSource(this.spec, this.handle, this.file);
  @override
  final FileSpec spec;
  @override
  final String handle;
  final File file;

  @override
  Stream<List<int>> open() async* {
    try {
      yield* file.openRead();
    } on FileSystemException catch (error) {
      throw TransferError(switch (error.osError?.errorCode) {
        2 => 'source_missing',
        1 || 13 => 'source_permission',
        _ => 'source_unreadable',
      });
    }
  }
}

TransferError _writeError(FileSystemException error) => TransferError(
  error.osError?.errorCode == 28 ? 'no_space' : 'storage_failed',
);

class _IosDownload implements PendingFile {
  _IosDownload(this.scratch, this.output, this.directory, this.name);
  final File scratch;
  final RandomAccessFile output;
  final Directory directory;
  final String name;
  bool _closed = false;

  @override
  Future<void> write(List<int> bytes) async {
    try {
      await output.writeFrom(bytes);
    } on FileSystemException catch (error) {
      throw _writeError(error);
    }
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await output.close();
  }

  @override
  Future<SavedFile> commit() async {
    try {
      await output.flush();
      await _close();
      for (var number = 0; number < 10000; number++) {
        final finalName = numberedName(name, number);
        final path = '${directory.path}/$finalName';
        final moved = (await IosBridge._methods.invokeMethod<bool>('commit', {
          'from': scratch.path,
          'to': path,
        }))!;
        if (moved) return SavedFile(finalName, path);
      }
      throw const TransferError('storage_failed');
    } on PlatformException catch (error) {
      throw TransferError(error.code);
    } on FileSystemException catch (error) {
      throw _writeError(error);
    }
  }

  @override
  Future<void> rollback() async {
    try {
      await _close();
    } finally {
      if (await scratch.exists()) await scratch.delete();
    }
  }
}
