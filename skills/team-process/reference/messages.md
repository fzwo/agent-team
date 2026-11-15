# Messages between the agents and to the owner

Every agent comment and issue starts with the tag on its own first line: `[engineering]` or `[design]`. Then the message. Keep to the formats below so the other agent and the owner can read them on a phone.

## A question to the other role

Issue labelled `for-design` or `for-engineering`. Title says what is asked. Body:

```
[engineering]
Question: <one sentence>
Context: <what the asker already knows; link the board, screenshot or code>
Options: <if the asker sees any>
Needed by: <which piece of work waits on it, or "not blocking">
```

Answer in a comment, then close the issue if nothing else is open in it. If the answer is a product or taste call, relabel to `owner` instead of guessing.

## A proposal (design to engineering), and the feasibility reply

Issue labelled `for-engineering`, for anything engineering would build from, after the critique pass:

```
[design]
Proposal: <one line>
Mockup: design/mockups/<file>  Entry: design/changelog/<file>  DESIGN.md: § <section> (draft in the PR)
What people see: <two or three lines, in the user's terms>
Decided alone / needs the owner: <which, and why by the rule in design-role.md>
```

Engineering replies before anything is built:

```
[engineering]
Feasibility: <fine / with changes / not as proposed>
Tier: low|standard|high  Cost: <hours / a day / more>
Constraints: <platform or architecture limits, one line each>
Alternatives: <if any>
```

Disagreement on either side relabels the issue to `owner`; the three of them settle it there.

## A review round (design to engineering)

One issue per round of screenshots, labelled `for-engineering`. One line per finding, naming the screenshot and the board:

```
[design]
Review of design/built/2026-11-01/ against the boards.
- [ ] home-light.png vs boards/home-light.png: the banner is 8 pt lower than the board
- [ ] settings-dark.png: "Speichern" should read "Sichern" (TOKENS.md, Wording)
- [ ] recording-large-text.png: title wraps to three lines; board allows two
```

Engineering ticks each line, or answers it in a comment with the line quoted, and closes the issue when every line is settled.

## A "Built" report and the confirm list (engineering to design)

Posted in the issue the work belongs to, or in its PR, after the merge:

```
[engineering]
Built in #<PR>. Screenshots: design/built/<date>/ (changed: home-light, home-dark, settings-*).
Clip: design/built/<date>/recording.mov
Strings:
- en: "Recording paused" (was: "Paused")
- de: "Aufnahme pausiert" (was: "Pausiert")
For design to confirm:
- Banner sits under the title, not over it (home-light.png). Board shows it over; the title would clip at large text.
- Settings rows use the compact height from TOKENS.md, not the board's (settings-dark.png).
Docs that no longer match the build: DESIGN.md § Home § Banner. TOKENS.md: none.
```

Design confirms each bullet with a tick or answers it; a taste call goes to the owner as an `owner` issue.

## A pull request body (both roles)

```
[engineering]
Tier: standard
<what and why, in a few lines; the evidence is in the PR's review summary>
See #N (the issue), #M (the decision it follows)
```

The tag on the first line is what keeps the watchers quiet about your own pushes, since both agents work under one account. "Closes #N" only for the issue the PR resolves and only when it is engineering's or design's; never for a `decision` or `owner` issue, which the owner closes. One closing keyword per line and nothing else on that line: GitHub closes every issue listed behind one keyword, so "Fixes #A, see #B" closed B.

## A `decision` issue

Filed by either agent whenever it makes a judgement call in its own domain that the owner might overrule, day or night, owner present or not:

```
[engineering]
Decision: <what was chosen, one line>
Alternatives: <each, one line, with the reason against>
Why: <two or three lines>
Where: <PR or commit>
Reverting costs: <small / a build cycle>  (anything dearer is an `owner` issue)
```

Work continues on the chosen option. The owner closes without comment to accept, or comments to overrule. Untouched for seven days means accepted; the expiry workflow closes it.

## An `owner` issue

```
[design]
Needs the owner: <the question, one line>
Options: <each with what it costs and what it looks like; attach the mockup or screenshot>
Recommendation: <one line, or "none">
Blocking: <what waits, or "nothing">
```

File it assigned to the owner: `gh issue create --label owner --assignee @me …` (both agents work under the owner's account, so `@me` is the owner). An `owner` issue needs them; it shows in their assigned list. A `decision` issue is informative and is not assigned. A `bug` the owner files comes through the Bug template, untagged, and is engineering's to take in its queue order.

## The report to the owner, and its footer (both roles)

Engineering reports at the end of each piece of work, design at the end of each session or product conversation. Housekeeping is never reported. The footer is the same for both:

```
Done: <one line, or a few for a shift>  Evidence: <what was observed, one line per claim>
Waiting on you (every open `owner` issue from both roles, and questions asked in this conversation; repeated until resolved):
- #<n> <title>, since <date>
Decisions since last report (overrule in the issue, or ignore):
- #<n> <one line>
Ideas since last report: #<n> <title>, #<n> <title>
Routine posts since last report: #<n>, #<n>  (design only; issue numbers, overrule in the issue)
```

"Waiting on you" is repeated in every report until each item is resolved, so it cannot drown. Decisions and ideas are listed once, when new. Engineering adds `State written to .agent-team/state.md.`, and on a shift's last report `Plugin: <version>` (`agentlock version`), since a session keeps the plugin copy it started with (the state file's "Updated" line carries it from the start).

**A report is not every reply.** The footer goes on a report: the end of a piece of work, the end of a session, or the first message after the owner has been away. It does not go on replies inside a live conversation, where the owner has just read the last message: a footer under "Confirmed, posted" repeats what is on the screen above it and teaches the owner to skip footers. In a live conversation, end with the open questions instead.

**Questions to the owner are numbered and answerable in a word.** Put them last, one per number, each with your recommendation, so the owner can reply "1. yes 2. no" from a phone. That is how the owner answered on the first project when the questions were numbered, and it is what saves the owner's attention, more than any footer. A question in the footer's "Waiting on you" keeps the same number until it is answered.

**"Waiting on you" includes questions asked in the conversation**, not only `owner` issues: design asks most of its questions in the chat, and those would otherwise be in no list. Give each one line and where it lives (the issue it belongs to, or "asked in chat on <date>").

## The closing comment on an issue (engineering)

```
[engineering]
Closed by #<PR>. Design docs that no longer match the build: DESIGN.md § <section>, § <section>. TOKENS.md: none.
```

Design takes the named sections as its to-do and updates them in its next session.

## Design's report to the owner

The same footer. Routine posts (review rounds, answers the docs or an earlier owner decision settle, mismatches with a board, reminders, relayed information, measurement requests, closing an issue the owner agreed to close) appear once as issue numbers on the footer's last line; housekeeping never appears. What design shows the owner before posting is in `design-role.md`, "What you decide alone and what you ask".
