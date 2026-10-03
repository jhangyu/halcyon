import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';

/// R6 pool activation (Task #9), Halcyon half: the host app must actually
/// ASSIGN the buffer pool, because ceyx leaves `CeyxDecodePool.nativeBufferPool`
/// null by default and every pooled-route gate short-circuits on that null.
///
/// Before this wiring the whole WP6/WP10 pooled route was reachable only from
/// ceyx's own tests: production decodes fell back to the legacy native
/// allocator and nothing was red anywhere. That is the failure this file
/// exists to make impossible to reintroduce.
void main() {
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
}
