import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/library/photo_library_scanner.dart';

/// Counts `open()` calls on files created inside an [IOOverrides] zone.
///
/// Same instrument TC-090 uses in `photo_source_test.dart`: only `open()` is
/// implemented, so a probe that reaches the filesystem another way fails
/// loudly instead of quietly under-counting.
class CountingFile implements File {
  CountingFile(this._inner, this._onOpen);

  final File _inner;
  final void Function() _onOpen;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    _onOpen();
    return _inner.open(mode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Runs [body] with every `File(...)` it creates wrapped in a [CountingFile]
/// and returns how many times `open()` was called.
Future<int> countingOpens(Future<void> Function() body) async {
  var opens = 0;
  await IOOverrides.runZoned(
    body,
    createFile: (path) =>
        CountingFile(Zone.root.run(() => File(path)), () => opens++),
  );
  return opens;
}

/// An [ImageStreamCompleter] that never emits an image and never errors:
/// pre-inserted into the ImageCache under a real key, it deterministically
/// simulates "registration landed, decode still pending" without racing a
/// real (near-instant) engine decode.
class NeverCompletingImageStreamCompleter extends ImageStreamCompleter {}

/// A scanner that returns a fixed item list for any directory.
class FixedScanner extends PhotoLibraryScanner {
  FixedScanner(this.result);
  final List<PhotoItem> result;
  @override
  Future<List<PhotoItem>> scan(Directory dir) async => result;
}
