import 'dart:io';

import 'transfer/model.dart';

typedef SelectionIssue = ({String name, String code});
typedef FileSelection = ({
  List<PlatformSource> files,
  List<SelectionIssue> issues,
});

abstract interface class PlatformSource implements FileSource {
  String get handle;
}

abstract class PlatformBridge implements ReceiveStorage {
  String get platform;
  Stream<String> get network;
  Future<void> refreshNetwork() async {}
  Stream<FileSelection> get drops => const Stream.empty();

  Future<({Directory directory, String name})> info();
  Future<void> cleanup();
  Future<FileSelection> pick();
  PlatformSource restore(FileSpec spec, String handle);
  String selectionKey(PlatformSource file) => file.handle;
  Future<void> retain(Iterable<PlatformSource> files) async {}
  Future<void> open(String location);
  Future<void> export(String location) async =>
      throw UnsupportedError('File export is unavailable on $platform');
  Future<void> downloads();
  Future<void> reveal(String location) => downloads();
}
