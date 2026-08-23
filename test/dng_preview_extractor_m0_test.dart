import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/dng_preview_extractor.dart';

/// M0 acceptance oracle (round-1-m0-contract.md, W2).
///
/// Written against the FROZEN API (§"Frozen API" of the contract) before the
/// M0 rewrite (`extractEmbeddedJpeg` with `longEdge`/`onDiskRead`) landed.
/// Real DNG samples only, per repo red line: local_data/photo_samples/DNG/.
///
/// NOTE on AC4: an earlier contract draft said "15 files"; that was a
/// drafting error (raw `ls | wc -l` including a stray `file_sort.sh`). The
/// contract has since been amended to "14 `.dng` files" — see AC4 below.
void main() {
  final sampleDir = Directory('local_data/photo_samples/DNG');

  // Kept in lockstep with the frozen oracle's `withPreview` list (read, not
  // retyped from memory) — test/dng_preview_extractor_test.dart lines 39-53.
  const withPreview = <String>[
    '2026-02-15-19-37-38.dng',
    '2026-02-15-20-53-24.dng',
    '2026-02-15-20-53-31.dng',
    '2026-02-15-20-57-15.dng',
    '2026-02-15-20-57-23-2.dng',
    '2026-02-15-20-57-23.dng',
    '2026-02-15-20-57-26.dng',
    '2026-02-15-20-57-28.dng',
    '2026-02-15-21-53-33.dng',
    '2026-02-15-21-53-41.dng',
    '2026-02-15-21-53-42.dng',
    '2026-02-15-21-53-43.dng',
    '2026-08-07-17-52-54.dng',
  ];

  const noPreviewFile = 'IMG_20251112_092839.dng';
  const noPreviewFileDiskBytes = 25192232;

  test('AC2: smallest candidate >= longEdge 200 is the 256x171 preview', () async {
    final path = '${sampleDir.path}/2026-02-15-19-37-38.dng';
    expect(File(path).existsSync(), isTrue, reason: 'missing $path');

    final result = await DngPreviewExtractor.extractEmbeddedJpeg(
      path,
      longEdge: 200,
    );

    expect(result, isNotNull);
    expect(result!.width, 256);
    expect(result.height, 171);
    expect(result.bytes.length, 9525);
    expect(result.orientation, 1);
  });

  group('AC3: longEdge 2800 is byte-identical to today\'s full-size extraction', () {
    for (final name in withPreview) {
      test(name, () async {
        final path = '${sampleDir.path}/$name';
        expect(File(path).existsSync(), isTrue, reason: 'missing $path');

        final selected = await DngPreviewExtractor.extractEmbeddedJpeg(
          path,
          longEdge: 2800,
        );
        expect(selected, isNotNull, reason: '$name expected a candidate at longEdge 2800');

        final fullSize = await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(
          path,
        );
        expect(fullSize, isNotNull, reason: '$name expected a full-size embedded preview');

        expect(
          selected!.bytes.length,
          fullSize!.length,
          reason: '$name: longEdge=2800 selection length differs from full-size length',
        );
        expect(
          listEquals(selected.bytes, fullSize),
          isTrue,
          reason: '$name: longEdge=2800 selection is not byte-identical to full-size '
              '(element-wise comparison)',
        );
      });
    }
  });

  test(
    'AC4: byte-range read budget stays bounded across every .dng sample',
    () async {
      final dngFiles = sampleDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.dng'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      expect(
        dngFiles.length,
        26,
        reason:
            'expected exactly 26 .dng files in ${sampleDir.path}; a sample '
            'vanishing/appearing must fail loudly',
      );

      for (final file in dngFiles) {
        var totalOnDiskRead = 0;
        final result = await DngPreviewExtractor.extractEmbeddedJpeg(
          file.path,
          longEdge: 200,
          onDiskRead: (byteCount) => totalOnDiskRead += byteCount,
        );

        final selectedCandidateByteCount = result?.bytes.length ?? 0;

        expect(
          totalOnDiskRead,
          lessThanOrEqualTo(selectedCandidateByteCount + 300000),
          reason:
              '${file.path}: on-disk read budget exceeded (read=$totalOnDiskRead, '
              'candidate=$selectedCandidateByteCount)',
        );

        if (file.path.endsWith(noPreviewFile)) {
          expect(
            File(file.path).lengthSync(),
            noPreviewFileDiskBytes,
            reason: 'ground-truth on-disk size for $noPreviewFile has changed',
          );
          expect(
            result,
            isNull,
            reason: '$noPreviewFile has no qualifying candidate and must return null',
          );
          expect(
            totalOnDiskRead,
            lessThan(300000),
            reason:
                '$noPreviewFile: with no candidate, total on-disk read must stay '
                'under 300000 bytes (got $totalOnDiskRead), not scan the whole '
                '25MB file',
          );
        }
      }
    },
  );

  test(
    'AC5: sole 6000x4000 candidate is selected, orientation 6, APP1 injected',
    () async {
      final path = '${sampleDir.path}/2026-08-07-17-52-54.dng';
      expect(File(path).existsSync(), isTrue, reason: 'missing $path');

      final result = await DngPreviewExtractor.extractEmbeddedJpeg(
        path,
        longEdge: 200,
      );

      expect(result, isNotNull);
      expect(result!.width, 6000);
      expect(result.height, 4000);
      expect(result.orientation, 6);
      expect(result.bytes.length, greaterThan(4));
      expect(
        result.bytes[2],
        0xFF,
        reason: 'expected injected APP1 segment marker byte 0 at offset 2',
      );
      expect(
        result.bytes[3],
        0xE1,
        reason: 'expected injected APP1 segment marker byte 1 at offset 3',
      );
    },
  );

  group('AC6: no-candidate/missing/non-DNG inputs return null, never throw', () {
    test('DNG with no qualifying candidate returns null', () async {
      final path = '${sampleDir.path}/$noPreviewFile';
      expect(File(path).existsSync(), isTrue, reason: 'missing $path');

      final result = await DngPreviewExtractor.extractEmbeddedJpeg(
        path,
        longEdge: 200,
      );
      expect(result, isNull);
    });

    test('nonexistent path returns null', () async {
      final result = await DngPreviewExtractor.extractEmbeddedJpeg(
        '${sampleDir.path}/does_not_exist.dng',
        longEdge: 200,
      );
      expect(result, isNull);
    });

    test('plain-JPEG file (not a DNG/TIFF container) returns null', () async {
      final tempFile = await File(
        '${Directory.systemTemp.path}/dng_preview_extractor_m0_plain_jpeg.jpg',
      ).create(recursive: true);
      await tempFile.writeAsBytes(
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0xFF, 0xD9]),
      );
      addTearDown(() async {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      });

      final result = await DngPreviewExtractor.extractEmbeddedJpeg(
        tempFile.path,
        longEdge: 200,
      );
      expect(result, isNull);
    });
  });

  test(
    'AC11a: readOrientation reads IFD0 tag 0x0112 via the bounded walk (discriminating case)',
    () async {
      final path = '${sampleDir.path}/2026-08-07-17-52-54.dng';
      expect(File(path).existsSync(), isTrue, reason: 'missing $path');

      final orientation = await DngPreviewExtractor.readOrientation(path);
      expect(orientation, 6);
    },
  );

  test(
    'AC11b: readOrientation on a no-preview DNG stays under the disk-read budget',
    () async {
      final path = '${sampleDir.path}/$noPreviewFile';
      expect(File(path).existsSync(), isTrue, reason: 'missing $path');
      expect(
        File(path).lengthSync(),
        noPreviewFileDiskBytes,
        reason: 'ground-truth on-disk size for $noPreviewFile has changed',
      );

      var totalOnDiskRead = 0;
      final orientation = await DngPreviewExtractor.readOrientation(
        path,
        onDiskRead: (byteCount) => totalOnDiskRead += byteCount,
      );

      expect(orientation, 1);
      expect(
        totalOnDiskRead,
        lessThan(300000),
        reason:
            '$noPreviewFile: readOrientation must not scan the whole 25MB file '
            '(got $totalOnDiskRead)',
      );
    },
  );

  // AC11c is REPLACED by AC12a (a nonexistent path now returns null, not 1)
  // per the AC12 contract amendment: readOrientation's return value split
  // "1" (tag absent) from "null" (unparseable/missing), because a single
  // "1" could not distinguish a working implementation from one that gives
  // up on files it cannot read.

  test('AC12a: readOrientation on a nonexistent path returns null, never throws', () async {
    final orientation = await DngPreviewExtractor.readOrientation(
      '${sampleDir.path}/does_not_exist.dng',
    );
    expect(orientation, isNull);
  });

  test('AC12b: a file that parses but carries no 0x0112 tag returns 1', () async {
    // Minimal, hand-crafted little-endian TIFF: valid header + an IFD0 with
    // one SHORT entry (tag 0x0100 ImageWidth, deliberately NOT 0x0112) and no
    // next IFD. This must genuinely parse -- if it returned null because it
    // were malformed rather than 1 because the tag is absent, this test
    // would prove nothing.
    final bytes = BytesBuilder()
      ..add([0x49, 0x49]) // 'II' byte-order marker (little-endian)
      ..add([0x2A, 0x00]) // TIFF magic 42
      ..add([0x08, 0x00, 0x00, 0x00]) // IFD0 offset = 8
      ..add([0x01, 0x00]) // IFD0 entry count = 1
      ..add([0x00, 0x01]) // tag 0x0100 (ImageWidth), not 0x0112
      ..add([0x03, 0x00]) // type = 3 (SHORT)
      ..add([0x01, 0x00, 0x00, 0x00]) // count = 1
      ..add([0x64, 0x00, 0x00, 0x00]) // value = 100, left-justified in the 4-byte field
      ..add([0x00, 0x00, 0x00, 0x00]); // next IFD offset = 0 (no more IFDs)

    final tempFile = await File(
      '${Directory.systemTemp.path}/dng_preview_extractor_m0_ac12b_no_orientation_tag.tiff',
    ).create(recursive: true);
    await tempFile.writeAsBytes(bytes.toBytes());
    addTearDown(() async {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    });

    final orientation = await DngPreviewExtractor.readOrientation(tempFile.path);
    expect(orientation, 1);
  });

  test('AC12c: non-TIFF/garbage input returns null, never throws', () async {
    final plainJpeg = await File(
      '${Directory.systemTemp.path}/dng_preview_extractor_m0_ac12c_plain_jpeg.jpg',
    ).create(recursive: true);
    await plainJpeg.writeAsBytes(
      Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0xFF, 0xD9]),
    );
    addTearDown(() async {
      if (await plainJpeg.exists()) {
        await plainJpeg.delete();
      }
    });

    final zeroByteFile = await File(
      '${Directory.systemTemp.path}/dng_preview_extractor_m0_ac12c_zero_byte.dng',
    ).create(recursive: true);
    await zeroByteFile.writeAsBytes(Uint8List(0));
    addTearDown(() async {
      if (await zeroByteFile.exists()) {
        await zeroByteFile.delete();
      }
    });

    expect(await DngPreviewExtractor.readOrientation(plainJpeg.path), isNull);
    expect(await DngPreviewExtractor.readOrientation(zeroByteFile.path), isNull);
  });

  test(
    'AC12h: 0x0112 tag PRESENT but unreadable -> readOrientation null, '
    'readDngOrientation 1 (distinct from AC12b\'s tag-ABSENT case)',
    () async {
      // Unlike AC12b (no 0x0112 entry at all), this file DOES have a 0x0112
      // entry, but its value cannot be resolved: type SHORT, count 3 (6
      // bytes, so the value does not fit inline and must live at an external
      // offset), and that offset points past EOF. "Found it, could not read
      // it" must be null, not the tag-absent value 1.
      final bytes = BytesBuilder()
        ..add([0x49, 0x49]) // 'II' byte-order marker (little-endian)
        ..add([0x2A, 0x00]) // TIFF magic 42
        ..add([0x08, 0x00, 0x00, 0x00]) // IFD0 offset = 8
        ..add([0x01, 0x00]) // IFD0 entry count = 1
        ..add([0x12, 0x01]) // tag 0x0112 (Orientation)
        ..add([0x03, 0x00]) // type = 3 (SHORT)
        ..add([0x03, 0x00, 0x00, 0x00]) // count = 3 (6 bytes -> needs an offset)
        ..add([0xF0, 0xFF, 0xFF, 0xFF]) // value offset = 0xFFFFFFF0, far past EOF
        ..add([0x00, 0x00, 0x00, 0x00]); // next IFD offset = 0 (no more IFDs)
      final fileBytes = bytes.toBytes();

      final tempFile = await File(
        '${Directory.systemTemp.path}/dng_preview_extractor_m0_ac12h_unreadable_tag.tiff',
      ).create(recursive: true);
      await tempFile.writeAsBytes(fileBytes);
      addTearDown(() async {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      });

      final pathResult = await DngPreviewExtractor.readOrientation(tempFile.path);
      final bytesResult = DngPreviewExtractor.readDngOrientation(fileBytes);

      expect(pathResult, isNull, reason: 'unreadable-but-present tag must be null, not 1');
      expect(
        bytesResult,
        1,
        reason: 'legacy readDngOrientation must still degrade to 1 (?? 1 unchanged)',
      );
    },
  );

  test(
    'AC12d: N1 fixture — large file with a patched non-default orientation tag',
    () async {
      final sourcePath = '${sampleDir.path}/$noPreviewFile';
      expect(File(sourcePath).existsSync(), isTrue, reason: 'missing $sourcePath');

      final tempPath =
          '${Directory.systemTemp.path}/dng_preview_extractor_m0_ac12d_n1_fixture.dng';
      final tempFile = File(tempPath);
      addTearDown(() async {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      });

      await _patchOrientationTag(sourcePath, tempPath, 6);
      expect(
        await tempFile.length(),
        noPreviewFileDiskBytes,
        reason: 'in-place tag patch must not change the file size',
      );

      var totalOnDiskRead = 0;
      final orientation = await DngPreviewExtractor.readOrientation(
        tempPath,
        onDiskRead: (byteCount) => totalOnDiskRead += byteCount,
      );

      expect(orientation, 6);
      expect(
        totalOnDiskRead,
        lessThan(300000),
        reason:
            'N1 fixture: readOrientation must not scan the whole 25MB file '
            '(got $totalOnDiskRead)',
      );
    },
  );
}

