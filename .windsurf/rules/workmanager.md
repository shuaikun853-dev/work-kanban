---
trigger: always_on
---

# WorkManager mandatory project rules

Before every task, read and follow the repository root `AGENTS.md`,
`docs/development/DEVELOPMENT_PHILOSOPHY.md` and
`docs/development/DEVELOPMENT_PLAN.md` (the V1 M0–M6 stage, task IDs and
dependencies).

WorkManager is a personal-use Windows application. Implement only confirmed
user requirements with the smallest complete solution. For every code task,
load and follow Ponytail
(https://github.com/DietrichGebert/ponytail/blob/main/skills/ponytail/SKILL.md)
and Matt Pocock Implement
(https://github.com/mattpocock/skills/blob/main/skills/engineering/implement/SKILL.md).
Do not over-engineer or add speculative features. Do not cut data integrity,
security, trust-boundary validation, necessary error handling, or requested
behavior. If upstream skills cannot be read, report that fact.

Never merge any pull request yourself. PR #8 stays OPEN until independent
audit, user acceptance, and verified GitHub Support server-side history cleanup
(P2-01) are all complete; do not bypass that gate with cherry-picks, replacement
PRs, force-pushes, or stacked branches.
