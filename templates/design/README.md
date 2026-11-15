# design/

The design agent's files, and engineering's screenshots of what was built. The process is the `agent-team:team-process` skill; this file says what is where in this repo.

| Path | Owner | What |
|---|---|---|
| `../DESIGN.md` | design | What each screen does and why, one section per screen |
| `../TOKENS.md` | design | Colours, type, spacing, wording rules. Tokens win over boards |
| `boards/` | design | A PNG of every board, light and dark, plus the variants listed in CLAUDE.md |
| `components/` | design | The boards' HTML source, which an agent can read and render |
| `mockups/` | design | Proposals, before they become boards |
| `built/<date>/` | engineering | Screenshots and clips of what was built, named like the boards |
| `changelog/` | both | One file per entry (`changelog-new.sh`). `CHANGELOG.md` here is generated and ignored |

## Screenshots of what was built

From the fixed simulator or viewports named in CLAUDE.md, in the same states as the boards, light and dark, and the extra variants where a board exists for them. Named like the matching board. The "Built" report in the issue lists which ones changed since the last round; design looks only at those.

## What a "Built" entry says

The exact strings in every language, a "Was:" for each change, and every deliberate deviation from the boards marked "for design to confirm". Rule-level logic goes in the PR and in code comments. The confirm list is also posted in the issue, where it is decided.

## Questions and reviews between design and engineering

As the `agent-team:team-process` skill says: GitHub issues with its labels, a role tag on the first line of every agent comment, review rounds as checklists. The issue is the conversation; these files are the record.
