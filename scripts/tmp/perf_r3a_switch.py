import statistics as st
from collections import defaultdict

def pct(xs, p):
    xs = sorted(xs)
    if len(xs)==1: return xs[0]
    k=(len(xs)-1)*p
    lo,hi=int(k),min(int(k)+1,len(xs)-1)
    return xs[lo]+(xs[hi]-xs[lo])*(k-lo)

def load(path):
    evs=[]
    with open(path) as f:
        for line in f:
            p=line.strip().split('|')
            if len(p)<3: continue
            evs.append((int(p[1]), p[2], p[3:]))
    return evs

def analyze(path, name):
    evs = load(path)
    switch_begins = [(ts,f[0],int(f[1]),f[2]) for ts,n,f in evs if n=='switch.begin']
    switch_ends = {}
    for ts,n,f in evs:
        if n=='switch.end':
            switch_ends[(f[0], int(f[1]))] = (ts, int(f[3].split('=')[1]))
    decoded = defaultdict(list)  # id -> [(ts, sync, dur)]
    for ts,n,f in evs:
        if n=='image.decoded':
            decoded[f[0]].append((ts, f[2]=='sync=true', int(f[3].split('=')[1])))
    for v in decoded.values(): v.sort()

    print(f"=== {name} ===")
    for label in ['paced','rapid']:
        rows = [(ts0,idx,ident) for ts0,l,idx,ident in switch_begins if l==label]
        hit_switchdur=[]
        hit_decodedur=[]
        miss=[]
        unresolved=0
        for ts0, idx, ident in rows:
            # first image.decoded event for ident at/after ts0
            match = None
            for ts,sync,dur in decoded.get(ident, []):
                if ts >= ts0:
                    match = (ts,sync,dur)
                    break
            se = switch_ends.get((label, idx))
            if match is None:
                unresolved += 1
                continue
            ts,sync,dur = match
            if sync:
                if se: hit_switchdur.append(se[1])
                hit_decodedur.append(dur)
            else:
                if se: miss.append(se[1])
        def line(nm, vals, div=1000):
            if not vals:
                print(f"  {nm}: n=0"); return
            print(f"  {nm}: n={len(vals)} median={st.median(vals)/div:.3f}ms p95={pct(vals,0.95)/div:.3f}ms max={max(vals)/div:.3f}ms")
        print(f" -- pass={label} (n_switches={len(rows)}, unresolved={unresolved})")
        line("tier1-HIT switch.end dur (switch.begin->settle)", hit_switchdur)
        line("tier1-HIT image.decoded dur (resolve-call latency)", hit_decodedur)
        line("tier1-MISS(sync=false) switch.end dur", miss)

analyze("tmp/verify/r3/perf_dng_r3a.log", "DNG")
analyze("tmp/verify/r3/perf_jpg_r3a.log", "JPG")
