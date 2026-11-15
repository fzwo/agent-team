#!/bin/bash
# Clean up after a PR, but only once GitHub shows it MERGED.
#   pr-cleanup.sh <pr-number> [--worktree PATH] [--also EXACT_PATH]...
# Removes: the worktree (if given and registered), the local branch, the remote branch,
# and each --also path exactly as given (no globs, no parents of the repo, never $HOME or /).
# Before a worktree is removed, an executable .agent-team/hooks/worktree-removed in the main
# checkout, if present, is run with the worktree's absolute path as its only argument, so a
# project can remove what it keeps per checkout outside the worktree (build folders in
# $TMPDIR, caches named for the path), by exact name. A failing hook warns; git cleanup goes on.
set -eu
pr="${1:-}"; shift || true
[ -n "$pr" ] || { echo "usage: pr-cleanup.sh <pr-number> [--worktree PATH] [--also PATH]..." >&2; exit 1; }
# Paths are made absolute against the caller's directory here, before the script moves to the
# main checkout; otherwise a relative path from inside a worktree would resolve against the wrong tree.
abs_arg() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
worktree=""; also=(); failed=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) worktree=$(abs_arg "$2"); shift 2 ;;
    --also) also+=("$(abs_arg "$2")"); shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

state=$(gh pr view "$pr" --json state -q .state)
branch=$(gh pr view "$pr" --json headRefName -q .headRefName)
if [ "$state" != "MERGED" ]; then
  echo "pr-cleanup: PR #$pr is $state, not MERGED. Nothing removed." >&2
  exit 1
fi
echo "PR #$pr is MERGED (branch $branch)"

# "Closes #N" in a PR body closes N on merge, and a `decision` or `owner` issue is the owner's to close:
# reopen it with a note. (PR bodies say "see #N" for those; this is the net under that rule.)
body=$(gh pr view "$pr" --json body -q .body 2>/dev/null || true)
merged_at=$(gh pr view "$pr" --json mergedAt -q .mergedAt 2>/dev/null || true)
this_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
# The forms GitHub honours: "#N", "owner/repo#N" and the issue's URL, each after a closing keyword with an
# optional colon; only this repo's issues (a number from another repo is never touched).
refs=$(printf '%s' "$body" | tr '\n' ' ' | grep -Eio "\b(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]*(#|${this_repo:-/}#|https://github\.com/${this_repo:-/}/issues/)[0-9]+" || true)
for n in $(printf '%s' "$refs" | grep -Eo '[0-9]+$' | sort -u); do
  # gh alone in the substitution: a pipe would hide its failure behind tr's status.
  labels=$(gh issue view "$n" --json labels -q '.labels[].name' 2>/dev/null) || { echo "warning: could not read issue #$n to see whether the merge closed a decision" >&2; continue; }
  labels=$(printf '%s\n' "$labels" | tr '\n' ' ')
  st=$(gh issue view "$n" --json state -q .state 2>/dev/null || true)
  # Only an issue this merge closed: one the owner closed earlier, and a later PR merely mentions, stays closed.
  # Timestamps are ISO-8601 in UTC, so they compare as strings; GitHub closes the issue at or after the merge.
  closed_at=$(gh issue view "$n" --json closedAt -q .closedAt 2>/dev/null || true)
  if [ -n "$merged_at" ] && [ -n "$closed_at" ] && [ "$closed_at" \< "$merged_at" ]; then continue; fi
  case " $labels " in
    *" decision "*|*" owner "*)
      if [ "$st" = CLOSED ]; then
        kind=$(printf '%s' "$labels" | grep -Eo 'decision|owner' | head -1)
        if gh issue reopen "$n" --comment "Reopened by pr-cleanup: PR #$pr closed this through a closing keyword, and a \`$kind\` issue is the owner's to close. PR bodies say \"see #$n\" for these."; then
          echo "reopened #$n: a $kind issue closed by the merge"
        else
          echo "warning: could not reopen #$n, a $kind issue the merge closed" >&2
        fi
      fi ;;
  esac
done

