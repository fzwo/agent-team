#!/bin/bash
# Set up a Mac that runs agents: the plugin at user scope, the lock on the owner's
# PATH, the guard config, and the list of checks that need a fresh session. Idempotent.
#   install-mac.sh [--marketplace owner/repo] [--local /path/to/agent-team] [--bin-dir DIR]
# --local loads a checkout with --plugin-dir instead of installing from the marketplace.
# --bin-dir puts the agentlock link there instead of the first writable of /opt/homebrew/bin,
# /usr/local/bin, ~/bin.
#
# Inside Claude Code sessions the plugin's own SessionStart hook puts its scripts/
# directory on the PATH, so agents find `agentlock` without any of this. The link
# made here is for the owner's own terminal.
set -eu
repo="fzwo/agent-team"; local_dir=""; bin_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --marketplace) repo="$2"; shift 2 ;;
    --local) local_dir="$2"; shift 2 ;;
    --bin-dir) bin_dir="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
here=$(cd "$(dirname "$0")/.." && pwd -P)

echo "== claude"
command -v claude >/dev/null || { echo "claude is not on the PATH" >&2; exit 1; }
claude --version

echo "== plugin"
# The marketplace is registered under the name in its marketplace.json, not the repo name.
mp_name=""
if [ -f "$here/.claude-plugin/marketplace.json" ]; then
  mp_name=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$here/.claude-plugin/marketplace.json" 2>/dev/null || true)
fi
[ -n "$mp_name" ] || mp_name="${repo%%/*}"
installed=""
if [ -n "$local_dir" ]; then
  echo "local checkout: $local_dir. Start sessions with: claude --plugin-dir $local_dir"
else
  out=$(claude plugin marketplace add "$repo" 2>&1) || true
  printf '%s\n' "$out" | tail -1
  if out=$(claude plugin install "agent-team@$mp_name" --scope user 2>&1); then
    printf '%s\n' "$out" | tail -1; installed=1
  elif printf '%s' "$out" | grep -qi "already installed"; then
    out=$(claude plugin update agent-team 2>&1) || true
    printf '%s\n' "$out" | tail -1; installed=1
  else
    printf '%s\n' "$out" >&2
    echo "plugin install failed; see above" >&2
  fi
fi
claude plugin list 2>/dev/null | grep -A3 -i 'agent-team' || echo "agent-team not in plugin list"

echo "== agentlock on the owner's PATH"
# What goes on the PATH is a small wrapper that finds the newest installed copy each time it runs,
# so `claude plugin update` is enough and the owner's terminal never lags the sessions.
newest_agentlock() {
  find "$HOME/.claude/plugins/cache" -type f -path '*/agent-team/*/scripts/agentlock' 2>/dev/null \
    | awk -F/ '{v=$(NF-2); split(v,a,"."); printf "%09d%09d%09d %s\n", a[1],a[2],a[3], $0}' | sort | tail -1 | cut -d' ' -f2-
}
follow_newest=""   # the wrapper looks up the newest installed copy at each run only when one exists now
if [ -n "$local_dir" ]; then src="$local_dir/scripts/agentlock"
elif src=$(newest_agentlock) && [ -n "$src" ]; then follow_newest=1
else
  src="$here/scripts/agentlock"
  echo "no installed copy of the plugin under ~/.claude/plugins/cache; the wrapper runs this checkout's copy, $src," >&2
  echo "until install-mac.sh is rerun after a successful plugin install" >&2
fi
[ -x "$src" ] || { echo "agentlock not found at $src" >&2; exit 1; }
wrapper="$HOME/.agentlock/agentlock"
mkdir -p "$HOME/.agentlock"
if [ -z "$follow_newest" ]; then
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$src" > "$wrapper"
else
  cat > "$wrapper" <<'WRAP'
#!/bin/bash
# agentlock wrapper (installed by agent-team's install-mac.sh): runs the newest installed plugin copy.
src=$(find "$HOME/.claude/plugins/cache" -type f -path '*/agent-team/*/scripts/agentlock' 2>/dev/null \
  | awk -F/ '{v=$(NF-2); split(v,a,"."); printf "%09d%09d%09d %s\n", a[1],a[2],a[3], $0}' | sort | tail -1 | cut -d' ' -f2-)
[ -n "$src" ] || { echo "agentlock: no installed agent-team plugin found under ~/.claude/plugins/cache" >&2; exit 1; }
exec "$src" "$@"
WRAP
fi
chmod +x "$wrapper"
if [ -n "$follow_newest" ]; then runs="runs the newest installed copy, today $src"; else runs="runs $src"; fi
linked=""
if [ -n "$bin_dir" ]; then
  mkdir -p "$bin_dir" && ln -sfn "$wrapper" "$bin_dir/agentlock" || { echo "cannot link into $bin_dir" >&2; exit 1; }
  echo "linked $bin_dir/agentlock -> $wrapper ($runs)"; linked=1
