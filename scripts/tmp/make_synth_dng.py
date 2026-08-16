#!/usr/bin/env python3
"""Synthesize minimal DNG-shaped TIFF files for extractor tests.

Why these exist: the real samples cannot make the `Compression == 7` and
`PhotometricInterpretation == 6` guards observable. On every real sample the
main image is multi-strip, so the extractor's single-strip condition already
excludes it and removing either guard changes nothing (lead's M2/M3/M4
mutations all survived). These fixtures put a SINGLE-STRIP main image that
fails exactly one guard at a time and is LARGER than the legitimate preview,
so dropping a guard changes which bytes come back.

The files are structure only -- the "JPEG" payloads are recognisable filler,
not decodable images. The extractor never decodes; it walks IFDs and slices
bytes. Tests that need a decodable image use the real samples.

Regenerate with:  python3 scripts/tmp/make_synth_dng.py [outdir]
Default outdir: scripts/tmp/fixtures  (deterministic; safe to delete)

Emitted files:
  synth_guards.dng      4 single-strip candidates, only one passes both
                        guards, and it is the SMALLEST. Expected result:
                        the small legitimate preview.
  synth_two_valid.dng   two fully valid candidates (5600x3733 listed first,
                        6000x4000 second). Expected result: the larger.
  synth_multistrip.dng  a full-size YCbCr JPEG candidate stored in TWO strips
                        plus a valid single-strip 5600x3733 preview. Expected
                        result: the single-strip preview.
  synth_too_small.dng   one valid YCbCr JPEG candidate at 50% of
                        DefaultCropSize. Expected result: nil.
  synth_orient8.dng     valid preview, IFD0 Orientation = 8, payload carries
                        no EXIF of its own. Expected result: payload with an
                        injected EXIF APP1 declaring orientation 8.
  synth_preexisting_exif.dng
                        same, but the payload already declares orientation 3.
                        Expected result: payload returned unchanged.
"""

import os
import struct
import sys

LONG, SHORT = 4, 3


