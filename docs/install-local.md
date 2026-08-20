# Installing on your own computer

A Mac mini, an iMac, a Linux desktop, a home server, a spare laptop. This is the
cheapest way to run a brain: you already own the hardware, and the electricity of
one idle desktop is not a monthly bill.

The easy way is to ask Claude — see the [README](../README.md). This document is
for doing it yourself, and for the details that only matter on a machine you use
for other things.

## Requirements

| | |
|---|---|
| macOS | 13 (Ventura) or newer, Apple Silicon or Intel. Homebrew (the installer offers to install it). |
| Arch Linux | current. `pacman`, systemd. |
| Ubuntu / Debian | 22.04+ / 12+. |
| Anything else | usually works; the installer says it's untested rather than pretending. |
| Hardware | 2 GB RAM is the floor (the model router is built from source). A few GB of disk. |

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mattvv/claude-brain/main/install.sh | bash
```

Choose **this computer**. It asks four things, then takes 5–15 minutes — most of
it building the model router. Add `--plan` to any invocation to see exactly what
it would do without doing it.

Non-interactive, if you'd rather script it:

```bash
bash install.sh --here \
  --scope workspace --workspace ~/brain-workspace \
  --link chatgpt,github --autostart --yes
```

## The scope question

This is the one decision worth thinking about. Your brain runs as **you**, with
your files and your logged-in accounts.

- **Its own folder** (`--scope workspace`) — the brain works in one directory and
  its instructions tell it to ask before reading or writing anything else on the
  machine. Sensible default for a computer you also use for other things.
- **The whole machine** (`--scope machine`) — how the cloud version behaves: it
  administers the computer, installs packages, works anywhere in your home
  directory.

Change your mind later:

```bash
brain config scope workspace ~/some/other/folder
brain config scope machine
```

Either way the brain is told the truth about `sudo` on your machine: if it will
prompt for a password, the brain knows it can't answer it and hands you the
command instead.

## What it changes on your machine

Everything here is reversible with `brain uninstall`:

| Path | What |
|---|---|
| `~/.local/bin/brain*` | the commands (symlinks into the checkout) |
| `~/.claude/settings.json` | claude-brain hooks; the statusline **only if you didn't already have one** |
| `~/.claude/CLAUDE.md` | three managed blocks (routing, ops, consult), clearly delimited |
| `~/.claude/agents/brain-*.md` | the consultant agents |
| `~/.config/brain/`, `~/.local/share/brain/`, `~/.local/state/brain/` | config, router binary, state |
| `~/.cli-proxy-api/` | your vendor OAuth credentials (0700) |
| `~/.bashrc` / `~/.zshrc` | one PATH line |
| launchd agent / systemd user unit | the router, and the session server if you enabled autostart |

A backup of your `settings.json` is taken **before** the first change, once, and
kept at `~/.local/state/brain/settings.json.pre-brain`.

Nothing else is touched. No firewall rules, no `/etc` (that's droplet-only), no
ports.

## Always on

Two different things:

```bash
brain autostart enable    # come back by itself after a reboot
brain keepawake           # stop the machine from sleeping (shows what it changes)
```

- **macOS**: autostart installs a launchd *user agent*, which only runs once
  someone is logged in — on a dedicated Mac, turn on automatic login
  (System Settings → Users & Groups → Automatic login). `brain keepawake` runs
  `pmset -c`, i.e. only while plugged in, so it can't flatten a laptop battery.
- **Linux**: autostart installs a systemd user unit and enables lingering so it
  survives logout. `brain keepawake` masks the sleep/suspend targets.

`brain autostart status` tells you what's still missing.

## Reaching it from outside your house

You don't need to. Remote Control is outbound: your brain connects to Anthropic,
your phone connects to Anthropic, and they meet there. No ports, no public IP.

For the extras — opening a dev server the brain built, or SSHing back to the
machine from a café — install [Tailscale](https://tailscale.com) and run
`brain auth tailscale`. Then `brain expose <port>` gives you a private HTTPS URL
that works on your phone.

## Uninstalling

```bash
brain uninstall           # restores your Claude Code config; keeps your logins
brain uninstall --purge   # also deletes state and linked credentials
```

The checkout stays where it is — delete it yourself if you want it gone.

## Security on a machine you use for other things

- The router listens on `127.0.0.1` only. `brain status` fails loudly if that
  ever changes.
- `~/.cli-proxy-api/` holds live OAuth tokens for your accounts. Keep full-disk
  encryption on (FileVault on macOS), and don't sync that directory anywhere.
- If you share the computer with someone else, remember the brain runs as you,
  with your access.
