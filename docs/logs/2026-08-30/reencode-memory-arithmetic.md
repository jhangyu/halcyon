# Re-encode transient memory peak — ARITHMETIC ESTIMATE, NOT A MEASUREMENT

**This document is an arithmetic estimate, not a measurement.** It is superseded by the
user's own combined-scenario measurement once the parallel-decode-lane feature lands,
per the "Post-landing" section of `plan-payload-reencode.md`. Treat every number below
as an interim, order-of-magnitude planning input only.

## Inputs and sources

| Input | Value | Source |
|---|---|---|
| 12.5MP fixture dimensions | 4080 × 3056 px | `docs/logs/2026-08-30/reencode-bench.txt:37` (`dims\|width=4080\|height=3056`) |
| RGBA bytes/pixel | 4 (tightly packed, 8-bit) | `/Users/jhangyu/project/ceyx/plugin/lib/src/encode_service.dart:61` (doc comment: "4 bytes/pixel, tightly packed") |
| Retained q80 JPEG size (12.5MP fixture) | 3,219,940 bytes | `docs/logs/2026-08-30/reencode-bench.txt:38` (`encode\|q80\|bytes=3219940\|ms=4102`) |
| Window-res PixelPayload fallback, per item | 22.4 MiB | `/Users/jhangyu/project/Halcyon/lib/services/image_pipeline/photo_payload_cache.dart:19` ("a RAW payload retains window-resolution RGBA (22.4 MiB measured per item...)") |
| rgba isolate-boundary handling | **copied**, not transferred | `/Users/jhangyu/project/ceyx/plugin/lib/src/encode_service.dart:50-51` (class doc: "`rgba` is copied into worker-isolate-owned bytes before crossing the isolate boundary and the returned `Uint8List` is fully Dart-owned — no native pointer survives the call") |
| Native-heap copy of rgba inside worker | `malloc<ffi.Uint8>(rgba.length)` then `.setAll(0, rgba)` | `/Users/jhangyu/project/ceyx/plugin/lib/src/encode_service.dart:126-127` |
| Native output buffer freed after Dart copy | `bindings.free(buffer)` runs only after `Uint8List.fromList(buffer.asTypedList(len))` returns | `/Users/jhangyu/project/ceyx/plugin/lib/src/encode_service.dart:157-161` |
| Caller-side rgba pointer freed | in outer `finally`, after the worker function has already returned its Dart-owned `Uint8List` | `/Users/jhangyu/project/ceyx/plugin/lib/src/encode_service.dart:162-166` |

### Note on the isolate-boundary claim

