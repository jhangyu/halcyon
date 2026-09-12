import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';
import 'package:halcyon_flutter/services/platform/working_set_trim.dart';

/// R6 pool activation (Task #9), Halcyon half: the host app must actually
/// ASSIGN the buffer pool, because ceyx leaves `CeyxDecodePool.nativeBufferPool`
/// null by default and every pooled-route gate short-circuits on that null.
///
/// Before this wiring the whole WP6/WP10 pooled route was reachable only from
/// ceyx's own tests: production decodes fell back to the legacy native
/// allocator and nothing was red anywhere. That is the failure this file
/// exists to make impossible to reintroduce.
void main() {
  setUp(WorkingSetTrim.debugReset);
  tearDown(WorkingSetTrim.debugReset);

  test(
    'R6-AC2: the production init assigns the shared native buffer pool',
    () {
      ensureHalcyonDecodePoolConfigured();

      expect(
        CeyxDecodePool.nativeBufferPool,
        isNotNull,
        reason:
            'a null pool disables the pooled decode route silently — every '
            'decode falls back to the legacy native allocator and no test '
            'anywhere goes red',
      );
      expect(
        identical(CeyxDecodePool.nativeBufferPool, CeyxNativeBufferPool.shared),
        isTrue,
        reason:
            'the process-wide instance is the one sized against the host '
            'budget; a second pool would double the slot bound',
      );
    },
  );

  test(
    'R6-AC3: the production init installs the shrink→trim hook, and the '
    'folder-switch trim still runs',
    () {
      ensureHalcyonDecodePoolConfigured();
      addTearDown(() => CeyxNativeBufferPool.shared.onShrink = null);

      final hook = CeyxNativeBufferPool.shared.onShrink;
      expect(
        hook,
        isNotNull,
        reason:
            'without this hook a completed pool shrink hands nothing back to '
            'the OS on Windows — the freed pages stay in the working set',
      );

      // Stand in for the pool: a completed shrink calls the hook with the
      // number of buffers it freed.
      hook!(3);
      expect(WorkingSetTrim.debugShrinkTrimCalls, 1);

      // The folder-switch trim is a different event: it fires after the caches
      // have already been evicted and nothing is about to be re-read, so it
      // stays enabled and is untouched by this change.
      WorkingSetTrim.trimNow();
      expect(WorkingSetTrim.debugTrimNowCalls, 1);
    },
  );
}
