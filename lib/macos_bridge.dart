import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'platform_bridge.dart';
import 'transfer/model.dart';

class MacOSBridge extends PlatformBridge {
  static const _methods = MethodChannel('near_transfer/macos');
  late String _partPrefix;

  @override
  String get platform => 'macos';

  @override
  Stream<String> get network async* {
    while (true) {
      try {
        yield (await _methods.invokeMethod<String>('network'))!;
      } on PlatformException catch (error, stack) {
        yield* Stream<String>.error(error, stack);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  @override
  Future<({Directory directory, String name})> info() async {
    final info = (await _methods.invokeMapMethod<String, String>('info'))!;
    final directory = Directory(info['directory']!);
    final key = sha256.convert(utf8.encode(directory.path));
    _partPrefix = '.neartransfer-${key.toString().substring(0, 16)}-';
    return (directory: directory, name: info['name']!);
  }

  @override
  Future<FileSelection> pick() async {
    final items =
        await _methods.invokeListMethod<Map<Object?, Object?>>('pick') ?? [];
    if (items.length > maxFiles) throw const TransferError('too_many_files');
    final files = <PlatformSource>[];
    final issues = <SelectionIssue>[];
    for (final item in items) {
      final path = item['path']! as String;
      final file = File(path);
      final name = file.uri.pathSegments.last;
      final bookmark = item['bookmark'] as String?;
      try {
        final type = await FileSystemEntity.type(path);
        if (type != FileSystemEntityType.file) {
          throw TransferError(switch (type) {
            FileSystemEntityType.directory => 'folder_unsupported',
            FileSystemEntityType.notFound => 'source_missing',
            _ => 'source_unreadable',
          });
        }
        if (bookmark == null) throw const TransferError('source_permission');
        final input = await file.open();
        try {
          files.add(
            _MacSource(
              FileSpec(randomId(), name, await input.length()),
              path,
              bookmark,
            ),
          );
        } finally {
          await input.close();
        }
      } on TransferError catch (error) {
        issues.add((name: name, code: error.code));
      } on FileSystemException catch (error) {
        issues.add((name: name, code: _readError(error).code));
      }
    }
    return (files: files, issues: issues);
  }

  @override
  PlatformSource restore(FileSpec spec, String handle) {
    if (jsonDecode(handle) case [final String path, final String bookmark]) {
      return _MacSource(spec, path, bookmark);
    }
    throw const FormatException('Invalid macOS source handle');
  }

  @override
  String selectionKey(PlatformSource file) => (file as _MacSource).path;

  Future<Directory> _downloads() async =>
      Directory((await _methods.invokeMethod<String>('downloadsPath'))!);

  @override
  Future<void> cleanup() async {
    try {
      final directory = await _downloads();
      final temporaryName = RegExp(
        '^${RegExp.escape(_partPrefix)}[0-9a-f]{32}\\.part\$',
        caseSensitive: false,
      );
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File &&
            temporaryName.hasMatch(entry.uri.pathSegments.last)) {
          try {
            await entry.delete();
          } on FileSystemException {
            // Retry on the next launch.
          }
        }
      }
    } on FileSystemException {
      // Downloads can be unavailable at startup. Report failure on receive.
    } on PlatformException {
      // The current user's Downloads path may be unavailable.
    }
  }

  @override
  Future<PendingFile> create(FileSpec spec) async {
    try {
      final directory = await (await _downloads()).create(recursive: true);
      var name = safeFileName(spec.name);
      if (name.toLowerCase().startsWith(_partPrefix)) name = '_$name';
      final scratch = File('${directory.path}/$_partPrefix${randomId()}.part');
      await scratch.create(exclusive: true);
      try {
        final output = await scratch.open(mode: FileMode.write);
        return _MacDownload(scratch, output, directory, name);
      } on FileSystemException {
        await scratch.delete().catchError((Object _) => scratch);
        rethrow;
      }
    } on FileSystemException catch (error) {
      throw _writeError(error);
    } on PlatformException catch (error) {
      throw TransferError(error.code);
    }
  }

  @override
  Future<void> open(String location) =>
      _methods.invokeMethod<void>('open', location);

  @override
  Future<void> downloads() async => open((await _downloads()).path);

  @override
  Future<void> reveal(String location) =>
      _methods.invokeMethod<void>('reveal', location);
}

TransferError _readError(FileSystemException error) =>
    TransferError(switch (error.osError?.errorCode) {
      2 || 20 => 'source_missing',
      1 || 13 => 'source_permission',
      _ => 'source_unreadable',
    });

TransferError _writeError(FileSystemException error) =>
    TransferError(switch (error.osError?.errorCode) {
      28 || 69 => 'no_space',
      _ => 'storage_failed',
    });

class _MacSource implements PlatformSource {
  _MacSource(this.spec, this.path, String bookmark)
    : _bookmark = bookmark,
      handle = jsonEncode([path, bookmark]);

  @override
  final FileSpec spec;
  final String path;
  final String _bookmark;
  @override
  final String handle;

  @override
  Stream<List<int>> open() async* {
    String? token;
    try {
      final access = (await MacOSBridge._methods
          .invokeMapMethod<String, String>('startAccess', _bookmark))!;
      token = access['token'];
      yield* File(access['path']!).openRead();
    } on PlatformException catch (error) {
      throw TransferError(error.code);
    } on FileSystemException catch (error) {
      throw _readError(error);
    } finally {
      if (token != null) {
        await MacOSBridge._methods.invokeMethod<void>('stopAccess', token);
      }
    }
  }
}

class _MacDownload implements PendingFile {
  _MacDownload(this.scratch, this.output, this.directory, this.name);

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
        final moved = (await MacOSBridge._methods.invokeMethod<bool>('commit', {
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
