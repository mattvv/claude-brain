# Plan: run a brain on any computer

**Goal.** Today claude-brain can only be installed one way: `setup.sh` provisions a
DigitalOcean droplet from your laptop. This plan makes the droplet *one target among
several* — your Mac mini, an Arch box under your desk, another machine you can SSH to, or
a DO droplet — behind a single installer that asks where to install and what to connect.

**Pitch it supports.** *Your multi-model agent. Anywhere, always on. Driven by Claude.*

**Silo.** All of this lives on branch `brain-anywhere` (worktree at
`../claude-brain-anywhere`), branched from `main`. It does not touch the compression work
in flight on `compression-measurement`; the only file both touch is `README.md`, and in
disjoint sections.

---

## 1. Scope

**First-class targets** (the ones we test and support):

| Target | OS | Packages | Service manager | Profile |
|---|---|---|---|---|
| Mac mini / MacBook | macOS 13+, arm64 & x86_64 | Homebrew | launchd (user agent) | `local` |
| Linux box | Arch | pacman | systemd (user) | `local` |
| DigitalOcean droplet | Ubuntu 24.04 | apt | systemd (user) | `droplet` |

Debian/Ubuntu stays first-class because the droplet path is Ubuntu — a local Ubuntu box
therefore works for free. Fedora (`dnf`) gets a best-effort package map and prints an
"untested" warning. Windows is WSL2-only and explicitly out of scope for this round.

**Two orthogonal settings**, both stored in `~/.config/brain/settings`:

- `PROFILE=droplet|local` — how the machine is administered. Chosen by the installer, not
  by the user: the droplet path sets `droplet`, everything else sets `local`.
- `SCOPE=machine|workspace` — **asked at setup time**, both supported:
  - `machine` — brain behaves like it does on the droplet today: it administers the whole
    computer, installs packages, works anywhere under `$HOME`.
  - `workspace` — brain gets a dedicated working root (default `~/brain-workspace`), and
    its ops instructions tell it that it does **not** have passwordless sudo and must ask
    before installing packages or changing system settings.

A third value is *detected*, not asked: `SUDO=passwordless|prompt|none` (via
`sudo -n true`), which the ops instruction block is rendered from.

## 2. What is DigitalOcean-shaped today

Inventory from reading the tree — every one of these is a blocker for a local install:

| Where | What assumes DO/Ubuntu |
|---|---|
| `setup.sh` (whole file) | doctl, droplet create, SSH key import, `ssh brain@IP` handoff |
| `cloud-init.yaml` | DO-only bootstrap: mirrors `/root/.ssh/authorized_keys`, `ufw`, `loginctl enable-linger`, Go **linux-amd64** tarball, gh apt repo, apt packages |
| `host/` (tree name) | the entire product lives under a cloud-vendor noun |
| `host/lib/common.sh:8` | `BRAIN_REPO_DIR` defaults to `$HOME/claude-brain` — a hardcoded clone location |
| `host/lib/common.sh:3` | "Targets Ubuntu (bash + GNU coreutils) only" |
| `host/lib/common.sh:111,134`, `host/claude/statusline.sh:18,22` | `stat -Lc` — GNU only, fails on macOS |
| `host/bin/brain:30-31,469-474,525,691-692` | systemd user unit is the only service model |
| `host/bin/brain:217` | `brain status` shells out to `systemctl --user` |
| `host/bin/brain:230-234` | loopback check uses `ss` (absent on macOS) |
| `host/bin/brain:449` | `ufw allow in on tailscale0` |
| `host/bin/brain:488` | `PATH=$PATH:/usr/local/go/bin` — the cloud-init tarball location |
| `host/bin/brain:82` | `timeout 8 git fetch` — no `timeout(1)` on macOS |
| `host/bin/brain:404-410,429-432,564` | help text hardcodes `ssh claude-brain` |
| `host/install.sh:85-92` | writes `/etc/update-motd.d/99-brain` |
| `host/install.sh:74` | **overwrites `~/.claude/settings.json.statusLine` unconditionally** — fine on a dedicated droplet user, hostile on a personal machine |
| `host/claude/brain-ops.md` | tells every session it has passwordless sudo, apt, and may install anything |
| `.github/workflows/ci.yml` | ubuntu-only lint; no macOS/Arch coverage |

**Good news from the same read:**

- Shipped scripts are already bash-3.2 clean (no `mapfile`/`declare -A`/`${x^^}`). Only
  `tests/compress/ab/run-ab.sh` uses bash-4 features, and it is a dev harness.
