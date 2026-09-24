---
name: della
description: Submit, monitor, debug, and cancel Slurm jobs on Princeton's Della cluster, sync files to/from it, and sanity-test code before queueing. Use for Princeton Della access, Slurm job operations on Della, and transfers between this machine and Della.
---

# Della cluster operations

All operations go through the helper script `scripts/della.sh`, which lives next
to this SKILL.md. Resolve it relative to the skill's install location:

```bash
~/.claude/skills/della/scripts/della.sh <command> [args]   # Claude Code
~/.codex/skills/della/scripts/della.sh <command> [args]    # Codex
```

Below, `della.sh` means that resolved path. It reuses the user's SSH
ControlMaster socket with explicit direct-connection options (`ProxyJump=none`).
It never handles credentials.

## Connection check before remote operations

```bash
della.sh check
```

If it reports no live connection, **you cannot fix this yourself** — Duo 2FA needs
the user. Ask them to run `della.sh connect` themselves:

- **Claude Code:** tell them to type it with the `!` prefix so the Duo prompt
  appears in their session, e.g. `! ~/.claude/skills/della/scripts/della.sh connect`
- **Codex:** ask them to run it in their own interactive terminal, e.g.
  `~/.codex/skills/della/scripts/della.sh connect`

That authenticates once (interactive password/Duo) and leaves a persistent master
socket; then retry. If `check` says "ControlMaster: not running" but the remote
command still succeeds, a fresh connection worked without Duo — proceed normally.

The helper defaults to `della9.princeton.edu` with explicit multiplexing options
and `ProxyJump=none`. Set `DELLA_USER` locally to your cluster account, or let
OpenSSH resolve it from your SSH configuration. `DELLA_HOST` overrides the host.
Never put account identifiers, passwords, SSH keys, or tokens in this repository.

Host-specific notes:

- **Claude Code:** run the helper with the Bash tool. Blocking commands
  (`gputest`, `gpucheck`, long `test` runs) can take minutes; give them a
  generous timeout or run them in the background and report when they finish.
- **Codex:** use shell execution. If sandbox restrictions block SSH or its
  control socket, request execution escalation through the tool; do not
  misdiagnose a sandbox denial as an authentication failure. Run blocking GPU
  allocations in a yielding shell session so progress can still be reported.

## Commands

| Task | Command |
|---|---|
| Connection + identity + queue summary | `check` |
| Arbitrary login-node command | `run 'squeue -u $USER'` |
| Code → cluster | `push <local> <remote-dir> [--exclude=...]` |
| Results → local | `pull <remote-path> <local-dir>` |
| List / read remote files | `ls <path>` · `cat <file> [n-lines]` |
| Submit job | `submit <remote-workdir> <script.slurm> [sbatch args]` — prints `JOBID=` |
| Queue status (all my jobs) | `status` |
| One job in detail (state, ExitCode, MaxRSS) | `status <jobid>` |
| History incl. finished jobs | `hist [YYYY-MM-DD]` |
| Tail a job's stdout | `logs <jobid> [n]` |
| Cancel | `cancel <jobid...>` |
| Sweep/array summary (counts by state) | `sweep <id1,id2,...>` or `sweep <array-id>` |
| Sanity-run before queueing | `test 'python train.py --tiny' [secs]` |
| Disk quotas | `quota` |
| Partition load + why jobs pend | `queue [partition]` |
| GPU node availability | `gpus [partitions]` (default `gpu,mig`) |
| Run a command on a GPU node | `gputest '<cmd>' [min] [partition] [gres]` |
| Verify conda env sees the GPU | `gpucheck [env]` (default env `jax-gpu`) |
| GPU/CPU/memory efficiency report | `jobstats <jobid>` (works on finished jobs) |
| Live GPU utilization of a running job | `gpuwatch <jobid>` |

## Workflow guidance

**Before any real submission**, sanity-test on the login node with a tiny problem
size: `test 'cd /scratch/gpfs/$USER/proj && python main.py --steps 2' 60`.
Login nodes are shared — keep tests short and small (that is what the `timeout` is for).
Exit code 124 means the timeout killed it; inspect output for the intended smoke-test milestone before treating it as useful evidence. A timeout alone is not a passing test.

**Standard submit loop:**
1. `push` the code (workdir on cluster is typically under `/scratch/gpfs/$USER/`; never run jobs out of `/home`).
2. `test` a tiny version.
3. `submit`, note the `JOBID=` line.
4. Poll with `status <jobid>` — do NOT poll in a tight loop; jobs queue for minutes to hours. Check once, tell the user, and check again later or when asked.
5. On completion, `status <jobid>` first: `COMPLETED 0:0` is success; then `pull` results.

**Debugging a failed job** — diagnose in this order:
1. `status <jobid>` → look at State + ExitCode:
   - `OUT_OF_MEMORY` or ExitCode `0:125`/oom in logs → raise `--mem`
   - `TIMEOUT` → raise `--time` or checkpoint
   - `FAILED` with nonzero exit → application error, go to logs
   - `NODE_FAIL` → just resubmit
2. `logs <jobid> 100` for the traceback.
3. If the Python env is suspect: `test 'module load anaconda3/2024.6 && python -c "import torch"'` (match the modules the job script loads).
4. Fix locally, `push`, resubmit. Never edit code on the cluster directly — the local copy is the source of truth.

## GPU jobs (in-context-learning training runs)

