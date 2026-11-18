# Review: tiers, rounds, the tripwire, merging

## Tiers

The engineering agent declares the tier in the PR body (`Tier: ...`). A PR without the line is `standard`. The owner can change it in a comment, and whoever applies the change edits the body's line too.

| Tier | What it covers | First review | Re-review of fixes |
|---|---|---|---|
| `low` | Strings, docs, layout and styling with no logic, tests only | One reviewer, `model: sonnet` on the Agent call | Same, every fix |
| `standard` | Everything else | One reviewer, the session's model | Every fix, by the same reviewer resumed (below) |
| `high` | Data and migrations, concurrency, money, auth, background work, anything the profile lists as high risk | One reviewer, the model CLAUDE.md names under `Review model, high tier:` (`session` or absent: the session's model) | Every fix, by the same reviewer resumed; the last clean round is a fresh reviewer |

The tier changes who reviews and how deep. It never changes whether fixes are re-reviewed: every fix commit is reviewed, because unreviewed fixes are a back door. The first shift's numbers (2026-11-02): 25 standard and high rounds on the strongest model were 38% of the shift's tokens; the first round of each PR is what caught the real bugs, later rounds verified fixes.

## What the reviewer gets

- The PR diff, the full current content of each touched file, the tests that cover them, and `ARCHITECTURE.md` if the change touches more than one module.
- Not the author's reasoning, not the author's test claims, not the whole repo. The reviewer can read more if it decides to; the brief must not hand it everything.
- Its brief is `agent-team:reviewer`. Its job is to break the change: wrong behaviour, missed cases, races, state that leaks, tests that cannot fail, and whether the change fits `ARCHITECTURE.md`.
- It must report evidence for each finding (file, line, the input and the wrong result), and for a clean round, what it checked.

## Re-review rounds

A re-review round **resumes the reviewer that did the previous round** (the Agent tool continues a subagent with its context intact) rather than starting a new one. It already holds the files, the tests and its own findings, so the round costs the fix diff and the new reasoning, not a re-read of everything; and it knows why the original failed, which is what breaking a fix needs. Its brief for the round: the list of fix commits; verify by reading the code that each finding is closed, never by the author's word; read the full diff of the fix commits, not only the lines that answer the findings, and look for what they broke elsewhere; re-run the tests. A resumed context is cheap only while it is still cached, and the cache lifetime varies with the session, so no clock decides this; the numbers do. Resume by default. Every subagent reports its token count when it finishes (the harness attaches it to the completion notice); write each round's count into the PR's review summary. If a resumed round cost more than about half of the PR's first round, the cache was cold: the remaining rounds of that PR start fresh, each given the previous findings verbatim and the fix commits, and the summary says so. Start fresh as well when the previous reviewer cannot be resumed (context near its limit, session restarted). The first round of every PR is always a fresh reviewer: that is where the fresh eyes matter, and where the first shift's real catches came from.

**Two guards, because instructions are not enforcement.** A resumed reviewer may see its own findings as closed once the fix matches what it asked for. So the last clean round of every high-tier PR is a fresh reviewer: start one for the whole PR once the resumed reviewer is clean; when it finds something, the fixes are re-checked by resuming that fresh reviewer, and its clean re-check is the clean round, since its own findings are what it checks. On standard tier, every fifth merged PR gets one fresh audit round after the resumed round passed it, and the bookkeeping is derived, not remembered: `.agent-team/state.md` has a "Review audits" section with the last audited PR number and one line per audit (PR, date, blocking finding yes or no); the count of merged standard-tier PRs since that number comes from GitHub, so a restarted session finds its place:

```
gh pr list --state merged --search "Tier: standard" --limit 500 --json number -q "[.[] | select(.number > ${LAST:-0})] | length"
```

(`--limit 500` because the default returns 30; `$LAST` is the last audited PR number from the state file, `0` before the first audit; an empty value counts as 0.) The query reads PR bodies, so the body's `Tier:` line is the source of truth: whoever applies an owner's tier change from a comment also edits that line in the body. Two blocking audit findings among the last ten audits switch standard tier back to fresh reviewers for every round; the switch is written in the same section with the date, and the owner lifts it.

A round is clean when it reports no finding that needs a code change. Notes (comments, naming, style) do not block a merge and are never fixed in the same PR, because every fix costs another round: record them in the PR, merge, and collect the shift's notes into one PR at the end of the shift, reviewed as low tier. A note that hides a bug is a finding, not a note.

## The tripwire

There is no cap on rounds. Technical findings, fixed and re-reviewed, are the system working. Escalate to a `decision` issue, with the history of rounds, when:

1. The same finding comes back after the author disputed it, or
2. Two rounds in a row do not shrink the list of findings (by count or by severity), or
3. A finding is really a product or taste question: that one is an `owner` issue, not a `decision`.
4. The same area gets a new finding three rounds in a row, each list short (per-exit patches of one concurrency window, four rounds, a PR of the first project on plugin 0.4.11): the count never shrinks because it never grows. The default answer is to restructure, not patch: brief the next builder to make the thing an explicit state consulted in one place.

Case 2 includes the count staying at one: four rounds of one finding each, every finding a bug in the previous round's fix (the first project PR 770), is the tripwire, not progress. Two kinds of case 2 look alike in the count and need different answers. When each round finds new paths through unchanged code, continuing is right: the reviewer is covering ground. When a round's findings are regressions of the previous round's fix, the fix is the problem: revert it and take the narrower alternative, cut the scope back through a `decision` issue, or change the mechanism (the second shift ended three rounds of detecting a SwiftUI alert from outside by presenting it through UIKit). Say in the round summary which kind it was. In case 1 and 2 the change's design is usually wrong, not its code. A related pattern the tripwire does not count: when a round's findings are caused by the previous round's fix, revert that fix and take its narrower alternative rather than patching the patch; the second shift's PR 653 needed two rounds to see that. The `decision` issue states the options; work continues on the author's choice unless the owner overrules. When the tripwire fires a second time in the same PR, after whatever answer the first firing chose (a restructure, a revert, a narrower scope), the design is beyond what engineering can settle by choosing again: that is an `owner` issue with the two attempts and their findings, not a second `decision` (a shift filed a second decision and was unsure; this is the answer).

## Merging

- Merge without asking once a round is clean, with `pr-merge.sh <number>` (`--method squash` where that is the repo's convention): it refuses while `main` has moved past the branch or GitHub has not computed mergeability, and confirms MERGED. Check the PR state before any cleanup (`pr-cleanup.sh`).
- Stop and file an `owner` issue instead when a finding needs a product call, a fix is risky or cannot be verified by observation, or the merge conflicts with `main` in a way that needs judgement.
- After the merge: the closing comment on the issue names the design-doc sections that no longer match the build, or says none do.

## Design proposals

A design proposal gets two looks before its docs PR merges: the critique pass and engineering's feasibility reply. The flow is in `design-role.md`, "How a proposal moves", and the reply format in `messages.md`; this file does not repeat it. Housekeeping changes to design files get no review.
