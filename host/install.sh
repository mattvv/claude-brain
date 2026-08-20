#!/usr/bin/env bash
# Idempotent on-host installer: links the brain CLI into ~/.local/bin, wires up
# the Claude Code integration, and records what it touched so `brain uninstall`
# can undo it. Run as the target (non-root) user.
#
# On a droplet this owns the machine's Claude config. On someone's own computer
# it is a guest: it backs up settings.json before the first change and refuses
# to steal a statusline they already had.

set -euo pipefail

SELF="$0"
while [ -L "$SELF" ]; do
  _d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$_d/$SELF" ;; esac
done
REPO_DIR="$(cd -P "$(dirname "$SELF")/.." && pwd)"
# shellcheck source=lib/platform.sh
. "$REPO_DIR/host/lib/platform.sh"

SETTINGS_FILE="$HOME/.config/brain/settings"
# `|| true`: on a fresh machine there is no settings file yet, and a failing
# command substitution in an assignment is fatal under `set -e` — which made
# this exit silently before default_profile ever ran.
PROFILE="$(sed -n 's/^PROFILE=//p' "$SETTINGS_FILE" 2>/dev/null | tail -1 || true)"
[ -n "$PROFILE" ] || PROFILE="$(default_profile)"

STATE_DIR="$HOME/.local/state/brain"
MANIFEST="$STATE_DIR/install-manifest"

mkdir -p "$HOME/.local/bin" "$STATE_DIR"
: > "$MANIFEST"
note() { printf '%s\n' "$*" >> "$MANIFEST"; }
for tool in brain brain-ask brain-compress brain-proxy-build; do
  chmod 755 "$REPO_DIR/host/bin/$tool"
  ln -sf "$REPO_DIR/host/bin/$tool" "$HOME/.local/bin/$tool"
  note "link $HOME/.local/bin/$tool"
done
chmod 755 "$REPO_DIR/host/libexec/legacy/brain-ask"

# Build and install the native brain-compress binary (async consultation +
# observe-only token accounting). Best effort: if the Rust toolchain is missing
# or the build fails, brain-ask transparently falls back to the bundled Bash
# implementation and compression is simply unavailable. Never fatal to install.
CRATE_DIR="$REPO_DIR/host/native/brain-compress"
NATIVE_BASE="$HOME/.local/share/brain/native"
if command -v cargo >/dev/null 2>&1 && [ -f "$CRATE_DIR/Cargo.toml" ]; then
  version="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$CRATE_DIR/Cargo.toml" | head -1)"
  version="${version:-0.1.0}"
  dest="$NATIVE_BASE/$version"
  if [ ! -x "$dest/brain-compress" ]; then
    echo "building brain-compress $version (this can take a few minutes)…"
    if ( cd "$CRATE_DIR" && cargo build --release --quiet ); then
      mkdir -p "$dest"
      install -m 755 "$CRATE_DIR/target/release/brain-compress" "$dest/brain-compress"
      printf '%s\n' "$version" > "$dest/VERSION"
      ln -sfn "$version" "$NATIVE_BASE/current"
      echo "brain-compress $version installed"
    else
      echo "warning: brain-compress build failed — brain-ask will use the Bash fallback" >&2
    fi
  else
    ln -sfn "$version" "$NATIVE_BASE/current"
  fi
fi

# brain-symbols (tree-sitter symbol helper) is OPTIONAL: without it, symbol
# commands degrade to a clearly marked lexical fallback. Preferred delivery is
# the prebuilt musl artifact from the GitHub release (H7 — see
# .github/workflows/release.yml); installing from a release is wired into
# `brain update` once the first release exists. As a stopgap, install a local
# dev build if one is already present (never build it here: the grammar C
# compile is exactly what H7 keeps off constrained hosts during install).
SYM_CRATE="$REPO_DIR/host/native/brain-symbols"
SYM_VENDOR="$HOME/.local/share/brain/vendor/brain-symbols"
if [ -f "$SYM_CRATE/Cargo.toml" ]; then
  sym_version="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$SYM_CRATE/Cargo.toml" | head -1)"
  for candidate in "$SYM_CRATE/target/release/brain-symbols" "$SYM_CRATE/target/debug/brain-symbols"; do
    if [ -x "$candidate" ] && [ ! -x "$SYM_VENDOR/$sym_version/brain-symbols" ]; then
      mkdir -p "$SYM_VENDOR/$sym_version"
      install -m 755 "$candidate" "$SYM_VENDOR/$sym_version/brain-symbols"
      echo "brain-symbols $sym_version installed (local build)"
      break
    fi
  done
fi

