#!/usr/bin/env python3
"""Settle the channel order straight from the decoder's raw buffer, with no
intermediate conversion step in the way.

Reads the raw 4-byte-per-pixel dump the decoder produced, interprets it BOTH
ways, and reports the sky-strip means. Daylight sky must be blue-dominant;
whichever interpretation puts the large value in blue is the true order.
"""
import pathlib
from PIL import Image

RAW = pathlib.Path("/Users/jhangyu/project/flutter_dng_decoder/dng_processor/native/scripts/tmp/vivo_out.rgba")
OUT = pathlib.Path("/Users/jhangyu/project/Halcyon/tmp/verify/r3/decoder_probe")
W, H = 4080, 3056

data = RAW.read_bytes()
expected = W * H * 4
print(f"raw bytes={len(data)} expected={expected} match={len(data)==expected}")
assert len(data) == expected, "buffer size mismatch — wrong dimensions assumed"

def sky_mean(order):
    """Mean of (R,G,B) over the top 1/8 of the frame, given a byte order.

    `order` maps byte position 0..2 -> channel index (0=R, 1=G, 2=B).
    Byte 3 is alpha and is deliberately NOT accumulated — folding it in
    inflates whichever channel it lands on and produces impossible means.
    """
    rows = H // 8
    acc = [0, 0, 0]
    n = 0
    # stride through the strip; sample every 37th pixel to stay fast and unbiased
    for i in range(0, rows * W, 37):
        o = i * 4
        px = data[o:o + 3]
        for k, ch in enumerate(order):
            acc[ch] += px[k]
        n += 1
    return [a / n for a in acc], n

as_rgba, n = sky_mean([0, 1, 2])   # byte0->R, byte1->G, byte2->B
as_bgra, _ = sky_mean([2, 1, 0])   # byte0->B, byte1->G, byte2->R
print(f"sky samples n={n}")
print(f"interpreted as RGBA : R={as_rgba[0]:.1f} G={as_rgba[1]:.1f} B={as_rgba[2]:.1f}")
print(f"interpreted as BGRA : R={as_bgra[0]:.1f} G={as_bgra[1]:.1f} B={as_bgra[2]:.1f}")

verdict = "BGRA" if as_bgra[2] > as_bgra[0] else "RGBA"
print(f"VERDICT: daylight sky is blue-dominant, so the buffer is {verdict}-ordered")

im = Image.frombytes("RGBA", (W, H), data).convert("RGB")
im.resize((W // 8, H // 8)).save(OUT / "raw_as_rgba.jpg", quality=88)
r, g, b = im.split()
Image.merge("RGB", (b, g, r)).resize((W // 8, H // 8)).save(OUT / "raw_as_bgra.jpg", quality=88)
print(f"wrote {OUT}/raw_as_rgba.jpg and raw_as_bgra.jpg")
