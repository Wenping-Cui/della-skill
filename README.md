# Della skill for Codex

Manage Princeton Della Slurm jobs and file transfers through a Bash helper.

Copy this repository into `~/.codex/skills/della`, then invoke `$della` in Codex.
Requires Bash, OpenSSH, rsync, Della access, and a campus/VPN network connection.

Set your account only in your local shell (replace the placeholder):

```bash
export DELLA_USER="YOUR_CLUSTER_ACCOUNT"
~/.codex/skills/della/scripts/della.sh connect
~/.codex/skills/della/scripts/della.sh check
```

Authenticate interactively in your own terminal. Passwords and Duo responses
are handled by SSH; never add them, tokens, SSH keys, or local account settings
to repository files. Existing SSH user configuration can replace `DELLA_USER`.

See [SKILL.md](SKILL.md) for workflows and run `scripts/della.sh help` for commands.
Cluster resource notes are inherited historical guidance; verify current limits
before submitting a workload.