def payload(tag: bytes, n: int) -> bytes:
    """Recognisable filler shaped like a JPEG (SOI ... EOI)."""
    body = (tag * ((n // len(tag)) + 1))[:n]
    return b"\xff\xd8" + body + b"\xff\xd9"


def exif_app1(orientation: int) -> bytes:
    tiff = b"II" + struct.pack("<HI", 42, 8)
    tiff += struct.pack("<H", 1)
    tiff += struct.pack("<HHI", 0x0112, SHORT, 1) + struct.pack("<HH", orientation, 0)
    tiff += struct.pack("<I", 0)
    seg = b"Exif\x00\x00" + tiff
    return b"\xff\xe1" + struct.pack(">H", len(seg) + 2) + seg


def payload_with_exif(tag: bytes, n: int, orientation: int) -> bytes:
    p = payload(tag, n)
    return p[:2] + exif_app1(orientation) + p[2:]


class Builder:
    """Lays out: header | payloads | external value blocks | IFDs."""

    def __init__(self):
        self.payloads = []      # list of bytes
        self.ext = []           # list of bytes (external IFD value blocks)

    def add_payload(self, data):
        self.payloads.append(data)
        return len(self.payloads) - 1

    def build(self, ifd0_tags, sub_tag_sets, sub_offsets_needed=True):
        """ifd0_tags / sub_tag_sets: list of (tag, type, values, payload_index)

        A tag whose values are the string 'STRIP_OFFSET' / 'STRIP_COUNT' is
        resolved from payload_index once the layout is known.
        """
        # 1. payload placement
        pos = 8
        payload_off = []
        for p in self.payloads:
            payload_off.append(pos)
            pos += len(p)
            pos += pos % 2  # keep things even-aligned; harmless

        # 2. reserve external blocks: SubIFDs array + DefaultCropSize, plus a
        # block for any other tag whose values do not fit in the 4-byte value
        # field (multi-strip offset/count arrays).
        n_sub = len(sub_tag_sets)
        sub_array_off = pos
        pos += 4 * n_sub if n_sub else 0
        crop_off = pos
        pos += 8
        ext_off_for = {}
        for ifd_i, tags in enumerate([ifd0_tags] + list(sub_tag_sets)):
            for tag, typ, vals, pidx in tags:
                if tag in (0x014A, 0xC620):
                    continue
                count = 2 if isinstance(vals, str) and vals.endswith("_SPLIT") \
                    else (1 if isinstance(vals, str) else len(vals))
                size = (4 if typ == LONG else 2) * count
                if size > 4:
                    ext_off_for[(ifd_i, tag)] = pos
                    pos += size

        # 3. IFD placement
        ifd0_off = pos
        pos += 2 + 12 * len(ifd0_tags) + 4
        sub_offs = []
        for tags in sub_tag_sets:
            sub_offs.append(pos)
            pos += 2 + 12 * len(tags) + 4

        total = pos
        buf = bytearray(total)
        buf[0:8] = b"II" + struct.pack("<HI", 42, ifd0_off)
        for p, off in zip(self.payloads, payload_off):
            buf[off:off + len(p)] = p
        for i, o in enumerate(sub_offs):
            buf[sub_array_off + 4 * i: sub_array_off + 4 * i + 4] = struct.pack("<I", o)
        buf[crop_off:crop_off + 8] = struct.pack("<II", 6000, 4000)

        def write_ifd(off, tags, ifd_i):
            struct.pack_into("<H", buf, off, len(tags))
            p = off + 2
            for tag, typ, vals, pidx in tags:
                if vals == "STRIP_OFFSET":
                    vals = [payload_off[pidx]]
                elif vals == "STRIP_COUNT":
                    vals = [len(self.payloads[pidx])]
                elif vals == "STRIP_OFFSET_SPLIT":
                    half = len(self.payloads[pidx]) // 2
                    vals = [payload_off[pidx], payload_off[pidx] + half]
                elif vals == "STRIP_COUNT_SPLIT":
                    n = len(self.payloads[pidx])
                    vals = [n // 2, n - n // 2]
                elif vals == "SUBIFDS":
                    vals = sub_offs
                elif vals == "CROP":
                    vals = [6000, 4000]
                count = len(vals)
                struct.pack_into("<HHI", buf, p, tag, typ, count)
                size = 4 if typ == LONG else 2
                if count * size <= 4:
                    blob = b"".join(
                        struct.pack("<I" if typ == LONG else "<H", v) for v in vals)
                    blob = blob.ljust(4, b"\x00")
                    buf[p + 8:p + 12] = blob
                else:
                    if tag == 0x014A:
                        ext_off = sub_array_off
                    elif tag == 0xC620:
                        ext_off = crop_off
                    else:
                        ext_off = ext_off_for[(ifd_i, tag)]
                        blob = b"".join(
                            struct.pack("<I" if typ == LONG else "<H", v)
                            for v in vals)
                        buf[ext_off:ext_off + len(blob)] = blob
                    struct.pack_into("<I", buf, p + 8, ext_off)
                p += 12
            struct.pack_into("<I", buf, p, 0)

        write_ifd(ifd0_off, ifd0_tags, 0)
        for i, (off, tags) in enumerate(zip(sub_offs, sub_tag_sets)):
            write_ifd(off, tags, i + 1)
        return bytes(buf)


def image_tags(w, h, compression, photometric, pidx, extra=()):
    tags = [
        (0x0100, LONG, [w], None),
        (0x0101, LONG, [h], None),
        (0x0103, SHORT, [compression], None),
        (0x0106, SHORT, [photometric], None),
        (0x0111, LONG, "STRIP_OFFSET", pidx),
        (0x0117, LONG, "STRIP_COUNT", pidx),
    ]
    tags.extend(extra)
    return sorted(tags, key=lambda t: t[0])


JPEG, LOSSY_JPEG = 7, 34892
YCBCR, LINEAR_RAW, CFA = 6, 34892, 32803


def build_guards():
    """Four single-strip candidates; only one passes both guards, and it is
    the smallest. Dropping either guard changes the answer."""
    b = Builder()
    p_main = b.add_payload(payload(b"MAIN", 400))          # fails both guards
    p_lin = b.add_payload(payload(b"LINR", 300))           # fails photometric
    p_lossy = b.add_payload(payload(b"LOSY", 200))         # fails compression
    p_good = b.add_payload(payload(b"GOOD", 100))          # passes, smallest
    ifd0 = image_tags(6000, 4000, LOSSY_JPEG, CFA, p_main, extra=[
        (0x0112, SHORT, [1], None),
        (0x014A, LONG, "SUBIFDS", None),
        (0xC620, LONG, "CROP", None),
    ])
    subs = [
        image_tags(6000, 4000, JPEG, LINEAR_RAW, p_lin),
        image_tags(6000, 4000, LOSSY_JPEG, YCBCR, p_lossy),
        image_tags(5600, 3733, JPEG, YCBCR, p_good),   # 93% of 6000 -> qualifies
    ]
    return b.build(ifd0, subs), {
        "main": payload(b"MAIN", 400),
        "linear_raw": payload(b"LINR", 300),
        "lossy": payload(b"LOSY", 200),
        "good": payload(b"GOOD", 100),
    }


def build_two_valid():
    """Two candidates that both pass every guard; the larger must win.

    Without this, the max-area comparison is never exercised: every real
    sample has exactly one qualifying candidate.
    """
    b = Builder()
    p_main = b.add_payload(payload(b"MAIN", 400))
    p_big = b.add_payload(payload(b"BIGG", 300))
    p_small = b.add_payload(payload(b"SMLR", 100))
    ifd0 = image_tags(6000, 4000, LOSSY_JPEG, CFA, p_main, extra=[
        (0x0112, SHORT, [1], None),
        (0x014A, LONG, "SUBIFDS", None),
        (0xC620, LONG, "CROP", None),
    ])
    subs = [
        image_tags(5600, 3733, JPEG, YCBCR, p_small),   # 93%, listed first
        image_tags(6000, 4000, JPEG, YCBCR, p_big),     # 100%, must win
    ]
    return b.build(ifd0, subs), {}


def build_multistrip():
    """A multi-strip candidate that passes every other test and is larger.

    Real DNGs never exercise the single-strip condition: their multi-strip main
    image is already excluded by the format guards. Here the multi-strip image
    is a YCbCr JPEG at full crop size, so only the single-strip condition keeps
    the extractor from returning a truncated first strip.
    """
    b = Builder()
    p_multi = b.add_payload(payload(b"MLTI", 400))
    p_good = b.add_payload(payload(b"GOOD", 100))
    ifd0 = image_tags(6000, 4000, LOSSY_JPEG, CFA, p_multi, extra=[
        (0x0112, SHORT, [1], None),
        (0x014A, LONG, "SUBIFDS", None),
        (0xC620, LONG, "CROP", None),
    ])
    multi = [
        (0x0100, LONG, [6000], None),
        (0x0101, LONG, [4000], None),
        (0x0103, SHORT, [JPEG], None),
        (0x0106, SHORT, [YCBCR], None),
        (0x0111, LONG, "STRIP_OFFSET_SPLIT", p_multi),
        (0x0117, LONG, "STRIP_COUNT_SPLIT", p_multi),
    ]
    subs = [
        sorted(multi, key=lambda t: t[0]),
        image_tags(5600, 3733, JPEG, YCBCR, p_good),
    ]
    return b.build(ifd0, subs), {}


def build_too_small():
    b = Builder()
    p_main = b.add_payload(payload(b"MAIN", 400))
    p_small = b.add_payload(payload(b"SMAL", 100))
    ifd0 = image_tags(6000, 4000, LOSSY_JPEG, CFA, p_main, extra=[
        (0x0112, SHORT, [1], None),
        (0x014A, LONG, "SUBIFDS", None),
        (0xC620, LONG, "CROP", None),
    ])
    subs = [image_tags(3000, 2000, JPEG, YCBCR, p_small)]  # 50% -> below 0.90
    return b.build(ifd0, subs), {}


def build_orient(orientation, preexisting=None):
    b = Builder()
    p_main = b.add_payload(payload(b"MAIN", 400))
    body = payload(b"GOOD", 100) if preexisting is None \
        else payload_with_exif(b"GOOD", 100, preexisting)
    p_good = b.add_payload(body)
    ifd0 = image_tags(6000, 4000, LOSSY_JPEG, CFA, p_main, extra=[
        (0x0112, SHORT, [orientation], None),
        (0x014A, LONG, "SUBIFDS", None),
        (0xC620, LONG, "CROP", None),
    ])
    subs = [image_tags(5600, 3733, JPEG, YCBCR, p_good)]
    return b.build(ifd0, subs), {"good": body}


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "fixtures")
    os.makedirs(outdir, exist_ok=True)
    files = {
        "synth_guards.dng": build_guards()[0],
        "synth_two_valid.dng": build_two_valid()[0],
        "synth_multistrip.dng": build_multistrip()[0],
        "synth_too_small.dng": build_too_small()[0],
        "synth_orient8.dng": build_orient(8)[0],
        "synth_preexisting_exif.dng": build_orient(8, preexisting=3)[0],
    }
    for name, data in files.items():
        path = os.path.join(outdir, name)
        with open(path, "wb") as f:
            f.write(data)
        print(f"wrote {path} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
