import 'package:flutter/widgets.dart';
import '../../models/photo_item.dart';
import '../../models/rename_rule.dart' show ExifMetadata;
import '../../services/image_pipeline/photo_payload.dart';

/// Key on the widget that must measure 1350x900 at 1440x900. Declared here so
/// the geometry gate does not depend on any theme-private type.
const ValueKey<String> kViewportKey = ValueKey<String>('layout.viewport');

/// Everything a layout theme is allowed to arrange. Constructed once per build
/// by MainScreen from AppState; contains no theme-specific field.
@immutable
class MainSurface {
  const MainSurface({
    required this.viewport,
    required this.statusOverlay,
    required this.strip,
    required this.identity,
    required this.actions,
  });

  /// The photo itself: empty state, spinner, unreadable state or the
  /// InteractiveViewer. Already built; a theme only positions it.
  final Widget viewport;

  /// The transient status toast. A theme positions it; timing is not its call.
  final Widget statusOverlay;

  final PhotoStripModel strip;

  /// Null when no folder is loaded.
  final PhotoIdentity? identity;

  final PhotoActions actions;
}

@immutable
class PhotoStripModel {
  const PhotoStripModel({
    required this.items,
    required this.selectedId,
    required this.recycleMode,
    required this.onSelect,
    required this.payloadFor,
    required this.onVisibleRange,
  });

  final List<PhotoItem> items;
  final String? selectedId;
  final bool recycleMode;
  final void Function(String id) onSelect;
  final SourcePayload? Function(String id) payloadFor;

  /// AD-014 contract: the strip reports the PURE visible index range once per
  /// frame; prefetch margin is the controller's business, not the view's.
  final void Function(int firstIndex, int lastIndex) onVisibleRange;
}

@immutable
class PhotoIdentity {
  const PhotoIdentity({
    required this.displayName,
    required this.indexInFolder, // 1-based, for "24 / 318"
    required this.folderCount,
    required this.status,
    required this.exif, // null while unread or unreadable
  });

  final String displayName;
  final int indexInFolder;
  final int folderCount;
  final PhotoStatus status;
  final ExifMetadata? exif;
}

@immutable
class PhotoActions {
  const PhotoActions({
    required this.recycleMode,
    required this.onStar,
    required this.onTrash,
    required this.onToggleRecycleMode,
    required this.onOpenFolder,
    required this.menu,
  });

  final bool recycleMode;
  final VoidCallback onStar;
  final VoidCallback onTrash;
  final VoidCallback onToggleRecycleMode;
  final VoidCallback onOpenFolder;

  /// The overflow menu, already built with its enable/disable rules and its
  /// dialog-opening handlers. A theme chooses where to hang it, never what is
  /// in it.
  final Widget menu;
}