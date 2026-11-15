#!/bin/bash
# Start a named, remote-controllable engineering shift on this Mac from any shell or session:
#   shift-start.sh <repo-folder> [--model opus] [--mode auto] [--close-ended [--close-after 10]] [--not-chained]
#   shift-start.sh <repo-folder> --leftovers     list processes left in the folder, start nothing
#   shift-start.sh <repo-folder> --began N       exit 0 if the state file shows shift N started or ended, or a later shift; else 1 (2 on a bad call)
# Names it "<Project> shift <N>" (N from the state file's Shift: line, plus one), starts an
# interactive claude session with Remote Control inside a detached tmux session, and sends
# "/agent-team:shift" as its first message. The session then shows up in the Claude app.
# An ending shift starts its successor with the same command (the shift skill), once its state file is
# merged; the session's Claude Code state is cleared from the new claude's environment. Ended shifts'
# sessions stay open until the owner archives them in the app (the next start then closes them: archiving
# alone leaves the process running) unless --close-ended: then all are closed at the start, and the
# ending shift's own session --close-after minutes after the new shift reports. It can wait
# up to ten minutes for the shift to report, so from a Claude session run it in the background or with a
# long tool timeout; the tmux session survives the script either way. Needs tmux (brew install tmux).
set -eu
dir=""; model="opus"; mode="auto"; leftovers_only=""; began_n=""; close_after=10; not_chained=""; close_ended=""
while [ $# -gt 0 ]; do
  case "$1" in
    --leftovers) leftovers_only=1; shift ;;   # only print the leftover listing for the folder and exit
    --began) began_n="${2:-}"; case "$began_n" in ''|*[!0-9]*) echo "--began needs a shift number" >&2; exit 2 ;; esac; shift 2 ;;   # exit 0/1: the state file shows shift N started
    --model) model="${2:-}"; [ -n "$model" ] || { echo "--model needs a value" >&2; exit 2; }; shift 2 ;;
    --mode) mode="${2:-}"; [ -n "$mode" ] || { echo "--mode needs a value" >&2; exit 2; }; shift 2 ;;
    --not-chained) not_chained=1; shift ;;   # the owner asked the ended session for this start: it counts as a person's start
    --close-ended) close_ended=1; shift ;;   # close ended shifts' sessions: leftovers now, the own one --close-after minutes after the start (the app archives them)
    --close-after) close_after="${2:-}"; case "$close_after" in ''|*[!0-9]*) echo "--close-after needs minutes" >&2; exit 2 ;; esac; close_after=$((10#$close_after)); close_ended=1; shift 2 ;;   # minutes until the ended session closes; implies --close-ended
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) dir="$1"; shift ;;
  esac
done
[ -n "$dir" ] || { echo "usage: shift-start.sh <repo-folder> [--model opus] [--mode auto] [--close-ended [--close-after 10]] [--not-chained] [--leftovers] [--began N]" >&2; exit 2; }
[ -d "$dir" ] || { echo "shift-start.sh: no such folder: $dir" >&2; exit 2; }
dir=$(cd "$dir" && pwd -P)
# The working directory of a process: lsof on macOS, /proc elsewhere; empty when unknown.
cwd_of() { { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; } || true; [ -e "/proc/$1/cwd" ] && readlink "/proc/$1/cwd" 2>/dev/null || true; }
# Processes an earlier session left behind in this folder (a wait loop that never ended, a watcher
# started with `&`) outlive it; the new session is not allowed to stop another session's processes,
# the owner is. Listed only; nothing is killed here. Candidates: anything that names the folder on its
# command line, and any watcher whose working directory is the folder or inside it (a watcher's folder
# is its cwd, not on its command line; a watcher of another project is another shift's, not a leftover).
# Excluded narrowly, by the command's own name, not by substring: a session's shell carries "claude"
# in its argv (the shell-snapshot path), and that is exactly what a leftover looks like. An ended shift's
# session stays open by default, so a watcher that shift left running is listed here, which is the point;
# with --close-ended the session is closed first and its watcher dies with it.
list_leftovers() {
  local d="$1" left watchers pid cwd line keep=""
  # Named on the command line: the folder itself, or a path inside it; not a sibling whose name merely
  # starts with it (Project2 is not Project). Each occurrence is judged by the characters around it:
  # after it, the end of the line, "/" or a shell delimiter; when a quote opens it, the same quote or "/"
  # must close it, so a quoted "Project copy" is not Project. An unquoted argument containing a space
  # cannot be told from two arguments in ps output, so "cd /x/Project copy" written without quotes is
  # still listed, and so is a longer path that ends with the folder's (a backup volume's copy), since on
  # macOS the same folder is reachable under /System/Volumes/Data as well; the folder path is passed
  # through the environment, since awk -v would unescape it.
  left=$( { ps -axo pid=,etime=,command= 2>/dev/null | grep -F -- "$d" || true; } )
  left=$(printf '%s\n' "$left" | D="$d" awk '
    BEGIN { d = ENVIRON["D"]; n = length(d); delim = " \t;)(|&<>:,=`" }
    {
      s = $0; off = 0; ok = 0
      while ((i = index(s, d)) > 0) {
        pos = off + i
        before = (pos > 1) ? substr($0, pos - 1, 1) : ""
        after = substr($0, pos + n, 1)
        if (after == "" || after == "/") ok = 1
        else if (before == "\047" || before == "\"") { if (after == before) ok = 1 }
        else if (after == "\047" || after == "\"" || index(delim, after) > 0) ok = 1
        if (ok) break
        s = substr(s, i + 1); off = pos
      }
      if (ok) print
    }' || true)
  watchers=$( { ps -axo pid=,etime=,command= 2>/dev/null | grep -F 'watch-github.py' || true; } )
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid=$(printf '%s' "$line" | awk '{print $1}'); cwd=$(cwd_of "$pid" | head -1)
    case "$cwd" in "$d"|"$d"/*) keep="$keep$line
" ;; esac
  done <<EOF
$watchers
EOF
  left=$(printf '%s\n%s' "$left" "$keep" | sort -u | awk 'NF >= 3 { c=$3; sub(/.*\//, "", c); if (c == "claude" || c == "tmux" || c == "grep" || c == "awk" || c == "ps" || c == "sort") next; if ($0 ~ /remote-control|shift-start/) next; print }' || true)
  if [ -n "$left" ]; then
    echo "note: processes still mention $d or watch it (not stopped; a shift cannot kill another session's processes). If they are leftovers of an earlier session, stop them by pid:" >&2
    printf '%s\n' "$left" | head -10 | sed 's/^/  /' >&2
  fi
}
# A shift has begun when the state file says so: the skill's first housekeeping commit writes "Shift: N started"
# and merges it, so origin/main or the working tree carries the line within minutes. The screen is only a
# fast path: Claude Code redraws in place, tmux keeps little of it, and a session may announce the start
# only in its thinking (the first project's shift 6, 2026-11-06, where the old screen check waited ten minutes for nothing).
# origin/main is read through a scratch git directory, never by fetching in the session's own repository:
# a fetch there races the session's first `git pull` (FETCH_HEAD and origin/main are shared) and makes it fail.
# The working-tree line counts only when the file changed after this script started ($3, a stamp file): a dead
# earlier shift of the same number can have left the line behind. `--began` has no stamp and takes the line as is.
scratch_git=""
# "Begun" is: the line shows shift N started or ended, or any later shift (a shift cannot end without starting).
began_line() { awk -v n="$1" '/^Shift: *[0-9]+ (started|ended)/ { sub(/^Shift: */, ""); split($0, a, " "); if (a[1] + 0 >= n + 0) found = 1 } END { exit found ? 0 : 1 }'; }
shift_began() {   # $1 = n, $2 = dir, $3 = stamp file or empty
  if [ -z "$3" ] || [ "$2/.agent-team/state.md" -nt "$3" ]; then
    began_line "$1" < "$2/.agent-team/state.md" 2>/dev/null && return 0
  fi
  local url; url=$(git -C "$2" remote get-url origin 2>/dev/null) || return 1
  # The URL is added as a remote once (it then stays off every poll's command line); the first depth-1 fetch
  # brings main's tree once per start, later polls are incremental.
  if [ -z "$scratch_git" ]; then scratch_git=$(mktemp -d "${TMPDIR:-/tmp}/shift-start.XXXXXX") || return 1; git init -q --bare "$scratch_git" 2>/dev/null || return 1; git --git-dir="$scratch_git" remote add origin "$url" 2>/dev/null || return 1; fi
  if ! git --git-dir="$scratch_git" fetch -q --depth 1 origin main 2>/dev/null; then
    [ -n "${fetch_warned:-}" ] || echo "note: could not fetch origin/main to read the state file (offline, or a relative origin URL); only the working tree is checked" >&2
    fetch_warned=1; return 1
  fi
  git --git-dir="$scratch_git" show FETCH_HEAD:.agent-team/state.md 2>/dev/null | began_line "$1"
}
trap '[ -n "$scratch_git" ] && rm -rf "$scratch_git"' EXIT
if [ -n "$began_n" ]; then if shift_began "$began_n" "$dir" ""; then exit 0; else exit 1; fi; fi
if [ "$leftovers_only" = 1 ]; then list_leftovers "$dir"; exit 0; fi
command -v tmux >/dev/null || { echo "tmux is not installed; brew install tmux" >&2; exit 1; }
command -v claude >/dev/null || { echo "claude is not on the PATH" >&2; exit 1; }
project=$(sed -n 's/^# \(.*\)/\1/p' "$dir/CLAUDE.md" 2>/dev/null | grep -v -i -e 'team process' -e 'how this repo' | head -1 | sed 's/ *<!--.*//; s/:.*//; s/ and .*//')
[ -n "$project" ] || project=$(basename "$dir")
# The skill writes the shift number through a merge on GitHub, so read it from origin/main,
# not from a local checkout that may be behind; fall back to the working tree if offline.
if git -C "$dir" fetch -q origin main 2>/dev/null; then
  state=$(git -C "$dir" show origin/main:.agent-team/state.md 2>/dev/null || true)
else
  echo "could not fetch origin/main; using the local state file (if git over SSH is refused, try: ssh -T git@github.com; GitHub incidents answer with 'Permission denied (publickey)' too)" >&2
  state=$(cat "$dir/.agent-team/state.md" 2>/dev/null || true)
fi
last=$(printf '%s\n' "$state" | sed -n 's/^Shift: *\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$last" ] || echo "no Shift: line in the state file; this will be shift 1 (set the line in .agent-team/state.md if the project has had shifts before)" >&2
n=$(( ${last:-0} + 1 ))
title="$project shift $n"
# An untrusted folder makes the session wait on a local keypress; say so instead of starting.
# A plain folder is trusted if it or any parent has an accepted trust dialog; a git repository
# is asked again at its own root (seen on the agent Mac, 2026-11-04, Claude Code 2.x: an empty
# plain folder under a trusted parent got no prompt, an empty git repo under the same parent did).
# Taking that as "a repository is keyed by its root" for any folder inside one is a generalisation
# nobody has tested; it errs towards refusing, which only costs a run of claude at the Mac.
top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
trusted=$(python3 -I -c 'import json,sys,os
d=json.load(open(sys.argv[1])).get("projects",{}); p=sys.argv[2]; top=sys.argv[3]
if top:
    print("True" if d.get(top,{}).get("hasTrustDialogAccepted") else "False"); sys.exit()
while True:
    if d.get(p,{}).get("hasTrustDialogAccepted"): print("True"); break
    q=os.path.dirname(p)
    if q==p: print("False"); break
    p=q' "$HOME/.claude.json" "$dir" "$top" 2>/dev/null || echo unknown)
if [ "$trusted" = "False" ]; then
  echo "claude has not been told to trust $dir yet: open claude in that folder once at the Mac and accept the trust prompt, then run this again" >&2; exit 1
fi
tmux_name=$(printf '%s' "$title" | tr -c 'A-Za-z0-9\n' '-')
if tmux has-session -t "=$tmux_name" 2>/dev/null; then echo "a tmux session named $tmux_name already exists" >&2; exit 1; fi
# The project's earlier tmux sessions (ten shifts back): while the state file shows the previous shift started,
# any alive one may host it and the start is refused (below); once it shows ended, they are ended shifts'
# sessions, listed and left open by default, or closed with --close-ended (the one this script runs in, an
# ending shift starting its successor, on a timer after the successor reports).
# The current session by name only when the pane is known: without TMUX_PANE, display-message answers for the
# most recently created session, which would be the wrong one (the ancestry check below needs neither).
cur=""; [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && cur=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)
own=""   # set when the script runs inside the ended previous shift's own session (a successor start)
# The session this script runs in, found without the environment too: one of its panes' processes is an ancestor
# of this one (a Bash tool that did not pass TMUX on would otherwise let the script close the session around it).
# Every pane of the session counts, not only the current window's: the owner may have attached and opened another.
own_session() {  # $1 = tmux session name
  local pids p; pids=$(tmux list-panes -s -t "=$1" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ') || return 1
  [ -n "$(printf '%s' "$pids" | tr -d ' ')" ] || return 1
  p=$$; while [ "$p" -gt 1 ]; do
    case " $pids " in *" $p "*) return 0 ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); case "$p" in ''|*[!0-9]*) return 1 ;; esac
  done
  return 1
}
prev=$(( n - 1 ))
prev_ended=$(printf '%s\n' "$state" | grep -c "^Shift: *$prev ended" || true)
# While the state file shows the previous shift started and not ended, nothing is closed and nothing starts if
# any session of this project is alive: the running shift may live in a session named for an older one (a
# session that opened the next shift inside itself, as the first project's shift 11 did in shift 10's session). With no
# session alive, the previous shift died without ending, the normal failure, and the start goes ahead.
alive=""; k=$prev
while [ "$k" -gt 0 ] && [ "$k" -gt $(( prev - 10 )) ]; do
  k_name=$(printf '%s shift %s' "$project" "$k" | tr -c 'A-Za-z0-9\n' '-')
  tmux has-session -t "=$k_name" 2>/dev/null && alive="$alive $k_name"
  k=$(( k - 1 ))
done
if [ "$prev" -gt 0 ] && [ "${prev_ended:-0}" -eq 0 ] && [ -n "$alive" ]; then
  for k_name in $alive; do
    if [ "$k_name" = "$cur" ] || own_session "$k_name"; then
      echo "this is shift $prev's own session and the state file on origin/main does not show it ended: merge the state file with 'Shift: $prev ended' first, then start the successor" >&2; exit 1
    fi
  done
  echo "shift $prev is still running (the state file on origin/main shows it started, not ended) and these tmux sessions are alive:$alive; end it first with 'end the shift' there (tmux attach -t <name>), or, if a session is a leftover of an ended shift, tmux kill-session -t <name>" >&2; exit 1
fi
# Ended shifts' sessions: the owner prefers them open in the app (an ended chat stays in the active list; a killed one
# is archived, readable), at the cost of an idle claude each, so closing is opt-in (--close-ended). One kind is
# closed by default: a session the owner has archived in the app. Archiving disconnects Remote Control and leaves
# the local claude running, unreachable, with its memory (seen on the Mac: the disconnect line on the pane with
# the reason that the session was ended or archived elsewhere, the process alive); the owner has already decided
# about that chat. The reason is matched, not the disconnect alone: the same line ends with other reasons (a
# login needed, a transport that gave up) where the chat is still active in the app and the owner wants it
# kept. Every pane of the session is read, since the owner may have opened a second window. The line is longer
# than a detached session's 80 columns, so tmux's wraps are joined (-J) and any wrap the TUI itself made, a
# newline and indentation inside the phrase, is folded to single spaces before the match (on the Mac it is the
# TUI's wrap, two lines with a two-space indent). The pane holds only its visible lines, since the TUI redraws in
# place: the match holds because an archived session goes idle with the line on screen, and anything that makes
# it print more afterwards (someone attaching and typing) can push the line off, in which case the session is
# listed as open instead of closed, never the other way round.
archived_session() {
  local pane
  for pane in $(tmux list-panes -s -t "=$1" -F '#{pane_id}' 2>/dev/null); do
    tmux capture-pane -p -J -S - -t "$pane" 2>/dev/null | tr -s '[:space:]' ' ' | grep -q 'ended or archived from another device or app' && return 0
  done
  return 1
}
open_ended=""
for k_name in $alive; do
  k=${k_name##*-}
  if [ "$k_name" = "$cur" ] || own_session "$k_name"; then
    own="$k_name"
    if [ -n "$close_ended" ]; then echo "shift $k's own session is starting this one; it closes $close_after min after the new shift reports its start"
    elif archived_session "$k_name"; then echo "shift $k's own session is starting this one; it is already archived in the app, so the next start closes it"
    else echo "shift $k's own session is starting this one; it stays open until you archive it in the app (the start after that closes it)"; fi
  elif [ -z "$close_ended" ] && archived_session "$k_name"; then
    tmux kill-session -t "=$k_name" && echo "closed the tmux session of shift $k: ended, and its Remote Control was ended or archived from the app (its claude was running on, unreachable)"
  elif [ -z "$close_ended" ]; then
    open_ended="$open_ended $k_name"
  elif [ "$k" = "$prev" ]; then
    tmux kill-session -t "=$k_name" && echo "closed the tmux session of shift $k, which had ended"
  else
    tmux kill-session -t "=$k_name" && echo "closed the tmux session of the earlier shift $k"
  fi
done
[ -z "$open_ended" ] || echo "ended shifts' sessions still open in the app (archive them there and the next start closes them, or tmux kill-session -t '=<name>' now; --close-ended would close them all):$open_ended"
list_leftovers "$dir"
# Started from inside a Claude Code session (an ending shift starting its successor), the environment carries
# that session's state (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT, CLAUDE_PID, the session id and messaging socket, …),
# and the tmux server hands new sessions its own global environment too, which is a session's when the server
# was first started from one (seen on the Mac: a stale CLAUDE_PID reaching the new session's children). The
# known state names are cleared always. Every other CLAUDE* name that the owner's login shell does not set is
# cleared too (the names change with Claude Code versions), the owner's configuration (CLAUDE_CONFIG_DIR,
# CLAUDE_CODE_USE_BEDROCK, …) being what the login shell sets: from the server's environment always, from this
# environment only inside a session (from a terminal it is the owner's shell). When the login shell cannot be
# asked (it fails under env -i, or is not sh-like), only the known names go. Configuration the login shell does
# not set (launchctl setenv, the GUI login environment) is read as state and cleared; put it in the shell's files.
session_names="CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_WORKER_EPOCH CLAUDE_CODE_SESSION_ATTENDED CLAUDE_EFFORT"
claude_names() { sed -n 's/^\(CLAUDE[A-Z0-9_]*\)=.*/\1/p' | sort -u | tr '\n' ' '; }
unset_names="$session_names"
# The probe's answer counts only when the command itself ran, shown by a sentinel: a profile that hands off to
# another shell (`exec zsh`, `exec fish`) exits 0 having printed nothing, and an empty answer would read as "the
# owner sets nothing".
login_env=""; login_ok=""
if login_env=$(env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" PATH="$PATH" TERM=dumb "${SHELL:-/bin/sh}" -lic 'echo __shift_start_env__; env' 2>/dev/null </dev/null) \
   && printf '%s\n' "$login_env" | grep -qx '__shift_start_env__'; then login_ok=1; fi
if [ -n "$login_ok" ]; then
  owner_names=$(printf '%s\n' "$login_env" | claude_names)
  if [ -n "${CLAUDECODE:-}" ] || [ -n "$own" ]; then found=$( { env; tmux show-environment -g 2>/dev/null; } | claude_names ); else found=$(tmux show-environment -g 2>/dev/null | claude_names); fi
  # A known name the owner's shell sets on purpose (CLAUDE_EFFORT) is configuration too and stays.
  unset_names=""; for v in $session_names $found; do
    case " $owner_names " in *" $v "*) ;; *) unset_names="$unset_names $v" ;; esac
  done
fi
unset_args=""; for v in $(printf '%s\n' $unset_names | sort -u); do unset_args="$unset_args -u $v"; done
# A successor is told so: the shift skill counts chained starts against CLAUDE.md's `Shifts chain: max N`;
# --not-chained is for a start the owner asked for in the ended session, which counts as a person's start.
first_message="/agent-team:shift"; [ -n "$own" ] && [ -z "$not_chained" ] && first_message="/agent-team:shift chained"
# shellcheck disable=SC2086
tmux new-session -d -s "$tmux_name" -c "$dir" \
  env $unset_args claude --remote-control "$title" --model "$model" --permission-mode "$mode" "$first_message"
# A live tmux session is not a started shift: wait for the skill's first line on screen. The skill
# pulls main first, so a slow or degraded GitHub delays that line by minutes; wait up to ten.
began=""; waited=0; limit=600; t0=$(date +%s); stamp=$(mktemp "${TMPDIR:-/tmp}/shift-start-stamp.XXXXXX")
trap '[ -n "$scratch_git" ] && rm -rf "$scratch_git"; rm -f "$stamp"' EXIT
echo "waiting for \"$title\" to report its start (up to $((limit / 60)) min; Ctrl-C stops the wait, not the session)"
while [ "$waited" -lt "$limit" ]; do
  sleep 3; waited=$(( $(date +%s) - t0 ))
  tmux has-session -t "=$tmux_name" 2>/dev/null || break
  # capture-pane takes a pane target, so the session name needs its trailing colon (has-session does not).
  if tmux capture-pane -p -S - -t "=$tmux_name:" 2>/dev/null | grep -q "shift $n started"; then began=1; break; fi
  if [ $((waited / 15)) -gt "${last_fetch_slot:-0}" ]; then last_fetch_slot=$((waited / 15)); shift_began "$n" "$dir" "$stamp" && { began=1; break; }; fi
  if [ $((waited / 30)) -gt "${last_note_slot:-0}" ]; then last_note_slot=$((waited / 30)); echo "  still waiting (${waited} s); to look: tmux attach -t $tmux_name"; fi
done
if [ -n "$began" ]; then
  # The plugin the new session loads: the newest installed copy, or this script's own when none is installed.
  pv=$(find "$HOME/.claude/plugins/cache" -type f -path '*/agent-team/*/.claude-plugin/plugin.json' 2>/dev/null \
    | awk -F/ '{v=$(NF-2); split(v,a,"."); printf "%09d%09d%09d %s\n", a[1],a[2],a[3], v}' | sort | tail -1 | cut -d' ' -f2)
  [ -n "$pv" ] || pv=$("$(dirname "$0")/agentlock" version 2>/dev/null) || pv=""
  echo "started \"$title\" after ${waited} s in tmux session $tmux_name (model $model, mode $mode, plugin ${pv:-unknown}); it appears in the Claude app under that name"
  echo "to watch it here: tmux attach -t $tmux_name   (detach with Ctrl-b d)"
  # With --close-ended, the ended session that started this one is closed once the successor is known to run (an
  # idle claude keeps some 370 MB and a Remote Control connection, the Mac's measurement; the owner prefers the
  # open chat and pays that by default). The close runs in the tmux server, detached from this script, after a
  # delay that leaves room for the ending session's last report.
  if [ -n "$own" ] && [ -n "$close_ended" ]; then
    tmux run-shell -b "sleep $(( close_after * 60 )); tmux kill-session -t '=$own'" 2>/dev/null \
      && echo "the ended session $own closes in $close_after min (tmux run-shell, detached from this script)"
  fi
elif tmux has-session -t "=$tmux_name" 2>/dev/null; then
  echo "the session is up but the state file does not show shift $n started after $((limit / 60)) min: look with  tmux attach -t $tmux_name  (it may be waiting on a trust or permission prompt, the slash command may not have been taken as the first message (then type /agent-team:shift there), or the first housekeeping merge is slow: check again with  shift-start.sh --began $n \"$dir\")" >&2
  exit 2
else
  echo "the session exited after ${waited} s; run it in the foreground to see why:" >&2
  echo "  cd \"$dir\" && claude --remote-control \"$title\" --model $model --permission-mode $mode \"/agent-team:shift\"" >&2
  exit 1
fi
