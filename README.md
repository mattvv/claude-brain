# claude-brain 🧠

**Your own Claude, running 24/7 on a small cloud computer, controlled from your phone.**

claude-brain sets up a personal AI server (a $12/month DigitalOcean "droplet") that runs
[Claude Code](https://claude.com/claude-code) around the clock. You open the Claude app on
your phone or [claude.ai/code](https://claude.ai/code) in a browser, attach to your brain,
and give it work. It keeps going even when your laptop is closed.

The twist: your brain isn't limited to Claude. It has a built-in **model router** that can
also consult **Grok**, **GPT**, and **Kimi** — using your own subscriptions to those
services — and it can work directly on your **GitHub** repositories.

claude-brain is two things working together: a **model router** (one Claude session that
delegates to other model families) and a **compression tool** (a local engine that shrinks
the tokens flowing to and from every model, so long-running work stays cheap). Both run on
the droplet; both are on by default.

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

1. On the droplet, run `brain`. This starts a persistent Remote Control server —
   one session is ready immediately, and you can spawn more whenever you like.
2. Open the Claude app on your phone (**Code** tab), or claude.ai/code in any browser.
   Your brain's sessions appear there — attach to one, or start a new one, from anywhere.

Close your laptop; everything keeps running on the droplet.

Want a second opinion from another model mid-conversation? Just ask — e.g. *"have
brain-grok double-check this"* or *"ask brain-sol to review this diff"*. Claude delegates
to the router and brings the answer back.

**Your brain manages itself.** From that same phone session you can just ask it to:
- *"link my ChatGPT account"* — it starts the login and sends you the URL and code to tap;
- *"link my Grok account"* — same, you tap the link, then paste the address it lands on back into chat;
- *"install &lt;some tool&gt;"* or *"add the &lt;X&gt; MCP server"* — it installs and configures it on the droplet;
- *"update yourself"* — it pulls the latest claude-brain release.

Skipping a login during setup is fine — you can always link accounts later this way,
without ever touching a terminal.

## Seeing what your brain builds

When your brain is building you a web app, you'll want to open it. That works through
[Tailscale](https://tailscale.com) (free), which puts your phone and your droplet on a
private network — no ports ever open to the internet:

1. Install the Tailscale app on your phone and sign in (Google/Apple/GitHub account works).
2. Ask your brain to *"set up tailscale"* — it sends you an approval link, you tap it. Once.
3. From then on: *"show me the app"* gets you a private `https://…ts.net` link that opens
   right on your phone. Ask for a **public** link when you want to send it to a friend —
   and tell your brain to *"stop sharing"* when you're done.

## Everyday use

| Command | What it does |
|---|---|
| `brain` | Start/attach the phone-control server (spawn as many sessions as you like from the app) |
| `brain repo add <owner/name>` | Clone one of your GitHub repos and serve phone sessions for it (`repo ls` / `repo serve` / `repo stop`) — or just ask your brain to do it |
| `brain status` | Health check: router, linked accounts, sessions |
| `brain multi` | Power mode: other models drive natively — no phone control in this mode |
| `brain expose <port>` | See a web app your brain is building — private HTTPS link for your devices (add `--public` to share with anyone, `off` to stop) |
| `brain auth <thing>` | Redo any login: `anthropic` `chatgpt` `grok` `kimi` `github` `tailscale` |
| `brain compress savings` | See how many tokens the compression engine has saved (and `status` / `discover` / `off`) |
| `brain explore "<question>"` | Ask a cheap model to navigate the repo and answer, so the brain doesn't read files itself |
| `brain recall "<query>"` | Search your past sessions for a command/decision/fix (opt-in; enable in `brain setup`) |
| `brain update` | Get the latest claude-brain (`brain` also checks at startup and prompts) |

All run on the droplet, after `ssh claude-brain`.

**What's `brain multi`?** In your normal session, Claude is always the brain and other
models are consultants. `brain multi` flips that: agents *run natively as* GPT/Grok/Kimi
with full tool access, parable-style. The trade-off: phone control (Remote Control) is
technically impossible in that mode, so you use it at a terminal over SSH.

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
  `brain compress refs <symbol>` finds definitions, references, and callers via a real
  tree-sitter parser instead of reading everything.
- **Navigate instead of read.** `brain explore "how does X flow through the system"` sends a
  small, locally-gathered pack to a *cheap* model and returns one dense, cited answer — so the
  expensive brain never reads a pile of files just to orient itself. The cheap model is a
  configurable fallback chain (`[explore] models`, default `gpt-5.6-luna,grok-4.5`).
- **Cheaper consultations.** When your brain asks Grok/GPT/Kimi about files, it hands over the
  *paths* (`brain-ask --context-file`) so the file bytes never fill the brain's *own* context
  twice, and it can ask the consultant for a terser answer (`--response debug|concise|…`) at the
  right effort for the vendor.
- **Recall past work (opt-in).** `brain recall "<what you're looking for>"` searches your past
  Claude Code sessions for the one command/decision/fix you need, instead of re-deriving it.
  Off by default; `brain setup` offers to enable it (it reads your transcripts, so it asks first).
- **Honest measurement.** `brain compress savings` reports three separate numbers —
  provider-reported ground truth, exact bytes saved, and a labelled token estimate — and never
  blends them into one inflated figure. `brain compress off` disables everything instantly.

**Typical savings** (measured on this project, not advertised):

- **Command & file output — the big, reliable win.** Verbose output shrinks **~60–95%** before
  it reaches the model: a 20-line `git log` went 10,881 → ~320 bytes (~97%), a recursive `grep`
  16,573 → 4,783 bytes (~71%). Every byte stays recoverable.
- **Consultation answers — depends on model + effort.** Asking a consultant for a task-matched
  terse answer cut its *generated* output by **20–40%** on debugging/config/architecture
  questions (Grok-4.5, 30-call-per-arm A/B). On other question types the lever is the model and
  its effort setting, not the wording: the same profile that did nothing on Grok cut GPT/Luna
  output ~**34%** overall, and dropping Grok to low effort cut review output **~80%** while still
  catching every seeded bug. So the brain tunes profile + effort per vendor. Handing over file
  *paths* saves the brain from re-holding those files in its own context — a separate, brain-side
  saving. `brain compress savings` splits all of this into honest classes; the full A/B is in the
  docs below.

The guarantee: **nothing is ever silently dropped.** Every compacted view carries a recovery
handle, and errors, diffs, and anything about to be edited are never compressed. Under the
hood it uses [RTK](https://github.com/rtk-ai/rtk) as a filter library, wrapped in a native
Rust binary that owns storage, safety, and accounting. Details:
[docs/compression-plan.md](docs/compression-plan.md) and
[docs/compression-capabilities.md](docs/compression-capabilities.md).

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
- Dev servers are shared through Tailscale (`brain expose`), never by opening ports.
  Public Funnel links are explicit and stopped with `brain expose off`.
- Never share the files in `~/.config/brain/` or `~/.cli-proxy-api/` on the droplet: they
  hold live login tokens for your accounts.
- Done with everything? `doctl compute droplet delete claude-brain` wipes it all.

## How it works

Curious about the internals (and why phone control and native multi-model routing can't
share one session)? See [docs/architecture.md](docs/architecture.md).

## License

MIT — see [LICENSE](LICENSE).
