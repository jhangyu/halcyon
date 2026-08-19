import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/rename_rule.dart';

const _meta = ExifMetadata(
  captureDate: null,
  camera: 'ILCE-7M4',
  lens: 'FE 24-70mm F2.8 GM',
  make: 'SONY',
  artist: 'Jhang Yu',
  aperture: 2.8,
  focalLength: 35,
  iso: 400,
  shutter: '1/250',
  gpsImgDirection: 127.4,
);

void main() {
  final captured = DateTime(2026, 4, 7, 9, 3, 5);
  final mtime = DateTime(2020, 1, 2, 3, 4, 5);

  ExifMetadata metaWithDate(DateTime? d) => ExifMetadata(
    captureDate: d,
    camera: _meta.camera,
    lens: _meta.lens,
    make: _meta.make,
    artist: _meta.artist,
    aperture: _meta.aperture,
    focalLength: _meta.focalLength,
    iso: _meta.iso,
    shutter: _meta.shutter,
    gpsImgDirection: _meta.gpsImgDirection,
  );

  // Sentinel lets us distinguish "meta not passed" (default to synthetic
  // metadata below) from "meta explicitly passed as null" (real null,
  // exercising RenameRule's own fallback to fileModified) — both collapse to
  // `null` under a plain `ExifMetadata?` parameter.
  const unsetMeta = Object();

  String render(String template, {Object? meta = unsetMeta, int seq = 1}) {
    final resolvedMeta = identical(meta, unsetMeta)
        ? metaWithDate(captured)
        : meta as ExifMetadata?;
    return RenameRule(template).render(
      meta: resolvedMeta,
      fileModified: mtime,
      originalBase: 'DSC_0431',
      seq: seq,
    );
  }

  test('TC-024 default template renders zero-padded date and time', () {
    expect(
      render(RenameRule.kDefaultTemplate),
      '2026-04-07-09-03-05',
    );
  });

  test('TC-025 {seq} defaults to one digit, {seq:3} zero-pads to three', () {
    expect(render('{YYYY}_{seq}', seq: 7), '2026_7');
    expect(render('{YYYY}_{seq:3}', seq: 7), '2026_007');
    expect(render('{YYYY}_{seq:3}', seq: 1234), '2026_1234');
  });

  test('TC-026 missing capture date falls back to file mtime', () {
    expect(
      render(RenameRule.kDefaultTemplate, meta: metaWithDate(null)),
      '2020-01-02-03-04-05',
    );
    expect(
      render(RenameRule.kDefaultTemplate, meta: null),
      '2020-01-02-03-04-05',
    );
  });

  test('TC-027 non-date variables render, missing ones render empty', () {
    expect(render('{camera}'), 'ILCE-7M4');
    expect(render('{lens}'), 'FE 24-70mm F2.8 GM');
    expect(render('{make}_{artist}'), 'SONY_Jhang Yu');
    expect(render('{f}'), 'f2.8');
    expect(render('{focal}'), '35mm');
    expect(render('{iso}'), 'ISO400');
    expect(render('{shutter}'), '1_250');
    expect(render('{direction}'), '127');
    expect(render('{orig}'), 'DSC_0431');
    expect(
      render('x{camera}y', meta: const ExifMetadata(captureDate: null)),
      'xy',
    );
  });

  test('TC-028 path-hostile characters are replaced, edges trimmed', () {
    expect(render(' a/b:c '), 'a_b_c');
    expect(render('..name..'), 'name');
  });

  test('TC-029 unknown variable and empty result are reported as errors', () {
    expect(const RenameRule('{fstop}').error, isNotNull);
    expect(const RenameRule('').error, isNotNull);
    expect(const RenameRule('{YYYY}-{seq:2}').error, isNull);
    expect(RenameRule(RenameRule.kDefaultTemplate).error, isNull);
  });

  test('TC-030 every preset is a valid template and the default is first', () {
    expect(RenameRule.presets.first.template, RenameRule.kDefaultTemplate);
    for (final preset in RenameRule.presets) {
      expect(RenameRule(preset.template).error, isNull, reason: preset.label);
    }
  });
}
