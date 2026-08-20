#!/usr/bin/env bash
# claude-brain statusline: model · dir, plus live consultation activity when a
# brain-ask --stream log is actively being written (see host/bin/brain-ask).
set -uo pipefail

input="$(cat)"
model="$(jq -r '.model.display_name // empty' <<<"$input" 2>/dev/null)"
dir="$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input" 2>/dev/null)"
line="${model:-claude}${dir:+ · ${dir##*/}}"

# Portable stat/readlink live in platform.sh; the statusline runs every couple
# of seconds, so it sources that one small file rather than all of common.sh.
_sl_self="${BASH_SOURCE[0]}"
while [ -L "$_sl_self" ]; do
  _sl_dir="$(cd -P "$(dirname "$_sl_self")" && pwd)"
  _sl_self="$(readlink "$_sl_self")"
  case "$_sl_self" in /*) ;; *) _sl_self="$_sl_dir/$_sl_self" ;; esac
done
# shellcheck source=../lib/platform.sh
. "$(cd -P "$(dirname "$_sl_self")/../lib" && pwd)/platform.sh"

consult="${BRAIN_STATE_DIR:-$HOME/.local/state/brain}/consult/current"
if [ -e "$consult" ]; then
  # Live while a brain-ask runs (xhigh models think silently for minutes before
  # the first text delta), or briefly after, so the finish is visible.
  now="$(date +%s)"
  mtime="$(file_mtime "$consult")"
  if pgrep -f 'brain-ask ' >/dev/null 2>&1 || [ $((now - mtime)) -le 45 ]; then
    target="$(basename "$(abs_path "$consult")")"
    name="${target%-*.log}"
    bytes="$(file_size "$consult")"
    if [ "$bytes" -eq 0 ]; then
      line="$line │ 🧠 $name thinking…"
    else
      snippet="$(tail -c 400 "$consult" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
      [ ${#snippet} -gt 70 ] && snippet="…${snippet: -70}"
      line="$line │ 🧠 $name $((bytes/1024))kB: $snippet"
    fi
  fi
fi
printf '%s' "$line"
