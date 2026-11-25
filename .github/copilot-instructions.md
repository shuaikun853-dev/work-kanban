# WorkManager — GitHub Copilot instructions

These instructions apply to all work in this repository.

Before every task, read and follow the repository root `AGENTS.md`,
`docs/development/DEVELOPMENT_PHILOSOPHY.md` and
`docs/development/DEVELOPMENT_PLAN.md`. The plan defines the current V1
M0–M6 stage, task IDs, dependencies and delivery order. The project is a
personal-use Windows application, not a commercial SaaS product. Implement only
the user's confirmed requirements using the smallest complete solution.

Never merge any pull request. PR #8 is blocked by the P2-01 merge gate: it must
stay OPEN until independent audit, user acceptance, and verified GitHub Support
server-side history cleanup are all complete. Do not bypass that gate with
cherry-picks, replacement PRs, force-pushes, or stacked branches.

For every code task, actually load and follow both:
- Ponytail: https://github.com/DietrichGebert/ponytail/blob/main/skills/ponytail/SKILL.md
- Matt Pocock Implement: https://github.com/mattpocock/skills/blob/main/skills/engineering/implement/SKILL.md

Use task-specific Matt Pocock skills only when relevant. Do not add speculative
features, abstractions, dependencies, frameworks, or exhaustive tests. Never
cut data integrity, security, trust-boundary validation, necessary error
handling, or user-requested behavior. If upstream skills cannot be read, say so.
