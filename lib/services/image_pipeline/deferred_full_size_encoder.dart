import 'dart:typed_data';

import '../../models/photo_item.dart';
import 'decode_lane.dart';
import 'decoded_rgba_image_provider.dart';
import 'dng_decode_contract.dart';
import 'lane_priority.dart';
import 'payload_reencoder.dart';
import 'photo_payload.dart';

/// Produces the full-size JPEG for a slot that is holding a TEMPORARY
/// [PixelPayload], at the lowest lane priority, and hands it to [onEncoded].
///
/// Spec v2 §3.2. Every slot in the retention window must end up resident as a
/// full-size JPEG; the two arms that cannot produce one at re-encode time (no
/// full-size pixels on hand, or an encoder that failed) keep their pixels only
/// until this job lands. "Temporarily" is bounded by this job's completion or
/// abandonment -- never by navigation.
///
/// It owns NO buffer sizing and NO concurrency of its own (S1 ledger-only): it
/// runs on the SAME [DecodeLane] every other expensive decode queues on, in an
/// appended, lowest band ([LaneGroup.deferredResidency]).
class DeferredFullSizeEncoder {
  DeferredFullSizeEncoder({
    required DecodeLane lane,
    required DngFullDecoder? Function() dngDecoder,
    required PayloadEncoder encoder,
    required int? Function(String id) exifOrientationFor,
    required SourcePayload? Function(String id) currentPayloadFor,
    required bool Function(String id) isRetained,
    required void Function(
      String id,
      SourcePayload previous,
      EncodedPayload replacement,
    )
    onEncoded,
    required Future<void> Function() awaitIdleSlot,
  }) : _lane = lane,
       _dngDecoder = dngDecoder,
       _encoder = encoder,
       _exifOrientationFor = exifOrientationFor,
       _currentPayloadFor = currentPayloadFor,
       _isRetained = isRetained,
       _onEncoded = onEncoded,
       _awaitIdleSlot = awaitIdleSlot;

  final DecodeLane _lane;
  final DngFullDecoder? Function() _dngDecoder;
  final PayloadEncoder _encoder;
  final int? Function(String id) _exifOrientationFor;
  final SourcePayload? Function(String id) _currentPayloadFor;
  final bool Function(String id) _isRetained;
  final void Function(
    String id,
    SourcePayload previous,
    EncodedPayload replacement,
  )
  _onEncoded;
  final Future<void> Function() _awaitIdleSlot;

  /// id -> the payload object the queued/running job was scheduled AGAINST.
  /// Cleared when that job finishes, either way.
  final Map<String, SourcePayload> _jobs = <String, SourcePayload>{};

  /// Payload objects a job has already been scheduled for.
  ///
  /// An [Expando], not a [Set]: a set would keep every attempted payload --
  /// including a ~21MB pixel buffer -- alive for the life of this object,
  /// which is the opposite of what this class exists to achieve. The mark
  /// therefore DIES WITH THE PAYLOAD, exactly like
  /// `TierTwoRegistry._fullResFailures`, and that is precisely the wanted
  /// lifetime: a NEW payload object for the same id may schedule a new job,
  /// while the object that already failed never gets a retry loop.
  final Expando<bool> _attempted = Expando<bool>('deferredFullSizeEncode');

  int _scheduled = 0;
  int _completed = 0;
  int _abandoned = 0;

  // These three are deliberately NOT `@visibleForTesting`: they are forwarded
  // through `ImagePreloadController.debugDeferredCompletedCount` /
  // `debugDeferredAbandonedCount`, which carry the annotation for the call
  // sites that matter. This class is an internal collaborator of the
  // controller, not a public API surface of its own -- the same convention
  // `TierTwoScheduler.debugCatchUpEnqueueCount` records
  // (`tier_two_scheduler.dart:145-149`).
  int get debugScheduledCount => _scheduled;

  int get debugCompletedCount => _completed;

  int get debugAbandonedCount => _abandoned;

