# Troubleshooting

Everything below happens **on the droplet** (`ssh claude-brain`) unless noted.
First move for almost any problem: `brain status`.

## "The login link/code expired" or a login failed halfway

Re-run just that login — they're all repeatable:

```bash
brain auth anthropic   # Claude (the main brain)
brain auth chatgpt     # GPT models
brain auth grok
brain auth kimi
brain auth github
```

## `brain status` shows the router unhealthy / red

```bash
systemctl --user restart cli-proxy-api
sleep 5 && brain status
```

Still down? Read the log:

```bash
journalctl --user -u cli-proxy-api -n 50 --no-pager
```

If the binary is missing (fresh droplet, build failed), check
`~/.local/state/brain/proxy-build.log`, then rebuild:

```bash
brain-proxy-build --force
```

## My phone can't find the session

1. On the droplet, `brain status` — is `brain-rc` running? If not: `brain`.
2. Inside the Claude session, run `/remote-control` again and use the fresh link.
3. Remote Control needs the same Claude account on both ends — check `/status` inside
   the session shows the account you expect.

## A bridge agent (brain-grok etc.) says it can't reach the model

- `brain status` — is that vendor listed under "linked accounts"? If not: `brain auth <vendor>`.
- Test the router directly: `brain-ask grok-4.5 "say hi"`. The error it prints
  (HTTP 401 = token problem, connection refused = router down) tells you which fix above applies.

## ChatGPT keeps saying "enable device code authorization"

Some ChatGPT accounts won't accept the device-code login even after enabling
**Settings → Security → Device code authorization** (plan and workspace restrictions
apply, and the toggle can take a while to stick). The fallback is the normal
browser login, tunneled so your laptop's browser can complete it. On your **laptop**, run:

```bash
ssh -t -L 1455:localhost:1455 claude-brain 'bash -lc "brain auth chatgpt --browser"'
```

It prints a URL — open it in your laptop's browser and sign in. The login's callback
comes back through the SSH tunnel to the droplet and the credential lands there
directly. Verify from the droplet: `brain-ask gpt-5.6-luna "say ok"`.

(If you already have a working credential from another CLIProxyAPI-based setup, copying
its `codex-*.json` into the droplet's `~/.cli-proxy-api/` and restarting the router with
`systemctl --user restart cli-proxy-api` also works — the router refreshes it from then
on. But then the login is live in two places.)

## `ssh claude-brain` says "Permission denied (publickey)"

Your laptop's SSH key doesn't match the one on the droplet. From your laptop:

```bash
cat ~/.ssh/id_ed25519.pub
```

then use the DigitalOcean console's **Droplet → Access → Launch Droplet Console** to log
in through the browser and append that line to `/home/brain/.ssh/authorized_keys`.

## The session lost its history / Claude seems to have restarted

Sessions persist on disk. Inside a fresh `claude`, run `/resume` to pick the previous
conversation back up, or start `claude --continue` from the shell.

## tmux basics (the thing your session lives inside)

- Detach (leave it running): `Ctrl-b` then `d`
- Re-attach: `brain` (or `tmux attach -t brain-rc`)
- Kill a stuck session: `tmux kill-session -t brain-rc`, then `brain` to start fresh

## The droplet feels frozen / out of memory

The default size is the minimum. From your laptop, resize up:

```bash
doctl compute droplet-action resize claude-brain --size s-2vcpu-4gb --wait
```

(Power off first in the DO console if it refuses.)

## Vendor login worked but the model errors mid-use

Subscription tokens expire and normally auto-refresh. If one wedges, delete its record
and log in again:

```bash
ls ~/.cli-proxy-api/           # find the vendor's .json file
rm ~/.cli-proxy-api/xai-*.json # example: Grok
brain auth grok
```

## Start completely over

From your laptop: `doctl compute droplet delete claude-brain`, then re-run the setup
command from the README. Nothing on the droplet is precious — all logins can be redone.

## Platform-specific

**macOS: the brain didn't come back after a reboot.**
A launchd *user agent* only runs once someone is logged in. On a dedicated Mac, turn on
automatic login (System Settings → Users & Groups → Automatic login). Check with
`brain autostart status`.

**macOS: the router isn't running.**
`launchctl kickstart -k gui/$(id -u)/sh.claude-brain.proxy`, then `brain status`. Logs are
files, not a journal: `~/.local/state/brain/log/sh.claude-brain.proxy.log`.

**macOS: `tailscale: command not found` but the app is installed.**
The App Store build hides the CLI inside the bundle; claude-brain finds it there
automatically. If you installed it that way and something still can't see it, use
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

**The machine keeps falling asleep.**
`brain keepawake` — it prints the exact commands first. On macOS it only stops sleep while
plugged in, so a laptop on battery will still sleep (deliberately).

**Linux: services die when I log out.**
`sudo loginctl enable-linger $USER`. `brain autostart enable` does this for you.

**Arch: `pacman` couldn't find a package.**
Refresh first (`sudo pacman -Sy`). The GitHub CLI is `github-cli`, not `gh`.

**The installer says my distro is untested.**
It still installs. Only macOS, Arch and Ubuntu/Debian are tested; if a package name is
wrong on yours, install it by hand and re-run `install.sh --here`.

**claude-brain took over my Claude Code statusline.**
It shouldn't have — it only claims an unset one. `brain config statusline off` removes
ours; your original settings are backed up at
`~/.local/state/brain/settings.json.pre-brain`.

**I want it off this machine.**
`brain uninstall` (add `--purge` to delete state and linked credentials too).
