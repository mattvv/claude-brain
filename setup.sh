#!/usr/bin/env bash
# claude-brain laptop bootstrapper.
#
#   curl -fsSL https://raw.githubusercontent.com/mattvv/claude-brain/main/setup.sh | bash
#
# Creates a DigitalOcean droplet running your personal Claude brain, then hands
# you off to `brain setup` on the droplet. Works on macOS and Linux. Your DO
# API token is stored only by doctl itself — never by this script.

set -euo pipefail

REPO_RAW="${BRAIN_REPO_RAW:-https://raw.githubusercontent.com/mattvv/claude-brain/main}"
DEFAULT_NAME="claude-brain"
DEFAULT_REGION="nyc3"
DEFAULT_SIZE="s-1vcpu-2gb"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say()  { printf '%s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ask()  { local v; read -r -p "$1" v </dev/tty || v=""; printf '%s' "${v:-$2}"; }

# Everything lives in main() so a partial download can't execute, and so ssh
# calls below can't swallow the remainder of the script when run via curl|bash.
main() {

for c in curl ssh ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || die "required command missing: $c"
done

bold "claude-brain setup — your personal Claude server"
say  "This will create a small cloud computer (~\$12/month) on DigitalOcean."
say  ""

# ---- doctl -----------------------------------------------------------------
if ! command -v doctl >/dev/null 2>&1; then
  say "Installing the DigitalOcean CLI (doctl)..."
  if command -v brew >/dev/null 2>&1; then
    brew install doctl
  else
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
    ver="$(curl -fsSL https://api.github.com/repos/digitalocean/doctl/releases/latest | grep -o '"tag_name": *"v[^"]*"' | head -1 | grep -o 'v[0-9.]*')"
    [ -n "$ver" ] || die "could not determine latest doctl version"
    mkdir -p "$HOME/.local/bin"
    curl -fsSL "https://github.com/digitalocean/doctl/releases/download/$ver/doctl-${ver#v}-$os-$arch.tar.gz" \
      | tar -xz -C "$HOME/.local/bin" doctl
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi

if ! doctl account get >/dev/null 2>&1; then
  bold "Connect your DigitalOcean account"
  say  "1. Open:  https://cloud.digitalocean.com/account/api/tokens"
  say  "2. Click 'Generate New Token', give it a name, allow Read AND Write"
  say  "3. Copy the token (treat it like a password) and paste it below"
  doctl auth init </dev/tty
  doctl account get >/dev/null 2>&1 || die "DigitalOcean login failed — re-run this script"
fi

# ---- ssh key ---------------------------------------------------------------
KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY" ]; then
  say "Creating an SSH key for you ($KEY)..."
  ssh-keygen -t ed25519 -f "$KEY" -N "" -q
fi
FP="$(ssh-keygen -lf "$KEY.pub" -E md5 | awk '{print $2}' | sed 's/^MD5://')"
if ! doctl compute ssh-key list --format FingerPrint --no-header | grep -qx "$FP"; then
  doctl compute ssh-key import "claude-brain-$(hostname -s)" --public-key-file "$KEY.pub" >/dev/null
  say "SSH key added to your DigitalOcean account."
fi

# ---- choices ---------------------------------------------------------------
NAME="$(ask "Droplet name [$DEFAULT_NAME]: " "$DEFAULT_NAME")"
say "Common regions: nyc3 (New York), sfo3 (San Francisco), lon1 (London), sgp1 (Singapore), syd1 (Sydney)"
REGION="$(ask "Region [$DEFAULT_REGION]: " "$DEFAULT_REGION")"
SIZE="$(ask "Size [$DEFAULT_SIZE]: " "$DEFAULT_SIZE")"

if doctl compute droplet list --format Name --no-header | grep -qx "$NAME"; then
  die "a droplet named '$NAME' already exists — pick another name or delete it first"
fi

# ---- create ----------------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$REPO_RAW/cloud-init.yaml" -o "$TMP/cloud-init.yaml"

bold "Creating your droplet (takes about a minute)..."
doctl compute droplet create "$NAME" \
  --image ubuntu-24-04-x64 \
  --size "$SIZE" \
  --region "$REGION" \
  --ssh-keys "$FP" \
  --user-data-file "$TMP/cloud-init.yaml" \
  --wait >/dev/null

IP="$(doctl compute droplet get "$NAME" --format PublicIPv4 --no-header)"
[ -n "$IP" ] || die "could not read the droplet's IP"
say "Droplet is up at $IP. Waiting for it to finish installing (5–10 min)..."

# ---- wait for bootstrap ----------------------------------------------------
tries=0
until ssh -n -i "$KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      -o BatchMode=yes "brain@$IP" true 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -le 60 ] || die "could not SSH to brain@$IP — check the droplet in the DO console"
  sleep 10
done
ssh -n -i "$KEY" "brain@$IP" 'cloud-init status --wait >/dev/null 2>&1 || true'

# ---- ssh config + handoff --------------------------------------------------
if ! grep -q "^Host $NAME\$" "$HOME/.ssh/config" 2>/dev/null; then
  reply="$(ask "Add '$NAME' shortcut to your SSH config so 'ssh $NAME' works? [Y/n] " Y)"
  case "$reply" in
    n|N|no|NO) ;;
    *) printf '\nHost %s\n  HostName %s\n  User brain\n  IdentityFile %s\n' \
         "$NAME" "$IP" "$KEY" >> "$HOME/.ssh/config" ;;
  esac
fi

bold "Your Claude brain is running at $IP"
say  "One step left: link your accounts."
reply="$(ask "Connect now and run setup? [Y/n] " Y)"
case "$reply" in
  n|N|no|NO) say "Later, run:  ssh $NAME   then:  brain setup" ;;
  *) exec ssh -i "$KEY" -t "brain@$IP" 'bash -lc "brain setup"' ;;
esac

}
main "$@"
