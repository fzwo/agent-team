#!/bin/bash
# Keep a `claude remote-control` host running in a project folder as a launchd user agent,
# so sessions can be started there from the app without anyone at the Mac, and the host
# comes back after a reboot. Run from any session on the Mac; no terminal window needed.
#
#   host-add.sh <folder>            create (or replace) the host for that folder and start it
#   host-add.sh --remove <folder>   stop and delete it
#   host-add.sh --list              show hosts and whether they run
#
# First run on a Mac (2026-11-02): the host starts under launchd and finds its login.
# Logs: ~/Library/Logs/agent-team/host-<name>.log, trimmed to the last 200 KB whenever
# this script runs, since the host writes its screen into the log.
set -eu
agents="$HOME/Library/LaunchAgents"; logs="$HOME/Library/Logs/agent-team"
mkdir -p "$agents" "$logs"
uid=$(id -u)

# The label carries a hash of the full path, so two folders with one name do not collide.
label_for() { printf 'com.agent-team.host.%s-%s' "$(basename "$1" | tr -c 'A-Za-z0-9\n' '-')" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }
legacy_label() { printf 'com.agent-team.host.%s' "$(basename "$1" | tr -c 'A-Za-z0-9\n' '-')"; }   # labels before 0.4.0 had no checksum
stop_label() { launchctl bootout "gui/$uid/$1" 2>/dev/null || true; rm -f "$agents/$1.plist"; }
plist_dir() { sed -n 's/.*<key>WorkingDirectory<\/key><string>\(.*\)<\/string>.*/\1/p' "$1" 2>/dev/null | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g'; }
# The legacy label (before 0.4.0) had no checksum, so it may belong to another folder with the same name:
# stop it only when its plist names this folder.
stop_legacy_if_ours() {
  local l; l=$(legacy_label "$1")
  [ -f "$agents/$l.plist" ] || return 1
  if [ "$(plist_dir "$agents/$l.plist")" = "$1" ]; then stop_label "$l"; echo "stopped the pre-0.4.0 host $l for this folder"; return 0; fi
  echo "note: a pre-0.4.0 host $l exists for another folder, $(plist_dir "$agents/$l.plist"); left alone" >&2; return 1
}
xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# "running" means launchd reports a live pid for the job, not merely that the job is loaded
# (a loaded job that crashes and restarts also answers `launchctl print`).
host_pid() { launchctl print "gui/$uid/$1" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -1; }
host_state() {  # prints "running <pid>", "crashing (last exit N)" or "stopped"
  local l="$1" pid exitc
  pid=$(host_pid "$l")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "running $pid"; return 0; fi
  if launchctl print "gui/$uid/$l" >/dev/null 2>&1; then
    exitc=$(launchctl print "gui/$uid/$l" 2>/dev/null | sed -n 's/^[[:space:]]*last exit code = \(.*\)/\1/p' | head -1)
    echo "crashing (last exit ${exitc:-unknown})"; return 1
  fi
  echo "stopped"; return 1
}
trim_log() {  # once over 1 MB, keep the last 200 KB; the host draws its screen into the log
  local f="$1"; [ -f "$f" ] || return 0
  local size; size=$(stat -f %z "$f" 2>/dev/null) || size=$(stat -c %s "$f" 2>/dev/null) || size=0
  if [ "$size" -gt 1048576 ]; then
    tail -c 204800 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
}

case "${1:-}" in
  --list)
    for f in "$agents"/com.agent-team.host.*.plist; do
      [ -e "$f" ] || { echo "no hosts"; exit 0; }
      l=$(basename "$f" .plist)
      dir=$(sed -n 's/.*<key>WorkingDirectory<\/key><string>\(.*\)<\/string>.*/\1/p' "$f" | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')
      st=$(host_state "$l" || true)
      trim_log "$logs/host-$(basename "$dir").log"
      echo "$l  $dir  $st"
    done; exit 0 ;;
  --remove)
    dir=$(cd "$2" 2>/dev/null && pwd -P || printf '%s' "$2"); l=$(label_for "$dir")   # the folder may be gone
    found=""
    if [ -f "$agents/$l.plist" ]; then stop_label "$l"; echo "removed $l"; found=1; fi
    stop_legacy_if_ours "$dir" && found=1
    [ -n "$found" ] || { echo "no host for $dir; see --list for the registered folders and their labels" >&2; exit 1; }
    exit 0 ;;
  ''|-h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

dir=$(cd "$1" && pwd -P)
[ -d "$dir/.git" ] || echo "note: $dir is not a git repo root; sessions will still start there" >&2
claude_bin=$(command -v claude) || { echo "claude not on PATH" >&2; exit 1; }
l=$(label_for "$dir"); plist="$agents/$l.plist"
stop_label "$l"; stop_legacy_if_ours "$dir" || true   # replace an existing host for this folder, old or new label
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$l</string>
  <key>ProgramArguments</key><array><string>$(xml "$claude_bin")</string><string>remote-control</string></array>
  <key>WorkingDirectory</key><string>$(xml "$dir")</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$(xml "$logs/host-$(basename "$dir").log")</string>
  <key>StandardErrorPath</key><string>$(xml "$logs/host-$(basename "$dir").log")</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$(xml "$(dirname "$claude_bin"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")</string>
    <key>HOME</key><string>$(xml "$HOME")</string>
    <key>TERM</key><string>dumb</string>
    <key>NO_COLOR</key><string>1</string>
  </dict>
</dict></plist>
EOF
log="$logs/host-$(basename "$dir").log"; trim_log "$log"
launchctl bootstrap "gui/$uid" "$plist"
# Give it time to start and, if it is going to crash, to crash at least once.
sleep 8
st=$(host_state "$l" || true)
case "$st" in
  running*) echo "host $l $st in $dir; log: $log"
            grep -a -o 'Connected[^[:cntrl:]]*' "$log" 2>/dev/null | tail -1 || true ;;
  *) echo "host $l is $st; see $log" >&2; tail -c 2000 "$log" 2>/dev/null | tr -d '\033' | tail -5 >&2; exit 1 ;;
esac