Inherited Della GPU notes (source skill recorded verification on 2026-08-29;
not reverified during this conversion). Check live partitions, limits, modules,
and project paths before relying on these values for a new workload:
- Partitions: `gpu` (public A100s, 40/80GB), `mig` (A100 MIG slices — cheap, fast to
  schedule; Princeton says "use a MIG GPU whenever possible" for small jobs),
  `pli`/`pli-lc` (H100, PLI members only — check `getent group pli`), `grace` (GH200),
  `rtx6000`. Request with `--gres=gpu:1`.
- Constraints on `gpu`: `--constraint=gpu40` / `gpu80` (only take 80GB if 40GB won't fit);
  `--constraint="nomig&gpu40"` to exclude MIG (MIG-incompatibility symptom:
  `IndexError: list index out of range`); `--constraint=intel` if a binary compiled on
  the login node throws "illegal instruction" on AMD nodes.
- MIG slice = fixed 1 GPU (10GB), 1 CPU-core, 32GB CPU mem — exceed either and the job
  dies. Fits env checks and tiny debug runs, not real training.
- QOS is auto-assigned from walltime — never specify it: `gpu-test` ≤61 min (max 2
  jobs, high priority — why `gputest`/`gpucheck` schedule fast), `gpu-short` ≤24h,
  `gpu-medium` ≤72h, `gpu-long` ≤6 days (hard max; longer needs checkpointing).
  Shorter walltime = faster scheduling; fairshare is charged for what you REQUEST.
- **Job-array gotcha for sweeps:** arrays with ≤61-min tasks land in `gpu-test` QOS,
  whose submit limit is tiny → `QOSMaxSubmitJobPerUserLimit` rejections. Fix: set
  `--time=01:02:00` or longer so the array lands in `gpu-short`. MaxArraySize is 2501.
- Compute nodes have **no internet** — download datasets/checkpoints on the login node first.
- The `della-gpu.princeton.edu` login node has a GPU (handy for pip-installing CUDA
  wheels), but it needs its own Duo login; the MIG-based `gpucheck` avoids that.
- Example training env: `module load anaconda3/2024.2` + `conda activate jax-gpu`
  (PyTorch + JAX). Job scripts live in the project dir as `train_*.slurm` and use
  job arrays over parameter grids.

**GPU debug order** (before and after the CPU-side checks above):
1. New/changed environment? `gpucheck` first — allocates a MIG slice and prints
   `nvidia-smi -L`, torch version + `cuda_available`, jax devices. Catches
   CPU-only torch builds and broken CUDA modules in ~a minute.
2. Code changed? `gputest 'cd /scratch/gpfs/$USER/proj && python train.py --tiny' 10`
   — real GPU node, 10-min cap, catches CUDA OOM and device-placement bugs cheaply.
   Use partition `mig` for small models; pass `gputest ... 15 gpu` when the tiny run
   itself needs a full A100.
3. Job running but slow? `gpuwatch <jobid>` — if GPU-Util is ~0%: the env fell back
   to CPU (check the log for `cuda_available: False`), or the code isn't GPU-enabled,
   or a module/library is missing. If low but nonzero (<15%): dataloader-bound —
   set PyTorch `DataLoader(num_workers=N)` with `--cpus-per-task=N` (Princeton's
   example: 1→8 workers took GPU util from 18% to 55%); also make sure output goes
   to `/scratch/gpfs`, not `/projects` or `/home`. For the last hour of utilization
   across all your GPU jobs: `run 'gpudash --me'`.
4. Job finished? `jobstats <jobid>` — GPU utilization and memory efficiency
   (web version with time-series: mydella.princeton.edu/pun/sys/jobstats/<jobid>);
   low GPU memory → a MIG slice would do; low utilization → batch size / workers.
   For many jobs at once use `run 'reportseff'`.
5. `CUDA out of memory` in logs (job state often plain FAILED, not OUT_OF_MEMORY):
   smaller batch or a bigger-memory GPU (`--constraint=gpu80` for 80GB A100s).
6. Requesting >1 GPU only helps if the code uses DistributedDataParallel — for single-GPU training scripts, always `--gres=gpu:1`.

`gputest`/`gpucheck` block until Slurm allocates the GPU — normally fast on `mig`,
but don't stack many; one at a time.

**Quota problems** masquerade as random crashes (`Disk quota exceeded`, jobs dying
at write time). If failures look I/O-related, run `quota` early.

## Cautions

- Keep cancellations, remote overwrites/deletions, submissions, and retries within the user-authorized scope. Ask only when that scope does not already authorize the action; avoid unbounded resubmission loops.
- `push`/`pull` never pass `--delete` by default; only add it when the user explicitly wants mirroring.
- Don't run heavy computation via `run` — login nodes are shared; that's what `test` (with timeout) and `submit` are for.
- Sweep submissions: prefer one Slurm job array (`sbatch --array=0-39`) over 40 separate submits; `sweep <array-id>` then summarizes it in one call.

Run `della.sh help` for CLI usage. Dependencies: local Bash, OpenSSH,
and rsync; network access to Della (campus network or VPN); remote Slurm and
Princeton cluster utilities. The `logs` fallback assumes `slurm-<jobid>.out`;
for completed jobs with custom output paths, read the configured file directly.
`gpucheck` prints diagnostics but may exit successfully even when a library
check fails; inspect the reported CUDA availability and devices.
