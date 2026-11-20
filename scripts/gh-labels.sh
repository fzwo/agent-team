#!/bin/bash
# Create (or update) the team-process labels in the current repo, or in --repo owner/name.
# REST only (`gh api`): `gh label` needs GraphQL, which a cloud session's gh cannot reach (HTTP 403, 2026-11).
set -eu
[ "${1:-}" = "--repo" ] && export GH_REPO="$2"   # gh fills {owner}/{repo} from it instead of the checkout's origin

# Create, or update when it exists (the create answers 422 then); either way the colour and the description are set.
mk() {
  local err
  if err=$(gh api -X POST "repos/{owner}/{repo}/labels" -f name="$1" -f color="$2" -f description="$3" 2>&1 >/dev/null); then return 0; fi
  gh api -X PATCH "repos/{owner}/{repo}/labels/$1" -f color="$2" -f description="$3" >/dev/null || { echo "gh-labels: creating $1 failed: $err" >&2; return 1; }
}

mk for-design      1d76db "Engineering asks design, or hands design something to confirm"
mk for-engineering 0e8a16 "Design asks engineering, or posts a review round as a checklist"
mk owner           d93f0b "A product or taste call. Waits for the owner. When in doubt, use this"
mk decision        fbca04 "An agent decided alone; the owner confirms or overrules. Untouched 7 days = accepted"
mk idea            c5def5 "For later"
mk bug             d73a4a "Something is wrong in the app; engineering takes it in queue order"
echo "labels ready"
