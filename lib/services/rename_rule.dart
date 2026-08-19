/// EXIF fields this feature can put into a filename. Read once per
/// [PhotoItem] (from its JPG sibling when there is one) and shared by every
/// file in that group.
class ExifMetadata {
  const ExifMetadata({
    this.captureDate,
    this.camera,
    this.lens,
    this.make,
    this.artist,
    this.shutter,
    this.aperture,
    this.focalLength,
    this.gpsImgDirection,
    this.iso,
  });

  final DateTime? captureDate;
  final String? camera;
  final String? lens;
  final String? make;
  final String? artist;
  final String? shutter;
  final double? aperture;
  final double? focalLength;
  final double? gpsImgDirection;
  final int? iso;
}

/// A filename template such as `{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}`.
///
/// Pure: rendering never touches the filesystem, so the whole naming policy
/// is unit-testable without photos. `{seq}` is supplied by the caller
/// (`planRenames`), which is the only place that can know how many items
/// collide on the same rendered name.
class RenameRule {
  const RenameRule(this.template);

  final String template;

  static const String kDefaultTemplate = '{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}';

  static const List<({String label, String template})> presets = [
    (label: 'Date & time', template: kDefaultTemplate),
    (label: 'Compact', template: '{YYYY}{MM}{DD}_{hh}{mm}{ss}'),
    (label: 'Camera-style', template: 'IMG_{YYYY}{MM}{DD}_{hh}{mm}{ss}'),
    (label: 'Date + sequence', template: '{YYYY}-{MM}-{DD}_{seq}'),
  ];

  static const List<({String title, List<String> tokens})> variableGroups = [
    (
      title: 'Date/time',
      tokens: ['{YYYY}', '{MM}', '{DD}', '{hh}', '{mm}', '{ss}'],
    ),
    (title: 'Camera', tokens: ['{camera}', '{lens}', '{make}', '{artist}']),
    (
      title: 'Shooting',
      tokens: ['{f}', '{focal}', '{iso}', '{shutter}', '{direction}'],
    ),
    (title: 'File', tokens: ['{seq}', '{orig}']),
  ];

  static final RegExp _token = RegExp(r'\{(\w+)(?::(\d+))?\}');

  static const Set<String> _known = {
    'YYYY', 'MM', 'DD', 'hh', 'mm', 'ss',
    'camera', 'lens', 'make', 'artist',
    'f', 'focal', 'iso', 'shutter', 'direction',
    'seq', 'orig',
  };

  /// Null when the template is usable; otherwise a message for the dialog.
  String? get error {
    if (template.trim().isEmpty) return 'Rule is empty';
    for (final match in _token.allMatches(template)) {
      final name = match.group(1)!;
      if (!_known.contains(name)) return 'Unknown variable {$name}';
    }
    final probe = render(
      meta: null,
      fileModified: DateTime(2000),
      originalBase: 'x',
      seq: 1,
    );
    if (probe.isEmpty) return 'Rule produces an empty filename';
    return null;
  }

  /// Renders the new basename (no extension). [seq] is 1-based.
  String render({
    required ExifMetadata? meta,
    required DateTime fileModified,
    required String originalBase,
    required int seq,
  }) {
    final date = meta?.captureDate ?? fileModified;
    final out = template.replaceAllMapped(_token, (match) {
      final name = match.group(1)!;
      final width = int.tryParse(match.group(2) ?? '') ?? 1;
      return switch (name) {
        'YYYY' => _pad(date.year, 4),
        'MM' => _pad(date.month, 2),
        'DD' => _pad(date.day, 2),
        'hh' => _pad(date.hour, 2),
        'mm' => _pad(date.minute, 2),
        'ss' => _pad(date.second, 2),
        'camera' => meta?.camera ?? '',
        'lens' => meta?.lens ?? '',
        'make' => meta?.make ?? '',
        'artist' => meta?.artist ?? '',
        'f' => meta?.aperture == null ? '' : 'f${_trim(meta!.aperture!)}',
        'focal' => meta?.focalLength == null
            ? ''
            : '${_trim(meta!.focalLength!)}mm',
        'iso' => meta?.iso == null ? '' : 'ISO${meta!.iso}',
        'shutter' => meta?.shutter ?? '',
        'direction' => meta?.gpsImgDirection == null
            ? ''
            : meta!.gpsImgDirection!.round().toString(),
        'seq' => _pad(seq, width),
        'orig' => originalBase,
        _ => match.group(0)!,
      };
    });
    return sanitise(out);
  }

  /// Strips what a filename cannot carry. `:` is a path separator to the
  /// classic Mac OS layer and shows up as `/` in Finder, so it goes too, and
  /// `1/250` shutter speeds would otherwise create a subdirectory.
  static String sanitise(String value) {
    final replaced = value.replaceAll(RegExp(r'[/:\x00\\]'), '_');
    return replaced.replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  }

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');

  /// 2.8 -> "2.8", 35.0 -> "35".
  static String _trim(double value) {
    return value == value.roundToDouble()
        ? value.round().toString()
        : value.toString();
  }
}
