# claude-brain 🧠

**Your own Claude, running 24/7 on a small cloud computer, controlled from your phone.**

claude-brain sets up a personal AI server (a $12/month DigitalOcean "droplet") that runs
[Claude Code](https://claude.com/claude-code) around the clock. You open the Claude app on
your phone or [claude.ai/code](https://claude.ai/code) in a browser, attach to your brain,
and give it work. It keeps going even when your laptop is closed.

The twist: your brain isn't limited to Claude. It has a built-in **model router** that can
also consult **Grok**, **GPT**, and **Kimi** — using your own subscriptions to those
services — and it can work directly on your **GitHub** repositories.

```
   your phone / laptop                     your droplet ("the brain")
  ┌──────────────────┐   Remote Control   ┌────────────────────────────┐
  │ Claude app        │ ◄───────────────► │ Claude Code (always on)    │
  │ claude.ai/code    │                   │   ├── brain-grok  ─┐       │
  └──────────────────┘                   │   ├── brain-sol   ─┼─► model router
                                          │   ├── brain-kimi  ─┘  (Grok/GPT/Kimi)
                                          │   └── your GitHub repos    │
                                          └────────────────────────────┘
```

## What you need

- A **Claude subscription** (Pro or Max) — this is the brain itself. Required.
- A **DigitalOcean account** — the cloud computer, about $12/month. Required.
- A Mac or Linux **laptop** for the one-time setup. Required.
- Optional, each adds a model to your brain: a **ChatGPT** subscription, a **Grok** (X.AI)
  subscription, a **Kimi** subscription.
- Optional: a **GitHub account**, if you want your brain to read and write your code.

## Step 1 — DigitalOcean account and API token

1. Sign up at [digitalocean.com](https://www.digitalocean.com) if you haven't.
2. Open <https://cloud.digitalocean.com/account/api/tokens>.
3. Click **Generate New Token**. Name it `claude-brain`, allow **Read and Write**.
4. Copy the token somewhere safe for a minute. **Treat it like a password.**

## Step 2 — run the setup command

Open the Terminal app on your laptop, paste this, and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/mattvv/claude-brain/main/setup.sh | bash
```

It will:
- install the small DigitalOcean helper tool (`doctl`) and ask you to paste your token,
- create an SSH key for you if you don't have one,
- ask a few questions (just press Enter to accept the defaults),
- create the droplet and wait ~5–10 minutes while it installs itself.

> Don't like terminals? There's a click-through alternative:
> [docs/manual-setup.md](docs/manual-setup.md).

## Step 3 — link your accounts

When step 2 finishes it offers to connect you straight to the droplet and run the
setup wizard. Say yes (or later: `ssh claude-brain`, then `brain setup`).

The wizard walks you through each login, one at a time. The pattern is always the same:
**it prints a web link and a code — open the link on your laptop or phone, enter the code,
approve.** In order:

1. **Claude** — required. This is your brain's mind.
2. **ChatGPT** — optional, adds the GPT models.
3. **Grok** — optional.
4. **Kimi** — optional.
5. **GitHub** — optional, lets your brain clone and push your repositories.

Everything is skippable and re-runnable: `brain auth chatgpt`, `brain auth github`, etc.

## Step 4 — your first phone session

1. On the droplet, run `brain`. Claude starts inside a persistent session.
2. Type `/remote-control` inside Claude. It prints a link.
3. Open the Claude app on your phone (or claude.ai/code) — your brain's session appears.
   Attach, and drive it from anywhere.

Close your laptop; the session keeps running on the droplet.

Want a second opinion from another model mid-conversation? Just ask — e.g. *"have
brain-grok double-check this"* or *"ask brain-sol to review this diff"*. Claude delegates
to the router and brings the answer back.

## Everyday use

| Command | What it does |
|---|---|
| `brain` | Start/attach your main session (the one with phone control) |
| `brain status` | Health check: router, linked accounts, sessions |
| `brain multi` | Power mode: other models drive natively — no phone control in this mode |
| `brain auth <thing>` | Redo any login: `anthropic` `chatgpt` `grok` `kimi` `github` |
| `brain update` | Get the latest claude-brain |

All run on the droplet, after `ssh claude-brain`.

**What's `brain multi`?** In your normal session, Claude is always the brain and other
models are consultants. `brain multi` flips that: agents *run natively as* GPT/Grok/Kimi
with full tool access, parable-style. The trade-off: phone control (Remote Control) is
technically impossible in that mode, so you use it at a terminal over SSH.

## Costs

- The droplet: ~$12/month for the default size (`s-1vcpu-2gb`). Billed hourly.
- Powering off in the DO console still bills (the disk is kept). To stop paying,
  **destroy** the droplet — but that erases all logins; next time you start from Step 2.

## Troubleshooting

The quick ones — full list in [docs/troubleshooting.md](docs/troubleshooting.md):

- **"The login code expired"** → just re-run it: `brain auth <thing>`.
- **`brain status` shows the router unhealthy** → `systemctl --user restart cli-proxy-api`, wait 10s.
- **Phone can't find the session** → make sure `brain` is running on the droplet and you ran `/remote-control` inside it.
- **`ssh claude-brain` says permission denied** → your SSH key changed; see the troubleshooting doc.

## Security notes

- The droplet accepts **SSH only** (key-based, no passwords, no root login) and updates
  itself with security patches automatically.
- The model router listens only inside the droplet — it is never reachable from the internet.
- Never share the files in `~/.config/brain/` or `~/.cli-proxy-api/` on the droplet: they
  hold live login tokens for your accounts.
- Done with everything? `doctl compute droplet delete claude-brain` wipes it all.

## How it works

Curious about the internals (and why phone control and native multi-model routing can't
share one session)? See [docs/architecture.md](docs/architecture.md).

## License

MIT — see [LICENSE](LICENSE).
