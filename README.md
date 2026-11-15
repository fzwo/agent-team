# agent-team

A development process for one owner and two agents, packaged as a Claude Code plugin: an **engineering agent** that builds, tests, reviews through subagents and merges; a **design agent** that owns the product and design documents and the boards and checks the build; GitHub issues as the only channel between them; adversarial review with a re-review of every fix; machine-wide locks so agents can share a Mac; and templates to set a repository up in one go.

It grew out of one iOS project (about 300 merged PRs in three weeks). `ASSESSMENT.md` is the analysis that shaped this version, `DECISIONS.md` the owner's decisions.

## What is in here

| Path | What |
|---|---|
| `skills/team-process/` | The process. `SKILL.md` is the short version; `reference/` has the review rules, message formats, changelog format, the design agent's full instructions, the platform profiles (`apple`, `web`) and the interim architecture rule |
| `skills/discover/` | `/agent-team:discover`: a vague idea to a brief the owner decides on (what exists, feasibility, platforms, licence, first version); runs anywhere with the owner's new repository, before the Mac has it |
| `skills/team-init/` | `/agent-team:team-init`: sets a repo up |
| `skills/shift/` | `/agent-team:shift`: starts or ends an engineering shift |
| `agents/` | Briefs for the `reviewer`, `builder` and `design-critic` subagents |
| `hooks/hooks.json` | Lock enforcement on every shell command, lock owner export at session start, lock release at session end |
| `scripts/agentlock` | The machine-wide lock |
| `scripts/watch-github.py` | Polls GitHub for input addressed to a role and wakes a session; no tokens while waiting |
| `scripts/gh-labels.sh`, `changelog-new.sh`, `changelog-render.sh`, `pr-cleanup.sh` | Labels, changelog entries, the rendered changelog view, cleanup that checks MERGED first and runs the project's worktree hook |
| `scripts/install-mac.sh`, `host-add.sh`, `shift-start.sh` | Mac setup, a launchd host per project folder, a named shift from the command line |
| `scripts/tmp-sweep.sh` | counts, and with `--delete` removes, known toolchain debris in the Mac's temporary directory (SwiftPM and Interface Builder leftovers that macOS clears only at reboot) |
| `scripts/publish.sh`, `publish-subs.py` | the maintainer's release step: the private repository's HEAD, rewritten for the public copy, as one commit per version in the public install source; the list of names and its test fixture are kept out of the public copy, where the script refuses to run |
| `tests/run.sh` | The regression suite for the scripts |
| `templates/` | CLAUDE.md lines, `design/README.md`, state file, issue templates, decision-expiry workflow, git-ignore entries |

## Install

On every machine or cloud environment that runs an agent:

```bash
claude plugin marketplace add fzwo/agent-team
```

```bash
claude plugin install agent-team@fzwo --scope user
```

The marketplace is registered under the name in its `marketplace.json`, `fzwo`, not under the repo name. User scope applies to every project on that machine. Inside every Claude Code session the plugin's session-start hook puts its `scripts/` directory on the PATH, so `agentlock` and the other scripts resolve by name without any shell configuration. To work on the plugin itself, run `claude --plugin-dir /path/to/agent-team` in any project and `/reload-plugins` after edits.

Two repositories: `fzwo/agent-team`, public, is the install source and holds the plugin at each release, one commit per release, with the project it was built on called "the first project" and the machine that runs its agents "the agent Mac"; `fzwo/agent-team-dev`, private, holds the full history, the pull requests and the record's issue numbers. Three checks of the test suite read a 0.3.x copy of the lock tool out of that history and run only there: the private suite passes 456 checks, the public copy 453 (as of 0.4.22).

## Apply to a project

In the project, in a Claude Code session: `/agent-team:team-init`. It creates the labels, appends the `Role:` and `Profile:` lines to `CLAUDE.md`, lays out `design/`, adds the state file, issue templates, the decision-expiry workflow and the git-ignore entries, and opens a PR. Then require PRs on `main` in the repository settings. One habit for you as owner: never start a comment or issue with `[engineering]` or `[design]`, since the watchers would read it as an agent's.

A session reads its role and profile from `CLAUDE.md` and follows the skill from there.

## On a Mac that agents share

One command does all of the below and prints what to verify afterwards:

```bash
git clone https://github.com/fzwo/agent-team ~/Code/agent-team && ~/Code/agent-team/scripts/install-mac.sh
```

By hand:

```bash
ln -s /path/to/agent-team/scripts/agentlock /usr/local/bin/agentlock
```

```bash
mkdir -p ~/.agentlock && cp /path/to/agent-team/hooks/guard.conf.example ~/.agentlock/guard.conf
```

Edit `guard.conf` to what the machine has. After a plugin update that changes the example (the decisions log says when; 0.4.7 moved `xcodebuild test` from `ui` to `sim`), re-copy it and merge your edits; `agentlock check-conf` checks the syntax. A session keeps the plugin copy it started with, so after a plugin update restart every session on the Mac before relying on the locks; the 0.4.1 copy honours locks taken by older copies, but older copies cannot see its locks. From then on, any shell command that matches a rule is blocked unless the session holds the lock, and the agent is told who holds it. `agentlock status` shows the holders; `agentlock acquire ui --ttl 2h --reason owner` keeps every agent off the screen while you use it.

The plugin's hook finds `agentlock` through `${CLAUDE_PLUGIN_ROOT}`, so the symlink is only for your own and the agents' direct use.

## Hosting sessions on the Mac

