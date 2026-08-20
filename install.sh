#!/usr/bin/env bash
# claude-brain installer — put a brain on any computer.
#
#   curl -fsSL https://raw.githubusercontent.com/mattvv/claude-brain/main/install.sh | bash
#
# Asks where the brain should live (this computer, another one over SSH, or a
# new DigitalOcean droplet), then installs it. Every question is also a flag,
# so a Claude session or a script can drive the whole thing:
#
#   install.sh --here [--scope machine|workspace] [--workspace DIR]
#              [--link chatgpt,grok,kimi,github] [--autostart] [--yes] [--plan]
#   install.sh --ssh user@host [same flags]
#   install.sh --digitalocean [--name N] [--region nyc3] [--size s-1vcpu-2gb]
#
# --plan prints everything it would do and changes nothing.

set -euo pipefail

REPO_URL="${BRAIN_REPO_URL:-https://github.com/mattvv/claude-brain.git}"
REPO_RAW="${BRAIN_REPO_RAW:-https://raw.githubusercontent.com/mattvv/claude-brain/main}"
CLONE_DIR="${BRAIN_CLONE_DIR:-$HOME/claude-brain}"

TARGET=""
SCOPE=""
WORKSPACE=""
LINK=""
AUTOSTART=0
ASSUME_YES=0
PLAN=0
SSH_HOST=""
DO_NAME="claude-brain"
DO_REGION="nyc3"
DO_SIZE="s-1vcpu-2gb"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say()  { printf '%s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ask()  { local v; read -r -p "$1" v </dev/tty || v=""; printf '%s' "${v:-$2}"; }
step() { if [ "$PLAN" -eq 1 ]; then printf '  %s\n' "$*"; else eval "$*"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --here|--local)   TARGET=here; shift ;;
    --ssh)            TARGET=ssh; SSH_HOST="${2:?--ssh needs user@host}"; shift 2 ;;
    --digitalocean|--do) TARGET=droplet; shift ;;
    --scope)          SCOPE="${2:?}"; shift 2 ;;
    --workspace)      WORKSPACE="${2:?}"; shift 2 ;;
    --link)           LINK="${2:?}"; shift 2 ;;
    --autostart)      AUTOSTART=1; shift ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    --plan|--dry-run) PLAN=1; shift ;;
    --name)           DO_NAME="${2:?}"; shift 2 ;;
    --region)         DO_REGION="${2:?}"; shift 2 ;;
    --size)           DO_SIZE="${2:?}"; shift 2 ;;
    -h|--help)        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# Everything lives in main() so a truncated download cannot execute half a
# script, and so ssh calls cannot swallow the rest of it under curl|bash.
main() {

bold "claude-brain — your multi-model agent, anywhere, always on"
say  ""

# ---- where should the brain live? ------------------------------------------
if [ -z "$TARGET" ]; then
  say "Where should your brain live?"
  say "  1) this computer            free, always on if this machine is"
  say "  2) another computer (SSH)   a spare box, a home server, a Mac mini"
  say "  3) a new cloud server       DigitalOcean droplet, about \$12/month"
  case "$(ask "Choose [1/2/3, default 1]: " 1)" in
    2) TARGET=ssh; SSH_HOST="$(ask "  SSH target (user@host): " "")" ;;
    3) TARGET=droplet ;;
    *) TARGET=here ;;
  esac
fi
[ "$TARGET" = ssh ] && [ -z "$SSH_HOST" ] && die "--ssh needs a user@host target"

# ---- remote targets just re-run this script over there ----------------------
if [ "$TARGET" = ssh ]; then
  local_flags="--here"
  [ -n "$SCOPE" ]     && local_flags="$local_flags --scope $SCOPE"
  [ -n "$WORKSPACE" ] && local_flags="$local_flags --workspace $WORKSPACE"
  [ -n "$LINK" ]      && local_flags="$local_flags --link $LINK"
  [ "$AUTOSTART" -eq 1 ] && local_flags="$local_flags --autostart"
  bold "Installing on $SSH_HOST"
  if [ "$PLAN" -eq 1 ]; then
    say "  ssh -t $SSH_HOST 'curl -fsSL $REPO_RAW/install.sh | bash -s -- $local_flags'"
    exit 0
  fi
  exec ssh -t "$SSH_HOST" "curl -fsSL $REPO_RAW/install.sh | bash -s -- $local_flags"
fi

if [ "$TARGET" = droplet ]; then
  bold "Creating a DigitalOcean droplet"
  if [ "$PLAN" -eq 1 ]; then
    say "  doctl compute droplet create $DO_NAME --image ubuntu-24-04-x64 --size $DO_SIZE --region $DO_REGION --user-data-file cloud-init.yaml"
    say "  then: ssh brain@<ip> 'brain setup'"
    exit 0
  fi
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$REPO_RAW/host/provision/digitalocean.sh" -o "$tmp/do.sh" 2>/dev/null \
    || cp "$(dirname "$0")/host/provision/digitalocean.sh" "$tmp/do.sh"
  exec bash "$tmp/do.sh" --name "$DO_NAME" --region "$DO_REGION" --size "$DO_SIZE"
