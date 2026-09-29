#!/usr/bin/env python3
"""Right-size Slurm requests from what past jobs actually used.

Reads `sacct -P --noheader --units=M -o JobID,JobName,State,ElapsedRaw,
TimelimitRaw,MaxRSS,ReqMem,AllocCPUS` on stdin (della.sh rightsize supplies it)
and, per job name, compares requested walltime / memory with the peak actually
used by COMPLETED tasks.  Recommends 1.5x the observed peak (the safety factor),
rounded up, and never recommends shrinking a limit that some task ran into
(TIMEOUT / OUT_OF_MEMORY) -- those need the limit RAISED.
"""
import math
import sys
from collections import defaultdict

import argparse, re
_ap = argparse.ArgumentParser()
_ap.add_argument("factor", nargs="?", type=float, default=1.5)
_ap.add_argument("--by", choices=["config", "name"], default="config",
                 help="config: group tasks that ran the same configuration (log header "
                      "minus seed); name: lump all tasks with the same job name")
_ap.add_argument("--match", help="regex: keep only configurations matching it")
_a = _ap.parse_args()
FACTOR, BY, MATCH = _a.factor, _a.by, (re.compile(_a.match) if _a.match else None)
MIN_MIN, MIN_GB = 10, 2          # floors: 10 min walltime, 2 GB memory
# Array tasks with --time <= 61 min land in the gpu-test QOS, whose tiny submit
# limit rejects them (QOSMaxSubmitJobPerUserLimit); keep arrays in gpu-short.
ARRAY_MIN = 62


def mb(x):
    """sacct value like '3164.57M' / '32768M' / '32G' / '8Gc' -> MB (float)."""
    x = (x or "").strip().rstrip("cn")        # old per-cpu/per-node suffixes
    if not x:
        return None
    mult = {"K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 ** 2}.get(x[-1].upper())
    try:
        return float(x[:-1]) * mult if mult else float(x) / 2 ** 20
    except ValueError:
        return None


def hhmm(minutes):
    minutes = int(math.ceil(minutes))
    return f"{minutes // 60:02d}:{minutes % 60:02d}:00"


# base job id (e.g. 13348529_7) -> record; steps (.batch/.extern) carry MaxRSS
jobs = {}
rss = defaultdict(float)
for line in sys.stdin:
    f = line.rstrip("\n").split("|")
    if len(f) < 8:
        continue
    jid, name, state, el, tl, maxrss, reqmem, cpus = f[:8]
    sig = f[8] if len(f) > 8 else ""
    base = jid.split(".")[0]
    if "." in jid:                                # a step: collect peak RSS
        v = mb(maxrss)
        if v:
            rss[base] = max(rss[base], v)
        continue
    jobs[base] = dict(array="_" in base, name=name, sig=sig, state=state.split()[0],
                      el=int(el) if el.isdigit() else None,
                      tl=int(tl) if tl.isdigit() else None,
                      req=mb(reqmem), cpus=int(cpus) if cpus.isdigit() else 1)

if not jobs:
    sys.exit("rightsize: no jobs matched (check the job ids / name / --since window)")

groups = defaultdict(list)
for jid, j in jobs.items():
    j["rss"] = rss.get(jid)
    if MATCH and not MATCH.search(j["sig"] or ""):
        continue
    key = j["name"] if (BY == "name" or not j["sig"]) else f'{j["name"]} | {j["sig"]}'
    groups[key].append(j)
if not groups:
    sys.exit("rightsize: no tasks left after --match")
if BY == "config" and not any(j["sig"] for js in groups.values() for j in js):
    print("note: no task logs were readable, so tasks are grouped by job name only")

for name, js in sorted(groups.items()):
    done = [j for j in js if j["state"] == "COMPLETED" and j["el"] is not None]
    hit_time = [j for j in js if j["state"] == "TIMEOUT"]
    hit_mem = [j for j in js if j["state"] in ("OUT_OF_MEMORY", "OOM")]
    other = len(js) - len(done) - len(hit_time) - len(hit_mem)
    req_tl = max((j["tl"] for j in js if j["tl"]), default=None)        # minutes
    req_mem = max((j["req"] for j in js if j["req"]), default=None)     # MB
    cpus = max(j["cpus"] for j in js)

    print(f"\n== {name}: {len(js)} tasks  ({len(done)} completed, {len(hit_time)} timeout, "
          f"{len(hit_mem)} out-of-memory, {other} other)")
    if not done:
        print("   no completed tasks -- nothing to size from")
        continue

    el = sorted(j["el"] / 60 for j in done)                 # minutes
    peak_el, med_el = el[-1], el[len(el) // 2]
    if len(el) >= 3 and med_el > 0 and peak_el / med_el > 3:
        print(f"   WARNING: peak is {peak_el/med_el:.0f}x the median -- these tasks are not "
              f"alike; the suggestion is set by the largest. Split by size or use --match.")
    rs = [j["rss"] for j in done if j["rss"]]
    peak_rss = max(rs) if rs else None

    # --- walltime
    if hit_time:
        rec_t = req_tl * FACTOR if req_tl else None
        t_note = f"RAISE: {len(hit_time)} task(s) hit the {hhmm(req_tl)} limit"
    else:
        rec_t = max(MIN_MIN, math.ceil(FACTOR * peak_el / 5) * 5)   # round up to 5 min
        floored = any(j["array"] for j in js) and rec_t < ARRAY_MIN
        if floored:
            rec_t = ARRAY_MIN
        over = req_tl / peak_el if req_tl and peak_el else float("nan")
        t_note = (f"requested {hhmm(req_tl)} = {over:.0f}x the peak"
                  + ("  -> OVERESTIMATED" if over > FACTOR * 1.5 else "  (fine)")
                  + ("  [array: floored at 01:02:00 to stay out of gpu-test QOS]" if floored else ""))
    print(f"   time : peak {peak_el:6.1f} min, median {med_el:6.1f} min;  {t_note}")

    # --- memory (host RAM; GPU memory is not in sacct)
    if hit_mem:
        rec_g = math.ceil(req_mem * FACTOR / 1024) if req_mem else None
        m_note = f"RAISE: {len(hit_mem)} task(s) ran out of memory"
    elif peak_rss:
        rec_g = max(MIN_GB, math.ceil(FACTOR * peak_rss / 1024))
        over = req_mem / peak_rss if req_mem else float("nan")
        m_note = (f"requested {req_mem/1024:.0f}G = {over:.0f}x the peak"
                  + ("  -> OVERESTIMATED" if over > FACTOR * 1.5 else "  (fine)"))
    else:
        rec_g, m_note = None, "no MaxRSS recorded"
    print(f"   mem  : peak {peak_rss/1024 if peak_rss else float('nan'):6.2f} G (host RAM);  {m_note}")

    parts = []
    if rec_t:
        parts.append(f"--time={hhmm(rec_t)}")
    if rec_g:
        per = math.ceil(rec_g / cpus)
        parts.append(f"--mem={rec_g}G  (or --mem-per-cpu={per}G with {cpus} cpus)")
    print(f"   SUGGEST ({FACTOR:g}x peak): " + "  ".join(parts))
