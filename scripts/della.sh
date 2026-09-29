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
# Cluster account (NetID): $DELLA_USER, else the one-line file
# ~/.config/della/user -- kept OUT of this repository, which must never contain
# account identifiers -- else whatever ~/.ssh/config sets for the host.
DELLA_USER_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/della/user"
DELLA_USER="${DELLA_USER:-$( { tr -d '[:space:]' < "${DELLA_USER_FILE}"; } 2>/dev/null || true)}"
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

# Resolve the cluster username without guessing. Order: $DELLA_USER, the file
# ~/.config/della/user (both applied above), then a User that ~/.ssh/config sets
# explicitly for this host. The local login name is NOT an acceptable fallback:
# using it silently is what produces "Permission denied" and, after repeats, a
# temporary block on this machine's address.
resolve_user() {
  [ -n "${DELLA_USER}" ] && return 0
  local u; u="$(ssh -G "${HOST}" 2>/dev/null | awk '/^user /{print $2; exit}')"
  if [ -n "$u" ] && [ "$u" != "$(id -un)" ]; then DELLA_USER="$u"; return 0; fi
  return 1
}

save_user() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "not a valid username: '$1'"
  mkdir -p "$(dirname "${DELLA_USER_FILE}")"
  printf '%s\n' "$1" > "${DELLA_USER_FILE}" && chmod 600 "${DELLA_USER_FILE}"
  DELLA_USER="$1"
}

no_user_hint() {
  cat >&2 <<EOF

No Della username is configured, so nothing was attempted (guessing the local
login name "$(id -un)" would fail and can get this address blocked).
Set it once:

    $(printf '%q' "${SELF}") user <your-Princeton-NetID>

or just run  $(printf '%q' "${SELF}") connect  and it will ask.
EOF
}

# True if a ControlMaster session is live. Talks only to the LOCAL control
# socket -- it never opens a connection to the login node.
have_master() { ssh "${BASE_OPTS[@]}" -O check "${HOST}" >/dev/null 2>&1; }

# The login node's SSH banner, read without authenticating. While Princeton is
# temporarily refusing an address (typically after repeated failed logins) the
# node answers "Not allowed at this time" instead of an SSH banner.
banner() {
  timeout "${CONNECT_TIMEOUT}" bash -c "exec 3<>/dev/tcp/${HOST}/22 && head -c 80 <&3" \
    2>/dev/null | tr -d '\r\n' || true
}

blocked_hint() {
  cat >&2 <<EOF

${HOST} is refusing connections from this address ("Not allowed at this time").
This is a temporary server-side block, usually after repeated failed or rapid
logins; it normally clears within minutes to an hour. Every further attempt can
extend it, so do not retry in a loop.

Either wait, or log in through another login node (same /scratch filesystem):

    DELLA_HOST=della8.princeton.edu $(printf '%q' "${SELF}") connect
EOF
}

# explain_failure <stderr-file>: say WHY ssh failed instead of always "log in".
explain_failure() {
  local f="$1"
  if grep -qiE 'not allowed at this time|kex_exchange_identification|connection reset by peer' "$f"; then
    blocked_hint
  elif grep -qiE 'password (has )?expired|change your password|must change|password change required' "$f"; then
    cat >&2 <<EOF

The NetID password has expired. Change your Princeton NetID password
(OIT password page, or at the prompt if the login offers it), then:

    $(printf '%q' "${SELF}") connect
EOF
  elif grep -qi 'permission denied' "$f"; then
    cat >&2 <<EOF

Authentication failed as ${DELLA_USER}@${HOST}. Check, in order:
  - the NetID (${DELLA_USER:-unset, so ~/.config/ssh decides}; set DELLA_USER or ${DELLA_USER_FILE}),
  - that the NetID password has not expired or changed,
  - that the Duo approval went through.
Repeated failures get this address temporarily blocked -- stop after one or two.
EOF
  elif grep -qiE 'timed out|no route to host|could not resolve|network is unreachable' "$f"; then
    echo >&2
    echo "Cannot reach ${HOST}: off campus without the Princeton VPN, or a network problem." >&2
  else
    conn_hint
  fi
}

# Fail fast, locally, when there is no live session. Without this every command
# would open a fresh (doomed, BatchMode) connection to the login node, and a
# burst of those looks like a password-guessing attack to Princeton's blocker.
require_master() {
  if ! resolve_user; then no_user_hint; exit 255; fi
  have_master && return 0
  conn_hint          # purely local: no banner probe, no connection attempt
  exit 255
}

conn_hint() {
  cat >&2 <<EOF

No live SSH session to ${HOST} as ${DELLA_USER:-<ssh-config user>}. Nothing was sent to the
cluster. Open a session once (password + Duo); it persists via ControlMaster:

    $(printf '%q' "${SELF}") connect

In Claude Code, type:  ! $(printf '%q' "${SELF}") connect

Then retry this command.
EOF
}

# remote '<command string>'  — run on the login node over the shared socket
remote() {
  require_master
  local rc=0 errf; errf="$(mktemp)"
  ssh "${SSH_OPTS[@]}" "${HOST}" "$1" 2> >(tee "$errf" >&2) || rc=$?
  wait 2>/dev/null || true
  if [ "$rc" -eq 255 ]; then explain_failure "$errf"; fi
  rm -f "$errf"
  return "$rc"
}

