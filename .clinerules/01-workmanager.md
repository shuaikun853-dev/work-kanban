# WorkManager mandatory project rules

These rules apply to every Cline task in this repository.

Read and obey `AGENTS.md`,
`docs/development/DEVELOPMENT_PHILOSOPHY.md` and
`docs/development/DEVELOPMENT_PLAN.md` (the V1 M0–M6 stage, task IDs and
dependencies) before starting. WorkManager is a personal-use Windows
application, not a commercial product. Do not complicate simple personal-software tasks;
build only the smallest complete solution for confirmed needs, without unnecessary
code, abstractions, workflows, or tests. Preserve necessary data integrity, security,
error handling, and explicitly requested behavior.

For every code task, actually read and follow:
- Ponytail: https://github.com/DietrichGebert/ponytail/blob/main/skills/ponytail/SKILL.md
- Matt Pocock Implement: https://github.com/mattpocock/skills/blob/main/skills/engineering/implement/SKILL.md

Do not add speculative features, abstractions, dependencies, frameworks, or
tests for hypothetical cases. Never sacrifice data integrity, security,
trust-boundary validation, necessary error handling, or requested behavior.
Report any skill that could not be loaded.

Never merge any pull request yourself. PR #8 stays OPEN until independent
audit, user acceptance, and verified GitHub Support server-side history cleanup
(P2-01) are all complete; do not bypass that gate with cherry-picks, replacement
PRs, force-pushes, or stacked branches.
