#!/usr/bin/env python3
"""Build scratch datasets for the image-switch latency measurement.

The macOS app is sandboxed (macos/Runner/DebugProfile.entitlements:
com.apple.security.app-sandbox = true) and can only reach user-selected
paths or its own container, so the datasets live inside the app container:
  ~/Library/Containers/com.jhangyu.halcyon/Data/perf/

Copies real camera samples from local_data/photo_samples:
  data_jpg: 30 x 6000x4000 JPEG (from 7 unique originals)
  data_dng: 24 x DNG            (from 12 unique originals)
"""
import glob
import os
import shutil

ROOT = "/Users/jhangyu/project/Halcyon"
CONTAINER = os.path.expanduser(
    "~/Library/Containers/com.jhangyu.halcyon/Data/perf"
)


def build(src_glob, dst_dir, count, prefix, ext):
    src = sorted(glob.glob(src_glob))
    if not src:
        raise SystemExit(f"no sources for {src_glob}")
    os.makedirs(dst_dir, exist_ok=True)
    for f in os.listdir(dst_dir):
        os.remove(os.path.join(dst_dir, f))
    for i in range(count):
        shutil.copyfile(src[i % len(src)], os.path.join(dst_dir, f"{prefix}{i:03d}{ext}"))
    print(f"{dst_dir}: {len(os.listdir(dst_dir))} files from {len(src)} unique sources")


if __name__ == "__main__":
    os.makedirs(CONTAINER, exist_ok=True)
    build(f"{ROOT}/local_data/photo_samples/JPG/*.jpg", f"{CONTAINER}/data_jpg", 30, "p", ".jpg")
    build(f"{ROOT}/local_data/photo_samples/DNG/*.dng", f"{CONTAINER}/data_dng", 24, "r", ".dng")
