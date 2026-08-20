#!/usr/bin/env bash
set -uo pipefail
BRAIN_DATA_DIR="${BRAIN_DATA_DIR:-$HOME/.local/share/brain}"
NATIVE="$BRAIN_DATA_DIR/native/current/brain-compress"
[ -x "$NATIVE" ] || exit 0
exec "$NATIVE" hook pre-read
