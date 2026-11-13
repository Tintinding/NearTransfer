import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'platform_bridge.dart';
import 'transfer/model.dart';

class AndroidBridge extends PlatformBridge {
  static const _methods = MethodChannel('near_transfer/android');
  static const _network = EventChannel('near_transfer/network');

  @override
  String get platform => 'android';

  @override
  Stream<String> get network =>
      _network.receiveBroadcastStream().cast<String>();

  @override
  Future<({Directory directory, String name})> info() async {
    final result = (await _methods.invokeMapMethod<String, String>('info'))!;
    return (directory: Directory(result['directory']!), name: result['name']!);
  }

  @override
  Future<FileSelection> pick() async {
    final result =
        await _methods.invokeListMethod<Map<Object?, Object?>>('pick') ?? [];
    return (
      files: [
        for (final file in result)
          AndroidSource(
            FileSpec(randomId(), file['name'] as String, file['size'] as int),
            file['uri'] as String,
          ),
      ],
      issues: const <SelectionIssue>[],
    );
  }

  @override
  AndroidSource restore(FileSpec spec, String handle) =>
      AndroidSource(spec, handle);

  @override
  Future<void> cleanup() => _methods.invokeMethod<void>('cleanup');
  @override
  Future<void> open(String uri) =>
      _methods.invokeMethod<void>('open', {'uri': uri});
  @override
  Future<void> downloads() => _methods.invokeMethod<void>('downloads');
  @override
  Future<void> retain(Iterable<PlatformSource> files) =>
      _methods.invokeMethod<void>('retain', {
        'uris': files.map((file) => file.handle).toSet().toList(),
      });

  @override
  Future<PendingFile> create(FileSpec spec) async {
    try {
      final handle = await _methods.invokeMethod<String>('create', {
        'name': safeFileName(spec.name),
        'size': spec.size,
      });
      return _AndroidDownload(handle!);
    } on PlatformException catch (error) {
      throw TransferError(error.code);
    }
  }
}

class AndroidSource implements PlatformSource {
  const AndroidSource(this.spec, this.handle);
  @override
  final FileSpec spec;
  @override
  final String handle;

  @override
  Stream<List<int>> open() async* {
    final arguments = {'handle': randomId()};
    try {
      await AndroidBridge._methods
          .invokeMethod<void>('openRead', {...arguments, 'uri': handle})
          .timeout(ioTimeout);
      while (true) {
        final bytes = (await AndroidBridge._methods
            .invokeMethod<Uint8List>('read', arguments)
            .timeout(ioTimeout))!;
        if (bytes.isEmpty) return;
        yield bytes;
      }
    } on PlatformException catch (error) {
      throw TransferError(error.code);
    } finally {
      await AndroidBridge._methods
          .invokeMethod<void>('closeRead', arguments)
          .catchError((Object _) {});
    }
  }
}

class _AndroidDownload implements PendingFile {
  _AndroidDownload(this.handle);
  final String handle;

  @override
  Future<void> write(List<int> bytes) async {
    try {
      for (var start = 0; start < bytes.length; start += chunkSize) {
        final end = start + chunkSize < bytes.length
            ? start + chunkSize
            : bytes.length;
        final chunk = bytes is Uint8List
            ? Uint8List.sublistView(bytes, start, end)
            : Uint8List.fromList(bytes.sublist(start, end));
        await AndroidBridge._methods.invokeMethod<void>('write', {
          'handle': handle,
          'bytes': chunk,
        });
      }
    } on PlatformException catch (error) {
      throw TransferError(error.code);
    }
  }

  @override
  Future<SavedFile> commit() async {
    final result = (await AndroidBridge._methods
        .invokeMapMethod<String, String>('commit', {'handle': handle}))!;
    return SavedFile(result['name']!, result['uri']!);
  }

  @override
  Future<void> rollback() =>
      AndroidBridge._methods.invokeMethod<void>('rollback', {'handle': handle});
}
