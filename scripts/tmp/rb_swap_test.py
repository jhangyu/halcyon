#!/usr/bin/env python3
"""Decisive check for the orange cast: is it an R<->B channel swap?
Blue sky rendered orange is the signature. Swap the channels; if the sky
goes blue and skin/snow look neutral, the decoder is emitting BGR where
Halcyon expects RGB (or the CFA red/blue phase is inverted).
Also prints mean channel values, which distinguishes a swap from a
white-balance problem: a swap exchanges the R and B means exactly.
"""
import sys, pathlib
from PIL import Image, ImageStat

src = pathlib.Path(sys.argv[1])
out = src.with_name(src.stem + "_rbswap.jpg")

im = Image.open(src).convert("RGB")
r, g, b = im.split()
stat = ImageStat.Stat(im)
print(f"original  mean R={stat.mean[0]:.1f} G={stat.mean[1]:.1f} B={stat.mean[2]:.1f}")

sw = Image.merge("RGB", (b, g, r))
sstat = ImageStat.Stat(sw)
print(f"rb-swapped mean R={sstat.mean[0]:.1f} G={sstat.mean[1]:.1f} B={sstat.mean[2]:.1f}")

# Sample the top strip, which is sky in this frame — the most diagnostic region.
w, h = im.size
sky = im.crop((0, 0, w, h // 8))
sky_sw = sw.crop((0, 0, w, h // 8))
print(f"sky strip original  R={ImageStat.Stat(sky).mean[0]:.1f} G={ImageStat.Stat(sky).mean[1]:.1f} B={ImageStat.Stat(sky).mean[2]:.1f}")
print(f"sky strip rb-swap   R={ImageStat.Stat(sky_sw).mean[0]:.1f} G={ImageStat.Stat(sky_sw).mean[1]:.1f} B={ImageStat.Stat(sky_sw).mean[2]:.1f}")

sw.save(out, quality=88)
print(f"wrote {out}")
