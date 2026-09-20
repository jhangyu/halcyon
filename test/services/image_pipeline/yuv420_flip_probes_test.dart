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
      // FILLED BY T15a (2026-09-20), as this file's header instructed. Exactly
      // the three files the seam gave a reason to name the output format; a
      // fourth appearing is an unreviewed format mention, and it must be
      // argued for here rather than added silently.
      //
      // `frame_bytes.dart` is deliberately NOT listed even though it names the
      // format: its mention is inside a dartdoc, and `_codeOf` strips comment
      // lines before scanning. Listing it would make the roster assert a file
      // the probe can never see — which reads as coverage and is not. The
      // roster is computed from what the probe observes, not from what the
      // author remembers editing.
      const kFormatAwareLibFiles = <String>{
        'lib/services/image_pipeline/decoded_rgba_image_provider.dart',
        'lib/services/image_pipeline/dng_decode_contract.dart',
        'lib/services/image_pipeline/dng_decode_service.dart',
      };

      // THE ONE ARGUED EXEMPTION -- LEAD-RULED 2026-09-20 (mem8 T15a).
      //
      // THE ARGUMENT, recorded so nobody widens this casually. This branch scan
      // is R-N's enforcement, and R-N forbids PLATFORM DIVERGENCE: a per-path
      // or per-platform format branch, where different lanes or different
      // targets end up carrying different pixel layouts. The exempted line is
      // categorically not that. It is the IDENTITY DISPATCH INSIDE the single
      // conversion seam; it executes identically on every platform; and it is
      // precisely what lets R-B (rgba8 stays a workable option -- the pure-Dart
      // TIFF arm and every fake decoder in the suite produce rgba8) coexist
      // with R-N. Exempting it does not contradict the rule's purpose; it names
      // the one place the rule's purpose permits.
      //
      // Removing it would mean either converting rgba8 buffers pointlessly or
      // pushing a conditional out to the three public producers -- which is the
      // per-path branching this rule actually exists to prevent.
      //
      // PINNED TO THE EXACT SITE, not to a pattern. A widened regex would
      // silently absolve the next branch someone adds; this absolves one
      // literal line in one named file, and the assertions below fail if that
      // line stops existing, appears more than once, or appears anywhere else.
      // A second format branch ANYWHERE -- including a second one in this same
      // file -- still goes red. A second entry in this set needs its own
      // written argument and its own ruling.
      //
      // HISTORY worth keeping: the flip's author first measured this with a
      // narrower grep of his own that did not flag the line at all, and
      // reported acceptance item 1 green on that basis -- while this probe's
      // branch assertion had in fact never executed, because the roster
      // assertion above it threw first. This probe, written before the flip by
      // someone with no stake in its outcome, was right to flag it. The answer
      // is the argument, made explicitly, not an instrument tuned until it
      // agreed.
      const kExemptFile =
          'lib/services/image_pipeline/decoded_rgba_image_provider.dart';
      const kExemptLine =
          'if (decoded.format == CeyxOutputFormat.rgba8) return decoded;';
      const kArguedFormatBranchExemptions = <String>{
        '$kExemptFile: $kExemptLine',
      };

      final mentions = <String>[];
      final branches = <String>[];
      var exemptionHits = 0;
      final exemptLineSightings = <String>[];
      for (final file in _libDartFiles()) {
        final code = _codeOf(file);
        if (code.contains('CeyxOutputFormat')) mentions.add(file.path);
        for (final line in code.split('\n')) {
          // Condition 1: the exempted TEXT is tracked wherever it appears, not
          // only where it is allowed to appear, so a copy of it in another file
          // is visible rather than silently tolerated.
          if (line.trim() == kExemptLine) {
            exemptLineSightings.add(file.path);
          }
          if (!line.contains('OutputFormat')) continue;
          // A branch on the format, in any of the three shapes Dart offers.
          if (line.contains('if (') ||
              line.contains('case ') ||
              line.contains('? ')) {
            final entry = '${file.path}: ${line.trim()}';
            if (kArguedFormatBranchExemptions.contains(entry)) {
              exemptionHits++;
              continue;
            }
            branches.add(entry);
          }
        }
      }

      // The exemption is pinned three ways: it must still match something (a
      // dead absolution is worse than none), it must match EXACTLY ONCE, and
      // the line must live only in the file it was argued for.
      expect(
        exemptionHits,
        1,
        reason: exemptionHits == 0
            ? 'the exempted line no longer exists -- delete the exemption '
                  'rather than leaving a dead absolution'
            : 'the exempted line appears $exemptionHits times; the argument '
                  'was made for ONE seam-internal dispatch, and a second copy '
                  'is a new format branch that needs its own ruling',
      );
      expect(
        exemptLineSightings,
        [kExemptFile],
        reason: 'the exempted line must exist exactly once and ONLY in the '
            'file it was argued for; a copy elsewhere is a per-path branch '
            'wearing the exemption\'s clothes',
      );

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

    // TC-1300 -- acceptance item 2, REWRITTEN BY T15a so its stated meaning
    // and its mechanism agree.
    //
    // The pre-flip version counted the three sites that hand a decoded buffer
    // to a pixel consumer and expected T15a to drive that count to ZERO. That
    // assumed the seam would convert AT each site. It does not: each public
    // producer calls `materialiseRgba` ONCE, at entry, and rebinds its local --
    // so all three hand-off sites survive and are CORRECT, because the buffer
    // reaching them is already RGBA. Left as a count, this probe would have
    // gone on passing while asserting a property nobody depends on any more.
    //
    // THE RULE THIS USES INSTEAD, and why it is sharper than "seam appears
    // before first hand-off": each producer takes its unconverted frame as
    // `decodedIn`, and the ONLY legitimate thing any of them may do with that
    // parameter is hand it to the seam. So `decodedIn` must occur EXACTLY ONCE
    // per producer body, inside `materialiseRgba(decodedIn)`. A producer that
    // reads a pixel out of `decodedIn`, passes it onward, or converts late is
    // touching decoder-format bytes and fails here -- no ordering heuristic
    // required.
    //
    // A FIRST DRAFT OF THIS TEST WAS WRONG AND THE MUTATION FOUND IT: it
    // searched `code.substring(producerStart)` -- unbounded to the end of the
    // FILE -- for the literal `decoded.rgba`. `decodedRgbaToImage` names its
    // local `rgba`, not `decoded`, so that needle matched a site in a LATER
    // function and the assertion passed vacuously for that producer. Hence the
    // explicit body bounding below; an unbounded slice is how a probe reads
    // green on a function it never actually examined.
    test(
      'each public producer touches its unconverted frame ONLY to hand it to '
      'materialiseRgba',
      () {
        final code = _codeOf(
          File('lib/services/image_pipeline/decoded_rgba_image_provider.dart'),
        );

        const producers = <String>[
          'Future<ui.Image> decodedRgbaToImage(',
          'Future<PixelPayload> decodedRgbaToPixelPayload(',
          'Future<OrientedFullRes> decodedRgbaToOrientedFullRes(',
        ];

        for (final signature in producers) {
          final start = code.indexOf(signature);
          expect(
            start,
            isNot(-1),
            reason: '$signature vanished or was renamed -- this roster is '
                'stale, and a stale roster is not a passing test',
          );

          // Bound the body at the next top-level declaration, so a later
          // function can never satisfy an assertion about this one.
          var end = code.length;
          for (final marker in <String>['\nFuture<', '\nvoid ', '\nclass ']) {
            final next = code.indexOf(marker, start + signature.length);
            if (next != -1 && next < end) end = next;
          }
          final body = code.substring(start, end);

          expect(
            'materialiseRgba(decodedIn)'.allMatches(body).length,
            1,
            reason: '$signature must hand its unconverted frame to the seam '
                'exactly once',
          );
          expect(
            'decodedIn'.allMatches(body).length,
            2, // the parameter declaration, plus the single seam call
            reason: '$signature references decodedIn somewhere other than the '
                'seam call -- that reference reads bytes still in the '
                "decoder's format",
          );
        }
      },
    );
  });
}
