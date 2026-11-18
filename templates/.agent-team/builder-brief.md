# Standing brief for builders   <!-- read by every builder before its task; the per-task brief carries only the task -->

Lock names: `sim:<device>` for a simulator, `device:<udid>`, `ui` for the screen, `port:<n>`, `db:<name>`. A test run on a physical device takes `device` and `sim` (the guard cannot tell the platforms apart), so it waits on any simulator lock. Prefix every lock command with the `AGENTLOCK_AS=<your name>` your brief gives. Wait with `--wait` (an hour) or `--wait 20m`; in a script, `agentlock acquire … && <command>`, never `;`. The guard extends a held lock on every guarded command; between long unguarded steps, `agentlock renew <resource>`. `agentlock status` guards nothing (it exits 0); wait with `agentlock wait quiet 30m` or ask `agentlock free <resource>`. A `quiet` measurement blocks every builder's builds and tests; the measurer runs each of its own under `AGENTLOCK_AS=<name> agentlock with quiet -- <command>` (a pipe after the command is covered; a `&&` or `;` is not), and each such run extends the quiet lock; do not count on the guard for that, give it a TTL that covers the measurement.
Disk floor: <20 GB on an Apple machine, 10 GB otherwise>; stop and say so before a build would break it.
Build folders: <where builds go, which are shared, what to never delete>
Attribution: <the commit trailer and PR footer the project uses>
Screenshots and recordings: <the content rule: what may appear in an image, which fixtures to use; from CLAUDE.md>
Simulator recipe: <device, appearance, text size, status bar; the commands>
Toolchain skills: <which of the skills in ~/.claude/skills to read for SwiftUI, App Intents, Instruments work; from CLAUDE.md's line>
Anything else every builder here needs: <one line each>
