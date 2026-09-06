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
    'R6-AC3: the idle working-set trim is suppressed once the pool route owns '
    'native buffers, while the folder-switch trim still runs',
    () async {
      ensureHalcyonDecodePoolConfigured();

      expect(
        WorkingSetTrim.suppressed,
        isTrue,
        reason:
            'idle-delayed trimming pages out exactly the idle pooled slots the '
            'pool keeps resident for immediate reuse',
      );

      // The idle path must not reach the platform call at all -- not even the
      // rate-limit bookkeeping, which is what `debugTrimAttempts` counts.
      //
      // Real time, not FakeAsync: the delay must be long enough that an
      // UNsuppressed request would have fired its zero-delay timer by now,
      // otherwise this assertion could not fail and would prove nothing.
      WorkingSetTrim.idleDelay = Duration.zero;
      WorkingSetTrim.request();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(WorkingSetTrim.debugTrimAttempts, 0);

      // The folder-switch trim is a different event: it fires after the caches
      // have already been evicted and nothing is about to be re-read, so it
      // stays enabled. Suppressing it too would be a bigger change than the
      // ruling asked for.
      WorkingSetTrim.trimNow();
      expect(
        WorkingSetTrim.debugTrimAttempts,
        1,
        reason: 'trimNow is deliberately NOT suppressed',
      );
    },
  );
}
