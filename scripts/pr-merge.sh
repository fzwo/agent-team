#!/bin/bash
# Merge a PR only when it is safe to: GitHub knows it is mergeable, and the branch holds the base it lands on.
#   pr-merge.sh <pr-number|branch> [--wait-mergeable 90] [--method merge|squash|rebase] [--dry-run] [--strict] [--unaffected <path>]...
# A branch name in place of the number is resolved to this repository's open PR for it (refused when there is none or
# more than one; a fork's PR does not count). A branch named like a number, or starting with -, needs the number.
# Every GitHub call is `gh api` on the REST endpoints: `gh pr` and `gh issue` go through GraphQL, which a cloud
# session's gh cannot reach (HTTP 403, 2026-11), so a shift there merged by hand without this script's checks.
# Refuses (exit 1) when the PR is not OPEN; when the base branch has commits the PR's head does not (two PRs each
# reviewed clean against an older main once broke main for an hour: one added an exhaustive switch, the other an
# enum case; merge the base into the branch, rerun the build and the tests the PR touches, push, run this again),
# unless every file those commits touch is a document (`*.md`, `.agent-team/`, `design/`, `docs/`), which cannot
# change a build (a shift was refused six times for state-file and design-doc commits); --strict refuses those too.
# --unaffected <path> (repeatable) names a directory whose changes cannot reach this PR's build, as the project's
# CLAUDE.md lists its independent targets (a shift rebuilt for nearly every merge while main's new commits touched
# only the other app): commits under those paths count as documents do, noted and not refused; a path the PR itself
# changes is refused as --unaffected, since the PR's build sees it;
# when GitHub reports CONFLICTING; and when mergeability is still UNKNOWN after --wait-mergeable seconds (GitHub
# computes it lazily after a push; never merge on UNKNOWN; an error from gh counts as unknown until then). The base
# check runs again after the wait, since the base can move during it, and the merge names the head commit it
# checked, so a head pushed meanwhile is refused by GitHub. Then merges through the REST merge endpoint (--method,
# default merge; a repository that allows only squash says so in its convention), waits until GitHub shows MERGED (exit 1
# if it does not within a minute: check before any cleanup), and prints the next steps. Nothing else is touched:
# closing the issue comes after MERGED, by hand or by the cleanup. Run it from the project checkout; it fetches
# the base and the head from origin into refs of its own (refs/pr-merge/<pr>/, removed when it exits), so the
# clone's refspec does not matter and two runs for two PRs in one repository do not mix.
# --dry-run runs every check and the wait, prints what would merge and exits 0 without merging (exit 1 on a refusal),
# so the script can be tried on a live PR. The fetch lands in the checkout the script runs from (refs of its own,
# removed on exit): run it from your shift's checkout, not a shared one. PR_MERGE_POLL (seconds between checks,
# default 5) is for the tests.
set -eu
usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }
# The PR number and the options in any order (`--dry-run 1141` and `1141 --dry-run` both work; the first form was a usage error once).
pr=""; wait_m=90; method=merge; dry=""; strict=""; noted=""; unaff=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wait-mergeable) wait_m="${2:-}"; case "$wait_m" in ''|*[!0-9]*) echo "--wait-mergeable needs a number of seconds" >&2; exit 2 ;; esac; shift 2 ;;
    --method) method="${2:-}"; case "$method" in merge|squash|rebase) ;; *) echo "--method is merge, squash or rebase" >&2; exit 2 ;; esac; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --strict) strict=1; shift ;;
    --unaffected) p="${2:-}"; case "$p" in ''|-*) echo "--unaffected needs a path (a directory the PR's build cannot see)" >&2; exit 2 ;; esac
       p=$(printf '%s' "$p" | sed 's|^\./||; s|/*$||'); case "$p" in ''|.|..|/*|../*) echo "--unaffected: a directory inside the repository, not the root or a path outside it" >&2; exit 2 ;; esac; unaff="$unaff$p/
"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) [ -z "$pr" ] || { echo "pr-merge.sh: one PR, not two ($pr and $1)" >&2; exit 2; }; pr="$1"; shift ;;
  esac
done
[ -n "$pr" ] || { echo "usage: pr-merge.sh <pr-number|branch> [--wait-mergeable SECONDS] [--method merge|squash|rebase] [--dry-run] [--strict] [--unaffected <path>]..." >&2; exit 2; }
case "$pr" in *[!0-9]*)   # a branch name: its one open PR (a shift pasted a branch and got the usage line)
  # A gh failure (no GitHub remote, a bad token, a 5xx) is not "no PR": gh's own message stays visible and the script
  # stops; a fork's PR with the same branch name is not this repository's (isCrossRepository).
  # This repository's own PRs: the head's repository is the base's (`.head.repo.fork` says whether that repository is
  # itself a fork, which a project forked from elsewhere always is; a deleted fork's head.repo is null).
  # The name reaches jq through the environment, not as program text: interpolated, a name holding `" or .number == 7 or "`
  # would have selected another PR (gh's jq resolves `env.NAME`).
  nums=$(PR_BRANCH="$pr" gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --paginate --jq '.[] | select(.head.ref == env.PR_BRANCH and .head.repo != null and .head.repo.full_name == .base.repo.full_name) | .number') || { echo "pr-merge.sh: cannot list the open PRs for branch '$pr'; see gh's message above" >&2; exit 1; }
  case "$(printf '%s\n' "$nums" | grep -c .)" in
    0) echo "pr-merge.sh: no open PR has the head branch '$pr'" >&2; exit 1 ;;
    1) echo "pr-merge.sh: branch $pr is #$nums"; pr="$nums" ;;
    *) echo "pr-merge.sh: more than one open PR has the head branch '$pr' ($(printf '%s\n' "$nums" | tr '\n' ' ' | sed 's/ $//')); give the number" >&2; exit 1 ;;
  esac ;;
esac
poll="${PR_MERGE_POLL:-5}"
# The PR's state as `gh pr view` named it: MERGED, OPEN or CLOSED.
pr_state() { gh api "repos/{owner}/{repo}/pulls/$1" --jq 'if .merged then "MERGED" else (.state | ascii_upcase) end'; }
state=$(pr_state "$pr") || { echo "pr-merge.sh: cannot read #$pr" >&2; exit 1; }
[ "$state" = OPEN ] || { echo "pr-merge.sh: #$pr is ${state:-unreadable}, not OPEN; nothing to merge" >&2; exit 1; }
base=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq .base.ref) || base=""; head=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq .head.ref) || head=""
[ -n "$base" ] && [ -n "$head" ] || { echo "pr-merge.sh: cannot read the branches of #$pr" >&2; exit 1; }
# The two tips, fetched into refs of this script's own, named for the PR and removed on exit: what the comparison
# sees is what origin has now, and a run for another PR in the same repository does not mix with this one.
rb="refs/pr-merge/$pr/base"; rh="refs/pr-merge/$pr/head"
trap 'git update-ref -d "$rb" 2>/dev/null; git update-ref -d "$rh" 2>/dev/null' EXIT
refresh() {
  git fetch -q origin "+refs/heads/$base:$rb" "+refs/heads/$head:$rh" \
    || { echo "pr-merge.sh: cannot fetch $base and $head from origin; run this from the project checkout" >&2; exit 1; }
  behind=$(git rev-list --count "$rh..$rb")
  # A path the PR itself changes is one its build sees: --unaffected cannot name it (a flag copied from another PR's merge).
  if [ -n "$unaff" ] && [ "$behind" -gt 0 ]; then
    # The list goes through the environment: BSD awk (macOS) refuses a newline in a -v value ("newline in string"), and
    # every --unaffected call exited 2 on the Mac in 0.4.37.
    own=$(git -c core.quotePath=off diff --no-renames --name-only "$rb...$rh" -- | PM_UNAFF="$unaff" awk 'BEGIN { n = split(ENVIRON["PM_UNAFF"], a, "\n") } { for (i = 1; i <= n; i++) if (a[i] != "" && index($0, a[i]) == 1) { print; exit } }')
    [ -z "$own" ] || { echo "pr-merge.sh: refusing: --unaffected names a path #$pr ($head) itself changes ($own); a directory the PR touches is one its build sees. Drop that --unaffected, or merge $base in and rerun the build." >&2; exit 1; }
  fi
  if [ "$behind" -gt 0 ]; then
    # Documents cannot change a build: when every file the missing commits touch is one, the merge goes on and says so.
    # No rename detection (a code file moved into docs/ would show under its new name only) and no path quoting.
    files=$(git -c core.quotePath=off diff --no-renames --name-only "$rh...$rb" --)
    code=$(printf '%s\n' "$files" | grep -Ev '^$|(^|/)[^/]*\.md$|^\.agent-team/|^design/|^docs/' || true)
    # A file under a path named --unaffected is outside this PR's build, as the caller says: counted as a document is.
    kind="documents only"
    if [ -n "$unaff" ] && [ -n "$code" ]; then
      rest=$(printf '%s\n' "$code" | PM_UNAFF="$unaff" awk 'BEGIN { n = split(ENVIRON["PM_UNAFF"], a, "\n") } { for (i = 1; i <= n; i++) if (a[i] != "" && index($0, a[i]) == 1) next; print }')
      [ "$rest" = "$code" ] || kind="documents and --unaffected paths only"
      code="$rest"
    fi
    shown=$(printf '%s\n' "$files" | tr '\n' ' ' | sed 's/ $//'); [ -n "$shown" ] || shown="no files"
    if [ -n "$code" ]; then
      echo "pr-merge.sh: refusing: origin/$base has $behind commit(s) that #$pr ($head) does not, touching code ($(printf '%s\n' "$code" | head -1)$( [ "$(printf '%s\n' "$code" | grep -c .)" -gt 1 ] && printf ' …' )). Merge $base into $head, rerun the build and the tests the PR touches, push, then run this again. (Two PRs each clean against an older $base once broke it.)" >&2
      exit 1
    fi
    if [ -n "$strict" ]; then
      echo "pr-merge.sh: refusing under --strict: origin/$base has $behind commit(s) that #$pr ($head) does not, touching $kind ($shown). Merge $base into $head, push, then run this again." >&2
      exit 1
    fi
    [ -n "$noted" ] || echo "note: origin/$base has $behind commit(s) that #$pr ($head) does not, touching $kind ($shown); going on, since none of them can change this PR's build (--strict refuses this too)."
    noted=1
  fi
}
refresh
deadline=$(( $(date +%s) + wait_m ))
while :; do
  # REST's mergeable is true, false or null while GitHub computes it: the three states gh pr view named.
  m=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq 'if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end' 2>/dev/null) || m=""
  case "$m" in
    MERGEABLE) break ;;
    CONFLICTING) echo "pr-merge.sh: refusing: GitHub reports #$pr CONFLICTING. Merge $base into $head and resolve, rebuild, push; the fix gets its review round." >&2; exit 1 ;;
    *) if [ "$(date +%s)" -ge "$deadline" ]; then echo "pr-merge.sh: refusing: mergeability of #$pr is still ${m:-unknown} after ${wait_m}s; GitHub has not computed it. Wait and run this again; never merge on UNKNOWN." >&2; exit 1; fi; sleep "$poll" ;;
  esac
done
refresh   # the base may have moved while we waited: the shift's case was two merges minutes apart
head_sha=$(git rev-parse "$rh")
if [ -n "$dry" ]; then echo "dry run: #$pr ($head into $base, $method) would merge at $head_sha if the head is unchanged by then; every check passed, nothing merged."; exit 0; fi
# `sha` is the head the checks saw: GitHub refuses the merge when the branch moved since (gh pr merge's --match-head-commit).
gh api -X PUT "repos/{owner}/{repo}/pulls/$pr/merge" -f merge_method="$method" -f sha="$head_sha" >/dev/null || { echo "pr-merge.sh: GitHub refused the merge of #$pr; nothing was merged. Do not close the issue; read the message above (a head pushed since the check, a merge method the repository does not allow, a conflict)." >&2; exit 1; }
deadline=$(( $(date +%s) + 60 ))
while :; do
  state=$(pr_state "$pr" 2>/dev/null) || state=""
  [ "$state" = MERGED ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then echo "pr-merge.sh: #$pr is not shown MERGED yet (${state:-unreadable}). Check the PR's state (gh api repos/{owner}/{repo}/pulls/$pr --jq .merged) before any cleanup or issue change." >&2; exit 1; fi
  sleep "$poll"
done
echo "merged #$pr ($head into $base, $method), shown MERGED."
echo "Next: pr-cleanup.sh $pr --worktree <path> when the worktree is no longer needed (it reopens a decision issue a 'Closes' line closed); then the issue; then the report."