fi
[ -n "$linked" ] || for dir in /opt/homebrew/bin /usr/local/bin; do
  if [ -d "$dir" ] && [ -w "$dir" ]; then
    ln -sfn "$wrapper" "$dir/agentlock"; echo "linked $dir/agentlock -> $wrapper ($runs)"; linked=1; break
  fi
done
# An older install linked ~/bin/agentlock straight at a checkout, which only moves on git pull; if that
# link is still there and is not the wrapper, it would shadow or be shadowed depending on PATH order.
if [ -n "$linked" ] && [ -L "$HOME/bin/agentlock" ] && [ "$(readlink "$HOME/bin/agentlock")" != "$wrapper" ]; then
  ln -sfn "$wrapper" "$HOME/bin/agentlock"; echo "repointed the older link ~/bin/agentlock at the wrapper as well"
fi
if [ -z "$linked" ]; then
  mkdir -p "$HOME/bin"; ln -sfn "$wrapper" "$HOME/bin/agentlock"
  echo "linked ~/bin/agentlock -> $wrapper ($runs)"
  case ":$PATH:" in
    *":$HOME/bin:"*) ;;
    *) echo "~/bin is not on your PATH. For your own terminal, add to ~/.zshrc:"; echo '  export PATH="$HOME/bin:$PATH"'; echo "(Claude Code sessions do not need this; the plugin's hook sets their PATH.)" ;;
  esac
fi

echo "== guard config"
mkdir -p "$HOME/.agentlock"
if [ -f "$HOME/.agentlock/guard.conf" ]; then
  # Rule by rule against this version's example: a rule the example changed (the device verbs in 0.4.25) or added is
  # named, so a kept copy does not run old rules unnoticed (an owner's copy ran 0.4.8 rules under 0.4.26).
  ex="$(dirname "$src")/../hooks/guard.conf.example"; mine="$HOME/.agentlock/guard.conf"; differs=""; missing=""; tab=$(printf '\t')
  while IFS="$tab" read -r name re || [ -n "$name" ]; do   # the last line counts without a trailing newline
    case "$name" in ''|'#'*) continue ;; esac
    m=$(awk -F'\t' -v n="$name" '$1==n {print substr($0, index($0, "\t") + 1); exit}' "$mine")
    if [ -z "$m" ]; then missing="$missing $name"; elif [ "$m" != "$re" ]; then differs="$differs $name"; fi
  done < "$ex"
  if [ -z "$differs$missing" ]; then echo "kept existing ~/.agentlock/guard.conf; every rule of this version's example is in it unchanged"
  else echo "kept existing ~/.agentlock/guard.conf; against this version's example it${differs:+ differs in:$differs;}${missing:+ lacks:$missing;} compare with $ex and merge your local edits into a fresh copy"; fi
  "$src" check-conf || echo "  fix the rules above before running agents; the guard blocks on a bad rule" >&2
else
  cp "$(dirname "$src")/../hooks/guard.conf.example" "$HOME/.agentlock/guard.conf"
  echo "wrote ~/.agentlock/guard.conf from the example; edit it to what this Mac has"
fi
# Locks from before 0.4.0 sat directly under ~/.agentlock; move them where 0.4.0 looks, so they show up and expire.
for d in "$HOME/.agentlock"/*/; do
  n=$(basename "$d")
  [ -d "$d" ] && [ -f "$d/info" ] && [ "$n" != locks ] || continue
  mkdir -p "$HOME/.agentlock/locks"
  if [ -e "$HOME/.agentlock/locks/$n" ]; then
    echo "left pre-0.4.0 lock ~/.agentlock/$n in place: locks/$n already exists; remove the old one by hand once it is not needed" >&2
  else
    mv "${d%/}" "$HOME/.agentlock/locks/" && echo "moved pre-0.4.0 lock $n into locks/"
  fi
done
# The marker that keeps a pre-0.4.0 binary's `clean` from deleting locks/ wholesale (agentlock writes the same
# on its first acquire; written here too, with the directory, so the guarantee holds from install time on).
mkdir -p "$HOME/.agentlock/locks"
if [ ! -e "$HOME/.agentlock/locks/info" ]; then
  printf 'owner=agentlock-0.4.0-marker\nacquired=%s\nexpires=0\nreason=not-a-lock\n' "$(date +%s)" > "$HOME/.agentlock/locks/info"
fi
"$src" status

cat <<'EOF'

== checks that need a FRESH Claude Code session on this Mac (so the plugin's hooks load)
1. `agentlock whoami` prints the session id (set by the SessionStart hook) and `which agentlock`
   resolves inside the plugin's cache directory (set by the same hook).
2. Identity of subagents: `agentlock acquire sim:test --ttl 2m`, then ask a subagent (Agent tool)
   to run `agentlock check sim:test && echo held || echo not-held`. "held" means subagents share
   the parent's lock identity; "not-held" means the guard falls back to the process tree.
3. Plugin agents: ask the session to start `agent-team:reviewer` on any small diff. It should start.
4. Guard: `xcrun simctl list` (allowed) and `xcrun simctl boot nonexistent` without a lock
   (blocked, with the holder list). Then `agentlock release sim:test`.
EOF
