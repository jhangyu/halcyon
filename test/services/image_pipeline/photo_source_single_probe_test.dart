// The user's single-probe ruling, made mechanical.
//
// The rejected seam asked one question per call: probe() for the rung, then
// probeOrientation() for the orientation. Two opens, two header+IFD0 walks,
// and -- worse -- a debounced RAW decode that went back to the native bridge
// for a value the first walk already had in its hand. These tests pin the
// three properties that make a re-split fail here rather than in review:
//
//   TC-090  ONE file open per probe, counted
//   TC-091  the fused orientation equals the dedicated reader's answer
//   TC-092  AC14's <=300 KB budget measured over the COMBINED probe
//   TC-093  an expensive item reaches its RAW decode with ZERO loader calls
//
// Real samples only (repo red line, local_data/photo_samples/): the probe's
// whole claim is about content, so a synthetic fixture would only exercise the
// parser.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

import '../../support/preload_fixtures.dart';
import '../../support/sample_photos.dart';

/// Counts `open()` calls on files created inside an [IOOverrides] zone.
///
/// Only `open()` is implemented: every other member throws, which is the
/// point. If the probe ever reaches for the filesystem another way, this test
/// fails loudly instead of quietly under-counting.
class _CountingFile implements File {
  _CountingFile(this._inner, this._onOpen);

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

/// Runs [body] with every `File(...)` construction counted.
Future<int> countingOpens(Future<void> Function() body) async {
  var opens = 0;
  await IOOverrides.runZoned(
    body,
    // Zone.root escapes this very override, so the wrapped File is a real one
    // rather than an infinite regress through the factory.
    createFile: (path) =>
        _CountingFile(Zone.root.run(() => File(path)), () => opens++),
  );
  return opens;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dngDir = sampleDngDir;
  final jpgDir = sampleJpgDir;
  final hasSamples = samplePhotosAvailable;

  List<File> dngs() =>
      dngDir.listSync().whereType<File>().where(
        (f) => f.path.toLowerCase().endsWith('.dng'),
      ).toList()..sort((a, b) => a.path.compareTo(b.path));

  // The no-preview witness: the one sample in fourteen that genuinely needs a
  // RAW decode, and therefore the only one whose orientation the pipeline must
  // carry across the debounce.
  final noPreviewDng = File('${dngDir.path}/IMG_20251112_092839.dng');

  const windowLongEdge = 2800;

  group('single-probe seam', () {
    // THE KILLER for the ruling. A two-call seam opens the file twice however
    // it is spelled, so this counts opens rather than trusting the shape of
    // the API.
    test('TC-090 the whole probe is ONE file open', () async {
      for (final file in dngs()) {
        late ProbeResult probed;
        final opens = await countingOpens(() async {
          probed = await PhotoSource.probeSource(
            file.path,
            longEdge: windowLongEdge,
          );
        });
        expect(
          opens,
          1,
          reason: '${file.path}: the rung and the orientation must come out of '
              'ONE bounded walk. $opens opens means the second walk is back',
        );
        expect(
          probed.cost,
          isNotNull,
          reason: '${file.path}: one open must still answer both questions -- '
              'a cheaper probe that stopped measuring is not the fix',
        );
        expect(probed.exifOrientation, isNotNull, reason: file.path);
      }
    }, skip: hasSamples ? null : 'no local samples');

    // A single walk must not be a DEGRADED walk. If the fused version ever
    // guessed -- folding an unreadable tag to 1, say -- the RAW decode would
    // silently orient pixels wrongly and nothing downstream would notice.
    test('TC-091 the fused orientation equals the dedicated reader',
        () async {
      for (final file in dngs()) {
        expect(
          (await PhotoSource.probeSource(
            file.path,
            longEdge: windowLongEdge,
          )).exifOrientation,
          await DngEmbeddedJpegExtractor.readOrientation(file.path),
          reason: file.path,
        );
      }
    }, skip: hasSamples ? null : 'no local samples');

    // AC14, over the COMBINED probe. The discarded WIP left its orientation
    // reads outside onDiskRead entirely, so its budget gate could not see half
    // of what it spent; summing the fused probe is what closes that hole.
    test('TC-092 the combined probe reads at most 300KB, and a JPEG still '
        'costs 2 bytes', () async {
      for (final file in dngs()) {
        var read = 0;
        final probed = await PhotoSource.probeSource(
          file.path,
          longEdge: windowLongEdge,
          onDiskRead: (n) => read += n,
        );
        expect(probed.exifOrientation, isNotNull, reason: file.path);
        expect(
          read,
          lessThan(300 * 1024),
          reason: '${file.path}: read $read bytes. The budget covers the '
              'orientation half too -- reads that skip onDiskRead are '
              'unmeasured spend, not free spend',
        );
        expect(read, greaterThan(0), reason: '${file.path}: reads must be '
            'reported through onDiskRead at all, or the gate measures nothing');
      }

      final jpg = jpgDir
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.toLowerCase().endsWith('.jpg'));
      var jpgRead = 0;
      final probed = await PhotoSource.probeSource(
        jpg.path,
        longEdge: windowLongEdge,
        onDiskRead: (n) => jpgRead += n,
      );
      expect(probed.cost, SourceCost.cheap);
      expect(
        jpgRead,
        2,
        reason: 'fusing orientation into the probe must not cost the JPEG hot '
            'path an IFD walk (design section 5). A JPEG carries its '
            'orientation inside the bitstream the decoder already reads',
      );
      expect(probed.exifOrientation, isNull);
    }, skip: hasSamples ? null : 'no local samples');
  });

