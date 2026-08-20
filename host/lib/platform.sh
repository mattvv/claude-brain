#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the sourcing scripts
# Platform abstraction for claude-brain. Sourced by lib/common.sh, so every
# script gets it for free. Everything that differs between a Mac, an Arch box,
# and an Ubuntu droplet lives here and nowhere else.
#
# Two hard rules:
#   1. bash 3.2 compatible — macOS still ships /bin/bash 3.2, and users run
#      these scripts with whatever bash is first on PATH.
#   2. No GNU-only flags outside this file (stat -c, timeout, ss, readlink -f
#      on possibly-missing paths). Callers use the helpers below instead.

# ---------------------------------------------------------------- detection

# linux | macos  (anything else is refused by the installer, not silently guessed)
brain_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos\n' ;;
    Linux)  printf 'linux\n' ;;
    *)      printf 'unsupported\n' ;;
  esac
}

# amd64 | arm64
brain_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64\n' ;;
    arm64|aarch64) printf 'arm64\n' ;;
    *)             uname -m ;;
  esac
}

# arch | debian | ubuntu | fedora | macos | unknown
brain_distro() {
  if [ "$(brain_os)" = macos ]; then printf 'macos\n'; return; fi
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    ( . /etc/os-release; printf '%s\n' "${ID:-unknown}" )
  else
    printf 'unknown\n'
  fi
}

# Supported targets are tested in CI and by hand; others still work but say so.
brain_target_supported() {
  case "$(brain_distro)" in
    macos|arch|ubuntu|debian) return 0 ;;
    *) return 1 ;;
  esac
}

# local | droplet — how this machine should be administered, when the settings
# file has not recorded a choice yet (older droplets, upgrades). Detected from
# the hardware vendor rather than guessed, so an existing droplet keeps its
# profile after `brain update`.
default_profile() {
  [ "$(brain_os)" = linux ] || { printf 'local\n'; return; }
  if grep -qi digitalocean /sys/class/dmi/id/sys_vendor 2>/dev/null; then
    printf 'droplet\n'
  else
    printf 'local\n'
  fi
}

# brew | pacman | apt | dnf | none
pkg_manager() {
  if command -v brew    >/dev/null 2>&1; then printf 'brew\n';   return; fi
  if command -v pacman  >/dev/null 2>&1; then printf 'pacman\n'; return; fi
  if command -v apt-get >/dev/null 2>&1; then printf 'apt\n';    return; fi
  if command -v dnf     >/dev/null 2>&1; then printf 'dnf\n';    return; fi
  printf 'none\n'
}

# passwordless | prompt | none — what `sudo` will do for us right now.
sudo_mode() {
  command -v sudo >/dev/null 2>&1 || { printf 'none\n'; return; }
  if sudo -n true 2>/dev/null; then printf 'passwordless\n'; else printf 'prompt\n'; fi
}

# --------------------------------------------------------------- file facts

# Epoch mtime of a file, following symlinks. 0 when absent.
file_mtime() {
  if [ "$(brain_os)" = macos ]; then
    stat -Lf %m "$1" 2>/dev/null || printf '0\n'
  else
    stat -Lc %Y "$1" 2>/dev/null || printf '0\n'
  fi
}

# Size in bytes, following symlinks. 0 when absent.
file_size() {
  if [ "$(brain_os)" = macos ]; then
    stat -Lf %z "$1" 2>/dev/null || printf '0\n'
  else
    stat -Lc %s "$1" 2>/dev/null || printf '0\n'
  fi
}

