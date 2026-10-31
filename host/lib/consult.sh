# shellcheck shell=bash
# Which brain-ask consultations are live, and for whom. Sourced by common.sh and
# by the statusline (which skips common.sh because it runs every few seconds).
#
# The brain-ask launcher writes consult/owners/<pid> before it execs:
#   line 1  the Claude session id (empty outside Claude Code)
#   line 2  the start time, epoch seconds
#   line 3  the model, with the character rule the log name uses
#   line 4  the process start time from `ps -o lstart=`, so a reused pid never
#           passes for the run
#   line 5  the answer log, appended by the applet once it creates it (native
#           0.4.3+ and the legacy script); older applets leave it out
# A consultation is live only while that exact process still runs. Matching
# `pgrep -f 'brain-ask '` instead counted any process whose command line merely
# mentioned brain-ask (a grep, an editor, the agent's own shell), and the
# machine-wide `current` link then showed a finished log as streaming in every
# session on the machine.

# Set by consult_current_log for its callers (`brain consult wait` reads it).
# shellcheck disable=SC2034
CONSULT_LOG_LIVE=0

consult_owner_dir() {
  printf '%s/consult/owners' "${BRAIN_STATE_DIR:-$HOME/.local/state/brain}"
}

# Pinned locale and zone: the stored text is compared byte for byte later.
_consult_process_start() {
  LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | sed 's/  */ /g; s/^ //; s/ $//'
}

# Called by the brain-ask launcher with its arguments; $$ survives its exec.
# Written to a temp file and renamed, so a scan never sees half a record.
consult_register_owner() {
  local dir model session tmp
  dir="$(consult_owner_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  model="$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_')"
  # Inside a Claude Code build that does not export its session id, record "*"
  # so every session still sees the run, as before. A terminal run stays empty.
  session="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$session" ] || [ -z "${CLAUDECODE:-}" ] || session="*"
  tmp="$dir/.$$.tmp"
  printf '%s\n%s\n%s\n%s\n' "$session" "$(date +%s)" "$model" \
    "$(_consult_process_start $$)" >"$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$$" 2>/dev/null
  return 0
}

# True while pid $1 is still the process that registered with start time $2. A
# pid and its start time together name one process; a reused pid starts later.
_consult_owner_alive() {
  local pid="$1" started="$2" record="$3"
  # An exited child its parent has not reaped yet keeps its start time.
  case "$(ps -o stat= -p "$pid" 2>/dev/null)" in Z* | *Z*) return 1 ;; esac
  if [ -n "$started" ]; then
    [ "$(_consult_process_start "$pid")" = "$started" ]
    return
  fi
  # Owner files from launchers that predate line 4: the older, weaker check,
  # trusted only for an hour, so a reused pid cannot keep one alive for long.
  [ $(($(date +%s) - $(file_mtime "$record"))) -le 3600 ] || return 1
  case "$(ps -ww -o args= -p "$pid" 2>/dev/null)" in
    *brain-ask*) return 0 ;;
  esac
  return 1
}

# The answer log of a run of model $2 started at $1: <model>-<unix>.log. The
# native applet and the legacy script both create it within a second or two of
# the launcher starting. The earliest match wins, so a later run of the same
# model (its own owner, a later stamp) never takes this one's; logs that other
# owners recorded ($3, "|path|" list) are never guessed.
_consult_log_for_start() {
  local start="$1" model="$2" claimed="${3:-}" dir f stamp best="" best_stamp=""
  dir="$(dirname "$(consult_owner_dir)")"
  for f in "$dir/$model"-*.log; do
    [ -f "$f" ] || continue
    case "$claimed" in *"|$f|"*) continue ;; esac
    # Exactly <model>-<unix>[.N].log: model m must not match m-other-<unix>.log.
    stamp="${f#"$dir/$model"-}"
    stamp="${stamp%.log}"
    case "$stamp" in *.*) [ -z "${stamp#*.}" ] || case "${stamp#*.}" in *[!0-9]*) continue ;; esac ;; esac
    stamp="${stamp%%.*}"
    case "$stamp" in '' | 0* | *[!0-9]*) continue ;; esac
    [ "$stamp" -ge "$start" ] && [ "$stamp" -le $((start + 10)) ] || continue
    if [ -z "$best_stamp" ] || [ "$stamp" -lt "$best_stamp" ]; then
      best="$f"
      best_stamp="$stamp"
    fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