usage() {
  cat <<'EOF'
Usage: della.sh <command> [args]

Connection
  user [netid]                  Show the cluster username, or save it (asked once; kept out of the repo)
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
  rightsize <ids>|--name <n>    Requested vs used time/RAM per configuration (tasks alike but for
                                the seed); suggest 1.5x the peak. [--since DATE] (30 days),
                                [--factor F] (1.5), [--by config|name], [--match REGEX]
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

Environment: DELLA_HOST (default della9.princeton.edu), DELLA_USER (or ~/.config/della/user; else SSH configuration),
             DELLA_CONNECT_TIMEOUT (default 8), DELLA_ANACONDA_MODULE (default anaconda3/2024.2),
             DELLA_CONDA_ENV (default jax-gpu; used by gpucheck)
EOF
}

cmd="${1:-help}"; shift || true

case "$cmd" in
  help|-h|--help)
    usage
    ;;

  user)
    # della.sh user          -> print the resolved username (exit 1 if unset)
    # della.sh user <netid>  -> save it to ~/.config/della/user (outside the repo)
    if [ $# -ge 1 ]; then
      save_user "$1"; echo "Saved Della username to ${DELLA_USER_FILE}"
    elif resolve_user; then
      echo "${DELLA_USER}"
    else
      echo "not set"; exit 1
    fi
    ;;

  connect)
    # Interactive (no BatchMode): shows the password/Duo prompt in this terminal,
    # then exits, leaving the ControlPersist master alive for all later commands.
    if ! resolve_user; then
      if [ -t 0 ]; then
        read -rp "Della username (Princeton NetID): " u
        save_user "$u"
        echo "Saved to ${DELLA_USER_FILE}"
      else
        no_user_hint; exit 1
      fi
    fi
    BASE_OPTS+=(-o User="${DELLA_USER}")
    if have_master; then
      echo "Already connected to ${HOST} as ${DELLA_USER:-<ssh-config user>} (master socket live)."; exit 0
    fi
    b="$(banner)"
    if [[ "$b" == *"Not allowed"* ]]; then blocked_hint; exit 1; fi
    echo "Connecting to ${DELLA_USER:+${DELLA_USER}@}${HOST} ..."
    errf="$(mktemp)"; rc=0
    ssh "${BASE_OPTS[@]}" "${HOST}" exit 2> >(tee "$errf" >&2) || rc=$?
    wait 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
      echo "Authenticated. Master socket is live; batch commands will now work."
    else
      explain_failure "$errf"
    fi
    rm -f "$errf"; exit "$rc"
    ;;

  check)
    if have_master; then
      echo "ControlMaster: live (${DELLA_USER:+${DELLA_USER}@}${HOST})"
    else
      echo "ControlMaster: not running for ${DELLA_USER:+${DELLA_USER}@}${HOST}"
      b="$(banner)"
      echo "Login-node banner: ${b:-<no response>}"
      if [[ "$b" == *"Not allowed"* ]]; then blocked_hint; else conn_hint; fi
      exit 255
    fi
    remote 'echo "host: $(hostname)  user: $USER  time: $(date "+%F %T")"; nq=$(squeue -u $USER -h 2>/dev/null | wc -l); echo "your jobs in queue: $nq"'
    ;;

  run)
    [ $# -ge 1 ] || die "usage: della.sh run '<command>'"
    remote "$1"
    ;;

  push)
    require_master
    [ $# -ge 2 ] || die "usage: della.sh push <local> <remote> [rsync-args...]"
    src="$1"; dst="$2"; shift 2
    rsync -az --human-readable --info=stats1 -e "${RSYNC_SSH}" \
      "$@" -- "${src}" "${HOST}:${dst}" || { rc=$?; [ "$rc" -eq 255 ] && conn_hint; exit "$rc"; }
    ;;

  pull)
    require_master
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

  rightsize)
    # rightsize <jobid[,jobid...]> | --name <jobname>  [--since DATE] [--factor F]
    #           [--by config|name] [--match REGEX]
    [ $# -ge 1 ] || die "usage: della.sh rightsize <jobid[,jobid...]> | --name <jobname> [--since DATE] [--factor 1.5] [--by config|name] [--match REGEX]"
    sel=(); since="$(date -d '-30 days' +%F)"; factor=1.5; local_args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --name)   sel=("--name=$2"); shift 2 ;;
        --since)  since="$2"; shift 2 ;;
        --factor) factor="$2"; shift 2 ;;
        --by)     local_args+=(--by "$2"); shift 2 ;;
        --match)  local_args+=(--match "$2"); shift 2 ;;
        *)        sel=("-j" "$1"); shift ;;
      esac
    done
    # The collector runs on the login node (it must read each task's log);
    # ship it as base64 so no quoting survives the ssh round trip.
    b64="$(base64 -w0 "$(dirname "${SELF}")/rightsize_collect.py")"
    rargs=""; for a in "${sel[@]}" -S "$since"; do rargs+=" $(printf '%q' "$a")"; done
    remote "echo ${b64} | base64 -d | python3 -${rargs}" 2>/dev/null \
      | python3 "$(dirname "${SELF}")/rightsize.py" "$factor" "${local_args[@]}"
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
