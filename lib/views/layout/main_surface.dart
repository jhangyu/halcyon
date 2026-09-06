import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import '../../models/photo_item.dart';
import '../../models/rename_rule.dart' show ExifMetadata;
import '../../services/image_pipeline/payload_state.dart';
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
    this.stateFor = _absentPayloadStateFor,
    required this.onVisibleRange,
  });

  final List<PhotoItem> items;
  final String? selectedId;
  final bool recycleMode;
  final void Function(String id) onSelect;
  final SourcePayload? Function(String id) payloadFor;

  /// PHASE 5: ONE ROW'S readiness. A tile wraps itself in a
  /// [ValueListenableBuilder] on its own id (see [StripTile]), so a landing
  /// repaints that tile and no other. This REPLACED a strip-wide `revision`
  /// Listenable that rebuilt every row on every tile landing.
  ///
  /// Defaults to [_absentPayloadStateFor], a constant listenable that never
  /// fires, so a theme widget test that supplies its payloads directly needs
  /// no pipeline. Production always passes `AppState.payloadStateFor`.
  final ValueListenable<PayloadState> Function(String id) stateFor;

  /// AD-014 contract: the strip reports the PURE visible index range once per
  /// frame; prefetch margin is the controller's business, not the view's.
  final void Function(int firstIndex, int lastIndex) onVisibleRange;
}

/// The never-firing default for [PhotoStripModel.stateFor]. One shared
/// instance, so a strip built without per-item state allocates nothing per
/// row and rebuilds exactly when it used to.
final ValueNotifier<PayloadState> _kAbsentPayloadState =
    ValueNotifier<PayloadState>(const PayloadState.absent());

ValueListenable<PayloadState> _absentPayloadStateFor(String id) =>
    _kAbsentPayloadState;

/// PHASE 5: one strip row, rebuilt when THAT row's payload state changes.
///
/// Every theme's tile builder wraps its chip in this instead of rebuilding the
/// whole strip, so a landing for one row cannot repaint 40 others. It hands
/// the builder the row's PAYLOAD (read back through the model at build time),
/// never the state object: what a tile paints is still decided by the
/// pipeline's own accessor.
class StripTile extends StatelessWidget {
  const StripTile({
    super.key,
    required this.strip,
    required this.id,
    required this.builder,
  });

  final PhotoStripModel strip;
  final String id;
  final Widget Function(BuildContext context, SourcePayload? payload) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PayloadState>(
      valueListenable: strip.stateFor(id),
      builder: (context, _, _) => builder(context, strip.payloadFor(id)),
    );
  }
}

@immutable
class PhotoIdentity {
  const PhotoIdentity({
    required this.displayName,
    required this.indexInFolder, // 1-based, for "24 / 318"
    required this.folderCount,
    required this.status,
    required this.exif, // null while unread or unreadable
    this.starredCount = 0,
    this.trashedCount = 0,
  });

  final String displayName;
  final int indexInFolder;
  final int folderCount;
  final PhotoStatus status;
  final ExifMetadata? exif;

  /// Folder-wide aggregates, for the themes whose mockup draws a marked-count
  /// readout (darkroom `.counter .s`, paper `.overcount`). Defaulted to 0 so a
  /// theme test that does not care about them constructs an identity exactly
  /// as it did before these fields existed.
  final int starredCount;
  final int trashedCount;
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