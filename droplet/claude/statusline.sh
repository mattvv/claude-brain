#!/usr/bin/env bash
# claude-brain statusline: model · dir, plus live consultation activity when a
# brain-ask --stream log is actively being written (see droplet/bin/brain-ask),
# plus lifetime estimated token savings from the compression ledger.
set -uo pipefail

input="$(cat)"
model="$(jq -r '.model.display_name // empty' <<<"$input" 2>/dev/null)"
dir="$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input" 2>/dev/null)"
line="${model:-claude}${dir:+ · ${dir##*/}}"

state="${BRAIN_STATE_DIR:-$HOME/.local/state/brain}"
consult="$state/consult/current"
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

# Compression savings segment. summary.txt is written atomically by the ledger
# on every append (droplet/native/brain-compress/src/ledger.rs::write_summary).
# Honesty rules carried into presentation: the figure is the ESTIMATED class and
# is labelled "est"; it is suppressed entirely below the minimum claim sample
# count (accounting.minimum_claim_samples, default 30) and when the summary is
# stale (>7 days) or absent. Never rendered as a bare unlabelled number.
summary="$state/compress/summary.txt"
if [ -r "$summary" ]; then
  read -r est_tokens samples updated < <(
    awk 'NR==1{for(i=1;i<=NF;i++){split($i,kv,"=");v[kv[1]]=kv[2]}
         print v["estimated_tokens"]+0, v["compressed_samples"]+0, v["updated_at"]+0}' \
      "$summary" 2>/dev/null
  ) || true
  min_samples="$(sed -n 's/^ *minimum_claim_samples *= *\([0-9][0-9]*\).*/\1/p' \
                   "$state/compress/compress.toml" 2>/dev/null | head -1)"
  min_samples="${min_samples:-30}"
  now="$(date +%s)"
  if [ "${samples:-0}" -ge "$min_samples" ] && [ "${est_tokens:-0}" -gt 0 ] \
     && [ $((now - ${updated:-0})) -le $((7 * 24 * 3600)) ]; then
    if [ "$est_tokens" -ge 10000 ]; then
      tok_h="$((est_tokens / 1000))k"
    elif [ "$est_tokens" -ge 1000 ]; then
      tok_h="$((est_tokens / 100))"
      tok_h="${tok_h%?}.${tok_h: -1}k"
    else
      tok_h="$est_tokens"
    fi
    line="$line │ 💾 ~${tok_h} tok est"
  fi
fi

printf '%s' "$line"
