import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

/// One [PhotoItem], file `<dir>/<id>.<ext>` (default `src/<id>.jpg`).
PhotoItem itemFor(String id, {String dir = 'src', String ext = 'jpg'}) =>
    PhotoItem(id: id, files: [File('$dir/$id.$ext')]);

/// A 4×4 zeroed [PixelPayload]; a fresh buffer per call.
PixelPayload tinyPixelPayload() =>
    PixelPayload(width: 4, height: 4, rgba: Uint8List(4 * 4 * 4));

/// The canonical red keyed viewport. Finders assert `find.byKey(kViewportKey)`,
/// so call sites pass it explicitly — [testSurface] never defaults a viewport.
const Widget kRedViewport = ColoredBox(key: kViewportKey, color: Colors.red);

/// The shared [MainSurface] skeleton. Every parameter except [viewport]
/// defaults to the literal the old per-file builders hard-coded; a builder that
/// differed passes that field explicitly. [recycleMode] feeds both the strip
/// and the actions (every builder kept them equal).
MainSurface testSurface({
  required Widget viewport,
  List<PhotoItem> items = const [],
  String? selectedId,
  PhotoIdentity? identity,
  SourcePayload? Function(String id)? payloadFor,
  void Function(String id)? onSelect,
  void Function(int firstIndex, int lastIndex)? onVisibleRange,
  bool recycleMode = false,
  VoidCallback? onStar,
  VoidCallback? onTrash,
  VoidCallback? onToggleRecycleMode,
  VoidCallback? onOpenFolder,
  Widget menu = const SizedBox.shrink(),
}) {
  return MainSurface(
    viewport: viewport,
    statusOverlay: const SizedBox.shrink(),
    strip: PhotoStripModel(
      items: items,
      selectedId: selectedId,
      recycleMode: recycleMode,
      onSelect: onSelect ?? (_) {},
      payloadFor: payloadFor ?? ((_) => null),
      onVisibleRange: onVisibleRange ?? (_, __) {},
    ),
    identity: identity,
    actions: PhotoActions(
      recycleMode: recycleMode,
      onStar: onStar ?? () {},
      onTrash: onTrash ?? () {},
      onToggleRecycleMode: onToggleRecycleMode ?? () {},
      onOpenFolder: onOpenFolder ?? () {},
      menu: menu,
    ),
  );
}
