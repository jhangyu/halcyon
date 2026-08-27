# `tool/decode_worker_bench` — persistent-decode-worker measurement gate

Answers one question before any refactor is attempted: **how much of a RAW
decode's cost is the throwaway isolate's dylib load plus cold GPU pipeline
build?** Spec: `docs/logs/2026-08-28/spec-tier2-bias-and-persistent-decoder.md`
§B.5.

Two variants over the same real samples, in one run:

- `throwaway` — a fresh `DngDecoderService()` and `decodeOnWorker(path)` per
  call. This is exactly what `halcyonDngFullDecoder` does today.
- `warm` — one `DngDecoderService()..initialize()` reused for every call via
  the synchronous same-isolate `decode(path)`. The dylib load and the pipeline
  build are paid once for the whole run, which is the state a persistent
  worker would put the app in.

`warm` is a *proxy* for the persistent worker, not the worker itself: it runs
on the calling isolate, so it also removes the isolate hand-off cost. That
makes it an upper bound on the win. If even the upper bound fails the
threshold, the worker cannot pass it either — which is precisely why the gate
runs before the build.

## Invocation

```bash
bash tool/decode_worker_bench/run_bench.sh <sample-dir> <out-file>
```

The sample directory must exist and hold at least 5 no-preview RAW files.
There is no synthetic fallback. The output file is pre-registered: the
decision rule is written above the numbers before the numbers exist, and each
measured command's `RC=$?` is captured on the following line inside the file.