/// Patches an on-disk copy of [sourcePath] (written to [destPath]) so IFD0's
/// orientation tag 0x0112 reads [value].
///
/// `IMG_20251112_092839.dng` already carries an explicit 0x0112 SHORT/count-1
/// entry with value 1 (verified by direct inspection: it is not that the tag
/// is absent, it is present and declares "no rotation"). This overwrites that
/// existing entry's inline value only -- it does not touch the tag id, type,
/// count, or any other byte in the file. An earlier version of this helper
/// hijacked a *different* SHORT/count-1 entry to fabricate a second 0x0112
/// tag, which produced two orientation entries in one IFD0 and made the
/// result implementation-defined (observed: the reader returned the
/// original's value, not the fabricated one). Patching the sole existing
/// entry avoids that ambiguity entirely, and keeps every other absolute
/// offset in the DNG (raw image strips, SubIFDs, thumbnail IFDs, etc.)
/// untouched.
Future<void> _patchOrientationTag(String sourcePath, String destPath, int value) async {
  final bytes = Uint8List.fromList(await File(sourcePath).readAsBytes());
  final data = ByteData.sublistView(bytes);
  final byteOrder = String.fromCharCodes(bytes.sublist(0, 2));
  final endian = byteOrder == 'II' ? Endian.little : Endian.big;

  final ifd0Offset = data.getUint32(4, endian);
  final entryCount = data.getUint16(ifd0Offset, endian);

  int? targetEntryOffset;
  for (var i = 0; i < entryCount; i++) {
    final entryOffset = ifd0Offset + 2 + i * 12;
    final tag = data.getUint16(entryOffset, endian);
    final type = data.getUint16(entryOffset + 2, endian);
    final count = data.getUint32(entryOffset + 4, endian);
    if (tag == 0x0112 && type == 3 && count == 1) {
      targetEntryOffset = entryOffset;
      break;
    }
  }

  if (targetEntryOffset == null) {
    throw StateError(
      'no existing SHORT/count==1 IFD0 orientation (0x0112) entry found in '
      '$sourcePath to patch for the N1 fixture',
    );
  }

  data.setUint16(targetEntryOffset, 0x0112, endian);
  data.setUint16(targetEntryOffset + 8, value, endian);
  data.setUint16(targetEntryOffset + 10, 0, endian);

  await File(destPath).writeAsBytes(bytes);
}
