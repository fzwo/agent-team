#!/bin/bash
# Create (or update) the team-process labels in the current repo, or in --repo owner/name.
set -eu
repo_arg=()
[ "${1:-}" = "--repo" ] && repo_arg=(--repo "$2")

# ${arr[@]+"${arr[@]}"} expands to nothing for an empty array; a bare "${arr[@]}" trips `set -u` on bash 3.2.
mk() { gh label create "$1" --color "$2" --description "$3" --force ${repo_arg[@]+"${repo_arg[@]}"}; }

mk for-design      1d76db "Engineering asks design, or hands design something to confirm"
mk for-engineering 0e8a16 "Design asks engineering, or posts a review round as a checklist"
mk owner           d93f0b "A product or taste call. Waits for the owner. When in doubt, use this"
mk decision        fbca04 "An agent decided alone; the owner confirms or overrules. Untouched 7 days = accepted"
mk idea            c5def5 "For later"
mk bug             d73a4a "Something is wrong in the app; engineering takes it in queue order"
echo "labels ready"