# Seed the compression config (observe-only) if the user has none yet.
COMPRESS_DIR="$HOME/.local/state/brain/compress"
mkdir -p "$COMPRESS_DIR"
if [ ! -f "$COMPRESS_DIR/compress.toml" ] && [ -f "$REPO_DIR/host/templates/compress.toml.tmpl" ]; then
  cp "$REPO_DIR/host/templates/compress.toml.tmpl" "$COMPRESS_DIR/compress.toml"
fi

# Register the Claude Code integration: model guard, consultation progress
# hooks, and the statusline. All three are keyed by script name so re-running
# install.sh replaces them rather than accumulating duplicates.
HOOKS_DIR="$REPO_DIR/host/claude/hooks"
chmod 755 "$HOOKS_DIR"/*.sh "$REPO_DIR/host/claude/statusline.sh"
if command -v jq >/dev/null 2>&1; then
  SETTINGS="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"

  # One backup, kept forever, taken before we first touch a config that may
  # predate us. Re-running the installer must not bury the original.
  if [ ! -f "$STATE_DIR/settings.json.pre-brain" ]; then
    cp "$SETTINGS" "$STATE_DIR/settings.json.pre-brain"
    cp "$SETTINGS" "$SETTINGS.pre-brain-$(date +%Y%m%d%H%M%S)"
    note "backup $STATE_DIR/settings.json.pre-brain"
  fi

  # The statusline is the one setting that can only have one owner. Claim it
  # when it is free or already ours; otherwise leave the user's alone and say
  # how to switch. (`brain config statusline on` forces it.)
  STATUSLINE_MODE=claim
  existing_statusline="$(jq -r '.statusLine.command // empty' "$SETTINGS")"
  case "$existing_statusline" in
    ''|*claude-brain*|*"$REPO_DIR"*|*/host/claude/statusline.sh|*/droplet/claude/statusline.sh) ;;
    *) [ "$PROFILE" = droplet ] || STATUSLINE_MODE=keep ;;
  esac

  MANAGED='model-guard|consult-poll-guard|consult-progress|brain-compress-bash|brain-compress-read'
  jq --arg hooks "$HOOKS_DIR" \
     --arg statusline "$REPO_DIR/host/claude/statusline.sh" \
     --arg managed "$MANAGED" '
    def strip(list): [list[]? | select((.hooks[]?.command // "") | test($managed) | not)];
    .hooks.PreToolUse = (strip(.hooks.PreToolUse) + [
      {matcher: "Agent|Task", hooks: [{type: "command", command: ($hooks + "/model-guard.sh")}]},
      {matcher: "Bash", hooks: [
        {type: "command", command: ($hooks + "/consult-poll-guard.sh")},
        {type: "command", command: ($hooks + "/brain-compress-bash.sh")}
      ]},
      {matcher: "Read", hooks: [{type: "command", command: ($hooks + "/brain-compress-read.sh")}]}
    ])
    | .hooks.PostToolUse = (strip(.hooks.PostToolUse) + [
      {matcher: "*", hooks: [{type: "command", command: ($hooks + "/consult-progress.sh")}]}
    ])
    | (if $mode == "claim"
       then .statusLine = {type: "command", command: $statusline, refreshInterval: 2}
       else . end)
  ' --arg mode "$STATUSLINE_MODE" "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  note "settings $SETTINGS"
  if [ "$STATUSLINE_MODE" = keep ]; then
    printf 'kept your existing statusline (%s).\n' "$existing_statusline"
    printf 'to use the claude-brain one instead: brain config statusline on\n'
  fi
fi

# Ensure ~/.local/bin is on PATH for interactive shells. macOS logs you in with
# zsh, so write to whichever rc file this user actually has.
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  case "$rc" in
    *.zshrc) [ "$(brain_os)" = macos ] || [ -f "$rc" ] || continue ;;
    *.bashrc) [ "$(brain_os)" = macos ] && [ ! -f "$rc" ] && continue ;;
  esac
  if ! grep -Fq '.local/bin' "$rc" 2>/dev/null; then
    printf '\n# Added by claude-brain\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    note "path $rc"
  fi
done

# First-login hint. A droplet greets you over SSH; nobody wants their own Mac
# rewriting /etc, so this is droplet-only.
if [ "$PROFILE" = droplet ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo tee /etc/update-motd.d/99-brain >/dev/null <<'MOTD'
#!/bin/sh
echo ""
echo "  claude-brain: run 'brain setup' to finish setting up, or 'brain' to start."
echo ""
MOTD
  sudo chmod 755 /etc/update-motd.d/99-brain
  note "motd /etc/update-motd.d/99-brain"
fi

echo "claude-brain installed. Run: brain setup"
