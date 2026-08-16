import re, statistics, sys
from collections import defaultdict

def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            parts = line.split('|')
            rows.append(parts)
    return rows

def stats(vals):
    if not vals:
        return None
    vals = sorted(vals)
    n = len(vals)
    med = statistics.median(vals)
    p95 = vals[min(n-1, int(round(0.95*(n-1))))]
    mx = vals[-1]
    return dict(n=n, median=med, p95=p95, max=mx)

def fmt(s, unit='us', div=1000.0):
    if s is None: return "n/a"
    return f"n={s['n']} median={s['median']/div:.2f}ms p95={s['p95']/div:.2f}ms max={s['max']/div:.2f}ms"

base = "tmp/verify/r3/"

# ---- Native DNG ----
dng_native = load(base+"perfnative_dng_r3a.log")
# Build per-file sequential state machine: since events per file arrive causally ordered
# (enter -> bg.start -> read/miss -> dispatch), track open record per file (FIFO, one at a time observed)
from collections import deque
pending = defaultdict(deque)
records = []  # dict per request: file, kind(purpose), enter_ts, read_dur, read_kind, dispatch_ts, nativeTotal

for p in dng_native:
    ts = int(p[1]); ev = p[2]; fname = p[3]
    if ev == 'handler.enter':
        purpose = p[4]
        rec = dict(file=fname, purpose=purpose, enter_ts=ts)
        pending[fname].append(rec)
    elif ev == 'bg.start':
        pass
    elif ev == 'dngPassthrough.read':
        dur = int(p[4].split('=')[1])
        # attach to oldest open record for this file without a read/miss/decoded yet
        for rec in pending[fname]:
            if 'passthrough_kind' not in rec:
                rec['passthrough_kind'] = 'hit'
                rec['passthrough_dur'] = dur
                break
    elif ev == 'dngPassthrough.miss':
        dur = int(p[4].split('=')[1])
        for rec in pending[fname]:
            if 'passthrough_kind' not in rec:
                rec['passthrough_kind'] = 'miss'
                rec['passthrough_dur'] = dur
                break
    elif ev == 'decoded':
        for rec in pending[fname]:
            if 'passthrough_kind' not in rec and rec['purpose']=='sidebarThumbnail':
                rec['passthrough_kind'] = 'sidebar_decode'
                break
    elif ev == 'result.dispatch':
        nativeTotal = int(p[4].split('=')[1])
        # closes the oldest pending record for this file
        if pending[fname]:
            rec = pending[fname].popleft()
            rec['dispatch_ts'] = ts
            rec['nativeTotal'] = nativeTotal
            records.append(rec)

print(f"Total DNG records reconstructed: {len(records)} (expect 68 handler.enter total)")
kinds = defaultdict(int)
for r in records:
    kinds[(r['purpose'], r.get('passthrough_kind'))] += 1
print("Breakdown:", dict(kinds))

# Group A2(a): preview + passthrough hit
groupA = [r['nativeTotal'] for r in records if r['purpose']=='preview' and r.get('passthrough_kind')=='hit']
groupB = [r['nativeTotal'] for r in records if r['purpose']=='preview' and r.get('passthrough_kind')=='miss']
groupC = [r for r in records if r['purpose']=='preview' and r.get('passthrough_kind') not in ('hit','miss')]
sidebarThumb = [r['nativeTotal'] for r in records if r['purpose']=='sidebarThumbnail']

print()
print("== A2 GROUP (a) DNG passthrough HITS (preview, hit) ==")
print(fmt(stats(groupA)))
print("== A2 GROUP (b) DNG passthrough MISSES (preview, miss) ==")
print(fmt(stats(groupB)))
print("== A2 GROUP (c) unassigned preview requests ==", len(groupC))
for r in groupC:
    print("  ", r)
print("== (info) sidebarThumbnail requests (NOT part of A2) ==")
print(fmt(stats(sidebarThumb)))

# also compute passthrough.read duration alone (extraction cost, not end-to-end)
read_durs_hit = [r['passthrough_dur'] for r in records if r['purpose']=='preview' and r.get('passthrough_kind')=='hit']
print("== passthrough.read duration ALONE (extraction cost, hits) ==")
print(fmt(stats(read_durs_hit)))

# Contention analysis: for each hit record, count how many OTHER handler.enter (preview) events
# landed between this record's enter_ts and its dispatch_ts (i.e. queued concurrently)
concurrent_counts = []
all_preview_enters = sorted([(r['enter_ts'], r) for r in records if r['purpose']=='preview'])
for r in records:
    if r['purpose']!='preview' or r.get('passthrough_kind')!='hit':
        continue
    cnt = sum(1 for ts,_ in all_preview_enters if r['enter_ts'] <= ts < r['dispatch_ts'] and ts != r['enter_ts'])
    concurrent_counts.append((r['nativeTotal'], cnt, r['file']))

# split into two bands by nativeTotal threshold (visually: <10ms vs >50ms)
fast = [nt for nt,c,f in concurrent_counts if nt < 10000]
slow = [nt for nt,c,f in concurrent_counts if nt >= 10000]
print()
print("== TWO-BAND CHECK (DNG passthrough hits, nativeTotal) ==")
print(f"fast band (<10ms): n={len(fast)} median={statistics.median(fast)/1000:.3f}ms" if fast else "fast band: none")
print(f"slow band (>=10ms): n={len(slow)} median={statistics.median(slow)/1000:.3f}ms" if slow else "slow band: none")

print()
print("== concurrency evidence for slow band ==")
for nt,c,f in concurrent_counts:
    if nt >= 10000:
        print(f"  file={f} nativeTotal={nt/1000:.2f}ms concurrent_other_preview_enters_before_dispatch={c}")
for nt,c,f in concurrent_counts:
    if nt < 10000:
        print(f"  [fast] file={f} nativeTotal={nt/1000:.2f}ms concurrent_other_preview_enters_before_dispatch={c}")


# ---- JPG native ----
print()
print("############ JPG NATIVE ############")
jpg_native = load(base+"perfnative_jpg_r3a.log")
jpg_dispatch_all = [int(p[4].split('=')[1]) for p in jpg_native if p[2]=='result.dispatch']
print("all result.dispatch (preview+sidebar):", fmt(stats(jpg_dispatch_all)))

pendingj = defaultdict(deque)
recj = []
for p in jpg_native:
    ts=int(p[1]); ev=p[2]; fname=p[3]
    if ev=='handler.enter':
        pendingj[fname].append(dict(file=fname, purpose=p[4], enter_ts=ts))
    elif ev=='result.dispatch':
        nt = int(p[4].split('=')[1])
        if pendingj[fname]:
            r = pendingj[fname].popleft()
            r['nativeTotal']=nt
            recj.append(r)
jpg_preview_native = [r['nativeTotal'] for r in recj if r['purpose']=='preview']
print("JPG preview-only nativeTotal:", fmt(stats(jpg_preview_native)))