# The main checkout, even when run from inside a worktree: the hook and the refusal checks use it.
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir)
root=$(cd "$common/.." && pwd -P)
if [ -n "$worktree" ]; then
  # Normalise through the parent, so a worktree whose directory is already gone still resolves.
  if wt_parent=$(cd "$(dirname "$worktree")" 2>/dev/null && pwd -P); then wt_abs="$wt_parent/$(basename "$worktree")"; else wt_abs="$worktree"; fi
  [ -d "$wt_abs" ] && wt_abs=$(cd "$wt_abs" && pwd -P)
  if [ "$wt_abs" = "$root" ]; then echo "pr-cleanup: $wt_abs is the main checkout, not a worktree. Nothing removed." >&2; exit 1; fi
fi
cd "$root"   # a worktree we are about to remove must not be our working directory
if [ -n "$worktree" ]; then
  if git worktree list --porcelain | grep -Fqx "worktree $wt_abs"; then
    hook="$root/.agent-team/hooks/worktree-removed"
    if [ -x "$hook" ]; then
      if "$hook" "$wt_abs"; then echo "ran worktree-removed hook for $wt_abs"; else echo "warning: worktree-removed hook failed for $wt_abs (exit $?); continuing" >&2; fi
    fi
    if [ ! -d "$wt_abs" ]; then
      git worktree prune
      if git worktree list --porcelain | grep -Fqx "worktree $wt_abs"; then echo "could not prune $wt_abs (locked?); unlock it with git worktree unlock" >&2; failed=1
      else echo "pruned $wt_abs (and any other unlocked registration whose directory is gone)"; fi
    elif git worktree remove --force "$wt_abs"; then echo "removed worktree $wt_abs"; else echo "could not remove worktree $wt_abs" >&2; failed=1; fi
  else
    echo "worktree not registered, left alone: $wt_abs"
  fi
fi

current=$(git branch --show-current)
if git show-ref --verify --quiet "refs/heads/$branch"; then
  if [ "$current" = "$branch" ]; then
    echo "branch $branch is checked out here; switch away first" >&2; failed=1
  elif git branch -D "$branch"; then
    echo "deleted local branch $branch"
  else
    echo "could not delete local branch $branch" >&2; failed=1
  fi
fi
# The remote branch goes only when the local cleanup succeeded, so a half-done cleanup can be redone.
if [ -n "$failed" ]; then
  echo "pr-cleanup: local cleanup incomplete; remote branch and --also paths left alone" >&2; exit 1
fi
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  if git push origin --delete "$branch" 2>/dev/null; then echo "deleted remote branch $branch"; else echo "could not delete remote branch $branch" >&2; failed=1; fi
elif ! git ls-remote --exit-code origin >/dev/null 2>&1; then
  echo "origin not reachable; remote branch $branch not checked" >&2
fi

for p in "${also[@]:-}"; do
  [ -n "$p" ] || continue
  case "$p" in *'*'*|*'?'*) echo "refusing glob: $p" >&2; continue ;; esac
  # A missing parent must not collapse the path to "/<name>".
  if ! pdir=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P); then echo "not found: $p"; continue; fi
  if [ "$pdir" = / ]; then abs="/$(basename "$p")"; else abs="$pdir/$(basename "$p")"; fi
  # Depth: at least three components below /, and at least two below $HOME; so /usr/local,
  # /private/tmp, /opt/homebrew, $HOME/Library and $HOME/Documents are all refused.
  case "$abs" in
    /|//*|"${HOME%/}"|"$root") echo "refusing: $abs" >&2; continue ;;
    /*/*/*) ;;
    *) echo "refusing a path this close to the root: $abs" >&2; continue ;;
  esac
  case "$abs" in "${HOME%/}"/*) case "${abs#"${HOME%/}"/}" in */*) ;; *) echo "refusing a path directly under HOME: $abs" >&2; continue ;; esac ;; esac
  case "$root/" in "$abs/"*) echo "refusing the repo or a parent of it: $abs" >&2; continue ;; esac
  if [ -e "$abs" ]; then
    if rm -rf "$abs"; then echo "removed $abs"; else echo "could not remove $abs" >&2; failed=1; fi
  else echo "not found: $abs"; fi
done
[ -z "$failed" ] || exit 1
exit 0