# consult_current_log [session]: the answer log of the newest running
# consultation, else of the newest that finished within 45s so its completion
# stays visible. Prints
# nothing and returns 1 when there is none. Sets CONSULT_LOG_LIVE to 1 when the
# chosen run is still running, 0 when it has finished. A running consult whose
# log does not exist yet reports <model>-pending.log, a path that never exists.
#
# With a session id, only that session's runs count. Without one (a terminal,
# or a client that sends no session id), only runs started without a session
# count, so a run from one place never lights up the other. A run recorded as
# "*" (a Claude Code build without a session id) counts for everyone.
#
# Prunes owner files whose log was last written over 10 minutes ago, whichever
# session started them, before the session filter, so leftovers never pile up.
consult_current_log() {
  local want="${1:-}" dir f pid session start model started log last now live
  local best="" best_start=0 best_live=0
  CONSULT_LOG_LIVE=0
  dir="$(consult_owner_dir)"
  [ -d "$dir" ] || return 1
  now="$(date +%s)"
  local claimed="" recorded
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    recorded=""
    { read -r _ && read -r _ && read -r _ && read -r _ && read -r recorded; } <"$f" 2>/dev/null
    [ -z "$recorded" ] || claimed="$claimed|$recorded|"
  done
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    pid="${f##*/}"
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    # Builtin reads, no subprocesses: the statusline runs this every few seconds.
    session="" start="" model="" started="" log=""
    { read -r session; read -r start; read -r model; read -r started; read -r log; } <"$f" 2>/dev/null
    case "$start" in '' | 0* | *[!0-9]*) rm -f "$f"; continue ;; esac
    [ -n "$model" ] || { rm -f "$f"; continue; }
    if [ -z "$log" ] || [ ! -f "$log" ]; then
      log="$(_consult_log_for_start "$start" "$model" "$claimed")" || log=""
    fi
    if _consult_owner_alive "$pid" "$started" "$f"; then
      live=1
    else
      live=0
      # Last sign of life: the answer, or the reasoning for a run that ends silent.
      last="$(file_mtime "$f")"
      if [ -n "$log" ]; then
        last="$(file_mtime "$log")"
        if [ -f "$log.thinking" ] && [ "$(file_mtime "$log.thinking")" -gt "$last" ]; then
          last="$(file_mtime "$log.thinking")"
        fi
      fi
      if [ $((now - last)) -gt 600 ]; then
        # A launcher may have just re-registered this pid: delete only the record read.
        [ "$(sed -n 2p "$f" 2>/dev/null)" != "$start" ] || rm -f "$f"
        continue
      fi
      [ -n "$log" ] && [ $((now - last)) -le 45 ] || continue
    fi
    [ "$session" = "$want" ] || [ "$session" = "*" ] || continue
    if [ -z "$log" ]; then
      # Started, log not created yet: still live, so the guard and status apply.
      [ "$live" -eq 1 ] || continue
      log="$(dirname "$dir")/$model-pending.log"
    fi
    # A running consult outranks one that just finished (a council runs several
    # at once); among equals, the newest wins.
    if [ "$live" -gt "$best_live" ] || { [ "$live" -eq "$best_live" ] && [ "$start" -ge "$best_start" ]; }; then
      best="$log"
      best_start="$start"
      best_live="$live"
    fi
  done
  [ -n "$best" ] || return 1
  CONSULT_LOG_LIVE="$best_live"
  printf '%s\n' "$best"
}