# Absolute, symlink-resolved path. Unlike `readlink -f`, tolerates a missing
# final component (BSD readlink errors on that), and needs no GNU coreutils.
abs_path() {
  local p="$1" dir base
  [ -n "$p" ] || return 1
  while [ -L "$p" ]; do
    dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || return 1
    p="$(readlink "$p")"
    case "$p" in /*) ;; *) p="$dir/$p" ;; esac
  done
  dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || return 1
  base="$(basename "$p")"
  case "$base" in
    .)  printf '%s\n' "$dir" ;;
    ..) printf '%s\n' "$(cd -P "$dir/.." && pwd)" ;;
    *)  printf '%s\n' "${dir%/}/$base" ;;
  esac
}

# --------------------------------------------------------------- exec helpers

# run_timeout SECS CMD... — macOS has no timeout(1); use gtimeout if the user
# installed coreutils, else a plain background+kill watchdog.
run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"; return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"; return $?
  fi
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$secs" ] && { kill -TERM "$pid" 2>/dev/null; return 124; }
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# True when PORT is bound on something other than loopback — the security
# assertion behind `brain status`. Unknown (no tool) is reported as "not public"
# but the caller is told the check was skipped via a non-zero second return.
listening_publicly() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "(0\.0\.0\.0|\[::\]):$port\b"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -qvE '127\.0\.0\.1|\[::1\]|COMMAND'
  else
    return 1
  fi
}

# True when anything is listening on PORT, on any interface. Distinct from
# listening_publicly: an `ssh -L` forward binds loopback, which is exactly the
# case the ChatGPT browser-login hint needs to detect.
port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":$port\b"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

# The Tailscale CLI, which on macOS may only exist inside the app bundle.
tailscale_bin() {
  if command -v tailscale >/dev/null 2>&1; then command -v tailscale; return; fi
  local app="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  [ -x "$app" ] && { printf '%s\n' "$app"; return; }
  return 1
}

# Go is installed in a non-PATH location by the droplet bootstrap; add the
# usual suspects rather than hardcoding one Linux tarball path.
go_path_hint() {
  local d
  for d in /usr/local/go/bin /opt/homebrew/bin /usr/local/bin "$HOME/go/bin"; do
    case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$PATH:$d" ;; esac
  done
  export PATH
}

# ------------------------------------------------------------ package install

# Map a generic package name to this platform's name. Empty output = "this
# platform gets it another way" (handled by bootstrap.sh).
pkg_name() {
  local generic="$1" mgr="$2"
  case "$generic" in
    gh)
      case "$mgr" in pacman) printf 'github-cli\n' ;; brew|apt|dnf) printf 'gh\n' ;; esac ;;
    go)
      case "$mgr" in brew) printf 'go\n' ;; pacman) printf 'go\n' ;; dnf) printf 'golang\n' ;; apt) printf '\n' ;; esac ;;
    rust)
      case "$mgr" in brew|pacman) printf 'rust\n' ;; dnf) printf 'rust cargo\n' ;; apt) printf '\n' ;; esac ;;
    coreutils)
      case "$mgr" in brew) printf 'coreutils\n' ;; *) printf '\n' ;; esac ;;
    *) printf '%s\n' "$generic" ;;
  esac
}

# pkg_install [--dry-run] NAME... — install generic package names.
pkg_install() {
  local dry=0
  [ "${1:-}" = "--dry-run" ] && { dry=1; shift; }
  local mgr names="" n mapped
  mgr="$(pkg_manager)"
  for n in "$@"; do
    mapped="$(pkg_name "$n" "$mgr")"
    [ -n "$mapped" ] && names="$names $mapped"
  done
  [ -n "${names# }" ] || return 0
  local cmd
  case "$mgr" in
    brew)   cmd="brew install$names" ;;
    pacman) cmd="sudo pacman -S --needed --noconfirm$names" ;;
    apt)    cmd="sudo apt-get install -y$names" ;;
    dnf)    cmd="sudo dnf install -y$names" ;;
    *)      printf 'no supported package manager found; install manually:%s\n' "$names" >&2; return 1 ;;
  esac
  if [ "$dry" -eq 1 ]; then printf '%s\n' "$cmd"; return 0; fi
  # shellcheck disable=SC2086  # deliberate word splitting of the built command
  $cmd
}

# ---------------------------------------------------------------- services
# A "service" here is one long-running user-owned process: the model router,
# and optionally the Remote Control server. systemd user units on Linux,
# launchd user agents on macOS. Never a root daemon: both hold the user's
# OAuth credentials and must run as the user that owns them.

# Overridable so the test suite can render units into a sandbox.
BRAIN_LAUNCHD_DIR="${BRAIN_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
BRAIN_SYSTEMD_DIR="${BRAIN_SYSTEMD_DIR:-$HOME/.config/systemd/user}"

# Map a brain service name to its platform-native unit id.
svc_unit_id() {
  case "$(brain_os)" in
    macos) printf 'sh.claude-brain.%s\n' "$1" ;;
    *)     printf '%s\n' "$(svc_systemd_unit "$1")" ;;
  esac
}

svc_systemd_unit() {
  case "$1" in
    proxy) printf 'cli-proxy-api\n' ;;
    rc)    printf 'brain-rc\n' ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# svc_install NAME — render the packaged unit for this platform and load it.
# Templates live in host/service/{systemd,launchd}/ and use __PLACEHOLDER__
# tokens because launchd plists have no %h equivalent.
svc_install() {
  local name="$1" src dst label
  case "$(brain_os)" in
    macos)
      label="$(svc_unit_id "$name")"
      src="$BRAIN_REPO_DIR/host/service/launchd/$label.plist.tmpl"
      dst="$BRAIN_LAUNCHD_DIR/$label.plist"
      [ -f "$src" ] || { printf 'missing service template: %s\n' "$src" >&2; return 1; }
      mkdir -p "$BRAIN_LAUNCHD_DIR" "$BRAIN_STATE_DIR/log"
      sed -e "s|__HOME__|$HOME|g" \
          -e "s|__LABEL__|$label|g" \
          -e "s|__BRAIN_BIN__|$HOME/.local/bin|g" \
          -e "s|__PATH__|$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin|g" \
          "$src" > "$dst"
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$dst"
      ;;
    *)
      src="$BRAIN_REPO_DIR/host/service/systemd/$(svc_systemd_unit "$name").service"
      dst="$BRAIN_SYSTEMD_DIR/$(svc_systemd_unit "$name").service"
      [ -f "$src" ] || { printf 'missing service unit: %s\n' "$src" >&2; return 1; }
      mkdir -p "$BRAIN_SYSTEMD_DIR"
      cp "$src" "$dst"
      systemctl --user daemon-reload
      systemctl --user enable --now "$(svc_systemd_unit "$name")"
      ;;
  esac
}

svc_is_active() {
  case "$(brain_os)" in
    macos) launchctl print "gui/$(id -u)/$(svc_unit_id "$1")" >/dev/null 2>&1 ;;
    *)     systemctl --user is-active --quiet "$(svc_systemd_unit "$1")" 2>/dev/null ;;
  esac
}

svc_restart() {
  case "$(brain_os)" in
    macos) launchctl kickstart -k "gui/$(id -u)/$(svc_unit_id "$1")" ;;
    *)     systemctl --user restart "$(svc_systemd_unit "$1")" ;;
  esac
}

svc_stop() {
  case "$(brain_os)" in
    macos) launchctl bootout "gui/$(id -u)/$(svc_unit_id "$1")" 2>/dev/null || true ;;
    *)     systemctl --user stop "$(svc_systemd_unit "$1")" 2>/dev/null || true ;;
  esac
}

svc_uninstall() {
  svc_stop "$1"
  case "$(brain_os)" in
    macos) rm -f "$BRAIN_LAUNCHD_DIR/$(svc_unit_id "$1").plist" ;;
    *)
      systemctl --user disable "$(svc_systemd_unit "$1")" 2>/dev/null || true
      rm -f "$BRAIN_SYSTEMD_DIR/$(svc_systemd_unit "$1").service"
      systemctl --user daemon-reload 2>/dev/null || true
      ;;
  esac
}

# The command a human should run to restart this service by hand — printed by
# `brain status` so the advice is always right for the machine it runs on.
svc_restart_hint() {
  case "$(brain_os)" in
    macos) printf 'launchctl kickstart -k gui/%s/%s\n' "$(id -u)" "$(svc_unit_id "$1")" ;;
    *)     printf 'systemctl --user restart %s\n' "$(svc_systemd_unit "$1")" ;;
  esac
}

svc_logs() {
  case "$(brain_os)" in
    macos) tail -n "${2:-50}" "$BRAIN_STATE_DIR/log/$(svc_unit_id "$1").log" 2>/dev/null ;;
    *)     journalctl --user -u "$(svc_systemd_unit "$1")" -n "${2:-50}" --no-pager 2>/dev/null ;;
  esac
}

# ------------------------------------------------------------- always-on
# Two separate things, deliberately kept apart:
#   autostart — does the brain come back by itself after a reboot?
#   keepawake — does the machine stay awake so it can be reached at all?
# Only the second one changes system-wide settings, so only it needs a
# confirmation from the user (`brain keepawake` prints the exact commands).

# Print what still stands between this machine and "comes back after a reboot".
autostart_status() {
  local os; os="$(brain_os)"
  if svc_is_active rc; then
    printf 'enabled: the Remote Control server starts by itself\n'
  else
    printf 'disabled: nothing starts the brain after a reboot (fix: brain autostart enable)\n'
  fi
  if [ "$os" = macos ]; then
    printf 'note: a launchd user agent only runs once someone is logged in.\n'
    printf '      On a dedicated Mac, turn on automatic login:\n'
    printf '      System Settings > Users & Groups > Automatic login.\n'
  else
    if loginctl show-user "$(id -un)" 2>/dev/null | grep -q 'Linger=yes'; then
      printf 'linger: on (services keep running when you log out)\n'
    else
      printf 'linger: OFF — services stop when you log out (fix: sudo loginctl enable-linger %s)\n' "$(id -un)"
    fi
  fi
}

autostart_enable() {
  if [ "$(brain_os)" = linux ]; then
    loginctl show-user "$(id -un)" 2>/dev/null | grep -q 'Linger=yes' \
      || sudo loginctl enable-linger "$(id -un)"
  fi
  svc_install rc
}

autostart_disable() {
  svc_uninstall rc
}

# The exact commands `brain keepawake` would run, one per line, so they can be
# shown before anything is changed. Empty output = nothing to do.
keepawake_cmds() {
  case "$(brain_os)" in
    macos)
      # -c is "while on charger" on purpose: never flatten a laptop battery
      # because someone tried claude-brain on a MacBook.
      printf 'sudo pmset -c sleep 0\n'
      printf 'sudo pmset -c disksleep 0\n'
      ;;
    linux)
      printf 'sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target\n'
      ;;
  esac
}

keepawake_status() {
  case "$(brain_os)" in
    macos)
      if pmset -g custom 2>/dev/null | awk '/AC Power/,0' | grep -qE '^[[:space:]]*sleep[[:space:]]+0'; then
        printf 'awake: this Mac will not sleep while plugged in\n'
      else
        printf 'sleeps: this Mac still sleeps on its own (fix: brain keepawake)\n'
      fi
      ;;
    linux)
      if systemctl is-enabled sleep.target 2>/dev/null | grep -q masked; then
        printf 'awake: suspend/sleep targets are masked\n'
      else
        printf 'sleeps: suspend is still enabled (fix: brain keepawake)\n'
      fi
      ;;
  esac
}
