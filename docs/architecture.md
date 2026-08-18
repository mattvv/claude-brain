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

## Provisioning

`setup.sh` (laptop, via doctl) and the manual DO-console path share one
`cloud-init.yaml`, which is deliberately **secret-free** (user-data is readable from the
droplet metadata endpoint). Boot installs packages, Go, gh, Claude Code, clones this repo,
and kicks off the proxy build in the background; everything interactive (OAuth logins)
lives in `brain setup`.
