import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/dart_image_loader.dart';
import 'package:halcyon_flutter/services/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/dng_embedded_jpeg_extractor.dart';
import 'package:halcyon_flutter/services/photo_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sampleDir = Directory('local_data/photo_samples/DNG');

  late int channelCalls;
  setUp(() {
    channelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('halcyon/thumbnail'),
            (call) async {
      channelCalls++;
      throw MissingPluginException(); // the Android/Linux condition (AC 5)
    });
  });

  Future<File?> sample({required bool withPreview}) async {
    for (final f in sampleDir.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.dng')) continue;
      final full = await DngEmbeddedJpegExtractor
          .extractFullSizeEmbeddedJpegFromFile(f.path);
      if ((full != null) == withPreview) return f;
    }
    return null;
  }

  test('AC4: preview DNG produces bytes with ZERO channel-seam calls',
      () async {
    final f = await sample(withPreview: true);
    expect(f, isNotNull);
    final source = PhotoSource(loader: dartImageLoad);
    final outcome = await source.load(f!.path, longEdge: 2800);
    expect(outcome.payload, isNotNull);
    expect(channelCalls, 0);
  });

  test('AC5: with the channel throwing MissingPluginException, cheap AND'
      ' no-preview DNGs still behave', () async {
    final cheap = await sample(withPreview: true);
    final dear = await sample(withPreview: false);
    expect(cheap, isNotNull);
    expect(dear, isNotNull);
    // Fake decoder: 1x1 RGBA pixel, the m3_amend3 pattern.
    Future<DecodedRgba> fakeDecoder(String path) async => DecodedRgba(
          rgba: Uint8List.fromList([0, 0, 0, 255]),
          width: 1,
          height: 1,
        );
    final source = PhotoSource(loader: dartImageLoad, dngDecoder: fakeDecoder);
    final cheapOut = await source.load(cheap!.path, longEdge: 2800);
    expect(cheapOut.payload, isNotNull);
    expect(cheapOut.observedCost, SourceCost.cheap);
    final dearOut = await source.load(dear!.path, longEdge: 2800);
    expect(dearOut.payload, isNotNull); // decoded via the fake, no channel
    expect(dearOut.observedCost, SourceCost.expensive);
  });
}
