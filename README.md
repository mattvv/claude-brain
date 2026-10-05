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

## Moving a session to another brain (teleport)

Got more than one brain — say a laptop and a Linux box at home? Tell a session
*"teleport this to mattvv-linux"* (or run `brain teleport <machine>` in it) and it moves,
mid-conversation, with its code:

- **The conversation** — the whole transcript, so the session remembers everything.
- **The code, exactly as it is** — branch, unpushed commits, and uncommitted and untracked
  changes. Your checkout is never touched; the work is rebuilt on the other machine in a
  fresh git worktree *inside the checkout that already hosts the repo there* — say
  `~/Documents/navigate/core/.claude/worktrees/teleport-…` — found by its origin wherever
  it lives (cloned into `~/repos/` first if that machine doesn't have it).

Within about a minute it shows up in the Claude app under the other machine, ready to carry
on. Once that machine confirms, the original session closes; if no confirmation comes back
within ten minutes, the original simply stays open. A session started outside a git repo
moves its conversation only, and lands in the same folder on the other machine (same path
under home, else a folder with that name) — or an empty one if there's no match.

It travels over Taildrop, Tailscale's file sharing between your own devices — no ports, no
SSH. To set up a machine to **receive** sessions (once):

1. Put it on your tailnet and turn on `brain autostart enable` — the every-minute watchdog
   is what picks up arriving sessions.
2. On Linux, let brain read Taildrop without sudo: `sudo tailscale set --operator=$USER`.

**It stays on the same Claude account.** With [account sets](#work-and-personal-accounts), a
session lands in whichever set on the other machine is signed in to the same Claude account
and organization — set names don't have to match (your work login can be `default` on one
machine and `work` on another). If no set there has that login, the session is refused rather
than run on another account: sign one in (`brain auth anthropic --account <set>`), then
`brain teleport retry`.

It arrives named after the conversation's title (plus where it came from), and opens with a
short recap of what it was doing, so you can pick up straight from your phone.

`tailscale file cp --targets` lists the machines you can send to; `brain teleport log`
shows what came and went.

## Opening a session in your terminal (attach)

Sessions you start from the Claude app run on your brain with no terminal attached. When
you'd rather drive one from a real terminal on that machine — or you closed one by accident
— `brain attach` gets you there:

```
brain attach            # recent sessions on this machine: title, folder, account set, state
brain attach twilio     # open the one whose title matches (or give an id prefix)
```

It reopens the conversation in its own folder, **under the account set it belongs to** (a
work session opens with your work login, not your personal one), still connected to the
Claude app. It runs inside tmux: `Ctrl-b d` steps out and leaves it running, and
`brain attach twilio` again puts you back.

- **Closed** → reopened right away.
- **Running on your brain from the app** → it asks first, then moves it into your terminal.
  Same history; the app gets a new entry for it (a running session can't be handed between
  processes).
- **Already open in another terminal** → refused, with which terminal has it, so the same
  conversation never runs twice.
- **On another of your machines** → if nothing here matches — or this machine's copy was
  teleported away — it asks your other brains, shows where the session is and whether it's
  running there, and offers to bring it over (a teleport, ending the copy there only if you
  say so). It lands within a minute or two and you're attached.

## Everyday use

| Command | What it does |
|---|---|
| `brain` | Start/attach the phone-control server (spawn as many sessions as you like from the app) |
| `brain repo add <owner/name>` | Clone one of your GitHub repos and serve phone sessions for it (`repo ls` / `repo serve` / `repo stop`) — or just ask your brain to do it |
| `brain account add <name>` | A second set of logins (say, your work Claude + ChatGPT) kept fully apart from your own — then `brain auth anthropic --account <name>`, `brain auth chatgpt --account <name>` and `brain repo add <owner/name> --account <name>`. See [Work and personal accounts](#work-and-personal-accounts) |
| `brain status` | Health check: host, router, linked accounts, sessions |
| `brain autostart enable` | Come back automatically after a reboot, and restart the server within a minute if it dies (e.g. after a long sleep) — `disable` / `status` |
| `brain attach [words]` | Open a session in this terminal — list recent ones, or pick one by words from its title; brings it over from another machine if that's where it is ([details](#opening-a-session-in-your-terminal-attach)) |
| `brain teleport <machine>` | Move this session — conversation, branch and uncommitted work — to the brain on another machine ([details](#moving-a-session-to-another-brain-teleport)) |
| `brain multi` | Power mode: other models drive natively — no phone control in this mode |
| `brain expose <port>` | See a web app your brain is building — private HTTPS link for your devices (add `--public` to share with anyone, `off` to stop) |
| `brain auth <thing>` | Redo any login: `anthropic` `chatgpt` `grok` `kimi` `github` `tailscale` |
| `brain compress savings` | See how many tokens the compression engine has saved (and `status` / `discover` / `off`) |
| `brain usage` | See how much of each subscription is left, and who can still take work (`override <min>` to spend the reserve anyway) |
| `brain explore "<question>"` | Ask a cheap model to navigate the repo and answer, so the brain doesn't read files itself |
| `brain recall "<query>"` | Search your past sessions for a command/decision/fix (opt-in; enable in `brain setup`) |
| `brain update` | Get the latest claude-brain. New sessions (phone included) and the statusline say when one is out, and `brain status` checks on demand |
| `brain config autoupdate on` | Let the brain install releases itself: at most once a day, only on a clean `main` checkout, never mid-consultation. The next session says it updated |
| `brain uninstall` | Remove claude-brain and put your Claude Code config back the way it was |

### Work and personal accounts

One brain can hold more than one set of logins. Your own Claude and ChatGPT stay the
`default` set; an extra set — say `work` — gets its own Claude login, its own ChatGPT/Grok/
Kimi links, its own router process, token and port, and its own usage numbers. Repos are
pinned to a set, so a work repo's phone sessions run on the work Claude account and its
`brain-*` consultants bill the work ChatGPT account — never yours, and never by accident.

```sh
brain account add work                         # router + ~/.claude-work, ready for logins
brain auth anthropic --account work            # sign in to the work Claude account
brain auth chatgpt --account work              # and its ChatGPT account
brain repo add my-org/core --account work      # clone + serve, pinned to work
brain account ls                               # every set, its logins and its repos
```

Any command takes `--account <name>` (`brain status --account work`, `brain usage
--account work`). `brain repo serve` remembers each repo's set. The new set starts with a
copy of your own `~/.claude/CLAUDE.md` instructions and links to your skills; MCP servers,
plugins and connectors belong to an account, so add the work ones in a work session.
In the Claude app, work sessions show up under the work Claude account.

Run them on the brain machine — at its own keyboard, over SSH, or by asking a phone session
to run them for you.

**What's `brain multi`?** In your normal session, Claude is always the brain and other
models are consultants. `brain multi` flips that: agents *run natively as* GPT/Grok/Kimi
with full tool access, parable-style. The trade-off: phone control (Remote Control) is
technically impossible in that mode, so you use it at a terminal.

## Spreading the load (usage-aware routing)

You are paying for several subscriptions. They have separate limits, and spending one does
not spend the others — so when your Claude window runs low, the brain should move work onto
a model that still has room instead of grinding to a halt.

`brain usage` shows where you stand:

```
claude subscription
  session                 17% used
  weekly_all              37% used
  weekly_scoped_fable     66% used ← binding
 ! headroom 34% · resets in 132h 22m — prefer consultants for heavy work

consultant vendors
  chatgpt    headroom 98% (weekly 2% used, secondary 0%) · plan prolite
  grok       linked · headroom not measurable (no usage endpoint)
  kimi       not linked — brain auth kimi
```

What the brain does with that, automatically:

- **Plenty left** — nothing changes.
- **Running low** (below 35% headroom by default) — the brain is told the live number at the
  moment it picks where to send work, and steers implementation, review, and bulk reading
  through a `brain-*` consultant instead of doing it in-session.
- **At the reserve** (below 15% by default) — dispatching an *Anthropic-backed* subagent is
  blocked outright. Your session keeps working: the reserve exists precisely so it can. The
  `brain-*` consultants are never blocked, so there is always a way forward.

```
brain config usage block|advisory|off    # how firm the guard is (default: block)
brain config usage reserve 15            # how much Claude quota to keep back
brain config usage probe off             # stop reading ChatGPT headroom (see below)
brain usage override 30                  # spend the reserve anyway, for 30 minutes
```

**What is and isn't measured.**

- **Anthropic** publishes per-window utilisation on a free endpoint. This is the number the
  reserve protects.
- **ChatGPT** reports usage too, but only as `x-codex-*` headers riding along on a real
  request — there is no endpoint that just tells you. So `brain usage` sends one minimal
  turn (**~21 tokens**, at most every 15 minutes) and keeps the headers. If you would rather
  not spend anything at all: `brain config usage probe off`, and ChatGPT goes back to being
  reported as unread rather than guessed at.
- **Grok and Kimi** expose nothing reachable, and are reported as *linked, headroom not
  measurable* — never a number we cannot actually see.

Every vendor also has a free negative signal: the router records when one has hit its own
quota, and a vendor in cooldown drops out of the rotation until it recovers. A consultant
vendor that is itself at the reserve stops being offered as a destination — the point is to
spread load across subscriptions, not to move a wall from one to another.

Every part of this fails open. An expired token, a changed endpoint, no network, or a
payload we do not recognise all mean "unknown", and unknown never blocks anything. Nor does
the guard ever block when no consultant is linked — there would be nowhere for the work to
go.

## Saving tokens (the compression engine)

A long-running brain reads a lot of verbose output — test logs, diffs, `git log`, whole
files — and re-sends context to consultants on every follow-up. claude-brain ships a local
**compression engine** (`brain-compress`) that trims that waste while keeping the exact
original one command away. It's on by default and needs no configuration.

What it does:

- **Compacts shell output automatically.** When your brain runs an eligible command
  (`git log`/`diff`, test runners, `grep`, `find`, and file reads via `cat`/`head`/`tail`/`sed -n`),
  a hook reroutes it through the engine: the command runs once, its full output is saved, and the
  model sees a compact view — e.g. a 10 KB `git log` becomes ~200 bytes. The full original is
  always recoverable with `brain compress show <id> --full`.
  Eligibility is judged per command, not per line, so `cd repo && git log` compacts the `git log`
  and leaves the `cd` alone. Commands whose output is piped, redirected, or built in a subshell or
  heredoc are never rewritten — `brain compress discover` lists those misses. Output under 2 KB,
  and anything the caller already bounded (`git log -40`), is handed over whole: a lossy view you
  then have to recover costs more than it saves.
- **Leaner file reads.** `brain compress read <file> --outline` (just the signatures),
  `--query '<goal>'` (matching regions), or `--lines A:B` instead of pulling a huge file whole.
  `brain compress refs <symbol>` finds definitions, references, and callers via a real
  tree-sitter parser instead of reading everything.
- **Navigate instead of read.** `brain explore "how does X flow through the system"` sends a
  small, locally-gathered pack to a *cheap* model and returns one dense, cited answer — so the
  expensive brain never reads a pile of files just to orient itself. The cheap model is a
  configurable fallback chain (`[explore] models`, default `gpt-6-luna,grok-4.5`).
- **Cheaper consultations.** When your brain asks Grok/GPT/Kimi about files, it hands over the
  *paths* (`brain-ask --context-file`) so the file bytes never fill the brain's *own* context
  twice, and it can ask the consultant for a terser answer (`--response debug|concise|…`) at the
  right effort for the vendor.
- **Recall past work (opt-in).** `brain recall "<what you're looking for>"` searches your past
  Claude Code sessions for the one command/decision/fix you need, instead of re-deriving it.
  Off by default; `brain setup` offers to enable it (it reads your transcripts, so it asks first).
- **Honest measurement.** `brain compress savings` reports three separate numbers —
  provider-reported ground truth, exact bytes saved, and a labelled token estimate — and never
  blends them into one inflated figure. Recovering an artifact (`brain compress show … --full`)
  is *debited* from the saving, so the figure reflects what compression actually netted rather
  than only its wins. `brain compress off` disables everything instantly.

**Typical savings** (measured on this project, not advertised):

- **Command & file output — the big, reliable win.** Verbose output shrinks **~60–95%** before
  it reaches the model: a `git log` went 10,881 → ~320 bytes (~97%), a recursive `grep`
  16,573 → 4,783 bytes (~71%). Every byte stays recoverable.
  *Coverage matters as much as ratio.* Replaying 1,336 Bash calls from real sessions, the engine
  now rewrites **50.5% of all command-output bytes** and cuts them by **43.7%** — against 0.02%
  of bytes before eligibility became per-command (see H14 in the capabilities doc).
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
- **Sessions went offline after the laptop slept** → with `brain autostart enable` the
  server is back within a minute of waking. It brings back its most recent session; start
  new ones for the rest (their history is still on disk).
- **Closed a session by accident** → `brain attach <words from its title>` reopens it under
  the right login, in its folder, and back on the Claude app.
- **A teleported session never showed up** → `brain teleport log` on both machines. The
  usual causes: the target's watchdog is off (`brain autostart status`), or on Linux
  Tailscale isn't letting brain read Taildrop (`sudo tailscale set --operator=$USER`).

## Security notes

- The model router listens on **localhost only** — it is never reachable from the internet,
  on any host. `brain status` fails loudly if that ever stops being true.
- Nothing about claude-brain opens a port. Dev servers are shared through Tailscale
  (`brain expose`); public Funnel links are explicit and stopped with `brain expose off`.
- Teleport sends sessions over Taildrop, which only moves files between your own devices.
  A teleported package holds the conversation and your uncommitted code, so it goes nowhere
  else; anything arriving by Taildrop that isn't a teleport is moved to `~/Downloads`.
- `brain attach` can ask your other brains which sessions they have (titles, folders, and
  whether each is running) and ask one to send a session over. Only your own devices can
  Taildrop to a brain, a running session there is only ended when you say so, and every
  request is logged in `brain teleport log`.
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
