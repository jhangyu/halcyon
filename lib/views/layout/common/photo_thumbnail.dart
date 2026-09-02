import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/image_pipeline/photo_payload.dart';
import '../../../services/image_pipeline/raw_pixels_image.dart';

/// A single gallery thumbnail chip: `width` x `height` logical pixels, the
/// decoded longest edge capped at `size * devicePixelRatio`, `fit: cover`.
///
/// Extracted from the old per-list-row thumbnail widget (T3 of the gallery
/// layout plan) so a layout theme can render a strip without redrawing it.
/// The placeholder box that widget drew before a payload landed is a
/// `null` [payload] here.
///
/// The SOURCE-PAYLOAD BOUND (frozen — do not raise without T12):
///
/// - Encoded payloads are decoded through `ResizeImage` with `policy: fit`, so
///   any source is capped to `max(width, height) * devicePixelRatio` on its
///   longest edge at DECODE time. `Image.memory`'s `width`/`height` alone are
///   LAYOUT constraints only (see the M1 comment); the cap has to be applied to
///   the decode or a full-resolution bitmap is decoded regardless of the paint
///   box.
/// - `PixelPayload` is returned as a bare `RawPixelsImage(payload)` — NOT
///   wrapped in `ResizeImage`, deliberately: `ResizeImage` applies its cap only
///   through the `decode` callback it hands down (flutter image_provider.dart:
///   1350-1418), and `RawPixelsImage` ignores that callback — it builds the
///   image with `decodeImageFromPixels` (raw_pixels_image.dart:36-45). A wrapper
///   here would cap nothing while reading in review as protection that exists.
///   The bound for pixel payloads is enforced at PRODUCTION time instead: the
///   RAW path is already capped at 200px long edge
///   (image_preload_controller.dart:156) and TC-373 asserts that on the payload
///   rather than on a wrapper.
///
/// The 200px production cap therefore bounds this widget's ceiling from above,
/// but only partially: within the gallery's 90-200px column range (plan R8,
/// `round1-plan.md` §5) the widest chip the design can ask for stays within what
/// the source already produces at 2× density. At 3× the cap falls short — the
/// 74px chip wants 222 physical px against 200 available (a pre-existing 22px
/// shortfall, true of the app today); it is unchanged by this round and is not a
/// new defect. The frozen plan records this honestly at `round1-plan.md:1021-1023`
/// ("the supply arithmetic holds at 2×, not 3×"). Raising the source to feed a
/// larger chip elsewhere is exactly what the dropped T12 (thumbnail source cap,
/// `round1-plan.md` §4 T12) would have cost (≈6.5x memory per cached thumbnail
/// plus a re-derivation of the retention budgets). Touch the image pipeline
/// instead of this doc if a future theme asks for a larger chip.
class PhotoThumbnail extends StatelessWidget {
  const PhotoThumbnail({
    super.key,
    required this.payload, // null -> placeholder box
    required this.width,
    required this.height,
    this.borderRadius = 0,
  });

  final SourcePayload? payload;
  final double width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final payload = this.payload;
    if (payload == null) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image(
        image: _thumbnailProvider(context, payload),
        width: width,
        height: height,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }

  ImageProvider _thumbnailProvider(BuildContext context, SourcePayload payload) {
    switch (payload) {
      case EncodedPayload(:final bytes):
        // M1 (image-pipeline redesign, docs/logs/2026-08-23/
        // image-pipeline-redesign-handover.md §6 M1): width/height on
        // Image.memory alone are LAYOUT constraints only — the decoder still
        // produces a full-resolution bitmap. Cap the DECODE itself at
        // size * devicePixelRatio on the longest edge via ResizeImage's `fit`
        // policy, which fits the source within a cap x cap box while
        // preserving aspect ratio — `exact` (or naive cacheWidth +
        // cacheHeight) would silently squash non-square sources.
        final cap =
            (math.max(width, height) * MediaQuery.devicePixelRatioOf(context)).round();
        return ResizeImage(
          MemoryImage(bytes),
          width: cap,
          height: cap,
          policy: ResizeImagePolicy.fit,
        );
      case PixelPayload():
        // NOT wrapped in ResizeImage, deliberately: ResizeImage applies its
        // cap only through the `decode` callback it hands down
        // (flutter image_provider.dart:1350-1418), and RawPixelsImage ignores
        // that callback -- it builds the image with decodeImageFromPixels
        // (raw_pixels_image.dart:36-45). A wrapper here would cap nothing
        // while reading in review as protection that exists. The bound is
        // enforced at PRODUCTION time instead: the payload is already capped
        // at 200px long edge (image_preload_controller.dart, RAW branch), and
        // TC-373 asserts that on the payload rather than on a wrapper.
        return RawPixelsImage(payload);
    }
  }
}