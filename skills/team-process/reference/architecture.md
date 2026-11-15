# Architecture without an architect (interim rule)

Parked for a fuller discussion. Until then:

## What still matters when change is cheap

- **Duplicated logic drifts.** A bug fixed in one copy stays in the others, because whoever fixes it does not know they exist. One place per rule. When you find a second copy, merge them in the same PR if it is cheap, or file an `idea` issue naming both; never fix one copy silently.
- **Unclear ownership of state** produces the concurrency bugs review rounds keep finding. Every piece of mutable state has one owner, named in `ARCHITECTURE.md`.
- **Missing boundaries make every change touch everything.** Each change then needs more context to make safely, and context is what the owner pays for. Modules with a stated interface keep changes local.
- **Tests coupled to implementation** block refactors the agent would otherwise do for free.

## What matters less

Speculative abstractions for future needs, strict layering for its own sake, and saving typing. If a thing is used once, it can be plain.

## The rule

- Engineering keeps `ARCHITECTURE.md`: the module map (what each module does and depends on), where each kind of state lives and who may change it, the invariants that must hold, and the two or three decisions a newcomer would otherwise get wrong. One page; update it in the PR that changes the structure.
- The reviewer brief asks: does this change fit `ARCHITECTURE.md`? If not, is the change wrong or is the document? Either answer is a finding.
- Every thirty merged PRs, or monthly, a structure review (its PR number and date are kept in `.agent-team/state.md`, "Review audits"): a fresh subagent reads for duplication, boundary leaks, dead code and state with unclear ownership, and files `idea` issues. The engineering agent takes the cheap ones as low-tier PRs.
