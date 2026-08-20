#!/usr/bin/env bash
# Unit tests for host/lib/platform.sh — the file every other script trusts to
# hide the difference between a Mac, an Arch box and an Ubuntu droplet.
#
# No network, no package installs, no services: platform commands are stubbed
# on PATH, so these run identically on any machine (and in CI on both).
#
#   tests/platform/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if ( set +o pipefail; eval "$2" ); then ok "$1"; else bad "$1 [$2]"; fi; }
# eq NAME EXPECTED ACTUAL
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

# Resolved on purpose: on macOS mktemp -d returns /var/... which is a symlink
# to /private/var/..., and abs_path resolves it. Comparing against an
# unresolved root would fail the helper for being right.
TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"

# stub NAME BODY — put a fake command first on PATH.
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STUB/$1"; chmod 755 "$STUB/$1"; }

# shellcheck source=../../host/lib/platform.sh
. "$REPO/host/lib/platform.sh"

echo "== detection =="
PATH="$STUB:$PATH"
stub uname 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac'
eq "brain_os macOS"          macos "$(brain_os)"
eq "brain_arch arm64"        arm64 "$(brain_arch)"
stub uname 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac'
eq "brain_os linux"          linux "$(brain_os)"
eq "brain_arch x86_64 to amd64" amd64 "$(brain_arch)"
stub uname 'case "$1" in -m) echo aarch64 ;; *) echo Linux ;; esac'
eq "brain_arch aarch64 to arm64" arm64 "$(brain_arch)"
stub uname 'echo FreeBSD'
eq "unsupported OS is named, not guessed" unsupported "$(brain_os)"
rm -f "$STUB/uname"

echo "== package managers =="
# Precedence, against ONLY the stubs — a real Mac has a real Homebrew on PATH,
# so dropping the brew stub would not drop brew. pkg_manager needs nothing but
# `command -v`, so an all-stub PATH is safe.
stub brew 'exit 0'; stub pacman 'exit 0'; stub apt-get 'exit 0'
eq "brew wins when present"   brew   "$(PATH="$STUB" pkg_manager)"
rm -f "$STUB/brew"
eq "pacman beats apt"         pacman "$(PATH="$STUB" pkg_manager)"
rm -f "$STUB/pacman"
eq "apt is last"              apt    "$(PATH="$STUB" pkg_manager)"
rm -f "$STUB/apt-get"
eq "none when nothing is installed" none "$(PATH="$STUB" pkg_manager)"

eq "gh is github-cli on Arch"       github-cli "$(pkg_name gh pacman)"
eq "gh is gh on brew"               gh         "$(pkg_name gh brew)"
eq "go comes from a tarball on apt" ""         "$(pkg_name go apt)"
eq "go is a package on pacman"      go         "$(pkg_name go pacman)"
eq "rust is rustup on apt"          ""         "$(pkg_name rust apt)"
eq "coreutils only matters on brew" ""         "$(pkg_name coreutils pacman)"
eq "unknown names pass through"     tmux       "$(pkg_name tmux apt)"

stub pacman 'exit 0'
eq "pacman install is non-interactive" \
   "sudo pacman -S --needed --noconfirm git jq" "$(PATH="$STUB" pkg_install --dry-run git jq)"
rm -f "$STUB/pacman"
stub brew 'exit 0'
eq "brew install needs no sudo" "brew install git jq" "$(PATH="$STUB" pkg_install --dry-run git jq)"
rm -f "$STUB/brew"
check "dry-run never executes anything" 'pkg_install --dry-run definitely-not-a-package >/dev/null'

echo "== file facts =="
printf 'hello' > "$TMP/f"
eq "file_size counts bytes"  5 "$(file_size "$TMP/f")"
eq "missing file is size 0"  0 "$(file_size "$TMP/nope")"
eq "missing file is mtime 0" 0 "$(file_mtime "$TMP/nope")"
check "file_mtime is an epoch" '[ "$(file_mtime "$TMP/f")" -gt 1000000000 ]'
ln -s "$TMP/f" "$TMP/link"
eq "file_size follows symlinks" 5 "$(file_size "$TMP/link")"

echo "== abs_path =="
eq "resolves symlinks" "$TMP/f" "$(abs_path "$TMP/link")"
eq "tolerates a missing final component (BSD readlink -f does not)" \
   "$TMP/not-here" "$(abs_path "$TMP/not-here")"
eq "makes relative paths absolute" "$REPO/README.md" "$(cd "$REPO" && abs_path README.md)"
check "empty input fails" '! abs_path "" 2>/dev/null'

