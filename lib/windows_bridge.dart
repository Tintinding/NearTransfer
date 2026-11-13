import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'platform_bridge.dart';
import 'transfer/model.dart';

class WindowsBridge extends PlatformBridge {
  static const _methods = MethodChannel('near_transfer/windows');
  static const _dropEvents = EventChannel('near_transfer/windows/drops');
  late String _partPrefix;

  @override
  String get platform => 'windows';

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
  Stream<FileSelection> get drops => _dropEvents
      .receiveBroadcastStream()
      .asyncMap((paths) => _selection((paths as List).cast<String>()));

  @override
  Future<({Directory directory, String name})> info() async {
    final info = (await _methods.invokeMapMethod<String, String>('info'))!;
    final directory = Directory(info['directory']!);
    // Scope cleanup to this user's installation, even on shared Downloads.
    final key = sha256.convert(utf8.encode(directory.path.toLowerCase()));
    _partPrefix = '.neartransfer-${key.toString().substring(0, 16)}-';
    return (directory: directory, name: info['name']!);
  }

  @override
  Future<FileSelection> pick() async =>
      _selection(await _methods.invokeListMethod<String>('pick') ?? []);

  Future<FileSelection> _selection(List<String> paths) async {
    final files = <PlatformSource>[];
    final issues = <SelectionIssue>[];
    final unique = paths.toSet();
    if (unique.length > maxFiles) throw const TransferError('too_many_files');
    for (final path in unique) {
      final file = File(path).absolute;
      final name = file.uri.pathSegments.lastWhere(
        (segment) => segment.isNotEmpty,
        orElse: () => path,
      );
      try {
        final type = await FileSystemEntity.type(file.path);
        if (type != FileSystemEntityType.file) {
          throw TransferError(switch (type) {
            FileSystemEntityType.directory => 'folder_unsupported',
            FileSystemEntityType.notFound => 'source_missing',
            _ => 'source_unreadable',
          });
        }
        final input = await file.open();
        try {
          files.add(
            restore(
              FileSpec(randomId(), name, await input.length()),
              file.path,
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
  PlatformSource restore(FileSpec spec, String handle) =>
      _WindowsSource(spec, handle);

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
            // Retry on the next launch if Windows temporarily locks the file.
          }
        }
      }
    } on FileSystemException {
      // Downloads can be unavailable on startup. Report failure on receive.
    } on PlatformException {
      // The known folder may point to a disconnected drive.
    }
  }

  @override
  Future<PendingFile> create(FileSpec spec) async {
    try {
      final directory = await (await _downloads()).create(recursive: true);
      var name = safeFileName(spec.name).replaceFirst(RegExp(r'[. ]+$'), '');
      if (name.toLowerCase().startsWith(_partPrefix) ||
          RegExp(
            r'^(CONIN\$|CONOUT\$) *(\.|$)',
            caseSensitive: false,
          ).hasMatch(name)) {
        name = '_$name';
      }
      final scratch = File('${directory.path}\\$_partPrefix${randomId()}.part');
      await scratch.create(exclusive: true);
      try {
        final output = await scratch.open(mode: FileMode.write);
        return _WindowsDownload(scratch, output, directory, name);
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
      2 || 3 => 'source_missing',
      5 => 'source_permission',
      _ => 'source_unreadable',
    });

TransferError _writeError(FileSystemException error) =>
    TransferError(switch (error.osError?.errorCode) {
      39 || 112 => 'no_space',
      _ => 'storage_failed',
    });

class _WindowsSource implements PlatformSource {
  const _WindowsSource(this.spec, this.handle);

  @override
  final FileSpec spec;
  @override
  final String handle;

  @override
  Stream<List<int>> open() async* {
    try {
      yield* File(handle).openRead();
    } on FileSystemException catch (error) {
      throw _readError(error);
    }
  }
}

class _WindowsDownload implements PendingFile {
  _WindowsDownload(this.scratch, this.output, this.directory, this.name);

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
        final path = '${directory.path}\\$finalName';
        final moved = (await WindowsBridge._methods.invokeMethod<bool>(
          'commit',
          {'from': scratch.path, 'to': path},
        ))!;
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
