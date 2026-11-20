# Profile: web (SaaS, sites, services)

Project-specific values (viewports, dev ports, database names, deploy commands, the staging URL) live in the repo's CLAUDE.md under `Profile: web`, not here.

## Observing the build

- Screenshots come from Playwright against the local dev server, at the viewports declared in CLAUDE.md (for example 390 × 844 and 1280 × 800), in the same states as the boards, light and dark where the product has both. Files go to `design/built/<date>/`, named like the boards with the viewport in the name (`home-390-light.png`).
- Design can run the app here. If the design session has a shell, it may take its own screenshots the same way instead of waiting for engineering; it still files findings as review rounds.
- A preview deploy per PR, where the host offers one, is linked in the PR; it is evidence for the reviewer and for design.

## Locks

| Resource | Taken for |
|---|---|
| `port:<n>` | Running a dev server or a test server on a fixed port |
| `db:<name>` | Migrations, seeds, resets or destructive tests against a shared development database |
| `staging` | Deploying to or running tests against the shared staging environment |
| `ui` | Only when a headed browser or screen recording is used on a shared Mac |

Prefer a per-worktree port and a per-worktree database (a schema or a database named after the branch) over the shared one, so builder subagents do not contend at all.

## Disk

Keep at least 10 GB free; check at shift start. Build output, container images and caches that belong to a worktree are removed by the project's `worktree-removed` hook, by exact name.

## Data and secrets

- Never run a migration against a shared or production database without the lock and a backup, and never as part of a review round.
- Secrets never appear in issues, PRs, changelog entries or screenshots. If one leaks, rotate it and say so in the report.
- Test data is synthetic. No production data in development, in screenshots or in subagent briefs.

## Where engineering runs

By default on the agent Mac, like every other project: the hosts, locks, watcher and per-folder memory are built and tested there, and a shift can run all night. Production is Linux, so the distance is closed the way human Mac developers close it: the app and its tests run inside a Linux container on the Mac (a light Docker runtime), the reviewer observes them there, and a green Linux CI run on GitHub is a condition for merging. Deploys run from GitHub Actions with the secrets kept there, never from the Mac. Install the stack's tools on the Mac under the usual rules.

A cloud session is the fallback (the Mac is busy, or ad hoc work). It cannot reach the Mac; the lock then applies only to what the session itself shares (its container's ports and databases are its own) and to shared services (`staging`).

## Verification

- Verify by observation: the rendered page, the HTTP response read back, the row in the database, the log line. A green test is not evidence on its own.
- Anything racy (queues, retries, concurrent requests) runs five to ten times.
- A negative result needs a control that shows the positive case in the same run.
- Every test and build command in a builder brief runs without prompts (`--noinput` for Django's test runner, the equivalent for others), so a prompt fails fast instead of waiting for an answer nobody gives: a test run once sat ten minutes on "delete the test database?" behind another builder's run.

## High-risk tier

Migrations, authentication and sessions, billing and anything that moves money, email sending, anything touching production data, the deploy pipeline itself, dependency upgrades of the framework.
