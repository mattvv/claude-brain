#!/usr/bin/env bash
# Back-compat shim. The published one-liner used to be setup.sh and only ever
# made a DigitalOcean droplet; claude-brain now installs on any computer, so
# install.sh is the entry point. Keep this until the old URL stops being shared.
set -euo pipefail
DIR="$(cd -P "$(dirname "$0")" && pwd)"
printf 'setup.sh now lives at install.sh --digitalocean; running that for you.\n\n' >&2
exec "$DIR/install.sh" --digitalocean "$@"
