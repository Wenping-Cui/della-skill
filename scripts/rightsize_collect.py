#!/usr/bin/env python3
"""Runs ON THE CLUSTER (della.sh rightsize pipes it over ssh).

Calls sacct with the given selection arguments and appends, to each job's
allocation row, a CONFIGURATION SIGNATURE: the first non-empty line of the
task's stdout log with seed tokens removed.  Tasks sharing a signature ran the
same configuration and differ only by seed -- those are the "similar tasks" a
resource estimate should be drawn from.  Slurm itself stores no per-task
configuration (SubmitLine is identical across an array; StdOut is a pattern),
so the log header is the only per-task record.
"""
import os
import re
import subprocess
import sys

FIELDS = "JobID,JobIDRaw,JobName,State,ElapsedRaw,TimelimitRaw,MaxRSS,ReqMem,AllocCPUS,StdOut"
SEED = re.compile(r"(?i)(--)?\bseed\b\s*[=:]?\s*\d+")


def signature(path):
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                if line.strip():
                    return re.sub(r"\s+", " ", SEED.sub("", line)).strip()[:200]
    except OSError:
        pass
    return ""


out = subprocess.run(["sacct", *sys.argv[1:], "--units=M", "-P", "--noheader", "-o", FIELDS],
                     capture_output=True, text=True).stdout
user = os.environ.get("USER", "")
for line in out.splitlines():
    f = line.split("|")
    if len(f) < 10:
        continue
    jid, raw, name, *rest, pattern = f
    sig = ""
    if "." not in jid and pattern:
        arr, _, task = jid.partition("_")
        path = (pattern.replace("%%", "\0").replace("%x", name).replace("%A", arr)
                .replace("%a", task or "4294967294").replace("%j", raw)
                .replace("%u", user).replace("\0", "%"))
        sig = signature(path).replace("|", "/")
    print("|".join([jid, name, *rest, sig]))
