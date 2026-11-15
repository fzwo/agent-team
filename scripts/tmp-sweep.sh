#!/bin/bash
# Count and, with --delete, remove known toolchain debris in the temporary directory of a Mac that runs agents.
#   tmp-sweep.sh [--delete] [--age-hours 24] [--warn-entries 10000] [DIR]
# DIR defaults to $TMPDIR. Without --delete it only reports. --age-hours 0 means everything, a running build's
# scratch included: never at the end of a shift while others may build. macOS clears its per-user temporary directory
# around reboots, and an agent Mac stays up for months; measured on 2026-11-15 after 88 days: 61,173 entries,
# of which 56,663 `TemporaryDirectory.XXXXXX` folders holding a lone `.keep-directory` (SwiftPM on Xcode 27.2
# leaves about five per build or test run), about 1,100 zero-length SwiftPM `.lock` files named after scratch
# paths that no longer exist, and 947 `ibtoold-<pid>` folders of a finished Interface Builder tool, each holding
# an `IB/` folder of named pipes and nothing else. They weigh little, but `ls` and globs
# fail past a few tens of thousands of entries and every listing is slow. The process rule is "delete by exact
# name, never by pattern"; this script is the one exception, with the matching kept tight: each class is
# matched by name shape and by content (a lone marker file; an `IB/` of pipes and sockets under a pid that is
# gone; a zero-length lock file no process holds open) and by age, and anything else in the directory is left
# alone. The project's own build folders
# are not debris; the project's worktree hook removes those.
set -eu
delete=""; age_hours=24; warn_entries=10000; dir="${TMPDIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --delete) delete=1; shift ;;
    --age-hours) age_hours="${2:-}"; case "$age_hours" in ''|*[!0-9]*) echo "--age-hours needs a number" >&2; exit 2 ;; esac; shift 2 ;;
    --warn-entries) warn_entries="${2:-}"; case "$warn_entries" in ''|*[!0-9]*) echo "--warn-entries needs a number" >&2; exit 2 ;; esac; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) dir="$1"; shift ;;
  esac