- `brain-compress` (Rust) uses only `std::os::unix` + `libc` — it compiles on macOS as-is.
- The router is loopback-only and Remote Control is **outbound** to `api.anthropic.com`.
  That is what makes local hosting work at all: a brain on your Mac mini behind NAT is
  reachable from your phone with no ports, no tunnel, no public IP.

## 3. Target layout

```
claude-brain/
  install.sh              # NEW universal entry: --here | --ssh user@host | --digitalocean
  setup.sh                # shim → install.sh --digitalocean (back-compat for the old curl line)
  cloud-init.yaml         # slimmed: create user, clone, call host/bootstrap.sh --profile droplet
  droplet -> host         # compat symlink, one release only (see risk 1)
  host/                   # was host/
    bootstrap.sh          # NEW dependency installer (brew | pacman | apt | dnf)
    install.sh            # existing wiring, now platform-aware + backs up ~/.claude
    lib/common.sh
    lib/platform.sh       # NEW os/arch/pkg/service/stat/timeout abstraction
    service/
      systemd/cli-proxy-api.service        (moved)
      systemd/brain-rc.service             # NEW autostart unit
      launchd/sh.claude-brain.proxy.plist  # NEW
      launchd/sh.claude-brain.rc.plist     # NEW
    claude/
      brain-ops-droplet.md   # was brain-ops.md
      brain-ops-local.md     # NEW: ask before system changes; sudo may prompt
    bin/ …                   (unchanged names: brain, brain-ask, brain-compress, …)
```

### `host/lib/platform.sh` API

Sourced by `common.sh`, so every script gets it for free:

```
brain_os            → linux | macos
brain_arch          → amd64 | arm64
brain_distro        → arch | debian | ubuntu | fedora | unknown
pkg_manager         → brew | pacman | apt | dnf | none
pkg_install NAME…   → generic name → per-manager name, then install
sudo_mode           → passwordless | prompt | none
file_mtime F / file_size F      → stat -Lc  vs  stat -Lf
abs_path P                      → readlink -f, else python3, else pure-bash loop
run_timeout SECS CMD…           → timeout | gtimeout | bash fallback
listening_publicly PORT         → ss  vs  lsof -nP -iTCP -sTCP:LISTEN
tailscale_bin                   → PATH, else /Applications/Tailscale.app/Contents/MacOS/Tailscale
svc_install NAME EXEC ARGS… / svc_start / svc_stop / svc_restart /
svc_is_active / svc_logs / svc_uninstall
autostart_enable / autostart_disable / autostart_status
keepawake_enable / keepawake_status
```

Package name map (generic → brew / pacman / apt):

