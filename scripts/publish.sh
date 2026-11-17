#!/bin/bash
# Publish the plugin from the maintainer's private repository to the public install source.
#   publish.sh [--push] [--source DIR] [--public-dir DIR] [--public-url URL]
# Exports the source checkout's HEAD (default: the repository this script lives in), rewrites it for the public
# copy with publish-subs.py (the first project's name, the machine's name, the private test data; a residue
# check refuses to go on when a name it exists to remove is still there), replaces the tree of a clone of the
# public repository with the result and commits it as one commit per version, authored by the maintainer's
# agent, with no session trailer. Without --push the commit stays in the clone and its diff stat is printed;
# --push pushes it. The clone lives in --public-dir (default $TMPDIR/agent-team-public), made from --public-url
# (default https://github.com/fzwo/agent-team.git) when absent; it is the tool's: every run resets it to the
# remote's main first (an unpushed commit from an earlier run is a preview and is remade), so the public history
# gets exactly one commit per run that publishes. Nothing is published when the exported tree equals the public one.
# publish-subs.py and the tests' fixture are export-ignored (.gitattributes), so the public copy carries this script
# without the list of names; there the script refuses to run.
set -euo pipefail
push=""; src=""; pub_dir="${TMPDIR:-/tmp}/agent-team-public"; pub_url="https://github.com/fzwo/agent-team.git"
while [ $# -gt 0 ]; do
  case "$1" in
    --push) push=1; shift ;;
    --source) src="${2:-}"; [ -n "$src" ] || { echo "--source needs a directory" >&2; exit 2; }; shift 2 ;;
    --public-dir) pub_dir="${2:-}"; [ -n "$pub_dir" ] || { echo "--public-dir needs a directory" >&2; exit 2; }; shift 2 ;;
    --public-url) pub_url="${2:-}"; [ -n "$pub_url" ] || { echo "--public-url needs a URL" >&2; exit 2; }; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
here=$(cd "$(dirname "$0")/.." && pwd -P)
[ -f "$here/scripts/publish-subs.py" ] || { echo "publish.sh: $here/scripts/publish-subs.py is absent: this is the public copy; publish from the maintainer's repository" >&2; exit 2; }
[ -n "$src" ] || src="$here"
src=$(cd "$src" && pwd -P)
if [ -e "$pub_dir" ]; then pub_res=$(cd "$pub_dir" 2>/dev/null && pwd -P) || pub_res=""
  case "$src" in "$pub_res"|"$pub_res"/*) echo "publish.sh: --public-dir is the source checkout itself or holds it; the public clone must be another directory, since its tree is replaced" >&2; exit 2 ;; esac
fi
git -C "$src" rev-parse --verify HEAD >/dev/null 2>&1 || { echo "publish.sh: $src is not a git repository with a commit" >&2; exit 2; }
if [ -n "$(git -C "$src" status --porcelain)" ]; then echo "publish.sh: $src has uncommitted or untracked files; publish a commit, not a working tree" >&2; exit 2; fi
head_sha=$(git -C "$src" rev-parse --short HEAD)
version=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$src/.claude-plugin/plugin.json" 2>/dev/null || true)
[ -n "$version" ] || { echo "publish.sh: no version in $src/.claude-plugin/plugin.json" >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-team-publish.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tree"
git -C "$src" archive HEAD | tar -x -C "$work/tree"
[ -f "$work/tree/.claude-plugin/plugin.json" ] || { echo "publish.sh: the export of $src has no .claude-plugin/plugin.json; not a plugin tree" >&2; exit 2; }
python3 -I "$here/scripts/publish-subs.py" "$work/tree" || { echo "publish.sh: not publishable, see above" >&2; exit 1; }
# The public clone, the tool's own: cloned when absent, then made equal to the remote's main (or unborn when the
# remote is still empty), so the one commit made below sits directly on what is published.
if [ -d "$pub_dir/.git" ]; then
  git -C "$pub_dir" fetch -q --prune origin || { echo "publish.sh: cannot fetch $pub_url in $pub_dir" >&2; exit 2; }
else
  git clone -q "$pub_url" "$pub_dir" || { echo "publish.sh: cannot clone $pub_url into $pub_dir" >&2; exit 2; }
fi
pub_dir=$(cd "$pub_dir" && pwd -P)   # a symlink here would make find's start point below yield nothing
[ "$(git -C "$pub_dir" remote get-url origin)" = "$pub_url" ] || { echo "publish.sh: $pub_dir is a clone of $(git -C "$pub_dir" remote get-url origin), not of $pub_url" >&2; exit 2; }
# The remote's heads are what the fetch or clone just brought: no second network call, whose failure would read as "no heads".
if ! git -C "$pub_dir" rev-parse --verify -q origin/main >/dev/null && [ -n "$(git -C "$pub_dir" for-each-ref refs/remotes/origin/ --format='%(refname)' | grep -v '/origin/HEAD$' || true)" ]; then   # the prefix form: a glob would miss release/1
  echo "publish.sh: $pub_url has branches but no main; this script publishes to main only" >&2; exit 2
fi
if git -C "$pub_dir" rev-parse --verify -q origin/main >/dev/null; then
  # Forced: a preview looked at and touched, or a run interrupted half-way, leaves the clone dirty; a failure here is fatal.
  git -C "$pub_dir" checkout -q -f -B main origin/main && git -C "$pub_dir" reset -q --hard origin/main && git -C "$pub_dir" clean -qfdx \
    || { echo "publish.sh: cannot make $pub_dir equal to origin/main" >&2; exit 2; }
else
  git -C "$pub_dir" symbolic-ref HEAD refs/heads/main; git -C "$pub_dir" update-ref -d refs/heads/main 2>/dev/null || true; git -C "$pub_dir" reset -q
  git -C "$pub_dir" clean -qfdx
fi
# Replace the public tree with the rewritten export: everything but .git goes, so deletions publish too.
find "$pub_dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R "$work/tree/." "$pub_dir/"
git -C "$pub_dir" add -A
if git -C "$pub_dir" diff --cached --quiet; then echo "publish.sh: the public copy already equals version $version at $head_sha; nothing to publish"; exit 0; fi
git -C "$pub_dir" -c user.name="Claude" -c user.email="noreply@anthropic.com" -c commit.gpgsign=false commit -q -F - <<EOF
agent-team $version

Published copy of the maintainer's repository at $head_sha. The project the process was built on is called "the first project" here, and the machine that runs its agents "the agent Mac".

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
echo "committed agent-team $version in $pub_dir (from $src at $head_sha):"
git -C "$pub_dir" show --stat --format= HEAD | tail -1
if [ -n "$push" ]; then
  git -C "$pub_dir" push -q origin main && echo "pushed to $pub_url"
else
  echo "not pushed: run again with --push, or push from $pub_dir after looking at the commit"
fi
