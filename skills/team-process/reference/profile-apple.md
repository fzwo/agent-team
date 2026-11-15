# Profile: apple (iOS, macOS, or both in one repo)

Project-specific values (simulator model, board size, device names, languages, text sizes) live in the repo's CLAUDE.md under `Profile: apple`, not here.

## Observing the build

- Screenshots come from one fixed simulator at the boards' size, declared in CLAUDE.md (for example iPhone 16e, 390 × 844 pt), in the same states as the boards, light and dark, plus the variants CLAUDE.md lists (languages, largest text size) where a board exists for them.
- Screenshots come from a device only for system UI and motion.
- Files go to `design/built/<date>/`, named like the matching board (`home-light.png`, `home-dark.png`, `settings-de-light.png`, `home-large-text-light.png`). A clip of anything that moves goes next to them.
- The "Built" report lists which screenshots changed since the last round; design looks only at those.
- A macOS app: screenshots of each window at the board size from CLAUDE.md, same naming, from a clean desktop. The macOS window takes the `ui` lock while it is on screen.
- Both platforms in one repo: one `design/built/<date>/ios/` and `.../macos/` folder; boards are likewise per platform or shared, as DESIGN.md says.

## Locks

| Resource | Taken for |
|---|---|
| `sim:<name>` | Booting, installing on, launching in, screenshotting, or recording a simulator, and `xcodebuild test` runs on a simulator-family destination, which boot one. One simulator at a time per session; shut it down when done |
| `device:<udid>` | Anything on a physical device: install, launch, logs, screenshots, and `xcodebuild test` runs with a device destination (which take `sim` as well, since the rule cannot tell the two platforms apart after the quote cut) |
| `ui` | Anything that takes the screen or keyboard focus from the owner: screen recording, driving the simulator window or a macOS app window, `osascript`, the Accessibility Inspector. A headless `xcodebuild test` on a simulator does not; it takes `sim`. A macOS test run (`platform=macOS`) drives a window and takes `ui` alone |
| `quiet` | A measurement that needs the machine to itself: performance, memory, battery, timing, background-task behaviour. Waits for every other lock, then blocks everyone else's heavy work until released, the holder's sibling builders included; the holder runs the measured commands as `AGENTLOCK_AS=<name> agentlock with quiet -- <command>` |

The hook config (`guard.conf`) maps `simctl`, `devicectl`, `screencapture`, `xcodebuild test` and the like to these. Take the lock with a reason and a TTL that covers the whole step. Shut the simulator down and release before the report.

## Devices

- Back up the app's database (or container) before each install on the device; keep the backup until the piece of work merges.
- Launch muted. Never touch or dismiss system dialogs; stop and ask instead.
- Do not attach a debugger (`lldb`) to the device build; use logs.
- Measurements of background behaviour (background tasks, battery, memory of the speech model) are per project and belong in CLAUDE.md with their method.

## Builds and disk

- One derived-data folder per target, reused across branches (`-derivedDataPath` fixed per target in the build script), never one per branch.
- Keep at least 20 GB free; Xcode needs headroom. Check at shift start and before a build; clean up by exact name, never by pattern.
- Anything the project keeps per worktree outside the worktree (build folders under `$TMPDIR`, caches named for the checkout's path) is removed by the project's `.agent-team/hooks/worktree-removed` hook, which `pr-cleanup.sh` runs with the worktree's path before removing it. The hook computes exact names from the path and never globs, so it cannot touch another session's live folders. A project that caches per checkout must have this hook, or the caches outlive their worktrees.
- **Instruments and traces.** No Instruments capture with less than 40 GB free on the Mac. On a device, Time Profiler alone with a time limit, never all processes with os_log or os_signpost: raw trace data ran at about 2 GB per 10 seconds and filled the phone.
- **The simulator's window is tool-version bound; `simctl` is not.** `simctl` (boot, launch, `io screenshot`, `recordVideo`) needs no app open and is what screenshots and clips use. Which app shows a simulator window, how it is opened, and where the screen sits in it change between Xcode versions, so those facts live in the project's CLAUDE.md with the Xcode version next to them, and a shift that finds them wrong updates them there, not here. Open the app from inside the selected Xcode (`xcode-select -p`), never by a bare name that an older install beside it may answer. Anything that depends on window geometry (`cliclick` positions, drag coordinates) is re-measured after an Xcode update. Before deleting an old Xcode, check that no running process lives inside it. Dated example, Xcode 27.2 (2026-11-03): there is no Simulator.app; DeviceHub (`com.apple.dt.Devices`) shows the device's screen beside a sidebar, after the device is selected there.
- Builder subagents build in their own worktree but share the target's derived-data folder; serialize builds of the same target with `agentlock acquire build:<target>`.

## Verification

- Verify by observation: the screen, the state read back, the log line. A test that passes is not evidence that the behaviour is right; a screenshot or a read-back is.
- Anything racy (concurrency, background transitions, audio sessions) runs five to ten times.
- A negative result ("the dialog does not appear") needs a control in the same run that shows the dialog can appear.

## High-risk tier

Data and migrations, speech or audio session handling, background tasks, anything that touches the user's recordings or the on-device model's memory, StoreKit.