done
[ -n "$dir" ] || { echo "tmp-sweep.sh: no directory: TMPDIR is not set and none was given" >&2; exit 2; }
[ -d "$dir" ] || { echo "tmp-sweep.sh: no such directory: $dir" >&2; exit 2; }
dir=$(cd "$dir" && pwd -P)
# Never the root, a home, or anything that is not plainly a temporary directory: the script removes files.
case "$dir" in
  /|/home|/home/*|/Users|/Users/*|/private|/var|/private/var|/etc|/etc/*|/usr|/usr/*|/opt|/opt/*|/System|/System/*|/Library|/Library/*|/Applications|/Applications/*) echo "tmp-sweep.sh: refusing to sweep $dir" >&2; exit 2 ;;
esac
[ "$dir" != "${HOME:-/nonexistent}" ] || { echo "tmp-sweep.sh: refusing to sweep the home directory" >&2; exit 2; }
mins=$(( age_hours * 60 ))
# The entry count by find, not ls: on macOS `ls -f` turns `.` and `..` on and a later `-A` does not turn them off.
total=$(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' ')
[ "$total" -le "$warn_entries" ] || echo "warning: $total entries in $dir (more than $warn_entries): listings and globs there are slow or fail"
old_enough() { [ -n "$(find "$1" -maxdepth 0 -mmin +"$mins" 2>/dev/null)" ]; }
# Paths are read NUL-separated throughout: a name holding a newline would otherwise split into two, the second
# relative to the caller's directory, and this script deletes.
# 1. SwiftPM's TemporaryDirectory.XXXXXX folders holding only an empty .keep-directory (swift-driver writes it empty).
td_all=0; td_old=0; td_gone=0
while IFS= read -r -d '' d; do
  td_all=$((td_all + 1))
  [ "$(ls -A "$d" 2>/dev/null)" = ".keep-directory" ] || continue
  [ -f "$d/.keep-directory" ] && [ ! -L "$d/.keep-directory" ] && [ ! -s "$d/.keep-directory" ] || continue
  old_enough "$d" || continue
  td_old=$((td_old + 1))
  if [ -n "$delete" ]; then rm -f "$d/.keep-directory" && rmdir "$d" && td_gone=$((td_gone + 1)); fi
done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -name 'TemporaryDirectory.??????' -print0 2>/dev/null)
# 2. ibtoold-<pid> folders (Interface Builder's tool under xcodebuild): the pid is gone, and the folder holds at most
#    an `IB/` whose entries are all named pipes or sockets (the tool's channels), nothing else. Reported by the shift
#    that measured them: none was empty; 795 of 796 matched this shape.
ib_debris() {  # $1 = folder; 0 when it is debris
  local pid="${1##*/ibtoold-}" e
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 1   # the tool is alive
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ "$e" = "$1/IB" ] && [ -d "$e" ] && [ ! -L "$e" ] || return 1
  done
  if [ -d "$1/IB" ]; then
    for e in "$1"/IB/* "$1"/IB/.[!.]* "$1"/IB/..?*; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      [ ! -L "$e" ] && { [ -p "$e" ] || [ -S "$e" ]; } || return 1
    done
  fi
  return 0
}
ib_all=0; ib_old=0; ib_gone=0
while IFS= read -r -d '' d; do
  ib_all=$((ib_all + 1))
  ib_debris "$d" || continue
  old_enough "$d" || continue
  ib_old=$((ib_old + 1))
  if [ -n "$delete" ]; then
    { [ ! -d "$d/IB" ] || { find "$d/IB" -mindepth 1 -maxdepth 1 \( -type p -o -type s \) -exec rm -f {} + && rmdir "$d/IB"; }; } && rmdir "$d" && ib_gone=$((ib_gone + 1))
  fi
done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -name 'ibtoold-[0-9]*' -print0 2>/dev/null)
# 3. SwiftPM lock files named after a scratch path (`_private_var_folders_..._SourcePackages_....lock`). SwiftPM only
#    opens and flocks them, so every one is zero-length and its age is its creation; what tells a stale one from a
#    live one is that no process holds it open, and even that has a window between the check and the removal. So the
#    class is skipped altogether while a Swift or Xcode build tool runs on the machine (Xcode itself and sourcekit-lsp
#    resolve packages too), lsof is asked once for all
#    candidates (one call per file costs seconds each on macOS), and without lsof the files stay.
lk_all=0; lk_old=0; lk_gone=0; lk_note=""; lk_cands=()
if ! command -v lsof >/dev/null 2>&1; then lk_note=" (lsof not found: lock files are left alone, since an open one cannot be told from a stale one)"
elif pgrep -x 'swift-build|swift-package|swift-frontend|swift-test|swift|xcodebuild|Xcode|sourcekit-lsp' >/dev/null 2>&1; then
  lk_note=" (a Swift or Xcode build tool is running: lock files are left alone this time)"
fi
while IFS= read -r -d '' f; do
  lk_all=$((lk_all + 1))
  [ -z "$lk_note" ] || continue
  [ -f "$f" ] && [ ! -L "$f" ] && [ ! -s "$f" ] || continue
  old_enough "$f" || continue
  lk_cands+=("$f")
done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f \( -name '_private_var_folders_*.lock' -o -name '_var_folders_*.lock' -o -name '_Users_*.lock' \) -print0 2>/dev/null)
if [ ${#lk_cands[@]} -gt 0 ]; then
  # lsof prints names with non-printable and, outside a UTF-8 locale, non-ASCII bytes escaped, so an open file whose
  # name it escaped would not match its candidate and would be removed. Every name lsof reports must be exactly one
  # of the candidates; otherwise the whole class is left alone this time (fail closed).
  open_now=$(lsof -Fn -- "${lk_cands[@]}" 2>/dev/null | sed -n 's/^n//p') || true
  unmatched=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    found=""; for f in "${lk_cands[@]}"; do [ "$n" = "$f" ] && { found=1; break; }; done
    [ -n "$found" ] || unmatched=1
  done <<LSOF
$open_now
LSOF
  if [ -n "$unmatched" ]; then
    lk_note=" (lsof reported an open file under a name this script cannot match, so lock files are left alone this time)"
  else
    for f in "${lk_cands[@]}"; do
      case "$open_now" in *"$f"*) continue ;; esac
      lk_old=$((lk_old + 1))
      if [ -n "$delete" ]; then rm -f "$f" && lk_gone=$((lk_gone + 1)); fi
    done
  fi
fi
mode="would remove"; [ -n "$delete" ] && mode="removed"
echo "$dir: $total entries"
echo "TemporaryDirectory.* folders: $td_all; debris (a lone empty .keep-directory, older than ${age_hours} h): $td_old; $mode: $( [ -n "$delete" ] && echo $td_gone || echo $td_old )"
echo "ibtoold-* folders: $ib_all; debris (pid gone, only an IB/ of pipes and sockets, older than ${age_hours} h): $ib_old; $mode: $( [ -n "$delete" ] && echo $ib_gone || echo $ib_old )"
echo "SwiftPM path-named .lock files: $lk_all; debris (older than ${age_hours} h, open by no process): $lk_old; $mode: $( [ -n "$delete" ] && echo $lk_gone || echo $lk_old )$lk_note"