echo "== run_timeout =="
check "kills a slow command with 124" 'run_timeout 1 sleep 5; [ $? -eq 124 ]'
check "passes through success"        'run_timeout 5 true'
check "passes through failure"        '! run_timeout 5 false'
# The fallback watchdog is the path macOS takes when coreutils is not installed:
# sleep exists, timeout/gtimeout do not.
MINBIN="$TMP/minbin"; mkdir -p "$MINBIN"
for b in sleep true false; do
  src="$(command -v "$b")"; [ -n "$src" ] && ln -sf "$src" "$MINBIN/$b"
done
check "no timeout(1) in the stripped PATH" \
  '( PATH="$MINBIN"; ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null )'
check "fallback watchdog still times out" \
  '( PATH="$MINBIN"; run_timeout 1 sleep 5; [ $? -eq 124 ] )'
check "fallback watchdog lets a fast command finish" \
  '( PATH="$MINBIN"; run_timeout 5 true )'
check "fallback watchdog reports a real failure" \
  '( PATH="$MINBIN"; ! run_timeout 5 false )'

echo "== services =="
eq "systemd unit name (proxy)" cli-proxy-api "$(svc_systemd_unit proxy)"
eq "systemd unit name (rc)"    brain-rc      "$(svc_systemd_unit rc)"
(
  brain_os() { printf 'macos\n'; }
  eq "launchd label" sh.claude-brain.proxy "$(svc_unit_id proxy)"
  eq "macOS restart hint is launchctl" \
     "launchctl kickstart -k gui/$(id -u)/sh.claude-brain.proxy" "$(svc_restart_hint proxy)"
  eq "macOS keepawake only applies on charger" \
     "sudo pmset -c sleep 0" "$(keepawake_cmds | head -1)"
)
(
  brain_os() { printf 'linux\n'; }
  eq "linux restart hint is systemctl" \
     "systemctl --user restart cli-proxy-api" "$(svc_restart_hint proxy)"
)

echo "== launchd rendering =="
(
  export BRAIN_LAUNCHD_DIR="$TMP/agents" BRAIN_STATE_DIR="$TMP/state" BRAIN_REPO_DIR="$REPO"
  stub launchctl 'exit 0'
  brain_os() { printf 'macos\n'; }
  svc_install proxy >/dev/null 2>&1
  svc_install rc >/dev/null 2>&1
  check "both agents rendered" \
    '[ -f "$BRAIN_LAUNCHD_DIR/sh.claude-brain.proxy.plist" ] && [ -f "$BRAIN_LAUNCHD_DIR/sh.claude-brain.rc.plist" ]'
  check "no placeholders survive"      '! grep -q "__" "$BRAIN_LAUNCHD_DIR"/*.plist'
  check "router agent restarts itself" 'grep -q KeepAlive "$BRAIN_LAUNCHD_DIR/sh.claude-brain.proxy.plist"'
  check "rc agent runs brain rc"       'grep -q "<string>rc</string>" "$BRAIN_LAUNCHD_DIR/sh.claude-brain.rc.plist"'
  if command -v plutil >/dev/null 2>&1; then
    check "plists are valid (plutil)" 'plutil -lint "$BRAIN_LAUNCHD_DIR"/*.plist >/dev/null'
  elif command -v python3 >/dev/null 2>&1; then
    check "plists are valid (plistlib)" \
      'python3 -c "import plistlib,glob,sys;[plistlib.load(open(f,\"rb\")) for f in glob.glob(sys.argv[1])]" "$BRAIN_LAUNCHD_DIR/*.plist"'
  fi
)

echo "== bash 3.2 floor (macOS ships bash 3.2 as /bin/bash) =="
SHIPPED="$REPO/install.sh $REPO/setup.sh $REPO/host/install.sh $REPO/host/bootstrap.sh $REPO/host/bin/brain $REPO/host/bin/brain-ask $REPO/host/bin/brain-proxy-build $REPO/host/lib/common.sh $REPO/host/lib/platform.sh $REPO/host/provision/digitalocean.sh $REPO/host/claude/statusline.sh"
check "no bash-4 syntax in shipped scripts" \
  '! grep -nE "mapfile|readarray|declare -A|local -n" '"$SHIPPED"
check "no bash-4 case conversion in shipped scripts" \
  '! grep -nE "\$\{[A-Za-z_]+\^\^|\$\{[A-Za-z_]+,,"'" $SHIPPED"
check "shipped scripts parse" \
  'for f in '"$SHIPPED"'; do bash -n "$f" || exit 1; done'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
