#!/usr/bin/env bash
# Idempotent on-droplet installer: links the brain CLI into ~/.local/bin and
# leaves a hint for first login. Run as the target (non-root) user.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

mkdir -p "$HOME/.local/bin" "$HOME/.local/state/brain"
for tool in brain brain-ask brain-compress brain-proxy-build; do
  chmod 755 "$REPO_DIR/droplet/bin/$tool"
  ln -sf "$REPO_DIR/droplet/bin/$tool" "$HOME/.local/bin/$tool"
done
chmod 755 "$REPO_DIR/droplet/libexec/legacy/brain-ask"

# Build and install the native brain-compress binary (async consultation +
# observe-only token accounting). Best effort: if the Rust toolchain is missing
# or the build fails, brain-ask transparently falls back to the bundled Bash
# implementation and compression is simply unavailable. Never fatal to install.
CRATE_DIR="$REPO_DIR/droplet/native/brain-compress"
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
SYM_CRATE="$REPO_DIR/droplet/native/brain-symbols"
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
if [ ! -f "$COMPRESS_DIR/compress.toml" ] && [ -f "$REPO_DIR/droplet/templates/compress.toml.tmpl" ]; then
  cp "$REPO_DIR/droplet/templates/compress.toml.tmpl" "$COMPRESS_DIR/compress.toml"
fi

# Register the Claude Code integration: model guard, consultation progress
# hooks, and the statusline. All three are keyed by script name so re-running
# install.sh replaces them rather than accumulating duplicates.
HOOKS_DIR="$REPO_DIR/droplet/claude/hooks"
chmod 755 "$HOOKS_DIR"/*.sh "$REPO_DIR/droplet/claude/statusline.sh"
if command -v jq >/dev/null 2>&1; then
  SETTINGS="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  MANAGED='model-guard|consult-poll-guard|consult-progress|brain-compress-bash|brain-compress-read'
  jq --arg hooks "$HOOKS_DIR" \
     --arg statusline "$REPO_DIR/droplet/claude/statusline.sh" \
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
    | .statusLine = {type: "command", command: $statusline, refreshInterval: 2}
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

# Ensure ~/.local/bin is on PATH for interactive shells.
if ! grep -Fq '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# Added by claude-brain\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
fi

# First-login hint (best effort; needs sudo, absent in some contexts).
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo tee /etc/update-motd.d/99-brain >/dev/null <<'MOTD'
#!/bin/sh
echo ""
echo "  claude-brain: run 'brain setup' to finish setting up, or 'brain' to start."
echo ""
MOTD
  sudo chmod 755 /etc/update-motd.d/99-brain
fi

echo "claude-brain installed. Run: brain setup"
