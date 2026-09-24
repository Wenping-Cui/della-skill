#!/usr/bin/env bash
# della.sh — thin wrapper around ssh/rsync/Slurm for the Princeton Della cluster.
#
# All remote calls ride the user's existing SSH ControlMaster socket
# (explicit ControlMaster auto / ControlPersist yes options), so this script
# never handles credentials or Duo. If no live master exists, commands fail
# fast (BatchMode=yes) with instructions to authenticate.
set -euo pipefail

# Absolute path of this script, so hints work wherever the skill is installed
# (~/.claude/skills/della for Claude Code, ~/.codex/skills/della for Codex, ...).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

HOST="${DELLA_HOST:-della9.princeton.edu}"
DELLA_USER="${DELLA_USER:-}"
CONNECT_TIMEOUT="${DELLA_CONNECT_TIMEOUT:-8}"
ANACONDA_MODULE="${DELLA_ANACONDA_MODULE:-anaconda3/2024.2}"   # used by gpucheck
CONDA_ENV="${DELLA_CONDA_ENV:-jax-gpu}"                        # default env for gpucheck

# ControlMaster sockets live here; ssh silently skips multiplexing if it is missing.
mkdir -p "${HOME}/.ssh/sockets" && chmod 700 "${HOME}/.ssh/sockets"

# Self-contained connection options: user, multiplexing, and no proxy —
# independent of whatever ~/.ssh/config says for this host.
BASE_OPTS=(
  -o ProxyJump=none
  -o ControlMaster=auto
  -o ControlPath=~/.ssh/sockets/%p-%h-%r
  -o ControlPersist=yes
  -o ServerAliveInterval=300
)
if [[ -n "${DELLA_USER}" ]]; then
  BASE_OPTS+=(-o User="${DELLA_USER}")
