import 'dart:io';

import 'package:near_transfer/transfer/model.dart';

class DiskSource implements FileSource {
  DiskSource(this.file, this.spec);
  final File file;
  @override
  final FileSpec spec;

  static Future<DiskSource> select(String path) async {
    final file = File(path);
    return DiskSource(
      file,
      FileSpec(randomId(), file.uri.pathSegments.last, await file.length()),
    );
  }

  @override
  Stream<List<int>> open() => file.openRead();
}

/// Test peer storage. The directory is only used by this test peer.
class DiskStorage implements ReceiveStorage {
  DiskStorage(this.directory);
  final Directory directory;

  @override
  Future<PendingFile> create(FileSpec spec) async {
    await directory.create(recursive: true);
    final scratch = File('${directory.path}/.neartransfer-${randomId()}.part');
    await scratch.create(exclusive: true);
    try {
      return _DiskPending(
        scratch,
        await scratch.open(mode: FileMode.write),
        directory,
        safeFileName(spec.name),
      );
    } catch (_) {
      await scratch.delete();
      rethrow;
    }
  }
}

class _DiskPending implements PendingFile {
  _DiskPending(this.scratch, this.output, this.directory, this.name);
  final File scratch;
  final RandomAccessFile output;
  final Directory directory;
  final String name;
  bool closed = false;

  @override
  Future<void> write(List<int> bytes) async {
    await output.writeFrom(bytes);
  }

  Future<void> _close() async {
    if (closed) return;
    closed = true;
    await output.close();
  }

  @override
  Future<SavedFile> commit() async {
    await output.flush();
    await _close();
    for (var number = 0; number < 10000; number++) {
      final displayName = numberedName(name, number);
      final path = '${directory.path}/$displayName';
      final reservation = File(path);
      try {
        await reservation.create(exclusive: true);
      } on PathExistsException {
        continue;
      }
      try {
        await scratch.rename(path);
      } catch (_) {
        await reservation.delete();
        rethrow;
      }
      return SavedFile(displayName, path);
    }
    throw const TransferError('storage_failed');
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
