# The design changelog: one file per entry

`design/changelog/` holds one Markdown file per entry. Nothing is ever appended to a shared file, so two agents cannot conflict. `design/CHANGELOG.md` is a generated view (newest first), ignored by git; make it with `changelog-render.sh` when you want to read the whole log.

## File name

`YYYY-MM-DD-HHMM-<role>-<slug>.md`, UTC, for example `2026-11-01-1430-engineering-overnight-line.md`. `changelog-new.sh <role> <slug>` creates the file with the right name and header and prints its path. Sorting the names sorts the entries by time.

## Header

```
# 2026-11-01 14:30 engineering: Overnight line
Issue: #570  PR: #582
```

## A design entry

One line per changed token, board or rule, stating what it was before:

```
- TOKENS.md § Spacing: `row-compact` 44 → 40 pt. Was 44 since 2026-10-12.
- boards/settings-light.png, settings-dark.png: rows use `row-compact`. Was `row`.
- DESIGN.md § Settings: "rows are compact" added.
```

A proposal is the same entry with `Proposed:` before the title; it becomes an entry without the prefix once the owner has agreed and the files are changed.

When the owner decides something about a proposal in the conversation with design, not in an issue, add a line to the entry in the owner's terms, and say the same in the issue ("agreed with the owner"). The conversation is condensed or ends; the entry and the issue stay:

```
- Decided (owner): "While charging," instead of "Overnight," when the task ran in the daytime; the line is in Activity only.
```

## A "Built" entry

Written by engineering after the merge. It gives what the user sees, and only that:

```
- Home banner: "Recording paused" / de "Aufnahme pausiert". Was: "Paused" / "Pausiert".
- Banner sits under the title (deviation, for design to confirm: the board shows it over; clips at large text).
- Settings rows: compact height from TOKENS.md, not the board's (for design to confirm).
```

Rules: the exact strings in every language, a "Was:" for each change, and every deliberate deviation from the boards marked "for design to confirm". Rule-level logic (grouping, counting, edge cases) goes in the PR and in code comments, not here. A rule that needs design's confirmation gets one line in the user's terms: what they see, and when.

The same confirm list is posted in the issue (see `messages.md`); the entry is the record, the issue is where it is decided.

## Reading

Agents read the newest entries, not the whole directory: `ls design/changelog | tail -20`. For history on one screen or token, `grep -l` across the directory.
