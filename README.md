# claude-brain 🧠

**Your multi-model agent. Anywhere, always on. Driven by Claude.**

claude-brain turns a computer you already have — a Mac mini in a closet, a Linux box under
your desk, a spare laptop, or a $12/month cloud VM — into a personal AI server that runs
[Claude Code](https://claude.com/claude-code) around the clock. You open the Claude app on
your phone or [claude.ai/code](https://claude.ai/code) in a browser, attach to your brain,
and give it work. It keeps going when you close your laptop, leave the house, or go to bed.

The twist: your brain isn't limited to Claude. It has a built-in **model router** that can
also consult **Grok**, **GPT**, and **Kimi** — using your own subscriptions to those
services — and it can work directly on your **GitHub** repositories.

claude-brain is two things working together: a **model router** (one Claude session that
delegates to other model families) and a **compression tool** (a local engine that shrinks
the tokens flowing to and from every model, so long-running work stays cheap). Both run on
your brain machine; both are on by default.

```
   your phone / laptop                      your brain (any computer)
  ┌──────────────────┐   Remote Control   ┌────────────────────────────┐
  │ Claude app        │ ◄───────────────► │ Claude Code (always on)    │
  │ claude.ai/code    │                   │   ├── brain-grok  ─┐       │
  └──────────────────┘                   │   ├── brain-sol   ─┼─► model router
                                          │   ├── brain-kimi  ─┘  (Grok/GPT/Kimi)
                                          │   └── your GitHub repos    │
                                          └────────────────────────────┘
```

The connection is **outbound only**. Your brain reaches out to Anthropic; your phone talks
to Anthropic. Nothing listens on the internet, so a machine at home behind a router works
exactly as well as a cloud server — no ports, no public IP, no tunnel.

## Install it by asking Claude

Open Claude Code on the computer you want to use as your brain (or the Claude app attached
to it) and say:

> **claude help me install claude brain at https://github.com/mattvv/claude-brain**

Claude reads the repo's install guide and walks you through it, asking:

1. **Where should your brain live?** — this computer, another computer over SSH, or a new
   DigitalOcean droplet it creates for you.
2. **How much of the machine does it get?** — its own working folder, or the run of the
   whole machine (the droplet default).
3. **Which accounts should it use?** — Claude is required; ChatGPT, Grok, Kimi, and GitHub
   are each optional and can be added later.
4. **Phone control?** — set up the Remote Control server so sessions show up in the Claude
   app.
5. **Always on?** — start at boot, and stop the machine from sleeping.

It shows you the plan before it changes anything, then runs it, hands you each login link
in chat, and finishes with a health check.

Details for each path: [installing on your own computer](docs/install-local.md) ·
[installing on a DigitalOcean droplet](docs/install-digitalocean.md).

**Prefer a terminal?** Same flow, no agent:

```bash
curl -fsSL https://raw.githubusercontent.com/mattvv/claude-brain/main/install.sh | bash
```

It asks the same questions. Every answer is also a flag, so you can script it:
`install.sh --here --scope workspace --link chatgpt,github --autostart --yes`.

## Where can a brain live?

| Host | Cost | Always on? | Notes |
|---|---|---|---|
| **Mac mini / iMac / any desktop Mac** | free (you own it) | yes, with `brain autostart` | The sweet spot: quiet, cheap, always plugged in. Enable auto-login so it comes back after a reboot. |
| **Linux desktop or home server** (Arch, Ubuntu, Debian) | free | yes, with `brain autostart` | Same story. Runs as your user; no root daemon. |
| **A spare laptop** | free | only while awake and plugged in | Fine for trying it out. A laptop that sleeps is not a brain — keep the lid open and the charger in, or use one of the options above. |
| **DigitalOcean droplet** | ~$12/month | yes, by definition | Nothing of yours to keep awake. The installer can create and configure it for you. |
| **Another computer you can SSH to** | — | depends on that machine | `install.sh --ssh you@host` installs remotely and hands back the same commands. |

Supported: **macOS** (Apple Silicon and Intel), **Arch Linux**, **Ubuntu/Debian**. Other
Linux distributions usually work — the installer will tell you it's untested rather than
guessing silently.

## What you need

- A **Claude subscription** (Pro or Max) — this is the brain itself. Required.
- A computer to run it on, from the table above. Required.
- Optional, each adds a model to your brain: a **ChatGPT** subscription, a **Grok** (X.AI)
  subscription, a **Kimi** subscription.
- Optional: a **GitHub account**, if you want your brain to read and write your code.

## Your first phone session

1. On your brain machine, run `brain`. This starts a persistent Remote Control server —
   one session is ready immediately, and you can spawn more whenever you like.
   (`brain autostart enable` makes that happen by itself after a reboot.)
2. Open the Claude app on your phone (**Code** tab), or claude.ai/code in any browser.
   Your brain's sessions appear there — attach to one, or start a new one, from anywhere.

Close your laptop; everything keeps running on the brain.

Want a second opinion from another model mid-conversation? Just ask — e.g. *"have
brain-grok double-check this"* or *"ask brain-sol to review this diff"*. Claude delegates
to the router and brings the answer back.

**Your brain manages itself.** From that same phone session you can just ask it to:
- *"link my ChatGPT account"* — it starts the login and sends you the URL and code to tap;
- *"link my Grok account"* — same, you tap the link, then paste the address it lands on back into chat;
- *"install &lt;some tool&gt;"* or *"add the &lt;X&gt; MCP server"* — it installs and configures it;
- *"update yourself"* — it pulls the latest claude-brain release.

Skipping a login during setup is fine — you can always link accounts later this way,
without ever touching a terminal.

On your own computer it asks before changing anything outside its workspace, and it tells
you when a step needs your password. On a droplet it just does it.

## Seeing what your brain builds

When your brain is building you a web app, you'll want to open it. That works through
[Tailscale](https://tailscale.com) (free), which puts your phone and your brain on a
private network — no ports ever open to the internet:

1. Install the Tailscale app on your phone and sign in (Google/Apple/GitHub account works).
2. Ask your brain to *"set up tailscale"* — it sends you an approval link, you tap it. Once.
3. From then on: *"show me the app"* gets you a private `https://…ts.net` link that opens
   right on your phone. Ask for a **public** link when you want to send it to a friend —
   and tell your brain to *"stop sharing"* when you're done.

Tailscale is also the easiest way to reach a brain at home from a coffee shop.

## Everyday use

| Command | What it does |
|---|---|
| `brain` | Start/attach the phone-control server (spawn as many sessions as you like from the app) |
| `brain repo add <owner/name>` | Clone one of your GitHub repos and serve phone sessions for it (`repo ls` / `repo serve` / `repo stop`) — or just ask your brain to do it |
| `brain status` | Health check: host, router, linked accounts, sessions |
| `brain autostart enable` | Come back automatically after a reboot (`disable` / `status`) |
| `brain multi` | Power mode: other models drive natively — no phone control in this mode |
| `brain expose <port>` | See a web app your brain is building — private HTTPS link for your devices (add `--public` to share with anyone, `off` to stop) |
| `brain auth <thing>` | Redo any login: `anthropic` `chatgpt` `grok` `kimi` `github` `tailscale` |
| `brain compress savings` | See how many tokens the compression engine has saved (and `status` / `discover` / `off`) |
| `brain update` | Get the latest claude-brain (`brain` also checks at startup and prompts) |
| `brain uninstall` | Remove claude-brain and put your Claude Code config back the way it was |

Run them on the brain machine — at its own keyboard, over SSH, or by asking a phone session
to run them for you.

**What's `brain multi`?** In your normal session, Claude is always the brain and other
models are consultants. `brain multi` flips that: agents *run natively as* GPT/Grok/Kimi
with full tool access, parable-style. The trade-off: phone control (Remote Control) is
technically impossible in that mode, so you use it at a terminal.

## Saving tokens (the compression engine)

A long-running brain reads a lot of verbose output — test logs, diffs, `git log`, whole
files — and re-sends context to consultants on every follow-up. claude-brain ships a local
**compression engine** (`brain-compress`) that trims that waste while keeping the exact
original one command away. It's on by default and needs no configuration.

What it does:

- **Compacts shell output automatically.** When your brain runs an eligible command
  (`git log`/`diff`, test runners, `grep`, `find`, …), a hook reroutes it through the engine:
  the command runs once, its full output is saved, and the model sees a compact view — e.g. a
  10 KB `git log` becomes ~200 bytes. The full original is always recoverable with
  `brain compress show <id> --full`.
- **Leaner file reads.** `brain compress read <file> --outline` (just the signatures),
  `--query '<goal>'` (matching regions), or `--lines A:B` instead of pulling a huge file whole.
- **Cheaper consultations.** When your brain asks Grok/GPT/Kimi about files, it hands over the
  *paths* (`brain-ask --context-file`) so the file bytes never fill its own context twice, and
  can request a terser answer (`--response review|debug|concise`).
- **Honest measurement.** `brain compress savings` reports three separate numbers —
  provider-reported ground truth, exact bytes saved, and a labelled token estimate — and never
  blends them into one inflated figure. `brain compress off` disables everything instantly.

The guarantee: **nothing is ever silently dropped.** Every compacted view carries a recovery
handle, and errors, diffs, and anything about to be edited are never compressed. Under the
hood it uses [RTK](https://github.com/rtk-ai/rtk) as a filter library, wrapped in a native
Rust binary that owns storage, safety, and accounting. Details:
[docs/compression-plan.md](docs/compression-plan.md) and
[docs/compression-capabilities.md](docs/compression-capabilities.md).

## Costs

- **On a computer you own: nothing.** It uses the electricity of a machine that's already on.
- **On DigitalOcean: ~$12/month** for the default size (`s-1vcpu-2gb`), billed hourly.
  Powering off in the DO console still bills (the disk is kept). To stop paying, **destroy**
  the droplet — but that erases all logins; next time you start over.
- Model usage rides on the subscriptions you already pay for. claude-brain adds no fees.

## Troubleshooting

The quick ones — full list in [docs/troubleshooting.md](docs/troubleshooting.md):

- **"The login code expired"** → just re-run it: `brain auth <thing>`.
- **`brain status` shows the router unhealthy** → restart it: `brain status` prints the exact
  command for your machine (`systemctl --user restart cli-proxy-api` on Linux,
  `launchctl kickstart -k gui/$UID/sh.claude-brain.proxy` on macOS).
- **Phone can't find the session** → make sure `brain` is running on the brain machine.
- **The brain vanished after a reboot** → `brain autostart status`. On a Mac, a brain only
  comes back once someone is logged in — turn on auto-login for a dedicated machine.
- **Your Mac keeps falling asleep** → `brain keepawake` (it shows you what it will change).

## Security notes

- The model router listens on **localhost only** — it is never reachable from the internet,
  on any host. `brain status` fails loudly if that ever stops being true.
- Nothing about claude-brain opens a port. Dev servers are shared through Tailscale
  (`brain expose`); public Funnel links are explicit and stopped with `brain expose off`.
- Never share the files in `~/.config/brain/` or `~/.cli-proxy-api/`: they hold live login
  tokens for your accounts. On a personal machine, keep full-disk encryption on.
- On your own computer, claude-brain backs up your Claude Code settings before touching
  them, and `brain uninstall` puts everything back.
- On a droplet: SSH only (key-based, no passwords, no root login), automatic security
  updates, and `doctl compute droplet delete claude-brain` wipes it all.

## How it works

Curious about the internals (and why phone control and native multi-model routing can't
share one session)? See [docs/architecture.md](docs/architecture.md). The plan for
running on any machine is in
[docs/deploy-anywhere-plan.md](docs/deploy-anywhere-plan.md).

## License

MIT — see [LICENSE](LICENSE).
