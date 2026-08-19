#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the sourcing scripts
# Shared helpers for claude-brain droplet scripts. Source, don't execute.
# Targets Ubuntu (bash + GNU coreutils) only.

set -o pipefail

BRAIN_REPO_DIR="${BRAIN_REPO_DIR:-$HOME/claude-brain}"
BRAIN_CONFIG_DIR="${BRAIN_CONFIG_DIR:-$HOME/.config/brain}"
BRAIN_DATA_DIR="${BRAIN_DATA_DIR:-$HOME/.local/share/brain}"
BRAIN_STATE_DIR="${BRAIN_STATE_DIR:-$HOME/.local/state/brain}"
BRAIN_AUTH_DIR="${BRAIN_AUTH_DIR:-$HOME/.cli-proxy-api}"

BRAIN_TOKEN_FILE="$BRAIN_CONFIG_DIR/token"
BRAIN_SETTINGS_FILE="$BRAIN_CONFIG_DIR/settings"
BRAIN_PROXY_CONFIG="$BRAIN_CONFIG_DIR/proxy-config.yaml"
BRAIN_PROXY_SRC="$BRAIN_DATA_DIR/proxy/src"
BRAIN_PROXY_BIN="$BRAIN_DATA_DIR/proxy/bin/cli-proxy-api"
BRAIN_PROXY_PORT="${BRAIN_PROXY_PORT:-8317}"
BRAIN_PROXY_URL="http://127.0.0.1:$BRAIN_PROXY_PORT"

BRAIN_PIN_FILE="$BRAIN_REPO_DIR/droplet/proxy/PIN"
BRAIN_PATCH_FILE="$BRAIN_REPO_DIR/droplet/proxy/patches/cliproxyapi-claude-effort.patch"
PROXY_REPO_URL="https://github.com/router-for-me/CLIProxyAPI.git"

# Colors only when stdout is a terminal.
if [ -t 1 ]; then
  C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_YELLOW=$'\033[33m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
else
  C_GREEN='' C_RED='' C_YELLOW='' C_BOLD='' C_RESET=''
fi

info()  { printf '%s\n' "${C_BOLD}==>${C_RESET} $*"; }
ok()    { printf '%s\n' "${C_GREEN} ✓${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW} !${C_RESET} $*" >&2; }
fail()  { printf '%s\n' "${C_RED} ✗${C_RESET} $*" >&2; }
die()   { fail "$@"; exit 1; }

need() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing required commands: ${missing[*]}"
}

# Read a KEY=VALUE user setting, falling back to a default: setting_get KEY DEFAULT
setting_get() {
  local val=""
  [ -f "$BRAIN_SETTINGS_FILE" ] && val="$(sed -n "s/^$1=//p" "$BRAIN_SETTINGS_FILE" | tail -1)"
  printf '%s\n' "${val:-$2}"
}

# Write a KEY=VALUE user setting: setting_set KEY VALUE
setting_set() {
  ensure_brain_dirs
  umask 077
  touch "$BRAIN_SETTINGS_FILE"
  { grep -v "^$1=" "$BRAIN_SETTINGS_FILE" || true; printf '%s=%s\n' "$1" "$2"; } \
    > "$BRAIN_SETTINGS_FILE.tmp"
  mv "$BRAIN_SETTINGS_FILE.tmp" "$BRAIN_SETTINGS_FILE"
}

# Read a KEY=VALUE entry from the PIN file.
pin_get() {
  [ -f "$BRAIN_PIN_FILE" ] || die "PIN file not found: $BRAIN_PIN_FILE"
  sed -n "s/^$1=//p" "$BRAIN_PIN_FILE"
}

ensure_brain_dirs() {
  umask 077
  mkdir -p "$BRAIN_CONFIG_DIR" "$BRAIN_DATA_DIR" "$BRAIN_STATE_DIR" "$BRAIN_AUTH_DIR"
  chmod 700 "$BRAIN_CONFIG_DIR" "$BRAIN_AUTH_DIR"
}

# Print the proxy API token, generating it on first use.
brain_token() {
  if [ ! -f "$BRAIN_TOKEN_FILE" ]; then
    ensure_brain_dirs
    umask 077
    openssl rand -hex 32 > "$BRAIN_TOKEN_FILE"
  fi
  chmod 600 "$BRAIN_TOKEN_FILE"
  cat "$BRAIN_TOKEN_FILE"
}

proxy_ready() {
  curl -fsS -m 5 -H "Authorization: Bearer $(brain_token)" \
    "$BRAIN_PROXY_URL/v1/models" >/dev/null 2>&1
}

# List model ids the proxy currently serves, one per line.
proxy_models() {
  curl -fsS -m 10 -H "Authorization: Bearer $(brain_token)" \
    "$BRAIN_PROXY_URL/v1/models" | jq -r '.data[].id'
}

# ---- consultation progress (shared by the statusline, hooks, and `brain consult`) ----

BRAIN_CONSULT_DIR="$BRAIN_STATE_DIR/consult"
BRAIN_CONSULT_LINK="$BRAIN_CONSULT_DIR/current"

# True while a `brain-ask --stream` consultation is running, or finished within
# the last 45s so the completion stays visible for one more poll.
consult_active() {
  [ -e "$BRAIN_CONSULT_LINK" ] || return 1
  pgrep -f 'brain-ask ' >/dev/null 2>&1 && return 0
  local now mtime
  now="$(date +%s)"
  mtime="$(stat -Lc %Y "$BRAIN_CONSULT_LINK" 2>/dev/null || echo 0)"
  [ $((now - mtime)) -le 45 ]
}

# Latest reasoning-summary step from the `.thinking` sidecar, if any. Codex
# emits these as `**Bolded step**` headers, which read well as progress.
consult_thinking_step() {
  local t step
  t="$(readlink -f "$BRAIN_CONSULT_LINK" 2>/dev/null || true).thinking"
  [ -f "$t" ] || return 0
  step="$(grep -o '\*\*[^*]\+\*\*' "$t" 2>/dev/null | tail -1 | tr -d '*')"
  [ ${#step} -le 64 ] || step="${step:0:61}..."
  printf '%s' "$step"
}

# One-line progress summary for the current consultation. Returns 1 when idle.
# xhigh models emit no answer text for minutes, so that window reports the live
# reasoning step instead — and falls back to a plain notice before one exists.
consult_progress_line() {
  consult_active || return 1
  local target name bytes heading step
  target="$(basename "$(readlink -f "$BRAIN_CONSULT_LINK")")"
  name="${target%-*.log}"
  bytes="$(stat -Lc %s "$BRAIN_CONSULT_LINK" 2>/dev/null || echo 0)"
  step="$(consult_thinking_step)"
  if [ "$bytes" -eq 0 ]; then
    if [ -n "$step" ]; then
      printf '%s · thinking: %s\n' "$name" "$step"
    else
      printf '%s · thinking, no output yet\n' "$name"
    fi
    return 0
  fi
  heading="$(grep -o '^#\+ .*' "$BRAIN_CONSULT_LINK" 2>/dev/null | tail -1 | sed 's/^#\+ *//')"
  local size
  if [ "$bytes" -lt 1024 ]; then size="${bytes}B"; else size="$((bytes / 1024))kB"; fi
  printf '%s · %s%s\n' "$name" "$size" "${heading:+ · writing: $heading}"
}

claude_bin() {
  if command -v claude >/dev/null 2>&1; then
    command -v claude
  elif [ -x "$HOME/.local/bin/claude" ]; then
    printf '%s\n' "$HOME/.local/bin/claude"
  else
    return 1
  fi
}
