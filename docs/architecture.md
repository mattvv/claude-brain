# Architecture

claude-brain is a remix of [Parable](https://parable.sh)-style multi-model routing,
re-designed around one goal: **sessions you can drive from your phone** via Claude Code's
Remote Control — on any computer you own, not just a rented VM.

## Why it can live anywhere

Remote Control is **outbound**: the brain connects to `api.anthropic.com`, the phone
connects to `api.anthropic.com`, and they meet there. The model router listens on
`127.0.0.1` only. Nothing in the design needs an inbound connection, so a Mac mini behind
a home router is as reachable as a droplet with a public IP — no ports, no tunnel, no
dynamic DNS. The cloud VM is a convenience for people without an always-on machine, not
an architectural requirement.

## The core constraint

Claude Code's Remote Control (attach from the Claude app / claude.ai/code) only works when
the session talks directly to `api.anthropic.com`. Parable's trick — pointing the whole
session at a local proxy with `ANTHROPIC_BASE_URL` so agents can run natively as other
models — breaks Remote Control the moment it's applied. One session cannot have both.

claude-brain resolves this with **two lanes**:

## Lane 1 — the RC lane (`brain`, the default)

```
phone/app ◄── Remote Control ──► claude (native Anthropic auth, tmux: brain-rc)
                                   │
                                   ├─ Agent: brain-grok ──┐
                                   ├─ Agent: brain-sol    ├─ Bash: brain-ask <model>
                                   └─ Agent: brain-kimi ──┘        │ HTTP (loopback)
                                                                   ▼
                                                    cli-proxy-api :8317 (systemd)
                                                     │ OAuth records ~/.cli-proxy-api
                                                     ▼
                                            xAI / OpenAI / Moonshot / Anthropic
```

- `brain` runs `claude remote-control` as a persistent server under tmux: one session is
  pre-created, and more spawn on demand from the Claude app / claude.ai/code (capacity 32,
  same-dir spawn mode; worktree isolation is a runtime toggle). It launches with
  `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_API_KEY` explicitly scrubbed from
  the environment, so Remote Control always works.
- The brain is always Claude. Other models are **consultants**: bridge agents
  (`host/claude/agents-rc/`) read the needed files, compose one self-contained prompt,
  and call the local router with the `brain-ask` CLI (`POST /v1/messages`, Anthropic wire
  format, bearer token from `~/.config/brain/token`).
- The router is stateless per call; multi-turn = re-send context.

## Lane 2 — the multi lane (`brain multi`)

```
ssh/tmux ──► claude  (env: ANTHROPIC_BASE_URL=http://127.0.0.1:8317)
               │ every request, parent and agents alike
               ▼
        cli-proxy-api :8317 ── fans out by model id
               │
    agents-multi/*.md pin models in frontmatter:
    brain-sol → gpt-5.6-sol, brain-grok → grok-4.5, ...
```

- Parable's original design: the whole session goes through the proxy, agents *are* the
  other models with full tool access.
- `CLAUDE_CODE_MAX_CONTEXT_TOKENS=372000` caps the context at the smallest window in the
  cast (the GPT models); the Claude parent uses the `[1m]` model suffix.
- No Remote Control in this lane — by platform constraint, not choice.

The two lanes share one agents directory (`~/.claude/agents/`), so launching a lane
installs its agent set and removes the other's. Don't run both lanes at once.

## Hosts, profiles and scope

One tree (`host/`) runs on every target. Everything that differs is either detected or
recorded, never hardcoded:

- **`host/lib/platform.sh`** is the only file that knows about macOS vs Linux: os/arch and
  distro detection, package-manager mapping (brew / pacman / apt / dnf), `sudo` mode,
  portable `stat`/`abs_path`/`timeout`/port checks, where Tailscale's CLI hides on macOS,
  and the service layer. Callers use the helpers; if a new platform difference appears, it
  goes here.
- **Services** are user-owned, never root daemons — they hold the user's OAuth credentials.
  systemd *user* units on Linux (`host/service/systemd/`), launchd *user agents* on macOS
  (`host/service/launchd/*.plist.tmpl`, rendered by `svc_install` because launchd has no
  `%h`). `svc_restart_hint` prints the correct command for the machine it runs on.
- **`PROFILE`** (`local` | `droplet`) decides how the machine is administered. Detected
  from the hardware vendor when unset, so an existing droplet keeps its behaviour across
  an update. Droplet-only things — `ufw`, `loginctl enable-linger`, `/etc/update-motd.d` —
  are gated on it and never run on someone's own computer.
- **`SCOPE`** (`workspace` | `machine`) is asked at setup on local machines and renders the
  ops instruction block: `host/claude/brain-ops-droplet.md` (owns the machine, passwordless
  sudo) or `host/claude/brain-ops-local.md` (asks first, may hit a password prompt it
  cannot answer, may be confined to a working root).
- **Always-on** is two separate promises: `brain autostart` (a user service that starts the
  RC server after a reboot) and `brain keepawake` (a system sleep setting — so it prints
  the exact commands and asks first). On macOS a launchd *agent* needs a logged-in user;
  `brain autostart status` says so rather than pretending.

Installing on a machine someone already uses is a guest relationship: `host/install.sh`
backs up `~/.claude/settings.json` once before the first change, refuses to take over a
statusline they already had, and records what it touched so `brain uninstall` can put it
all back.

## The router

A pinned, patched build of
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (Go):

- Pin + patch checksum live in `host/proxy/PIN`; `brain-proxy-build` verifies both
  before building. The vendored patch propagates `output_config.effort` →
  `reasoning.effort` for Claude→GPT translation.
- Listens on `127.0.0.1:8317` **only**. Config: `~/.config/brain/proxy-config.yaml`,
  bearer token: `~/.config/brain/token` (32 random bytes, hex).
- Vendor logins are OAuth *subscription* logins performed by the proxy binary itself
  (`--codex-device-login`, `--xai-login --no-browser`, ...). Credentials land in
  `~/.cli-proxy-api/` (0700, records 0600) and auto-refresh.
- Runs as a systemd **user** service (`host/systemd/cli-proxy-api.service`) with
  `Restart=always`; `loginctl enable-linger` keeps it alive without a login session.

## Routing intelligence

The proxy itself is dumb fan-out; task→model routing lives a layer up (parable's design):

- **Routing tables** (`host/claude/routing-rc.md`, `routing-multi.md`) — per-task-class
  preference orderings with fallbacks and effort guidance, adapted from parable's
  `[routing]` config. Launching a lane installs its table into the droplet's
  `~/.claude/CLAUDE.md` as a managed block, so the brain reads it every session.
- **Effort tiers** — easy classes route to cheap lanes at `low`/`medium` effort; hard
  classes climb to sol/fable at `xhigh`. Multi-lane efforts are pinned in agent
  frontmatter; the RC lane passes `--effort` per call through `brain-ask`.
- **Model guard** (`host/claude/hooks/model-guard.sh`) — a PreToolUse hook, modeled on
  parable's `model_guard.py`, that blocks delegation to a `brain-*` agent whose vendor
  isn't linked and tells the model the exact fix (`brain auth <vendor>`) plus "use the
  next fallback", instead of a raw HTTP error mid-task. Registered idempotently in
  `~/.claude/settings.json` by `host/install.sh`.

## Self-service operations

The brain administers its own machine. `host/claude/brain-ops.md` is installed into
`~/.claude/CLAUDE.md` (managed `ops` block, alongside the lane's `routing` block) and
tells every session it may install packages/MCP servers, update itself, and link vendor
accounts using the headless auth flow:

- `brain auth start <vendor>` runs the OAuth login in a detached tmux pane
  (`tmux pipe-pane` captures output) and prints the login URL — which a Claude session
  relays to the user's phone.
- ChatGPT's device flow completes on its own (`brain auth check chatgpt` polls).
- Grok/Kimi callbacks land on a dead `localhost` URL in the user's browser; the user
  pastes it back into chat and `brain auth paste <vendor> '<url>'` feeds it to the
  waiting login's pty via `tmux send-keys`.

Updates: `brain update` = `git pull` + re-run install (agents/hooks/routing/unit refresh)
+ proxy rebuild if the PIN changed + `claude update`. The `brain`/`brain multi` launchers
also `git fetch` at startup (8s timeout, silent on failure) and prompt when behind.

## Exposing dev servers

`ufw` never opens anything beyond SSH. Web apps the brain builds are shared via
Tailscale: `brain auth tailscale` joins the owner's tailnet (install-on-demand, approval
URL relayed to the phone, `ufw allow in on tailscale0` so tailnet traffic passes the
default-deny firewall), then `brain expose <port>` maps the port with `tailscale serve`
(tailnet-only HTTPS) or `--public` with `tailscale funnel` (world-reachable, revocable
via `brain expose off`). The raw droplet IP is deliberately never used for app traffic:
always-on dev servers on a public IP are scanner bait, and this box holds live OAuth
tokens.

## Provisioning

One installer, three targets. `install.sh` asks where the brain should live and then:

- `--here` — runs `host/bootstrap.sh` (dependencies for this platform), `host/install.sh`
  (wiring), the pinned router build, and `brain setup`.
- `--ssh user@host` — re-runs itself over there with the same flags.
- `--digitalocean` — `host/provision/digitalocean.sh` creates the droplet via doctl and
  hands off to `brain setup` over SSH.

Every question is also a flag and `--plan` prints the whole thing without executing, which
is what the agent-driven install (`docs/agent-install.md`) shows the user before touching
their machine.

`cloud-init.yaml` is deliberately **secret-free** (user-data is readable from the droplet
metadata endpoint) and now does only the genuinely DigitalOcean-shaped parts — user, SSH
keys, swap, sshd — then calls the same `host/bootstrap.sh` a local install uses. Everything
interactive (OAuth logins) lives in `brain setup`.

`setup.sh` remains as a shim for the previously published one-liner, and a `droplet -> host`
symlink keeps `brain update` working on machines installed before the rename. Both are
removable one release after this ships.
