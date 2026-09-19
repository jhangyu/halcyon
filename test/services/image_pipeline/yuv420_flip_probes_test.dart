// T15a-pre (Task #14, 2026-09-20): the two grep-class acceptance probes for the
// yuv420 flip, placed BEFORE the flip so they are in the tree when it lands.
//
// T15a.5 acceptance items 1 and 2 are "grep-class, output stored then matched":
//   1. zero output-format conditionals in lib/;
//   2. no function returns `decoded.rgba` without passing through the
//      `materialiseRgba` seam — covering BOTH short-circuits, which is the
//      defect that nearly shipped in the v2 draft (a seam at `_imageFromPixels`
//      alone silently emits yuv420 bytes from the two arms that bypass it).
//
// WHY THESE PASS TODAY, AND WHY THAT IS NOT A FALSE GREEN. The flip has not
// landed (T15a is blocked on T14's binding), so "grep finds no format
// conditional" is trivially true and would stay true if the whole campaign were
// abandoned. A probe whose green means nothing is the assertion-never-seen-red
// defect. So neither of these is written as "grep finds nothing": each pins a
// ROSTER — the exact set of sites that exist today — and therefore fails on the
// thing that can actually go wrong BEFORE the flip, namely a new unconverted
// hand-off or a new format mention appearing while nobody is looking.
//
// WHAT T15a MUST DO TO THESE, stated here because a probe that the flip silently
// invalidates is worse than no probe:
//   * `kFormatAwareLibFiles` goes from empty to exactly the seam's files;
//   * `expectedVerbatimHandOffs` goes to ZERO — every site listed below routes
//     through `materialiseRgba` instead — and the counts below are replaced by an
//     assertion that no site hands `decoded.rgba` to a pixel consumer at all.
// Until then these are staged as roster pins, not as the flip's own tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Code lines only: a doc comment that MENTIONS a format is prose, not a
/// conditional, and this project has been bitten before by greps that could not
/// tell the two apart (TC-817 uses the same stripping for the same reason).
String _codeOf(File f) => f
    .readAsLinesSync()
    .where((line) {
      final t = line.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

Iterable<File> _libDartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  group('yuv420 flip acceptance probes (T15a.5 items 1-2)', () {
    // TC-1299 -- acceptance item 1, as a roster pin.
    //
    // The design rule is "no format branch anywhere" (T15a step 2): uniformity
    // IS the design, and one exemption reintroduces the mixed-format lane
    // problem. Two assertions, because they fail on different mistakes: the
    // roster catches a format mention appearing in a file that has no business
    // holding one, and the branch scan catches a conditional inside a file that
    // legitimately mentions the format.
    test('no output-format conditional exists in lib/', () {
      // EMPTY TODAY, and T15a replaces it with the seam's files. An empty
      // allowlist is meaningful here precisely because the flip has not landed:
      // any mention appearing before T15a is unreviewed.
      const kFormatAwareLibFiles = <String>{};

      final mentions = <String>[];
      final branches = <String>[];
      for (final file in _libDartFiles()) {
        final code = _codeOf(file);
        if (code.contains('CeyxOutputFormat')) mentions.add(file.path);
        for (final line in code.split('\n')) {
          if (!line.contains('OutputFormat')) continue;
          // A branch on the format, in any of the three shapes Dart offers.
          if (line.contains('if (') ||
              line.contains('case ') ||
              line.contains('? ')) {
            branches.add('${file.path}: ${line.trim()}');
          }
        }
      }

      expect(
        mentions.toSet(),
        kFormatAwareLibFiles,
        reason: 'roster pin: every lib/ file that names the output format must '
            'be a reviewed one. Update the allowlist in T15a, not here.',
      );
      expect(
        branches,
        isEmpty,
        reason: 'T15a step 2: no format branch anywhere. One exemption '
            'reintroduces the mixed-format lane problem R-D made moot.',
      );
    });

    // TC-1300 -- acceptance item 2, as a roster pin over the THREE sites that
    // hand a decoded buffer to a pixel consumer today. Line numbers are
    // deliberately not asserted (they drift on unrelated edits); the source
    // shapes are.
    test(
      'the sites handing decoded.rgba to a pixel consumer are exactly the '
      'three known ones',
      () {
        final code = _codeOf(
          File('lib/services/image_pipeline/decoded_rgba_image_provider.dart'),
        );
        int countOf(String needle) =>
            needle.allMatches(code).length; // occurrences, not lines

        // Site 1: `_imageFromPixels`, the single conversion point all three
        // public producers are SUPPOSED to funnel through.
        expect(
          countOf('    decoded.rgba,\n'),
          1,
          reason: 'the decodeImageFromPixels hand-off',
        );
        // Site 2: short-circuit 1, which T6/SR-2 already turned from an alias
        // into an owned copy -- so T15a's conversion lands where the copy
        // already is, at no extra allocation.
        expect(
          countOf('Uint8List.fromList(decoded.rgba)'),
          1,
          reason: 'short-circuit 1 (the T6 copy)',
        );
        // Site 3: short-circuit 2, the genuinely new conversion site, still
        // handing back the decoder's own buffer verbatim.
        expect(
          countOf('rgba: decoded.rgba,'),
          1,
          reason: 'short-circuit 2 (verbatim) -- the arm a seam placed at '
              '_imageFromPixels alone would silently miss',
        );

        // The roster's point: a FOURTH such site appearing before the flip is
        // one more place T15a has to find, and the plan's sweep was taken on
        // 2026-09-19. This is what makes the probe fail on something real while
        // the flip is still blocked.
        const expectedVerbatimHandOffs = 3;
        expect(
          countOf('    decoded.rgba,\n') +
              countOf('Uint8List.fromList(decoded.rgba)') +
              countOf('rgba: decoded.rgba,'),
          expectedVerbatimHandOffs,
          reason: 'T15a must route ALL of these through materialiseRgba and '
              'drive this count to zero; a new one appearing first means the '
              'seam has one more arm than the plan enumerated.',
        );
      },
    );
  });
}