Sessions started from the app land in the folder where `claude remote-control` runs, and Claude Code reads `CLAUDE.md` and the project memory from that working directory. So run one host per project folder, not one at the parent, or a shift will not see the project's `Role:` and `Profile:` lines. Hosts should be services, not terminal windows: `scripts/host-add.sh ~/Code/<project>` installs a launchd user agent that keeps the host running there and restarts it after a reboot, and it can be run from any session already on the Mac, so a new project never needs someone at the keyboard. `host-add.sh --list` and `--remove` manage them. (Verified on the agent Mac on 2026-11-02.) A session starts in the default permission mode, which asks for every new kind of command; a shift that runs through the night wants auto mode, with the lock hook still blocking what needs a lock.

## Starting a project

**On the Mac, a repo that is not there yet.** From any session hosted on the Mac: clone it into `~/Code/<project>` (or create it on GitHub with `gh repo create` and scaffold it; the Mac has the credentials), run `scripts/host-add.sh ~/Code/<project>`, start a session in the new host from the app, and give it `/agent-team:team-init`. For a UI project, point the design session at the repo with `templates/design-session-prompt.md`; one design session per project. Nobody needs to be at the Mac after the first host exists.

**Web projects** run on the agent Mac by default, the same way as Apple projects, with the app and its tests in a Linux container on the Mac and a green Linux CI run as a merge condition; deploys run from GitHub Actions. The cloud is the fallback.

**In the cloud (fallback).** Engineering sessions start from the app with the repo selected. Containers are fresh per session, so a user-scope plugin install does not persist: install the plugin in the environment's setup script (a project-scope enablement committed in `.claude/settings.json` is the other route; untested). Checked once, on 2026-11-15: a cloud environment whose setup script runs `claude plugin marketplace add fzwo/agent-team || true` and `claude plugin install agent-team@fzwo --scope user || true` gave a fresh session the plugin installed, in under two seconds, with its four skills listed; no hook or skill was exercised in that check. It works because `fzwo/agent-team` is public: a private source fails there, since the script runs before the session has any GitHub credential, and a container cached from a failed script was rebuilt once the script's text changed. A `discover` session, which needs the web and a repository, not the Mac, is the first use of this. The rest of this paragraph is untested as of 2026-11-02. The lock directory is per machine and coordinates nothing between cloud sessions; the web profile avoids shared resources (database and port per branch, preview deploy per PR) instead of locking them. The watcher runs as a background command that exits on input (`--exit-on-input --max-minutes`), restarted by the session; between shifts, a scheduled task that runs it once every few hours is the fallback. Design runs the app in its own container with a headless browser. The Mac path is the tested one.

## Shifts

An engineering shift is a session: `/agent-team:shift` as its first message starts one (it numbers itself from the state file, does the one-time housekeeping, starts the watcher and works the queue); `/agent-team:shift end` ends one. From the phone, a new session in the project's host plus that one word is enough. `scripts/shift-start.sh ~/Code/<project>` does the same from any shell or session on the Mac and names the session "<Project> shift <N>" in the app; it needs tmux, since an interactive session must live in a terminal. Design has no shifts: its session is persistent, woken by its watcher, and keeps its own state file.

## The watcher

The default, for both roles: the session runs it as a background command at the start of a shift and again after each exit. It exits 0 with the summary when there is input (the session is notified and handles it), 3 when nothing came in before the time limit (the harness shows that as a failed command; it is the normal case), 2 after a week without activity, when the session tells the owner and stops:

```bash
watch-github.py --role engineering --exit-on-input --max-minutes 110
```

The alternative, for a session that someone else wakes, is a long-running watcher with a wake command, from a terminal or a launchd job:

```bash
python3 /path/to/agent-team/scripts/watch-github.py --role engineering --wake 'tmux send-keys -t eng -l "$(cat "$1")"; tmux send-keys -t eng Enter'
```

It polls every two minutes (polling is free; only wake-ups cost tokens), slows to every thirty minutes after four hours without activity, keeps a cursor so restarts do not replay, wakes only for items addressed to the role, and stops after a week without activity, so nothing runs forever (the owner's schedule, 2026-11-04; `--interval`, `--slow-after`, `--slow-interval`, `--idle-hours` change it). For a headless session: `--wake 'claude -p "$(cat "$1")" --resume "$(cat .agent-team/session-id)"'`. With no `--wake` it prints the summary, which is enough for a session that runs it itself at the start of each step. A session that is woken when its own background command ends (Cowork) uses `--exit-on-input --max-minutes 110`; see the script's header for the exit codes.

## The design agent outside Claude Code

The design role has run in a Claude Design session: a Cowork session with Anthropic's open-source Design plugin (seven task skills and nine optional connectors, [anthropics/knowledge-work-plugins](https://github.com/anthropics/knowledge-work-plugins)). That plugin is a toolbox, not a role; the role is `SKILL.md` (shared by both roles) plus `reference/design-role.md` (design's own loop). `templates/design-session-prompt.md` is the first message that installs both in such a session.

If the design role runs in a Claude Design or Cowork session that cannot load the plugin, start it with `templates/design-session-prompt.md`, which lists the files to paste (the shared skill, the design role, the message and changelog formats, the critic's brief) and the watcher script, and says how such a session runs the watcher and keeps its state across condensing (`design-role.md`, "In a Cowork session").

## Changing the process

The plugin holds principles and the mechanics of the process. Facts bound to a tool version (which app shows a simulator, a flag's name, a path inside Xcode) go in the project's `CLAUDE.md` with the version written next to them, and the agent that finds one wrong updates it there. The plugin carries at most a dated example of such a fact, to show what a principle means, never a table of versions.

Edit the skill on a branch and open a PR; whoever merges it bumps `version` in `.claude-plugin/plugin.json` in the merge, then pushes. Every machine picks it up with `claude plugin update agent-team`. Rules that come from incidents go in the "Rules that came from incidents" section of `SKILL.md` with the incident, so the next project knows why.
