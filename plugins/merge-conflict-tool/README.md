# merge-conflict-tool

A Claude Code plugin for careful git merge conflict resolution. Auto-invokes when git reports a `CONFLICT`. Spawns paired defender subagents per cluster of conflicts so each side's intent is articulated before synthesis — preventing the "favor ours, drop theirs" failure mode.

## Install

```bash
/plugin marketplace add dawsonl1/merge-conflict-tool
/plugin install merge-conflict-tool@dawson-plugins
```

Hooks auto-activate on install. No `settings.json` changes required.

## What it does

When you run `git merge` (or `rebase`, `cherry-pick`) and hit a conflict, Claude will:

1. **Inventory & tier** — assess scope (file count, divergence depth, integration overlap with subsystems main touched). Halt on Tier 3 (huge merges) and recommend alternatives.
2. **Cluster** — group related conflicted files (directory proximity, import graph, shared commits).
3. **Spawn paired defender subagents** — one per side, in parallel, neither seeing the other's analysis. Each defender articulates what their side accomplishes and what would be lost if dropped.
4. **Synthesize** — overlap, complement, or genuine conflict. Halt on incompatible designs; preserve both intents otherwise.
5. **Verify** — targeted tests on touched code, frontend build, mandatory visual verification for UI changes. Pre-existing debt is distinguished from merge-induced failures via a reactive baseline check.
6. **Continue** — with a backup branch push pattern for large merges.

## What's NOT covered (will halt and ask)

- **Tier 3 merges** (>25 files, >3mo divergence, severely asymmetric)
- **Modify/delete (`UD`/`DU`) conflicts**
- **Squashed / collapsed migrations** (e.g. Django's `replaces = [...]`, Alembic merge revisions)
- **Data migrations in conflict** (any migration that runs code or SQL against existing rows)
- **Genuine incompatible-design conflicts**

For these, the skill surfaces what it found and asks for direction. Don't apply the workflow blindly to scenarios it wasn't tuned for.

## Customize

The skill is stack-agnostic — Step 7 in `skills/merge-conflict-tool/SKILL.md` covers conflict patterns by category (lockfiles, dependency manifests, generated artifacts, migrations, config/build files, routing tables, UI files) with examples drawn from many ecosystems. The bias-prevention defender-pair pattern (Step 4) is fully language-agnostic. Tier thresholds and the risky-surface list are heuristics worth tuning for your team.