| generic | brew | pacman | apt |
|---|---|---|---|
| git, tmux, jq, curl, tree | same | same | same |
| openssl | openssl | openssl | openssl |
| gh | gh | github-cli | official gh apt repo |
| go | go | go | tarball (apt's is too old for the pinned proxy build) |
| rust | rust | rust | rustup.rs |
| gtimeout | coreutils | — (has timeout) | — |

## 4. Phases

Each phase is one reviewable commit; the branch is not mergeable until phase 9.

### Phase 0 — spike (no commit, findings recorded here)

Before anything else, verify on the actual Mac mini:

1. `go build ./cmd/server` of the pinned+patched CLIProxyAPI on darwin/arm64.
2. `curl -fsSL https://claude.ai/install.sh | bash` → `claude remote-control` attaches
   from the phone.
3. `cargo build --release` of `brain-compress` on darwin/arm64.

The router build is the one true blocker — the patch requires a source build, so no
prebuilt fallback exists. If it fails, that finding reshapes the plan and everything else
waits.

### Phase 1 — rename and unpin from `$HOME/claude-brain`

- `git mv droplet host`; add `droplet -> host` symlink.
- `BRAIN_REPO_DIR` derives from `abs_path "${BASH_SOURCE[0]}"` instead of `$HOME`, so the
  repo can be cloned anywhere (`~/src/claude-brain` on a Mac). Env override kept.
- Update every path reference in scripts, docs, CI.

### Phase 2 — platform abstraction

- Add `host/lib/platform.sh`; replace the GNU-isms listed in §2 (`stat -Lc`, `timeout`,
  `ss`, `/usr/local/go/bin`) with its helpers.
- Keep shipped scripts bash-3.2 compatible; CI enforces it (§5).

### Phase 3 — dependency bootstrap

- `host/bootstrap.sh` installs git, tmux, jq, curl, openssl, tree, gh, go, and (optional)
  rust for the detected package manager. Flags: `--unattended`, `--dry-run`, `--profile`.
- On macOS it installs Homebrew if absent (with an explicit confirmation — it is a large,
  visible change to someone's personal machine).
- `cloud-init.yaml` shrinks to: create `brain` user, mirror SSH keys, ufw, linger, clone
  the repo, run `host/bootstrap.sh --profile droplet --unattended`, `host/install.sh`.
  Both paths then share one dependency installer.

### Phase 4 — services and always-on

- systemd user units (existing) and launchd agents (new) behind `svc_*`.
  launchd: `RunAtLoad`+`KeepAlive`, logs to `~/.local/state/brain/log/`, loaded with
  `launchctl bootstrap gui/$(id -u)` and `kickstart -k`.
- `brain autostart enable|disable|status` — one command that makes the brain survive a
  reboot on every target:
  - Linux: `loginctl enable-linger $USER` + `brain-rc.service`.
  - macOS: `sh.claude-brain.rc.plist` + a printed note that a **user agent needs a
    logged-in user**, so a dedicated Mac mini should have auto-login on.
- `brain keepawake` (or a setup step): `sudo pmset -a sleep 0 / disksleep 0` on macOS,
  logind `HandleLidSwitch`/sleep-target guidance on Linux. Prints exactly what it will
  change and asks first — this modifies the user's own computer.
- `brain status` grows a first line: `profile · os/arch · service manager · autostart`.

### Phase 5 — profiles, scope, and living on a personal machine

- Setup asks the `SCOPE` question (machine vs workspace) and stores it; `WORKSPACE_DIR`
  becomes a setting instead of a hardcoded `$HOME/workspace`.
- Split `brain-ops.md` into `-droplet` and `-local` variants; the local one says: sudo may
  prompt, ask before installing packages or changing system settings, never touch files
  outside the workspace root when `SCOPE=workspace`.
- **`~/.claude` co-existence** (this is the part most likely to annoy a real user):
  - back up `settings.json` once to `settings.json.pre-brain-<ts>`;
  - only set `.statusLine` when unset or already ours — otherwise print
    `brain config statusline on` and move on;
  - write an uninstall manifest of everything we touched;
  - new `brain uninstall` reverts hooks, statusline, agents, CLAUDE.md blocks, services,
    and (with `--purge`) state and credentials.
- Skip `ufw`/motd on `local`; keep them on `droplet`.

### Phase 6 — the universal installer

`install.sh` at the repo root:

```
curl -fsSL https://raw.githubusercontent.com/mattvv/claude-brain/main/install.sh | bash
    → interactive: "Where should your brain live?"
       1) this computer      2) another computer over SSH      3) a new DO droplet

bash install.sh --here [--scope machine|workspace] [--link chatgpt,grok,kimi,github]
                [--autostart] [--keep-awake] [--yes] [--plan]
bash install.sh --ssh user@host  [same flags, executed remotely]
bash install.sh --digitalocean [--region nyc3] [--size s-1vcpu-2gb]
```

- `--plan` prints the exact command list and changes without executing — this is what the
  agent path shows the user before touching anything.
- `setup.sh` becomes a three-line shim to `install.sh --digitalocean` so the published
  curl one-liner keeps working.
- Every question has a flag, so the whole flow is drivable non-interactively.

### Phase 7 — agent-driven install

`docs/agent-install.md`, written **for an agent**, plus a short root `CLAUDE.md` pointing
at it so it is picked up automatically inside a clone. The README's entry point becomes:

> **claude help me install claude brain at https://github.com/mattvv/claude-brain**

The doc scripts the agent explicitly:

1. Detect OS/arch/package manager; refuse politely on unsupported targets.
2. Ask the user, in one batch: **where** (this computer / another over SSH / DO droplet),
   **scope** (whole machine / dedicated workspace), **which accounts** (Claude required;
   ChatGPT, Grok, Kimi, GitHub optional), **phone control** on/off, **autostart +
   keep-awake** on/off.
3. Show `install.sh --plan …`, get a go-ahead, then run it with the matching flags.
4. Drive the OAuth logins through `brain auth start|paste|check`, relaying URLs and device
   codes into chat (the headless flow already exists and is already documented for the
   brain's own use — same mechanism, different driver).
5. Verify with `brain status`; report what is linked, what was skipped, and how to add it
   later.
6. Hard rules: never print `~/.config/brain/token` or `~/.cli-proxy-api/*`; never open
   firewall ports; never enable Funnel unasked.

### Phase 8 — README and docs

- README rewritten around the new pitch and the "ask Claude to install it" entry point
  (done on this branch already — see §6).
- `docs/install-local.md` (macOS + Arch/Linux specifics, always-on, uninstall) and
  `docs/install-digitalocean.md` (the current DO/manual content moved out of the README).
- `docs/architecture.md`: droplet → host, add the profile/scope model and the service
  abstraction; keep the two-lane explanation.
- `docs/troubleshooting.md`: per-platform sections (launchd not loaded, Mac asleep,
  linger off, brew missing).

### Phase 9 — tests and CI

- `tests/platform/run.sh` — unit tests for `platform.sh` pure functions with stubbed
  `uname`/`sw_vers`/package managers.
- `tests/install/dry-run.sh` — asserts `install.sh --plan` output per target/profile.
- CI matrix:
  - `ubuntu-latest`: existing lint + cloud-init schema + PIN checksum, plus the new tests.
  - `macos-latest`: shellcheck, run the test suites **under `/bin/bash` (3.2)** to enforce
    the bash floor, `install.sh --plan --here`.
  - `archlinux:latest` container: `bootstrap.sh --dry-run`, platform tests.
- Manual sign-off before merge:
  1. the live droplet survives `brain update` across the rename (risk 1);
  2. fresh install on the Mac mini → phone session attaches;
  3. fresh install on the Arch box → phone session attaches;
  4. `brain uninstall` on a personal machine leaves `~/.claude` as it was.

## 5. Risks

1. **`brain update` breaks across the rename.** The *old* `brain` script runs
   `$REPO/host/install.sh` **after** `git pull`. Mitigation: ship the `droplet -> host`
   symlink in the same commit as the rename, keep it for at least one release, and add a
   fallback in `cmd_update`. Verified against the live droplet before merge.
2. **Router build on darwin/arm64 unproven.** Phase 0 spike gates everything; there is no
   prebuilt fallback because of the vendored patch.
3. **macOS bash is 3.2.** Enforced by running the suites under `/bin/bash` on the macOS
   runner. `tests/compress/ab/run-ab.sh` stays bash-4 and is marked dev-only.
4. **A personal machine is not a droplet.** Overwriting someone's statusline, hooks, or
   sleep settings is a real cost. Everything that touches the user's own config is backed
   up, opt-in, or reverted by `brain uninstall`.
5. **launchd agents need a login session.** A Mac mini that reboots without auto-login has
   no brain until someone logs in. Documented, and `brain autostart status` says so.
6. **"Always on" ≠ a closed laptop.** Say it plainly in the README: a laptop that sleeps is
   not a brain. Recommend a desktop/Mac mini/always-plugged machine, or the droplet.
7. **Secrets at rest on a shared computer.** `~/.cli-proxy-api` stays 0700/0600; the local
   docs add a FileVault/full-disk-encryption note.

## 6. Status

All nine phases are implemented on `brain-anywhere`, and `main` (compression
0.3.0, brain-symbols, explore/recall) is merged in.

| Phase | State |
|---|---|
| 0 — spike | **pending: needs the Mac.** The pinned+patched CLIProxyAPI has not been built on darwin/arm64 yet, and there is no prebuilt fallback. |
| 1 — rename + repo-root derivation | done, and the compat path is regression-tested |
| 2 — platform.sh | done (39 unit tests) |
| 3 — bootstrap.sh + slimmed cloud-init | done |
| 4 — services, autostart, keepawake | done; systemd verified for real, launchd verified with a stubbed launchctl |
| 5 — profiles, scope, guest behaviour, uninstall | done (37 installer tests) |
| 6 — one installer, three targets | done; local install verified end to end in a sandbox HOME |
| 7 — agent-driven install | done |
| 8 — docs | done |
| 9 — tests + CI | done: 39 platform + 37 installer + the existing 114 compression checks, CI on Linux, macOS (under /bin/bash 3.2) and an Arch container |

**What is still unverified, and only real hardware can settle it:**

1. **macOS end to end** — the Go build of the pinned router on darwin/arm64,
   `launchctl bootstrap` of the two agents against real launchd, `pmset -c`, and
   a phone session attaching. CI covers the scripts under bash 3.2 and the plist
   rendering, not the runtime.
2. **Arch end to end** — package names and the systemd path are exercised in a
   container by CI; a real box is still worth one pass.
3. **The live droplet** — `brain update` across the rename works in a clone-based
   test, including from a machine with no settings file. Running it on the actual
   droplet is the last step before merging.
