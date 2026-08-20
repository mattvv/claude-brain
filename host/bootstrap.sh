#!/usr/bin/env bash
# Install what claude-brain needs on this machine, whatever this machine is.
#
#   host/bootstrap.sh [--profile local|droplet] [--unattended] [--dry-run]
#                     [--with-rust] [--no-claude]
#
# Shared by every install path: the local installer runs it on your Mac or
# Linux box, and cloud-init runs it on a fresh droplet. Idempotent — anything
# already present is left alone.

set -euo pipefail

SELF_DIR="$(cd -P "$(dirname "$0")" && pwd)"
# shellcheck source=lib/platform.sh
. "$SELF_DIR/lib/platform.sh"

PROFILE=local
UNATTENDED=0
DRY=0
WITH_RUST=0
WITH_CLAUDE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)    PROFILE="${2:?}"; shift 2 ;;
    --unattended) UNATTENDED=1; shift ;;
    --dry-run)    DRY=1; shift ;;
    --with-rust)  WITH_RUST=1; shift ;;
    --no-claude)  WITH_CLAUDE=0; shift ;;
    -h|--help)    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

C_BOLD='' C_RESET='' C_YELLOW=''
if [ -t 1 ]; then C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'; C_YELLOW=$'\033[33m'; fi
info() { printf '%s %s\n' "${C_BOLD}==>${C_RESET}" "$*"; }
warn() { printf '%s %s\n' "${C_YELLOW} !${C_RESET}" "$*" >&2; }
# Steps are written as one shell string so --dry-run can print them verbatim;
# that is the whole point, so the eval is deliberate.
run()  {
  if [ "$DRY" -eq 1 ]; then printf '  %s\n' "$*"; else eval "$*"; fi
}

OS="$(brain_os)"
[ "$OS" = unsupported ] && { warn "unsupported OS: $(uname -s). claude-brain needs macOS or Linux."; exit 1; }

info "target: $(brain_distro) · $OS/$(brain_arch) · profile=$PROFILE"
brain_target_supported || warn "$(brain_distro) is not one of the tested targets (macOS, Arch, Ubuntu/Debian) — continuing, but you may have to install a package or two by hand"

# ---- Homebrew (macOS only) --------------------------------------------------
# Installing Homebrew is a large, visible change to someone's personal machine,
# so it is never silent: unattended runs say so, interactive runs ask.
if [ "$OS" = macos ] && ! command -v brew >/dev/null 2>&1; then
  if [ "$DRY" -eq 1 ]; then
    printf '  install Homebrew (https://brew.sh)\n'
  elif [ "$UNATTENDED" -eq 1 ]; then
    info "installing Homebrew (required to install the rest)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    printf 'claude-brain needs Homebrew to install its dependencies.\n'
    printf 'Install it now from https://brew.sh? [Y/n] '
    read -r reply </dev/tty || reply=""
    case "$reply" in
      n|N|no|NO) warn "skipping Homebrew — install git, tmux, jq, go and gh yourself, then re-run"; exit 1 ;;
      *) /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ;;
    esac
  fi
  # A fresh install is not on PATH for this shell yet.
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [ -x /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"
fi

MGR="$(pkg_manager)"
[ "$MGR" = none ] && { warn "no supported package manager (brew/pacman/apt/dnf) found"; exit 1; }

# ---- package index ----------------------------------------------------------
case "$MGR" in
  apt)    run "sudo apt-get update -qq" ;;
  pacman) run "sudo pacman -Sy --noconfirm >/dev/null" ;;
esac

# ---- core packages ----------------------------------------------------------
# tree is optional but lets the compression engine render directory listings.
info "installing core tools (git, tmux, jq, curl, openssl, tree)"
if [ "$DRY" -eq 1 ]; then
  pkg_install --dry-run git tmux jq curl openssl tree
else
  pkg_install git tmux jq curl openssl tree || warn "some core packages failed to install — check the output above"
fi

# GNU coreutils on macOS gives us gtimeout; not required, but nice to have.
if [ "$MGR" = brew ]; then
  if [ "$DRY" -eq 1 ]; then pkg_install --dry-run coreutils; else pkg_install coreutils || true; fi
fi

# ---- GitHub CLI -------------------------------------------------------------
if command -v gh >/dev/null 2>&1; then
  info "gh already installed"
else
  info "installing the GitHub CLI"
  case "$MGR" in
    apt)
      # gh is not in Debian/Ubuntu's own repos; add the official one.
      run "sudo mkdir -p -m 755 /etc/apt/keyrings"
      run "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null"
      run "sudo chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg"
      run "echo 'deb [arch=$(dpkg --print-architecture 2>/dev/null || echo amd64) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null"
      run "sudo apt-get update -qq"
      if [ "$DRY" -eq 1 ]; then pkg_install --dry-run gh; else pkg_install gh || warn "gh install failed (optional — GitHub support only)"; fi
      ;;
    *)
      if [ "$DRY" -eq 1 ]; then pkg_install --dry-run gh; else pkg_install gh || warn "gh install failed (optional — GitHub support only)"; fi
      ;;
  esac
fi

# ---- Go (required: the model router is built from pinned source) ------------
go_path_hint
if command -v go >/dev/null 2>&1; then
  info "go already installed ($(go version 2>/dev/null | awk '{print $3}'))"
elif [ "$MGR" = apt ]; then
  # Ubuntu 24.04 ships a Go too old for the pinned proxy build; use the tarball.
  GO_VER=1.24.5
  case "$(brain_arch)" in arm64) GO_ARCH=arm64 ;; *) GO_ARCH=amd64 ;; esac
  info "installing Go $GO_VER (apt's is too old for the pinned router build)"
  run "curl -fsSL https://go.dev/dl/go$GO_VER.linux-$GO_ARCH.tar.gz -o /tmp/go.tgz"
  run "sudo rm -rf /usr/local/go"
  run "sudo tar -C /usr/local -xzf /tmp/go.tgz"
  run "rm -f /tmp/go.tgz"
  run "printf 'export PATH=\$PATH:/usr/local/go/bin\n' | sudo tee /etc/profile.d/golang.sh >/dev/null"
  go_path_hint
else
  info "installing Go"
  if [ "$DRY" -eq 1 ]; then pkg_install --dry-run go; else pkg_install go || warn "go install failed — the model router cannot be built without it"; fi
fi

# ---- Rust (optional: the compression engine) --------------------------------
if [ "$WITH_RUST" -eq 1 ] && ! command -v cargo >/dev/null 2>&1; then
  info "installing Rust (for the compression engine)"
  case "$MGR" in
    apt) run "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path" ;;
    *)   if [ "$DRY" -eq 1 ]; then pkg_install --dry-run rust; else pkg_install rust || warn "rust install failed — compression falls back to the bundled shell implementation"; fi ;;
  esac
fi

# ---- Claude Code ------------------------------------------------------------
if [ "$WITH_CLAUDE" -eq 1 ]; then
  if command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then
    info "claude already installed"
  else
    info "installing Claude Code"
    run "curl -fsSL https://claude.ai/install.sh | bash"
  fi
fi

# ---- droplet-only hardening -------------------------------------------------
# A rented VM with a public IP needs a firewall and a service that survives
# logout. Someone's own Mac or desktop does not — we never touch those.
if [ "$PROFILE" = droplet ] && [ "$OS" = linux ]; then
  info "droplet hardening: ufw (SSH only) + systemd linger"
  run "sudo ufw allow OpenSSH >/dev/null"
  run "sudo ufw --force enable >/dev/null"
  run "sudo loginctl enable-linger \"$(id -un)\""
fi

info "dependencies ready"