  // The caller's list is LIVE. AppState hands the controller its own photo
  // list and clears it on a folder reload, which can land in the middle of one
  // of preloadImages' awaits -- after which `items.length - 1` is -1 and the
  // retention-window clamp throws ArgumentError from inside an async gap.
  //
  // The aliasing always existed; probe-first made it reachable on the ordinary
  // path by adding an await before the clamp. The fix is a snapshot at entry,
  // and this is the assertion that fails if anyone removes it: the list is
  // emptied while the first probe is still in flight, which is precisely the
  // window the crash lived in.
  test('TC-094 emptying the caller list mid-load does not crash preloadImages',
      () async {
    expect(noPreviewDng.existsSync(), isTrue, reason: 'sample missing');
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageFailure('NULL_RESULT', 'not the subject'),
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    final live = [PhotoItem(id: 'live-0', files: [noPreviewDng])];
    final pending = controller.preloadImages(
      items: live,
      selectedItemId: 'live-0',
      notifyLoaded: () {},
    );
    // Mid-flight, exactly as a folder reload does it.
    live.clear();

    await expectLater(
      pending,
      completes,
      reason: 'preloadImages must not index a list the caller mutated under '
          'it -- before the snapshot this threw ArgumentError from the '
          'window clamp',
    );
  }, skip: hasSamples ? null : 'no local samples');

  // The end-to-end consequence, and the reason the ruling exists: invariant I6.
  // The loader here is the native bridge seam. A no-preview DNG used to reach
  // its RAW decode only after asking the bridge -- that call was where the
  // orientation came from. With the fused probe it must reach the decoder
  // having asked NOBODY: the probe classified it AND supplied the orientation.
  //
  // The zero is asserted twice on purpose. Before the debounce it proves the
  // probe decided the rung; after the decode it proves the decode did not need
  // the bridge either. Only the second one dies if orientation quietly goes
  // back to being a bridge product.
  test('TC-093 an expensive item reaches its RAW decode with ZERO loader '
      'calls', () async {
    expect(noPreviewDng.existsSync(), isTrue, reason: 'sample missing');
    var loaderCalls = 0;
    var decodes = 0;
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async {
        loaderCalls++;
        return const NativeImageFailure('UNEXPECTED', 'must not be asked');
      },
      dngDecoder: (path) async {
        decodes++;
        return DecodedRgba(rgba: Uint8List(2 * 2 * 4), width: 2, height: 2);
      },
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    final item = PhotoItem(id: 'no-preview', files: [noPreviewDng]);
    await controller.preloadImages(
      items: [item],
      selectedItemId: item.id,
      notifyLoaded: () {},
    );
    expect(
      loaderCalls,
      0,
      reason: 'the content probe classified this file, so the immediate pass '
          'has nothing to ask the bridge',
    );

    await until(() => decodes == 1, reason: 'the debounced RAW decode ran');
    expect(
      loaderCalls,
      0,
      reason: 'the decode got its EXIF orientation from the probe walk. A '
          'bridge call here means the second lookup is back (invariant I6)',
    );
  }, skip: hasSamples ? null : 'no local samples');
}
