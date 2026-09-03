// F5 / AC7: the cost memo must not stay frozen against the BOOTSTRAP viewport.
//
// `_longEdge` answers `kDefaultPreviewLongEdge` (2800) until the viewport's
// LayoutBuilder calls `updateTargetSize`, and the first window pass runs before
// that frame exists. The memo was keyed by id alone and written first-writer-
// wins, so that whole first window was classified against a placeholder and the
// verdict was never revisited -- not when the real viewport reported, not on a
// window resize. On a display whose physical long edge exceeds 2800, previews
// between 2800 and the real viewport stayed permanently `cheap` and were
// displayed upscaled: exactly what AD-033's frozen threshold exists to prevent.
//
// Synthetic fixture on purpose: the flip is only visible on a preview that
// STRADDLES the bootstrap default and the real viewport (here 3000px, between
// 2800 and 4000). The user's 7008px corpus clears both and is blind to it.
//
//   TC-714  scheduler: the verdict changes when the long edge changes
//   TC-715  controller: the verdict flips after updateTargetSize
//   TC-716  probe economy: still ONE walk per file for a stable viewport

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
// `prefetch_scheduler.dart` re-exports `SourceCost`, which is the only thing
// from `photo_source.dart` this file names.
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';

import '../../support/preload_fixtures.dart';
import '../../support/synthetic_dng.dart';
import '../../support/temp_dirs.dart';

/// Counts `open()` calls on files created inside an [IOOverrides] zone.
///
/// Same instrument TC-090 uses in `photo_source_single_probe_test.dart`: only
/// `open()` is implemented, so a probe that reaches the filesystem another way
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

