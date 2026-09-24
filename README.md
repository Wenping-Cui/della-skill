# Della skill for Claude Code and Codex

Manage Princeton Della Slurm jobs and file transfers through a Bash helper.
One repository works as a skill for both [Claude Code](https://claude.com/claude-code)
and the OpenAI Codex CLI: both read `SKILL.md`, and `scripts/della.sh` resolves
its own install path.

Requires Bash, OpenSSH, rsync, Della access, and a campus/VPN network connection.

## Install

**Claude Code** — put the repository at `~/.claude/skills/della` (clone, copy, or
symlink). The skill triggers automatically when you mention Della, Slurm, or
jobs; you can also invoke it with `/della`.

```bash
git clone git@github.com:Wenping-Cui/della-skill.git ~/.claude/skills/della
```

**Codex** — put the repository at `~/.codex/skills/della` and invoke `$della`.

```bash
git clone git@github.com:Wenping-Cui/della-skill.git ~/.codex/skills/della
```

Both can share one checkout: clone once and symlink the other location to it.

## Setup

Set your account only in your local shell (replace the placeholder), then
authenticate once and verify:

```bash
export DELLA_USER="YOUR_CLUSTER_ACCOUNT"
~/.claude/skills/della/scripts/della.sh connect   # or ~/.codex/skills/della/...
~/.claude/skills/della/scripts/della.sh check
```

Inside Claude Code, run the login as `! ~/.claude/skills/della/scripts/della.sh connect`
so the password and Duo prompts appear in your session. Passwords and Duo
responses are handled by SSH; never add them, tokens, SSH keys, or local account
settings to repository files. Existing SSH user configuration can replace
`DELLA_USER`. `DELLA_HOST` overrides the default `della9.princeton.edu`.

See [SKILL.md](SKILL.md) for workflows and run `scripts/della.sh help` for commands.
Cluster resource notes are inherited historical guidance; verify current limits
before submitting a workload.
