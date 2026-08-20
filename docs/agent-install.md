# Installing claude-brain (instructions for the agent)

You are reading this because someone said something like:

> claude help me install claude brain at https://github.com/mattvv/claude-brain

This document is written for you, not for them. Follow it in order. The person
you're helping may not be technical — they should never have to read a stack
trace, and they should never be surprised by a change to their computer.

## What you are installing

A personal AI server: Claude Code running around the clock on a machine they
own (or a cloud VM), reachable from the Claude app on their phone, with a local
router that can also consult Grok, GPT and Kimi on their own subscriptions.

Two facts that matter for the install:

- The connection is **outbound only**. Nothing listens on the internet, so a
  machine at home behind a router works fine. Never open a port. Never suggest
  port forwarding.
- The machine holds **live OAuth credentials** for their accounts. Everything
  runs as their user, never as root. Never print `~/.config/brain/token`,
  `~/.config/brain/proxy-config.yaml`, or anything in `~/.cli-proxy-api/`.

## Step 1 — check the machine

```bash
uname -s -m          # Darwin/Linux, arm64/x86_64
```

Supported: macOS 13+ (Apple Silicon or Intel), Arch Linux, Ubuntu/Debian. Other
Linux distributions usually work — tell them it's untested rather than pretending
otherwise. Anything else (Windows without WSL2, BSD): say so and stop.

If you are running *on* the machine that will be the brain, that's the simple
case. If not, you'll use `--ssh` in step 3.

## Step 2 — ask the five questions

Ask them **in one batch** (use AskUserQuestion if you have it), not one at a
time. Recommended options are marked.

1. **Where should the brain live?**
   - *this computer* (recommended if you're running on their desktop/Mac mini)
   - *another computer over SSH* — ask for `user@host`
   - *a new DigitalOcean droplet, ~$12/month* — they'll need a DO account and API token
2. **How much of this computer should it use?** (skip for a droplet: the answer is
   always "the whole machine")
   - *its own folder* (recommended) — it works in one directory and asks before
     going outside. Ask for the folder, default `~/brain-workspace`.
   - *the whole machine* — it administers the computer like the cloud version does
3. **Which accounts?** Claude is required. ChatGPT, Grok, Kimi and GitHub are each
   optional, each needs a subscription they already pay for, and each can be added
   later in ten seconds. Don't push.
4. **Start automatically after a reboot?** (recommended yes)
5. **Keep the machine awake?** Only ask if it's a laptop or a Mac. Be honest: this
   changes a system sleep setting. On macOS it only applies while plugged in.

Warn them, once, if the answer to (1) is a laptop: a laptop that sleeps or gets
carried around is not an always-on brain. Suggest a desktop, a Mac mini, or the
droplet. Then do what they asked.

## Step 3 — show the plan, then run it

Build the command from their answers:

```bash
# on this computer
curl -fsSL https://raw.githubusercontent.com/mattvv/claude-brain/main/install.sh -o /tmp/brain-install.sh
bash /tmp/brain-install.sh --plan --here --scope workspace --workspace ~/brain-workspace --link chatgpt,github --autostart
```

Show them that `--plan` output — it changes nothing — and get a go-ahead. Then
run the same command **without `--plan`** and with `--yes`:

```bash
bash /tmp/brain-install.sh --here --scope workspace --workspace ~/brain-workspace --link chatgpt,github --autostart --yes
```

For the other targets, same flags:

```bash
bash /tmp/brain-install.sh --ssh user@host --scope machine --autostart --yes
bash /tmp/brain-install.sh --digitalocean --region nyc3
```

Notes:
- It takes **5–15 minutes**, mostly building the model router from pinned source.
  Say so before you start, and keep them posted — don't go silent.
- On a Mac without Homebrew it will install Homebrew. Tell them first.
- `--yes` deliberately does **not** start OAuth logins (nobody would be watching)
  and does not enable autostart unless `--autostart` was passed.
- If it needs a password for `sudo`, you cannot type it. Hand them the exact
  command and wait.

## Step 4 — sign them in

After the installer finishes, `brain status` will show Claude as not logged in.
Claude is required; the rest are optional.

**Claude** is an interactive login and must be done by them, at a terminal on the
brain machine:

```bash
brain auth anthropic     # follow the prompts, then /exit
```

**Everything else you can drive from chat.** This is the same headless flow the
brain uses on itself:

```bash
brain auth start chatgpt        # prints a URL (+ a device code)
```

- Relay the URL and code. They open it on any device and approve.
- ChatGPT completes on its own: poll `brain auth check chatgpt` every ~15s, up to
  2 minutes.
- Grok and Kimi land on a `localhost` address that won't load. Ask them to copy
  that address out of the browser bar and paste it to you, then:
  `brain auth paste grok '<that-url>'`.
- GitHub: `brain auth github` (device flow, same pattern).

Confirm each one with `brain auth check <vendor>`.

## Step 5 — verify and hand over

```bash
brain status
```

Every line should be green except the ones they chose to skip. Then:

1. Tell them to run `brain` on the machine (or confirm autostart is on).
2. Tell them to open the Claude app → **Code** tab, or claude.ai/code, where
   their brain's sessions now appear.
3. Tell them what they skipped and the one command that adds it later.

Useful afterwards: `brain autostart status`, `brain keepawake`, `brain update`,
`brain uninstall`.

## If something goes wrong

- **The router won't build** — it needs Go and a few minutes of RAM. On a 1GB
  droplet it can OOM; a 2GB machine is the floor.
- **`brain status` says the router isn't running** — `brain status` prints the
  right restart command for that machine (systemd or launchd; they differ).
- **A login "expired"** — just re-run `brain auth <vendor>`. Nothing else breaks.
- **They already had a Claude Code statusline** — the installer keeps theirs and
  tells them `brain config statusline on` if they want ours. Don't override it
  for them.
- **They want it gone** — `brain uninstall` restores their Claude Code config;
  `brain uninstall --purge` also deletes state and linked credentials.

Report honestly at the end: what's installed, what's linked, what's not, and
what it cost them (nothing, if it's their own machine).