Future<int> _countingOpens(Future<void> Function() body) async {
  var opens = 0;
  await IOOverrides.runZoned(
    body,
    createFile: (path) =>
        _CountingFile(Zone.root.run(() => File(path)), () => opens++),
  );
  return opens;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String dngPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('m4_cost_memo');
    addTempDirTeardown(dir);
    // 3000px STRADDLES the bootstrap default (2800) and the real viewport
    // (4000) used below: cheap under the placeholder, expensive under the
    // truth. That gap is the whole defect.
    dngPath = await writeSyntheticDng(
      buildSyntheticDng(
        candidates: const [SyntheticCandidate(width: 3000, height: 2000)],
      ),
      dir: dir,
      name: 'preview3000.dng',
    );
  });

  test('TC-714 the memo answers for the long edge it was measured at',
      () async {
    final scheduler = PrefetchScheduler();

    expect(
      (await scheduler.classify('straddler', dngPath, longEdge: 2800)).cost,
      SourceCost.cheap,
      reason: '3000 >= 2800: correct answer for the BOOTSTRAP viewport',
    );

    // The real viewport now reports. Before the fix this returned the memoised
    // `cheap` without a second thought, and the item was served a 3000px
    // preview upscaled to a 4000px window forever.
    expect(
      (await scheduler.classify('straddler', dngPath, longEdge: 4000)).cost,
      SourceCost.expensive,
      reason: 'a verdict measured against 2800 says nothing about a 4000px '
          'viewport -- the memo must not answer a question it never asked',
    );
  });

  // AC7 through the controller: a first-window item classified against the
  // bootstrap 2800 must be re-evaluated once the real viewport is known.
  //
  // The item is browsed AWAY from first, so retention evicts its payload while
  // the cost memo (cleared only by `reset()`) keeps the stale 2800 verdict.
  // That is the state the shipped mechanism governs, and it is the ordinary
  // "browse on, resize the window, come back" sequence.
  //
  // SCOPE, stated rather than implied: an item whose payload is STILL RETAINED
  // is not re-routed by this fix, because `_earlyResolve`
  // (image_preload_controller.dart:832-845) returns on the cache hit before
  // `classify` is reached. Root-caused and parked, with evidence, in
  // docs/logs/2026-09-03/m4-ac7-cached-payload-finding.md. Asserting the
  // retained case here would be asserting something nothing implements.
  //
  // Observable: whether the RAW decoder runs. Cheap => the embedded preview is
  // served and the decoder is never touched; expensive => the serial lane
  // decodes. Counting decodes makes the flip mechanical rather than a claim
  // about an enum nobody can see.
  test('TC-715 a first-window verdict is re-evaluated after updateTargetSize',
      () async {
    var decodes = 0;
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageFailure('UNEXPECTED', 'probe decides the rung here'),
      dngDecoder: (path) async {
        decodes++;
        return DecodedRgba(rgba: Uint8List(2 * 2 * 4), width: 2, height: 2);
      },
    );
    addTearDown(controller.dispose);

    // One file, many ids: the memo is keyed per id, so only 'straddler' carries
    // a first-window verdict. The rest exist to move the retention window.
    final items = [
      for (var i = 0; i < 30; i++)
        PhotoItem(id: i == 0 ? 'straddler' : 'filler-$i', files: [File(dngPath)]),
    ];

    // Pass 1: NO updateTargetSize yet -- exactly the first-window ordering
    // (loadFolder -> selectItem -> preloadImages all precede the first frame).
    // _longEdge is the 2800 placeholder, so 3000 clears it and the item is
    // cheap: no decode may run.
    await controller.preloadImages(
      items: items,
      selectedItemId: 'straddler',
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(
      decodes,
      0,
      reason: 'against the bootstrap 2800 this item is genuinely cheap; a '
          'decode here would mean the test is measuring something else',
    );
    expect(
      controller.payloadFor('straddler'),
      isNotNull,
      reason: 'pass 1 served the embedded preview at the bootstrap viewport',
    );

    // The viewport finally reports a display whose physical long edge is 4000,
    // and the user browses on. Retention drops the payload; the cost memo
    // survives (it is cleared only by a folder reload), which is exactly the
    // state F5 describes.
    controller.updateTargetSize(4000, 2600);
    await controller.preloadImages(
      items: items,
      selectedItemId: 'filler-29',
      notifyLoaded: () {},
    );
    await until(
      () => controller.payloadFor('straddler') == null,
      reason: 'browsing away must evict the first-window payload, or this test '
          'is measuring the cache rather than the memo',
    );
    final decodesBeforeReturn = decodes;

    // Coming back. Nothing is retained for this id any more, so the router has
    // to ask again -- and before the fix the memo answered with the verdict it
    // had measured against 2800, so the item was served the same 3000px
    // preview upscaled into a 4000px window forever (the outcome AD-033
    // exists to prevent) and NO decode ever ran.
    await controller.preloadImages(
      items: items,
      selectedItemId: 'straddler',
      notifyLoaded: () {},
    );
    await until(
      () => decodes > decodesBeforeReturn,
      reason: 'the re-evaluated verdict is expensive, so the serial lane must '
          'run a real RAW decode once the true viewport is known',
    );
  });

  // The economy this memo exists for (the invariant-I6 successor): a STABLE
  // viewport must still cost exactly one walk per file per folder. Re-probing
  // on a long-edge change is bounded by resize events; re-probing per
  // navigation would be the regression.
  test('TC-716 a stable viewport still costs exactly ONE walk per file',
      () async {
    final scheduler = PrefetchScheduler();

    final opensAtFirstLongEdge = await _countingOpens(() async {
      for (var i = 0; i < 5; i++) {
        await scheduler.classify('straddler', dngPath, longEdge: 2800);
      }
    });
    expect(
      opensAtFirstLongEdge,
      1,
      reason: 'five classify calls at the SAME long edge must walk the file '
          'once; $opensAtFirstLongEdge opens is a probe-per-navigation '
          'regression',
    );

    final opensAfterResize = await _countingOpens(() async {
      for (var i = 0; i < 5; i++) {
        await scheduler.classify('straddler', dngPath, longEdge: 4000);
      }
    });
    expect(
      opensAfterResize,
      1,
      reason: 'a long-edge change buys exactly ONE re-measurement, then the '
          'new value is memoised in its turn',
    );
  });
}
