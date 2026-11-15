#!/bin/bash
# Create a new design changelog entry file and print its path.
#   changelog-new.sh <engineering|design> <slug> [--title "..."] [--issue N] [--pr N] [--proposed]
# Files live in design/changelog/ (relative to the repo root), one per entry, named
# YYYY-MM-DD-HHMM-<role>-<slug>.md in UTC so that sorting by name sorts by time.
set -eu
role="${1:-}"; slug="${2:-}"; shift 2 2>/dev/null || { echo "usage: changelog-new.sh <role> <slug> [--title ..] [--issue N] [--pr N] [--proposed]" >&2; exit 1; }
case "$role" in engineering|design) ;; *) echo "role must be engineering or design" >&2; exit 1 ;; esac
title=""; issue=""; pr=""; proposed=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --proposed) proposed=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
slug=$(printf '%s' "$slug" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
[ -n "$slug" ] || { echo "empty slug" >&2; exit 1; }
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
dir="$root/design/changelog"; mkdir -p "$dir"
stamp=$(date -u +%Y-%m-%d-%H%M)
file="$dir/$stamp-$role-$slug.md"
[ -e "$file" ] && { echo "exists: $file" >&2; exit 1; }
[ -n "$title" ] || title=$(printf '%s' "$slug" | tr '-' ' ')
{
  printf '# %s %s %s: %s%s\n' "$(date -u +%Y-%m-%d)" "$(date -u +%H:%M)" "$role" "${proposed:+Proposed: }" "$title"
  line=""
  [ -n "$issue" ] && line="Issue: #$issue"
  [ -n "$pr" ] && line="${line:+$line  }PR: #$pr"
  [ -n "$line" ] && printf '%s\n' "$line"
  printf '\n'
} > "$file"
# The body is the agent's to write (bullet lines); no placeholder, which once shipped as a stray "- " line.
echo "$file"
