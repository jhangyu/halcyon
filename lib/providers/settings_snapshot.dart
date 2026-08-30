import '../models/shortcut_bindings.dart';
import '../services/image_pipeline/retention_policy.dart';
import '../services/library/photo_export_service.dart';

/// Everything the settings panel can change, captured when it opens.
///
/// The panel applies live (so lane width and retention are a real preview),
/// which only works if Cancel can put every field back -- including the
/// persisted prefs, since every setter writes through.
class SettingsSnapshot {
  const SettingsSnapshot({
    required this.autoAdvance,
    required this.overwriteExisting,
    required this.decodeLaneWidth,
    required this.exportJpegQuality,
    required this.exportLongEdge,
    required this.exportFiletype,
    required this.retentionTierOverride,
    required this.shortcuts,
  });

  final bool autoAdvance;
  final bool overwriteExisting;
  final int decodeLaneWidth;
  final int exportJpegQuality;
  final int exportLongEdge;
  final ExportFiletype exportFiletype;

  /// Null means "no override, follow the machine-derived tier".
  final RetentionTier? retentionTierOverride;
  final ShortcutBindings shortcuts;
}