  /// Schedules one job for [item]. A second call for the same
  /// `(id, previous)` pair -- while one is queued or running, or after one has
  /// already finished -- is a no-op.
  void schedule(
    PhotoItem item, {
    required SourcePayload previous,
    required int distance,
  }) {
    if (_attempted[previous] == true) return;
    _attempted[previous] = true;
    _jobs[item.id] = previous;
    _scheduled++;
    _lane.enqueue(
      (LaneTaskKind.deferredEncode, item.id),
      priority: deferredResidencyPriorityFor(distance),
      // No `estimatedBytes`: S1 ledger-only. This task introduces no new
      // byte sizing, and an estimate charged here would make the byte gate
      // refuse work it does not bound.
      body: () => _run(item, previous),
    );
  }

  /// Drops all in-flight bookkeeping (folder switch / dispose).
  ///
  /// The QUEUED entries are dropped by the lane's own `clearPending()`, which
  /// the controller's reset/dispose already call -- this class does not
  /// reach into a lane it shares. A job already RUNNING completes and then
  /// finds its guards false, because the payload cache it re-checks against
  /// has been cleared by the same teardown.
  void reset() {
    _jobs.clear();
  }

  bool _guardsHold(String id, SourcePayload previous) =>
      _isRetained(id) && identical(_currentPayloadFor(id), previous);

  Future<void> _run(PhotoItem item, SourcePayload previous) async {
    final id = item.id;

    void abandon() {
      _abandoned++;
      if (identical(_jobs[id], previous)) _jobs.remove(id);
    }

    // (1) Guards, before anything is bought.
    if (!_guardsHold(id, previous)) return abandon();
    final decoder = _dngDecoder();
    if (decoder == null) return abandon();
    final file = item.bestFileToLoad;
    if (file == null) return abandon();
    final orientation = _exifOrientationFor(id);
    if (orientation == null) return abandon();

    // (2) Idle priority. The user's own navigation never waits behind this.
    await _awaitIdleSlot();
    // (3) Re-check after the await: every post-await re-check in this pipeline
    // is load-bearing (G-023).
    if (!_guardsHold(id, previous)) return abandon();

    // (4) Decode the ORIGINAL file at full resolution.
    final DecodedRgba decoded;
    try {
      decoded = await decoder(file.path);
    } catch (_) {
      return abandon();
    }

    // (5) Orient, still at full resolution. The window-resolution downscale
    // (`decodedRgbaToPixelPayload`'s longEdge path) is not reachable from
    // here at all -- that is the never-below-full-size guarantee (AC-5),
    // expressed structurally rather than as a check.
    final OrientedFullRes fullRes;
    try {
      fullRes = await decodedRgbaToOrientedFullRes(
        decoded,
        exifOrientation: orientation,
      );
    } catch (_) {
      decoded.releaseNative?.call();
      return abandon();
    }

    try {
      // The same buffer-length guard `reencodePayload` applies: the native
      // encoder trusts width*height to bound its scanline reads, and a short
      // buffer is a heap OOB read in release.
      if (fullRes.rgba.lengthInBytes != fullRes.width * fullRes.height * 4) {
        return abandon();
      }
      // (6) Encode at the EXISTING quality symbol. No literal, no constant of
      // this file's own (spec §4).
      final Uint8List jpeg;
      try {
        jpeg = await _encoder(
          fullRes.rgba,
          width: fullRes.width,
          height: fullRes.height,
          quality: kReencodeJpegQuality,
        );
      } catch (_) {
        return abandon();
      }
      if (jpeg.isEmpty) return abandon();
      // (7) Third guard re-check: the decode and the encode are both awaits.
      if (!_guardsHold(id, previous)) return abandon();

      // (8) Hand it over. The replacement records the FULL-RESOLUTION frame's
      // dimensions, so a payload whose recorded size is smaller than the
      // decoded frame is never constructed on this path.
      deferredFullSizeEncodes++;
      _completed++;
      if (identical(_jobs[id], previous)) _jobs.remove(id);
      _onEncoded(
        id,
        previous,
        EncodedPayload(jpeg, width: fullRes.width, height: fullRes.height),
      );
    } finally {
      // This path never publishes a `ui.Image`: the tier-2 entry comes from
      // the replaced payload through the ordinary encoded route. So the
      // oriented handle, when one had to be rendered, is ours to dispose --
      // at 4080x3056 RGBA8 that is ~50MB, a leak rather than a nit.
      fullRes.image?.dispose();
      fullRes.releaseNative?.call();
    }
  }
}