fi

# ---- this computer ----------------------------------------------------------
case "$(uname -s)" in
  Darwin|Linux) ;;
  *) die "claude-brain needs macOS or Linux (this is $(uname -s))" ;;
esac
[ "$(id -u)" -eq 0 ] && die "run this as your normal user, not root — the brain holds your logins"

# Are we already inside a checkout? Then use it; otherwise clone one.
here="$(cd -P "$(dirname "$0")" && pwd)"
if [ -f "$here/host/bootstrap.sh" ]; then
  REPO="$here"
else
  REPO="$CLONE_DIR"
  if [ -d "$REPO/.git" ]; then
    step "git -C '$REPO' pull --ff-only --quiet || true"
  else
    step "git clone --quiet '$REPO_URL' '$REPO'"
  fi
fi

# ---- the questions ----------------------------------------------------------
# Asked once, here, so the rest of the install is unattended. --plan and --yes
# skip the asking entirely.
if [ "$PLAN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] && [ -z "$SCOPE" ]; then
  say ""
  say "How much of this computer should your brain use?"
  say "  1) its own folder    it works in one directory, and asks before going outside"
  say "  2) the whole machine like the cloud version: it administers this computer"
  case "$(ask "Choose [1/2, default 1]: " 1)" in
    2) SCOPE=machine ;;
    *) SCOPE=workspace
       WORKSPACE="${WORKSPACE:-$(ask "  Working folder [$HOME/brain-workspace]: " "$HOME/brain-workspace")}" ;;
  esac
fi
SCOPE="${SCOPE:-workspace}"
[ "$SCOPE" = workspace ] && WORKSPACE="${WORKSPACE:-$HOME/brain-workspace}"

if [ "$PLAN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] && [ -z "$LINK" ]; then
  say ""
  say "Claude is required and you'll sign in during setup."
  say "Which other accounts should your brain be able to use? (all optional)"
  reply="$(ask "  Comma-separated from chatgpt,grok,kimi,github [none]: " "")"
  LINK="$reply"
fi

if [ "$PLAN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] && [ "$AUTOSTART" -eq 0 ]; then
  case "$(ask "Start your brain automatically after a reboot? [Y/n] " Y)" in
    n|N|no|NO) AUTOSTART=0 ;;
    *) AUTOSTART=1 ;;
  esac
fi

# ---- show the plan ----------------------------------------------------------
bold ""
bold "Plan"
say  "  repo:      $REPO"
say  "  scope:     $SCOPE${WORKSPACE:+ ($WORKSPACE)}"
say  "  accounts:  claude${LINK:+, $(printf '%s' "$LINK" | tr ',' ' ' | tr -s ' ' | sed 's/ /, /g')}"
say  "  autostart: $([ "$AUTOSTART" -eq 1 ] && echo yes || echo no)"
say  ""
say  "  1. install dependencies (git, tmux, jq, Go, gh, Claude Code)"
say  "  2. link the brain commands into ~/.local/bin"
say  "  3. build the model router from pinned source"
say  "  4. run 'brain setup' to sign you in"
say  ""

setup_flags="--scope $SCOPE"
[ -n "$WORKSPACE" ] && setup_flags="$setup_flags --workspace $WORKSPACE"
[ -n "$LINK" ]      && setup_flags="$setup_flags --link $LINK"
[ "$AUTOSTART" -eq 1 ] && setup_flags="$setup_flags --autostart"
[ "$ASSUME_YES" -eq 1 ] && setup_flags="$setup_flags --yes"

if [ "$PLAN" -eq 1 ]; then
  say "  $REPO/host/bootstrap.sh --profile local --with-rust"
  say "  $REPO/host/install.sh"
  say "  brain setup $setup_flags"
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  case "$(ask "Go ahead? [Y/n] " Y)" in n|N|no|NO) say "nothing changed"; exit 0 ;; esac
fi

# ---- do it ------------------------------------------------------------------
mkdir -p "$HOME/.config/brain"
umask 077
touch "$HOME/.config/brain/settings"
{ grep -v '^PROFILE=' "$HOME/.config/brain/settings" 2>/dev/null || true; echo "PROFILE=local"; } \
  > "$HOME/.config/brain/settings.tmp"
mv "$HOME/.config/brain/settings.tmp" "$HOME/.config/brain/settings"

bash "$REPO/host/bootstrap.sh" --profile local --with-rust
bash "$REPO/host/install.sh"
export PATH="$HOME/.local/bin:$PATH"

# The router build takes a few minutes; do it before setup so the wizard's
# vendor logins (which run through the router binary) are ready when asked for.
"$REPO/host/bin/brain-proxy-build" || die "the model router failed to build — see the output above"

# shellcheck disable=SC2086  # deliberate word splitting of the built flags
"$REPO/host/bin/brain" setup $setup_flags

}
main "$@"
