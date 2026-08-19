#!/usr/bin/env bash
# claude-brain statusline: model · dir, plus live consultation activity when a
# brain-ask --stream log is actively being written (see droplet/bin/brain-ask).
set -uo pipefail

input="$(cat)"
model="$(jq -r '.model.display_name // empty' <<<"$input" 2>/dev/null)"
dir="$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input" 2>/dev/null)"
line="${model:-claude}${dir:+ · ${dir##*/}}"

consult="${BRAIN_STATE_DIR:-$HOME/.local/state/brain}/consult/current"
if [ -e "$consult" ]; then
  # Live while a brain-ask runs (xhigh models think silently for minutes before
  # the first text delta), or briefly after, so the finish is visible.
  now="$(date +%s)"
  mtime="$(stat -Lc %Y "$consult" 2>/dev/null || echo 0)"
  if pgrep -f 'brain-ask ' >/dev/null 2>&1 || [ $((now - mtime)) -le 45 ]; then
    target="$(basename "$(readlink -f "$consult")")"
    name="${target%-*.log}"
    bytes="$(stat -Lc %s "$consult" 2>/dev/null || echo 0)"
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