I read `encode_service.dart` directly (not inferred): the class doc at lines 45-53
explicitly states the copy behavior ("rgba is copied into worker-isolate-owned bytes
before crossing the isolate boundary"), and no `TransferableTypedData`/`.materialize()`
call appears anywhere in the file (`grep -n Transferable` returns nothing) — the
`Isolate.run` closure captures `rgba` by value across isolates, which in the Dart VM's
current implementation performs a full copy of the underlying bytes, not a zero-copy
transfer. This matches the doc comment, so the "copied" assumption is used below.

## Formula

For one lane (one item) mid-encode, before the native rgba copy is freed, the
following byte ranges are simultaneously live in the process (chronological peak
occurs at the moment the Dart JPEG copy exists but the native JPEG output buffer has
not yet been freed, and before the native rgba `malloc` copy is freed — see file:line
citations above for why each survives to that point):

```
peak_per_item = rgba_original        (1×, held by the calling isolate for tier-2 reuse)
              + rgba_isolate_copy    (1×, Isolate.run closure copy, encode_service.dart:50-51)
              + rgba_native_copy     (1×, malloc'd inside worker, encode_service.dart:126-127)
              + jpeg_native_buffer   (1×, native encode output, freed only after the Dart copy exists, :160-161)
              + jpeg_dart_copy       (1×, Uint8List.fromList, encode_service.dart:158)
              + window_res_payload   (1×, 22.4 MiB fallback per item, photo_payload_cache.dart:19)

            = 3 × rgba_bytes + 2 × jpeg_bytes + 22.4 MiB
```

`rgba_bytes = width × height × 4`. All arithmetic below was computed with `python3`
one-liners (not by hand); see the transcript inline.

## 12.5MP fixture (4080 × 3056)

```
$ python3 -c "
w,h=4080,3056
rgba = w*h*4
jpeg = 3219940
window = 22.4*1024*1024
peak_per_item = 3*rgba + 2*jpeg + window
print('rgba_bytes', rgba, rgba/1024/1024, 'MiB')
print('jpeg_bytes', jpeg, jpeg/1024/1024, 'MiB')
print('peak_per_item_MiB', peak_per_item/1024/1024)
for n in (1,2,4):
    print('N=', n, 'total_MiB', n*peak_per_item/1024/1024)
"
rgba_bytes 49873920 47.5634765625 MiB
jpeg_bytes 3219940 3.0707740783691406 MiB
peak_per_item_MiB 171.2319778442383
N= 1 total_MiB 171.2319778442383
N= 2 total_MiB 342.4639556884766
N= 4 total_MiB 684.9279113769531
```

| N (lanes) | Total transient peak (MiB) |
|---|---|
| 1 | 171.23 |
| 2 | 342.46 |
| 4 | 684.93 |

## 24MP model item (pixel terms scaled ×(24/12.5); JPEG size scaled the same way as an approximation — actual JPEG size depends on content entropy, not just pixel count)

```
$ python3 -c "
w,h=4080,3056
rgba12=w*h*4
jpeg12=3219940
window=22.4*1024*1024
scale=24/12.5
rgba24=rgba12*scale
jpeg24=jpeg12*scale
peak24 = 3*rgba24 + 2*jpeg24 + window
print('rgba24_MiB', rgba24/1024/1024)
print('jpeg24_MiB_approx', jpeg24/1024/1024)
print('peak_per_item_24MP_MiB', peak24/1024/1024)
for n in (1,2,4):
    print('N=', n, 'total_24MP_MiB', n*peak24/1024/1024)
"
rgba24_MiB 91.32187499999999
jpeg24_MiB_approx 5.89588623046875
peak_per_item_24MP_MiB 308.1573974609375
N= 1 total_24MP_MiB 308.1573974609375
N= 2 total_24MP_MiB 616.314794921875
N= 4 total_24MP_MiB 1232.62958984375
```

| N (lanes) | Total transient peak (MiB) |
|---|---|
| 1 | 308.16 |
| 2 | 616.31 |
| 4 | 1232.63 |

## Caveats (explicitly acknowledged limitations of this estimate)

1. **JPEG size scaling by pixel-count ratio is a rough proxy.** Compressed JPEG size
   depends on image content/entropy, not purely megapixel count; the 24MP row's JPEG
   term is a linear extrapolation of the single measured 12.5MP q80 sample
   (`reencode-bench.txt:38`), not a second measurement.
2. **This assumes all N lanes hit their peak moment simultaneously**, which is the
   worst case, not necessarily the typical case — actual overlap depends on the
   parallel-decode-lane scheduler's timing once it lands.
3. **Allocator/GC behavior is not modeled.** Dart's GC and the native allocator may
   retain freed memory as unreturned heap pages rather than releasing it to the OS
   immediately; this estimate counts logical byte lifetimes, not RSS.
4. **The window-res PixelPayload term (22.4 MiB) is treated as a fixed per-item
   constant** taken directly from the existing measured figure in
   `photo_payload_cache.dart:19`; it is not itself re-derived or scaled for 24MP here
   because the cited source does not break it out by resolution.
5. Per the mission header: this whole document is arithmetic, not observed RSS/Instruments
   data, and must be replaced by the user's real combined-scenario measurement once the
   parallel-decode-lane feature lands.
