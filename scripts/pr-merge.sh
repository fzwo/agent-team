#!/bin/bash
# Merge a PR only when it is safe to: GitHub knows it is mergeable, and the branch holds the base it lands on.
#   pr-merge.sh <pr-number> [--wait-mergeable 90] [--method merge|squash|rebase]
# Refuses (exit 1) when the PR is not OPEN; when the base branch has commits the PR's head does not (two PRs each
# reviewed clean against an older main once broke main for an hour: one added an exhaustive switch, the other an
# enum case; merge the base into the branch, rerun the build and the tests the PR touches, push, run this again);
# when GitHub reports CONFLICTING; and when mergeability is still UNKNOWN after --wait-mergeable seconds (GitHub
# computes it lazily after a push; never merge on UNKNOWN; an error from gh counts as unknown until then). The base
# check runs again after the wait, since the base can move during it, and the merge names the head commit it
# checked, so a head pushed meanwhile is refused by GitHub. Then merges with `gh pr merge` (--method, default
# merge; a repository that allows only squash says so in its convention), waits until GitHub shows MERGED (exit 1
# if it does not within a minute: check before any cleanup), and prints the next steps. Nothing else is touched:
# closing the issue comes after MERGED, by hand or by the cleanup. Run it from the project checkout; it fetches
# the base and the head from origin into refs of its own (refs/pr-merge/<pr>/, removed when it exits), so the
# clone's refspec does not matter and two runs for two PRs in one repository do not mix.
# PR_MERGE_POLL (seconds between checks, default 5) is for the tests.
set -eu
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
pr="${1:-}"; shift || true
case "$pr" in -h|--help) usage; exit 0 ;; ''|*[!0-9]*) echo "usage: pr-merge.sh <pr-number> [--wait-mergeable SECONDS] [--method merge|squash|rebase]" >&2; exit 2 ;; esac
wait_m=90; method=merge
while [ $# -gt 0 ]; do
  case "$1" in
    --wait-mergeable) wait_m="${2:-}"; case "$wait_m" in ''|*[!0-9]*) echo "--wait-mergeable needs a number of seconds" >&2; exit 2 ;; esac; shift 2 ;;
    --method) method="${2:-}"; case "$method" in merge|squash|rebase) ;; *) echo "--method is merge, squash or rebase" >&2; exit 2 ;; esac; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
poll="${PR_MERGE_POLL:-5}"
state=$(gh pr view "$pr" --json state -q .state) || { echo "pr-merge.sh: cannot read #$pr" >&2; exit 1; }
[ "$state" = OPEN ] || { echo "pr-merge.sh: #$pr is ${state:-unreadable}, not OPEN; nothing to merge" >&2; exit 1; }
base=$(gh pr view "$pr" --json baseRefName -q .baseRefName) || base=""; head=$(gh pr view "$pr" --json headRefName -q .headRefName) || head=""
[ -n "$base" ] && [ -n "$head" ] || { echo "pr-merge.sh: cannot read the branches of #$pr" >&2; exit 1; }
# The two tips, fetched into refs of this script's own, named for the PR and removed on exit: what the comparison
# sees is what origin has now, and a run for another PR in the same repository does not mix with this one.
rb="refs/pr-merge/$pr/base"; rh="refs/pr-merge/$pr/head"
trap 'git update-ref -d "$rb" 2>/dev/null; git update-ref -d "$rh" 2>/dev/null' EXIT
refresh() {
  git fetch -q origin "+refs/heads/$base:$rb" "+refs/heads/$head:$rh" \
    || { echo "pr-merge.sh: cannot fetch $base and $head from origin; run this from the project checkout" >&2; exit 1; }
  behind=$(git rev-list --count "$rh..$rb")
  if [ "$behind" -gt 0 ]; then
    echo "pr-merge.sh: refusing: origin/$base has $behind commit(s) that #$pr ($head) does not. Merge $base into $head, rerun the build and the tests the PR touches, push, then run this again. (Two PRs each clean against an older $base once broke it.)" >&2
    exit 1
  fi
}
refresh
deadline=$(( $(date +%s) + wait_m ))
while :; do
  m=$(gh pr view "$pr" --json mergeable -q .mergeable 2>/dev/null) || m=""
  case "$m" in
    MERGEABLE) break ;;
    CONFLICTING) echo "pr-merge.sh: refusing: GitHub reports #$pr CONFLICTING. Merge $base into $head and resolve, rebuild, push; the fix gets its review round." >&2; exit 1 ;;
    *) if [ "$(date +%s)" -ge "$deadline" ]; then echo "pr-merge.sh: refusing: mergeability of #$pr is still ${m:-unknown} after ${wait_m}s; GitHub has not computed it. Wait and run this again; never merge on UNKNOWN." >&2; exit 1; fi; sleep "$poll" ;;
  esac
done
refresh   # the base may have moved while we waited: the shift's case was two merges minutes apart
head_sha=$(git rev-parse "$rh")
gh pr merge "$pr" "--$method" --match-head-commit "$head_sha" || { echo "pr-merge.sh: gh pr merge refused #$pr; nothing was merged. Do not close the issue; read the message above (a head pushed since the check, a merge method the repository does not allow, a conflict)." >&2; exit 1; }
deadline=$(( $(date +%s) + 60 ))
while :; do
  state=$(gh pr view "$pr" --json state -q .state 2>/dev/null) || state=""
  [ "$state" = MERGED ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then echo "pr-merge.sh: #$pr is not shown MERGED yet (${state:-unreadable}). Check 'gh pr view $pr --json state' before any cleanup or issue change." >&2; exit 1; fi
  sleep "$poll"
done
echo "merged #$pr ($head into $base, $method), shown MERGED."
echo "Next: pr-cleanup.sh $pr --worktree <path> when the worktree is no longer needed (it reopens a decision issue a 'Closes' line closed); then the issue; then the report."
