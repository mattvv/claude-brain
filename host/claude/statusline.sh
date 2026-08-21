#!/usr/bin/env bash
# claude-brain statusline: model · dir, plus live consultation activity when a
# brain-ask --stream log is actively being written (see host/bin/brain-ask),
# plus lifetime estimated token savings from the compression ledger, plus
# subscription headroom while it is low enough to matter.
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

state="${BRAIN_STATE_DIR:-$HOME/.local/state/brain}"
consult="$state/consult/current"
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

# Compression savings segment. summary.txt is written atomically by the ledger
# on every append (host/native/brain-compress/src/ledger.rs::write_summary).
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

# Subscription headroom segment. Written atomically by usage_refresh_anthropic
# (droplet/lib/common.sh). Read-only and awk-only on purpose: the statusline runs
# at refreshInterval=2, so this must never fetch, and never spawn jq or curl.
# Shown only when it is actionable — silent at healthy headroom, and silent when
# the sample is missing, unparseable, or older than the window it describes.
usage_summary="$state/usage/summary.txt"
if [ -r "$usage_summary" ]; then
  # -1 when the key is absent: a truncated summary must read as "no data", not
  # as 0% headroom, which would falsely announce an exhausted subscription.
  read -r headroom u_updated < <(
    awk 'NR==1{for(i=1;i<=NF;i++){split($i,kv,"=");v[kv[1]]=kv[2]}
         print (("headroom" in v) ? v["headroom"]+0 : -1),
               (("updated_at" in v) ? v["updated_at"]+0 : -1)}' "$usage_summary" 2>/dev/null
  ) || true
  settings="${BRAIN_CONFIG_DIR:-$HOME/.config/brain}/settings"
  reserve="$(sed -n 's/^USAGE_RESERVE_PCT=//p' "$settings" 2>/dev/null | tail -1)"
  advisory="$(sed -n 's/^USAGE_ADVISORY_PCT=//p' "$settings" 2>/dev/null | tail -1)"
  reserve="${reserve:-15}"; advisory="${advisory:-35}"
  now="$(date +%s)"
  age=$((now - ${u_updated:-0}))
  if [ "${u_updated:-0}" -gt 0 ] && [ "$age" -ge -300 ] && [ "$age" -le 18000 ] \
     && [ "${headroom:--1}" -ge 0 ] && [ "$headroom" -le "$advisory" ]; then
    if [ "$headroom" -le "$reserve" ]; then
      line="$line │ 🪫 ${headroom}% claude — reserve"
    else
      line="$line │ ⚡ ${headroom}% claude"
    fi
  fi
fi

printf '%s' "$line"
