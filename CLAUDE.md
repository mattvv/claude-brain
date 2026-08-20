# claude-brain

Two different jobs land in this repo. Work out which one you're doing first.

## Someone asked you to install claude-brain

They said something like *"claude help me install claude brain at <url>"*.
Read **[docs/agent-install.md](docs/agent-install.md)** and follow it — it is
written for you, in order, including what to ask, what to show before changing
anything, and how to drive the account logins from chat.

## You're working on claude-brain itself

- `install.sh` — the one entry point: `--here`, `--ssh user@host`,
  `--digitalocean`. Every question is also a flag; `--plan` changes nothing.
- `host/` — everything that runs on a brain machine (the name is deliberate:
  it is not always a droplet). `droplet/` is a compat symlink for one release.
- `host/lib/platform.sh` — the only place that knows about macOS vs Linux,
  brew vs pacman vs apt, launchd vs systemd. Put platform differences here,
  not in the callers.
- Shipped scripts must stay **bash 3.2 compatible** — macOS still ships bash 3.2
  as `/bin/bash`. No `mapfile`, `declare -A`, `${x^^}`. CI enforces this on a
  macOS runner. (`tests/compress/ab/` is a dev-only harness and is exempt.)
- Two profiles: `droplet` (owns the machine, passwordless sudo, firewall) and
  `local` (someone's own computer — back up their config, ask before changing
  the machine, and never touch their firewall). Anything that changes the
  user's machine outside `~/.local/share/brain` needs to be reversible by
  `brain uninstall`.
- Run `tests/platform/run.sh` and `tests/install/run.sh` before pushing.
