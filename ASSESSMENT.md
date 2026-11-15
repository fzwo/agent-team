# Making the two-agent process reusable: assessment and proposal

> Historical. This is the round-one analysis. Where it differs from `DECISIONS.md` (sessions per piece of work, an invisible comment marker, a round cap, design's owner gate), `DECISIONS.md` and the skill are what applies.

Written 2026-11-01 from the engineering agent's description (`agent-team-process.md`) and the Claude Code docs as of today. This is round one: the shape of the thing, the three issues you named, the issues I found, and the decisions I need from you before building the rest. The one piece that needed no decision, the machine-wide lock, is built and tested (`scripts/agentlock`, see section 4).

## 0. Summary

- **Home:** one git repo that is a Claude Code plugin. Installed at user scope it applies to every project on the Mac. It holds the process as a skill, the two subagent briefs, the hooks, the scripts and the repo templates. A project then needs about five lines in its `CLAUDE.md`. This is what both agents suggested, and the plugin mechanism fits it exactly.
- **Token use:** the biggest lever is probably not the review loop but the long-running session plus the forty memory files it carries. Make sessions disposable and move the rules into the skill, which loads on demand. Keep re-review of every fix, as you asked, but make rounds cheaper and tiered by risk.
- **Communication:** keep GitHub issues as the channel. Fix the three structural problems: fragile author detection (an invisible marker in every agent comment), slow and token-free polling that could simply run more often (every few minutes, since the poll itself costs nothing), and the shared newest-first changelog that guarantees merge conflicts (one file per entry).
- **Mac coexistence:** a machine-wide lock tool with named resources (`ui`, `sim:<name>`, `device:<udid>`, `port:3000`), enforced by a hook so an agent cannot forget it. Built, see section 4.
- **SaaS:** not a separate version. The same core with a platform profile (`ios`, `web`, `none` for libraries and CLIs). The profiles differ in how the build is observed, what the risky changes are, and what the lock protects.

## 1. The shape: a plugin repo

```
agent-team/                          the repo, installable with /plugin marketplace add <you>/agent-team
  .claude-plugin/plugin.json
  .claude-plugin/marketplace.json
  skills/
    team-process/SKILL.md            the core: roles, labels, loop, reports, decisions (short)
    team-process/reference/
      review.md                      tiers, reviewer briefing, re-review rules
      messages.md                    the message types and their templates
      changelog.md                   the entry format
      design-role.md                 the design agent's instructions (the half that was missing)
      profile-ios.md                 simulator, device, screenshots, disk
      profile-web.md                 browser screenshots, migrations, deploys, ports
    team-init/SKILL.md               sets a repo up: labels, design/ dir, CLAUDE.md lines, issue templates
  agents/
    reviewer.md                      adversarial review brief
    builder.md                       builder brief: own worktree, delete only own files by name
  hooks/hooks.json                   lock enforcement, lock cleanup at session end
  scripts/
    agentlock                        the lock (done)
    watch-github.sh                  polls comments since a cursor, wakes a session
    gh-labels.sh                     creates the labels
    changelog-render.sh              joins entry files into one view
  templates/
    CLAUDE.md.snippet
    design/README.md
    .github/ISSUE_TEMPLATE/          review-round, decision, owner
    .github/workflows/decisions.yml  closes silent `decision` issues after N days
  README.md
```

Why a plugin and not loose files in `~/.claude`: it is versioned, installable in one command on another Mac or a cloud session, and the plugin layout has a place for each kind of thing. Skills load their body only when invoked, so the process costs almost nothing in context until it is needed. Agent briefs load only when a subagent is started. Hooks cost no tokens at all.

Things the docs confirm today: user-scope install applies to all projects; `--plugin-dir` loads the repo directly while developing it; a SessionStart hook can export environment variables to the session's later shell commands via `CLAUDE_ENV_FILE`; a PreToolUse hook that exits 2 blocks the command and shows its message to the agent; hooks also fire for subagents' tool calls.

**Which agent runs where.** The description does not say how the design agent runs, only that it is "a separate Claude session" that renders HTML boards to PNG, so it runs code somewhere. If it is a Claude Code session (local or cloud), the same plugin serves it, with the role set by one line in its CLAUDE.md or its first prompt. If it is a claude.ai chat with a GitHub connector, it needs a pasted instruction set instead, and `design-role.md` is that set. Either way the content is the same; I need to know which. See the questions in section 7.

## 2. Token use

Where the tokens go, in my estimate, largest first. I have not measured your sessions, and I suggest you do before deciding: `/cost` in a session, or the `ccusage` tool over `~/.claude/projects`, for a week.

1. **The long-running engineering session.** Every wake-up re-sends the whole context. After an hour the prompt cache is cold, so a wake-up on a 150k-token session costs 150k input tokens before the agent reads a word of the new comment. Compaction then throws away the rules it needed. The forty memory files, `design/README.md` and the CLAUDE.md files are re-read on every start as well.
   - **Change:** sessions are disposable. The watcher starts a fresh `claude -p` run (or resumes a short one) with "handle these issues", the skill provides the rules, and the repo and the issues provide the state. Your process already says "the issue is the conversation; the docs are the record", so a fresh session can pick up anything. State that is neither code nor issue goes in one file in the repo (`.agent-team/state.md`: what is in flight, what to resume), not in session memory. A SessionStart hook can print it.
   - **Change:** the forty memory files become the skill and its profile. What is left in memory should be project facts only (device UDIDs, build quirks), one short file.
2. **The re-review loop.** Your rule stands: every fix gets a review, because unreviewed fixes are a back door. What can change is how much a round costs:
   - A re-review round gets the previous round's findings (those are the reviewer's words, not the author's) and the fix commits highlighted, and is asked to verify each finding is closed and to break the fixes. It does not restart from zero.
   - Tier by risk, declared by the engineering agent in the PR and overridable by you. **Low** (strings, docs, layout with no logic): one review, re-review of fixes with a smaller model. **Standard:** as now, but after three rounds that still find code changes the agent stops and files an `owner` issue instead of a sixth round. **High** (data, migrations, concurrency, money, speech memory): until clean, no cap, strongest model.
   - The reviewer brief gets the diff and the files it touches, not the whole repo. Subagents that read broadly are the expensive part of a round.
3. **Screenshots.** Each image is roughly a thousand tokens, and design looks at every board in every state, language and theme. Engineering should list which screenshots changed since the last round and design should open only those. A pixel diff against the board (ImageMagick `compare`, a number per screenshot) is cheap and lets design skip unchanged screens entirely. Optional, project-specific.
4. **Polling.** Already solved: shell scripts cost nothing while waiting. The ten-minute cron was expensive because it woke the session, not because it polled. Section 3 makes use of this.

## 3. How the agents talk

Keep GitHub issues. They are durable, readable from your phone, and the record you want. Four changes:

1. **Identity.** Every agent comment carries an invisible marker on its first line, an HTML comment such as `<!-- agent: design -->`, which GitHub does not render and a script matches exactly. No account change needed. Later, if you want it, a machine account for the design agent (GitHub allows one per person for automation) adds proper authorship, @-mentions and notifications. The marker works with or without it.
2. **Latency.** Polling costs nothing, so poll every three minutes instead of every thirty or sixty. One API call lists every comment in the repo since a cursor (`issues/comments?since=`). The watcher keeps the cursor in a file, filters by marker and label, and wakes a session only for something addressed to its role. A round trip between the agents then takes minutes, not hours, with no token change. The four-hour auto-stop stays.
3. **Writes to `main`.** The merge incident happened because design pushes to `main` directly. All writes go through PRs, design's too, and design's own-files-only PRs auto-merge (`gh pr merge --auto`). Branch protection then makes the race impossible, and the "clean up only after MERGED" rule becomes a check the tooling does rather than one the agent must remember.
4. **The changelog.** A shared file with newest-first entries conflicts on every concurrent change by construction. Replace it with one file per entry in `design/changelog/`, named `YYYY-MM-DD-HHMM-<role>-<slug>.md`, and a script that renders them into one view when someone wants to read it. The conflict script and the marker search go away. Nothing else about the entry format changes.

What stays: the labels and their rules, review rounds as checklists, the confirm list in the issue, the report footer, `decision` issues when you are away. One addition for the `decision` pile: a scheduled workflow closes `decision` issues untouched for seven days with the comment "accepted by silence, per process", which makes the existing rule honest instead of a growing list.

## 4. Coexisting on the Mac: the lock

`scripts/agentlock` is built and tested on Linux with the same primitives macOS has (`mkdir` is atomic, `ps`, `kill -0`; it runs on the stock bash 3.2). Resources are names: `ui` for anything that needs the screen or keyboard focus, `sim:<name>` per simulator, `device:<udid>` per phone, and for web projects `port:3000` or `db:dev`. Locks live in `~/.agentlock`, one directory per resource, so every session on the machine sees the same set regardless of project.

```
agentlock acquire ui --ttl 30m --reason "screenshots for #538"
agentlock acquire sim:iPhone-16e --wait 15m
agentlock with device:00008120-... --ttl 20m -- ./scripts/install-and-run.sh
agentlock status
agentlock release ui
```

- A lock has an owner, a TTL and a reason. The owner is the Claude session id, exported into the session's shells by a SessionStart hook, so every Bash call and every subagent of that session count as the same holder, and a different session or project does not.
- A lock is stale when its holder's process is gone or its TTL has passed. Stale locks are removed automatically on the next acquire.
- **Enforcement** is the part that makes it central: a PreToolUse hook runs `agentlock guard` on every Bash command. A small config file maps patterns to resources (`simctl boot` needs `sim`, `screencapture` and `xcodebuild test` need `ui`, `devicectl` needs `device`). A command that needs a lock the session does not hold is blocked, and the agent sees who holds it and how to wait. Nothing to remember; a wrong guess is a blocked command, not a broken session.
- At session end a hook releases everything the session held.
- You, at the keyboard, are a holder too: `agentlock acquire ui --ttl 2h --reason owner` stops every agent from touching the screen. The hook could also refuse `ui` while the Mac shows recent keyboard activity (`ioreg` HIDIdleTime under a minute); I left that out until you say you want it.

Open point: the docs do not state whether a subagent's hook input carries the parent's session id. The SubagentStop example suggests it does. The first run on the Mac should check it with a one-line logging hook; if not, the guard falls back to the process tree, which is already implemented.

## 5. Issues I found beyond yours

- **The design agent's instructions are undocumented** ("its instructions weren't available here"). Half the process lives in a place nobody can read. `design-role.md` in the skill fixes that, and the design agent should review it.
- **The process depends on the engineering agent's memory of many rules.** Hooks can enforce the mechanical ones: the lock, "delete only your own files by exact name" (block `rm -rf` with a glob or outside the worktree), "search for conflict markers before committing" (a pre-commit check), "clean up only after MERGED" (the cleanup script checks `gh pr view --json state` itself). Each rule that becomes a check is a rule the skill no longer has to spend words on.
- **Two agents, one credential.** Fine for a solo project, but the design agent has write access to the code and the engineering agent to the design docs. Branch protection with required PRs (section 3) is the cheap version of a boundary; a CODEOWNERS file per directory, enforced on auto-merge, is the next step if you ever want it.
- **"Merge without asking" plus a bot that pushes to `main`** is what deleted a branch. Covered by section 3.
- **Review subagents get "the repo".** That is the broad, expensive read. Give them the diff, the touched files and the tests, and let them ask for more.
- **The "Built" entries and the "for design to confirm" list are two records of the same thing.** Already trimmed by you on 2026-11-01; the entry-per-file changelog keeps the trim.
- **Design checks the build from screenshots only.** Structural, as the critique says. The only real fix is giving design a way to run the app. With the lock in place, a design session on the same Mac could run the simulator in its own turn. Whether design should is a role question, not a tooling one; I would not do it by default.

## 6. SaaS and other project kinds: profiles, not a fork

The core is platform-neutral: roles, labels, the loop, reviews, reports, decisions, the lock, the watcher. What differs is a profile:

| | `ios` (this project) | `web` (SaaS) | `none` (library, CLI, backend) |
|---|---|---|---|
| Design agent | yes, once there is UI | yes, once there is UI | no; reviewer and builder only |
| Observing the build | one simulator at board size, screenshots and clips in `design/built/` | Playwright at fixed viewports, same naming; design can run it too, so it can take its own screenshots | tests, logs, CLI output |
| High-risk tier | data, speech memory, background tasks | migrations, auth, billing, anything touching production data, deploys | public API, data formats |
| Lock resources | `ui`, `sim:*`, `device:*` | `port:*`, `db:dev`, `staging` | usually none |
| Extra rules | disk, device backup, muted launch | never run migrations against a shared database without the lock; secrets never in issues or changelog; a preview deploy per PR if the host offers one | none |

So: one skill, a `profile:` line in the project's CLAUDE.md, and the profile file loaded on demand. A SaaS project adds roughly a page of rules, not a second process.

## 7. Decisions I need from you

1. **How does the design agent run?** Claude Code (local on the Mac, or a cloud session), or a claude.ai chat with GitHub access? This decides whether one plugin serves both roles.
2. **Disposable sessions** started by the watcher instead of one long-running session: yes?
3. **Review tiers with a cap on the standard tier** (stop and ask after three rounds that still change code), re-review of every fix kept: yes?
4. **Changelog as one file per entry** with a rendered view: yes?
5. **All writes to `main` through PRs**, design's own-files PRs auto-merged: yes?
6. **Comment marker now, machine account for design later or never:** fine?
7. **Name** for the plugin and repo. I used `agent-team`.

Your earlier open questions, with my recommendation: start a new project with engineering only and add design when there is UI, as design said; one skill plus repo templates, as both agents said, and the plugin is that; separate accounts are optional once the marker exists.

## 8. Next round

Once you have answered, I write the skill and its reference files from the first project's description and your `design/README.md` sections, the two agent briefs, the watcher, the label and init scripts, and the templates, then validate the plugin with `claude plugin validate` and a `--plugin-dir` dry run. The design agent should read `design-role.md` and correct it the way it corrected the description. The first Mac run checks the one unverified hook detail (section 4) and installs the lock config.
