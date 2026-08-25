import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A one-shot [ImageProvider] that hands a pre-decoded full-resolution
/// [ui.Image] to the [ImageCache] and then owns nothing.
///
/// This is the RAW full-resolution tier-2 twin of [RawPixelsImage] (design
/// `docs/logs/2026-08-24/m5-dual-window-design.md` §2.3). Unlike
/// [RawPixelsImage], which decodes fresh pixels on every load, this provider
/// is constructed with an already-decoded [ui.Image] -- the controller does
/// the decode+upload once, in one function body, and immediately hands the
/// result off through [loadImage] so the [ImageCache] becomes the sole owner.
/// No retained RGBA buffer is ever held by this class or its key (AC-M5-9):
/// a retained buffer alongside the `ui.Image` would double per-item cost at
/// 24MP, and would be invisible to the [ImageCache] LRU.
///
/// Key semantics (frozen, amendments only via team-lead): equality is
/// [identical] on [payloadIdentity] plus [width] and [height] -- deliberately
/// NOT on the [ui.Image] itself. When a payload is replaced (item leaves the
/// retention window and returns), `payloadIdentity` changes and a fresh key
/// is produced automatically, so a stale tier-2 entry can never be mistaken
/// for the current one (round-2 BLOCKER-1 semantics, same rule as
/// [RawPixelsImage]).
///
/// Delivery is one-shot: the first [loadImage] call hands [image] to the
/// [ImageCache]-owned completer and drops this provider's reference to it.
/// The controller is expected to resolve this provider synchronously within
/// the same function body that constructs it, so a second load should be
/// unreachable in practice; if it somehow happens, this returns an error
/// stream rather than crashing or handing out a disposed/foreign image.
class RawFullResImage extends ImageProvider<RawFullResImage> {
  RawFullResImage({
    required this.payloadIdentity,
    required this.width,
    required this.height,
    required ui.Image image,
  }) : _image = image;

  /// Identity anchor -- typically the window-resolution payload object this
  /// full-resolution upgrade was decoded on behalf of. Compared with
  /// [identical], never by value.
  final Object payloadIdentity;

  final int width;
  final int height;

  ui.Image? _image;
  bool _delivered = false;

  @override
  Future<RawFullResImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<RawFullResImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    RawFullResImage key,
    ImageDecoderCallback decode,
  ) {
    final image = key._image;
    if (key._delivered || image == null) {
      // Defensive only -- the controller resolves this provider once,
      // synchronously. A second load request has nothing left to deliver.
      return OneFrameImageStreamCompleter(
        Future<ImageInfo>.error(
          StateError(
            'RawFullResImage is one-shot and has already been delivered.',
          ),
        ),
      );
    }
    key._delivered = true;
    key._image = null;
    return OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RawFullResImage &&
        identical(other.payloadIdentity, payloadIdentity) &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(
    identityHashCode(payloadIdentity),
    width,
    height,
  );

  @override
  String toString() => 'RawFullResImage(${width}x$height)';
}