fi
SSH_OPTS=("${BASE_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout="${CONNECT_TIMEOUT}")
RSYNC_SSH="ssh $(printf '%s ' "${BASE_OPTS[@]}") -o BatchMode=yes -o ConnectTimeout=${CONNECT_TIMEOUT}"

die() { echo "della: $*" >&2; exit 1; }

conn_hint() {
  cat >&2 <<EOF

No live SSH connection to ${HOST} (Duo login required).
Open one from your own terminal (it persists via ControlMaster):

    $(printf '%q' "${SELF}") connect

In Claude Code, type:  ! $(printf '%q' "${SELF}") connect

Then retry this command.
EOF
}

# remote '<command string>'  — run on the login node over the shared socket
remote() {
  local rc=0
  ssh "${SSH_OPTS[@]}" "${HOST}" "$1" || rc=$?
  if [ "$rc" -eq 255 ]; then conn_hint; fi
  return "$rc"
}

usage() {
  cat <<'EOF'
Usage: della.sh <command> [args]

Connection
  connect                       Interactive login (Duo) that leaves a persistent master socket
  check                         Master-socket status + remote identity + queue summary
  run '<cmd>'                   Run an arbitrary command on the login node

Files
  push <local> <remote> [rsync-args...]   rsync local -> cluster (-az, delete NOT default)
  pull <remote> <local> [rsync-args...]   rsync cluster -> local
  ls <remote-path>              List a remote directory (ls -lah)
  cat <remote-file> [n]         Print a remote file (first n lines; default whole file)

Jobs
  submit <remote-workdir> <script> [sbatch-args...]   sbatch from a directory; prints job id
  status [jobid]                No arg: your squeue. With id: sacct detail (incl. steps/MaxRSS)
  hist [since]                  sacct history (default: since today 00:00)
  logs <jobid> [n]              Tail the job's stdout file (default 60 lines)
  cancel <jobid...>             scancel one or more jobs
  sweep <id1[,id2,...]>         Per-job state table + counts by state (works for arrays)
  test '<cmd>' [secs]           Sanity-run a command on the login node under `timeout` (default 30s)

GPU
  gpus [partitions]             Free GPUs by model (gfree) + per-node view (shownodes; default gpu,mig)
  gputest '<cmd>' [min] [part] [gres]   Run cmd ON A GPU NODE via blocking srun
                                (defaults: 10 min, partition mig, gpu:1)
  gpucheck [conda-env]          Verify conda env sees the GPU (torch/jax) on a MIG slice
  jobstats <jobid>              Princeton job efficiency report (GPU util, memory, CPU)
  gpuwatch <jobid>              nvidia-smi on a RUNNING job's node (utilization snapshot)

Cluster
  quota                         checkquota (scratch/home usage)
  queue [partition]             Cluster load; with partition: sinfo + your pending reasons

Environment: DELLA_HOST (default della9.princeton.edu), DELLA_USER (optional; otherwise SSH configuration),
             DELLA_CONNECT_TIMEOUT (default 8), DELLA_ANACONDA_MODULE (default anaconda3/2024.2),
             DELLA_CONDA_ENV (default jax-gpu; used by gpucheck)
EOF
}

cmd="${1:-help}"; shift || true

case "$cmd" in
  help|-h|--help)
    usage
    ;;

  connect)
    # Interactive (no BatchMode): shows the password/Duo prompt in this terminal,
    # then exits, leaving the ControlPersist master alive for all later commands.
    ssh "${BASE_OPTS[@]}" "${HOST}" exit \
      && echo "Authenticated. Master socket is live; batch commands will now work."
    ;;

  check)
    if ssh "${BASE_OPTS[@]}" -O check "${HOST}" 2>/dev/null; then
      echo "ControlMaster: live"
    else
      echo "ControlMaster: not running (will attempt fresh batch-mode connection)"
    fi
    remote 'echo "host: $(hostname)  user: $USER  time: $(date "+%F %T")"; nq=$(squeue -u $USER -h 2>/dev/null | wc -l); echo "your jobs in queue: $nq"'
    ;;

  run)
    [ $# -ge 1 ] || die "usage: della.sh run '<command>'"
    remote "$1"
    ;;

  push)
    [ $# -ge 2 ] || die "usage: della.sh push <local> <remote> [rsync-args...]"
    src="$1"; dst="$2"; shift 2
    rsync -az --human-readable --info=stats1 -e "${RSYNC_SSH}" \
      "$@" -- "${src}" "${HOST}:${dst}" || { rc=$?; [ "$rc" -eq 255 ] && conn_hint; exit "$rc"; }
    ;;

  pull)
    [ $# -ge 2 ] || die "usage: della.sh pull <remote> <local> [rsync-args...]"
    src="$1"; dst="$2"; shift 2
    rsync -az --human-readable --info=stats1 -e "${RSYNC_SSH}" \
      "$@" -- "${HOST}:${src}" "${dst}" || { rc=$?; [ "$rc" -eq 255 ] && conn_hint; exit "$rc"; }
    ;;

  ls)
    [ $# -ge 1 ] || die "usage: della.sh ls <remote-path>"
    remote "ls -lah $(printf '%q' "$1")"
    ;;

  cat)
    [ $# -ge 1 ] || die "usage: della.sh cat <remote-file> [n]"
    if [ $# -ge 2 ]; then
      remote "head -n $(printf '%q' "$2") $(printf '%q' "$1")"
    else
      remote "cat $(printf '%q' "$1")"
    fi
    ;;

  submit)
    [ $# -ge 2 ] || die "usage: della.sh submit <remote-workdir> <script> [sbatch-args...]"
    workdir="$1"; script="$2"; shift 2
    extra=""
    for a in "$@"; do extra+=" $(printf '%q' "$a")"; done
    out=$(remote "cd $(printf '%q' "$workdir") && sbatch${extra} $(printf '%q' "$script")")
    echo "$out"
    jobid=$(echo "$out" | grep -oE '[0-9]+' | tail -1 || true)
    [ -n "$jobid" ] && echo "JOBID=$jobid"
    ;;

  status)
    if [ $# -ge 1 ]; then
      remote "sacct -j $(printf '%q' "$1") --format=JobID%-16,JobName%-20,Partition,State,ExitCode,Elapsed,MaxRSS,ReqMem,NodeList%-14"
    else
      remote 'squeue -u $USER -o "%.10i %.11P %.24j %.8T %.10M %.10l %.5D %R"'
    fi
    ;;

  hist)
    since="${1:-$(date +%F)}"
    remote "sacct -u \$USER -S $(printf '%q' "$since") -X --format=JobID%-16,JobName%-24,Partition,State,ExitCode,Elapsed,Start"
    ;;

  logs)
    [ $# -ge 1 ] || die "usage: della.sh logs <jobid> [n]"
    jobid="$1"; n="${2:-60}"
    remote "
      p=\$(scontrol show job ${jobid} 2>/dev/null | grep -oE 'StdOut=[^ ]+' | cut -d= -f2 | head -1)
      if [ -z \"\$p\" ]; then
        wd=\$(sacct -j ${jobid} -X -n -P --format=WorkDir%500 2>/dev/null | head -1)
        [ -n \"\$wd\" ] && p=\"\$wd/slurm-${jobid}.out\"
      fi
      if [ -z \"\$p\" ] || [ ! -f \"\$p\" ]; then
        echo \"stdout file for job ${jobid} not found (looked via scontrol and sacct WorkDir)\" >&2; exit 1
      fi
      echo \"== \$p (last ${n} lines) ==\"
      tail -n ${n} \"\$p\"
    "
    ;;

  cancel)
    [ $# -ge 1 ] || die "usage: della.sh cancel <jobid...>"
    remote "scancel $* && echo 'cancelled: $*'"
    ;;

  sweep)
    [ $# -ge 1 ] || die "usage: della.sh sweep <id1[,id2,...]>"
    out=$(remote "sacct -j $(printf '%q' "$1") -X -n -P --format=JobID,JobName%30,State,ExitCode,Elapsed")
    echo "$out" | column -t -s'|'
    echo "---"
    echo "$out" | awk -F'|' '{ s[$3]++ } END { for (k in s) printf "%-12s %d\n", k, s[k] }' | sort
    ;;

  test)
    [ $# -ge 1 ] || die "usage: della.sh test '<cmd>' [secs]"
    secs="${2:-30}"
    remote "timeout ${secs} bash -lc $(printf '%q' "$1")" \
      || { rc=$?; [ "$rc" -eq 124 ] && echo "(killed by ${secs}s timeout — check the output above for the expected milestone; a timeout alone is not a pass)"; exit "$rc"; }
    ;;

  gpus)
    p="${1:-gpu,mig}"
    remote "gfree 2>/dev/null; echo; shownodes -p $(printf '%q' "$p")"
    ;;

  gputest)
    [ $# -ge 1 ] || die "usage: della.sh gputest '<cmd>' [minutes] [partition] [gres]"
    mins="${2:-10}"; part="${3:-mig}"; gres="${4:-gpu:1}"
    echo "Requesting ${gres} on partition ${part} for ${mins} min (blocks until a GPU is allocated)..." >&2
    remote "srun --partition=$(printf '%q' "$part") --gres=$(printf '%q' "$gres") --time=${mins} --job-name=gputest bash -lc $(printf '%q' "$1")"
    ;;

  gpucheck)
    env_name="${1:-${CONDA_ENV}}"
    check_py='import sys
try:
    import torch
    print("torch", torch.__version__, "cuda_available:", torch.cuda.is_available(),
          "device:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none")
except Exception as e:
    print("torch check failed:", e)
try:
    import jax
    print("jax", jax.__version__, "devices:", jax.devices())
except Exception as e:
    print("jax check failed:", e)'
    cmd="module purge; module load ${ANACONDA_MODULE}; conda activate ${env_name}; nvidia-smi -L; python - <<'PYEOF'
${check_py}
PYEOF"
    echo "Verifying conda env '${env_name}' on a MIG GPU slice (blocks until allocated)..." >&2
    remote "srun --partition=mig --gres=gpu:1 --time=5 --job-name=gpucheck bash -lc $(printf '%q' "$cmd")"
    ;;

  jobstats)
    [ $# -ge 1 ] || die "usage: della.sh jobstats <jobid>"
    remote "jobstats $(printf '%q' "$1")"
    ;;

  gpuwatch)
    [ $# -ge 1 ] || die "usage: della.sh gpuwatch <jobid>"
    jobid="$1"
    remote "
      state=\$(squeue -j ${jobid} -h -o %T 2>/dev/null | head -1)
      if [ \"\$state\" != \"RUNNING\" ]; then
        echo \"job ${jobid} is not RUNNING (state: \${state:-not in queue}) — for finished jobs use: della.sh jobstats ${jobid}\" >&2; exit 1
      fi
      srun --overlap --jobid=${jobid} nvidia-smi
    "
    ;;

  quota)
    remote "checkquota"
    ;;

  queue)
    if [ $# -ge 1 ]; then
      remote "sinfo -p $(printf '%q' "$1") -o '%.12P %.6a %.11l %.7D %.10T'; echo '--- your pending jobs (reasons) ---'; squeue -u \$USER -t PD -p $(printf '%q' "$1") -o '%.10i %.24j %.10l %r' 2>/dev/null || true"
    else
      remote 'sinfo -o "%.12P %.6a %.11l %.7D %.10T" | head -30; echo "--- your pending jobs (reasons) ---"; squeue -u $USER -t PD -o "%.10i %.24j %.11P %.10l %r"'
    fi
    ;;

  *)
    usage
    die "unknown command: $cmd"
    ;;
esac
