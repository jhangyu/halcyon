import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/file_retry.dart';

/// Builds the exception Dart raises on Windows when another process holds the
/// file open. Injected rather than provoked, so these tests are meaningful on
/// macOS/Linux where the condition cannot be reproduced at all.
PathAccessException sharingViolation() => const PathAccessException(
  'C:\\photos\\IMG_0001.JPG',
  OSError(
    'The process cannot access the file because it is being used by another '
    'process.',
    kWindowsSharingViolation,
  ),
  'Cannot rename file',
);

void main() {
  group('isSharingViolation', () {
    // TC-335
    test('matches errno 32 and 33, rejects other OS errors', () {
      expect(isSharingViolation(sharingViolation()), isTrue);
      expect(
        isSharingViolation(
          const PathAccessException('p', OSError('locked', kWindowsLockViolation)),
        ),
        isTrue,
      );
      // POSIX EACCES arrives as the SAME exception type: type alone must never
      // be the discriminator, or every permission error would be retried.
      expect(
        isSharingViolation(
          const PathAccessException('p', OSError('Permission denied', 13)),
        ),
        isFalse,
      );
      expect(
        isSharingViolation(
          const FileSystemException('no space', 'p', OSError('ENOSPC', 28)),
        ),
        isFalse,
      );
      expect(isSharingViolation(const FileSystemException('no osError')), isFalse);
      expect(isSharingViolation(StateError('unrelated')), isFalse);
    });
  });

  group('retryOnSharingViolation', () {
    // TC-336
    test('returns the value without delay when the first attempt succeeds', () async {
      var calls = 0;
      final result = await retryOnSharingViolation(() async {
        calls++;
        return 'ok';
      });
      expect(result, 'ok');
      expect(calls, 1);
    });

    // TC-337 — the "obstruction clears" case.
    test('retries and then SUCCEEDS once the locker releases the file', () async {
      var calls = 0;
      final result = await retryOnSharingViolation(() async {
        calls++;
        if (calls < 3) throw sharingViolation();
        return 'renamed';
      }, delaysMs: const [1, 1, 1, 1]);
      expect(result, 'renamed');
      expect(calls, 3);
    });

    // TC-338 — the anti-swallow guard. If a future refactor turns the wrapper
    // into a swallow, a user's failed move becomes silent data loss; this test
    // is what stops that.
    test('gives up and RETHROWS the original exception when the budget is spent',
        () async {
      var calls = 0;
      final injected = sharingViolation();
      await expectLater(
        retryOnSharingViolation(() async {
          calls++;
          throw injected;
        }, delaysMs: const [1, 1, 1, 1]),
        throwsA(same(injected)),
      );
      expect(calls, 5, reason: '1 initial attempt + 4 retries');
    });

    // TC-339
    test('does NOT retry a non-sharing-violation failure', () async {
      var calls = 0;
      final permission = const PathAccessException(
        'p',
        OSError('Permission denied', 13),
      );
      await expectLater(
        retryOnSharingViolation(() async {
          calls++;
          throw permission;
        }, delaysMs: const [1, 1, 1, 1]),
        throwsA(same(permission)),
      );
      expect(calls, 1, reason: 'a permanent error must fail immediately');
    });
  });
}
