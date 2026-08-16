import statistics as st
from collections import defaultdict, deque

def pct(xs,p):
    xs=sorted(xs)
    if len(xs)==1: return xs[0]
    k=(len(xs)-1)*p; lo,hi=int(k),min(int(k)+1,len(xs)-1)
    return xs[lo]+(xs[hi]-xs[lo])*(k-lo)

def fmt(vals):
    if not vals: return "n=0"
    return f"n={len(vals)} median={st.median(vals)/1000:.3f}ms p95={pct(vals,0.95)/1000:.3f}ms max={max(vals)/1000:.3f}ms"

def analyze(path, label):
    rows=[]
    with open(path) as f:
        for line in f:
            rows.append(line.strip().split('|'))
    pending=defaultdict(deque)
    records=[]
    for p in rows:
        ts=int(p[1]); ev=p[2]; fname=p[3]
        if ev=='handler.enter':
            pending[fname].append(dict(file=fname,purpose=p[4],enter_ts=ts))
        elif ev in ('jpegPassthrough.read','dngPassthrough.read'):
            dur=int(p[5].split('=')[1])
            for r in pending[fname]:
                if 'kind' not in r:
                    r['kind']='passthrough_hit'; r['read_dur']=dur; break
        elif ev in ('jpegPassthrough.miss','dngPassthrough.miss'):
            dur=int(p[4].split('=')[1]) if len(p)>4 and 'dur=' in p[4] else None
            for r in pending[fname]:
                if 'kind' not in r:
                    r['kind']='passthrough_miss'; break
        elif ev=='decoded':
            for r in pending[fname]:
                if 'kind' not in r:
                    r['kind']='decode_reencode_path'; break
        elif ev=='result.dispatch':
            nt=int(p[4].split('=')[1])
            if pending[fname]:
                r=pending[fname].popleft(); r['nativeTotal']=nt; records.append(r)

    print(f"=== {label} ===")
    print(f"records reconstructed: {len(records)}")
    for purpose in ['preview','sidebarThumbnail']:
        for kind in ['passthrough_hit','passthrough_miss','decode_reencode_path']:
            vals=[r['nativeTotal'] for r in records if r['purpose']==purpose and r.get('kind')==kind]
            if vals:
                print(f"  purpose={purpose} kind={kind}: {fmt(vals)}")
    unassigned = [r for r in records if 'kind' not in r]
    print(f"  unassigned: n={len(unassigned)}")

analyze("tmp/verify/r3/r2_recompute/perfnative_jpg_r2b.log", "JPG r2b (baseline source for 0.4/2.2/2.6)")
analyze("tmp/verify/r3/r2_recompute/perfnative_dng_r2b.log", "DNG r2b (baseline source for 109.8/120.9/221.5)")
