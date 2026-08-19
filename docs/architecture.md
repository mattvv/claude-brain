# Architecture

claude-brain is a remix of [Parable](https://parable.sh)-style multi-model routing,
re-designed around one goal: **sessions you can drive from your phone** via Claude Code's
Remote Control.

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

- The session is launched with `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_API_KEY`
  explicitly scrubbed from the environment, so Remote Control always works.
- The brain is always Claude. Other models are **consultants**: bridge agents
  (`droplet/claude/agents-rc/`) read the needed files, compose one self-contained prompt,
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

## The router

A pinned, patched build of
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (Go):

- Pin + patch checksum live in `droplet/proxy/PIN`; `brain-proxy-build` verifies both
  before building. The vendored patch propagates `output_config.effort` →
  `reasoning.effort` for Claude→GPT translation.
- Listens on `127.0.0.1:8317` **only**. Config: `~/.config/brain/proxy-config.yaml`,
  bearer token: `~/.config/brain/token` (32 random bytes, hex).
- Vendor logins are OAuth *subscription* logins performed by the proxy binary itself
  (`--codex-device-login`, `--xai-login --no-browser`, ...). Credentials land in
  `~/.cli-proxy-api/` (0700, records 0600) and auto-refresh.
- Runs as a systemd **user** service (`droplet/systemd/cli-proxy-api.service`) with
  `Restart=always`; `loginctl enable-linger` keeps it alive without a login session.

## Routing intelligence

The proxy itself is dumb fan-out; task→model routing lives a layer up (parable's design):

- **Routing tables** (`droplet/claude/routing-rc.md`, `routing-multi.md`) — per-task-class
  preference orderings with fallbacks and effort guidance, adapted from parable's
  `[routing]` config. Launching a lane installs its table into the droplet's
  `~/.claude/CLAUDE.md` as a managed block, so the brain reads it every session.
- **Effort tiers** — easy classes route to cheap lanes at `low`/`medium` effort; hard
  classes climb to sol/fable at `xhigh`. Multi-lane efforts are pinned in agent
  frontmatter; the RC lane passes `--effort` per call through `brain-ask`.
- **Model guard** (`droplet/claude/hooks/model-guard.sh`) — a PreToolUse hook, modeled on
  parable's `model_guard.py`, that blocks delegation to a `brain-*` agent whose vendor
  isn't linked and tells the model the exact fix (`brain auth <vendor>`) plus "use the
  next fallback", instead of a raw HTTP error mid-task. Registered idempotently in
  `~/.claude/settings.json` by `droplet/install.sh`.

## Self-service operations

The brain administers its own machine. `droplet/claude/brain-ops.md` is installed into
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

## Provisioning

`setup.sh` (laptop, via doctl) and the manual DO-console path share one
`cloud-init.yaml`, which is deliberately **secret-free** (user-data is readable from the
droplet metadata endpoint). Boot installs packages, Go, gh, Claude Code, clones this repo,
and kicks off the proxy build in the background; everything interactive (OAuth logins)
lives in `brain setup`.
