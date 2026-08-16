#!/bin/bash
# Extract every embedded preview-ish JPEG from a DNG and report dimensions + byte size.
set -u
f="$1"
out=/tmp/dngprobe
rm -rf "$out"; mkdir -p "$out"
for tag in PreviewImage JpgFromRaw OtherImage ThumbnailImage; do
  exiftool -b -"$tag" "$f" > "$out/$tag.jpg" 2>/dev/null
  sz=$(stat -f%z "$out/$tag.jpg")
  if [ "$sz" -gt 1000 ]; then
    dim=$(sips -g pixelWidth -g pixelHeight "$out/$tag.jpg" 2>/dev/null | tr -d ' \n' | sed 's/.*pixelWidth:/W=/;s/pixelHeight:/ H=/')
    echo "$tag: bytes=$sz $dim"
  else
    echo "$tag: absent (bytes=$sz)"
  fi
done
echo "--- all SubIFD JPEG interchange offsets:"
exiftool -a -G1 -s -PreviewImageStart -PreviewImageLength -ThumbnailOffset -ThumbnailLength "$f"
