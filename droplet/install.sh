#!/usr/bin/env bash
# Idempotent on-droplet installer: links the brain CLI into ~/.local/bin and
# leaves a hint for first login. Run as the target (non-root) user.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

mkdir -p "$HOME/.local/bin" "$HOME/.local/state/brain"
for tool in brain brain-ask brain-proxy-build; do
  chmod 755 "$REPO_DIR/droplet/bin/$tool"
  ln -sf "$REPO_DIR/droplet/bin/$tool" "$HOME/.local/bin/$tool"
done

# Register the model-guard hook (blocks delegation to unlinked vendors).
chmod 755 "$REPO_DIR/droplet/claude/hooks/model-guard.sh"
if command -v jq >/dev/null 2>&1; then
  SETTINGS="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  HOOK_CMD="$REPO_DIR/droplet/claude/hooks/model-guard.sh"
  jq --arg cmd "$HOOK_CMD" '
    .hooks.PreToolUse = ([.hooks.PreToolUse[]? | select((.hooks[]?.command // "") | test("model-guard") | not)]
      + [{matcher: "Agent|Task", hooks: [{type: "command", command: $cmd}]}])
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
