# merge-conflict-tool

A [Claude Code](https://claude.com/claude-code) plugin that resolves git merge conflicts without silently dropping one side's work.

The naive failure mode in conflict resolution is to favor "ours" because it's the side you've been working on, and silently drop "theirs" to make the markers go away. That's fast and almost always wrong — both sides represent real engineering work; picking one means deleting the other's contribution, often without realizing it.

This plugin auto-invokes whenever git reports a `CONFLICT`, then spawns **paired defender subagents per conflict cluster** — one defending each side, neither seeing the other's analysis — so each side's intent is articulated independently before the parent synthesizes a resolution. The structural separation prevents the natural anchoring bias toward the branch you've been working on.

## Install

```bash
/plugin marketplace add dawsonl1/merge-conflict-tool
/plugin install merge-conflict-tool@dawson-plugins
```

That's it. Hooks auto-activate on install — no `settings.json` changes required. The next time `git merge` (or `rebase`, `cherry-pick`) reports `CONFLICT`, the skill fires automatically.

## What it actually does

When you hit a conflict, Claude will:

1. **Inventory & tier the merge** — assess scope (file count, divergence depth, integration overlap with subsystems main touched). Halt on Tier 3 (>25 files, >3mo divergence, severely asymmetric) and recommend alternatives instead of grinding through.
2. **Cluster related conflicts** — files in the same module / feature / import-graph are usually one semantic conflict expressed across files. Each cluster gets ONE defender pair, preserving cross-file reasoning.
3. **Spawn paired defender subagents** — one per side, in parallel, structurally isolated. Each articulates what their side accomplishes, what would be lost if dropped, and what they did NOT verify.
4. **Synthesize, don't pick** — categorize each hunk as overlap / complement / genuine conflict. Halt on incompatible designs; preserve both intents otherwise.
5. **Verify** — targeted tests on touched code, mandatory frontend build + visual verification (via Playwright MCP) for any UI changes. Pre-existing branch debt is distinguished from merge-induced failures via a reactive baseline check.
6. **Continue** — with a backup-branch push pattern for large merges, so reviewers can inspect the merge state independently before it lands.

## What it deliberately won't do

These trigger a halt-and-ask, not a heuristic guess:

- **Tier 3 merges** (>25 files, >3mo divergence, severely asymmetric)
- **Modify/delete (`UD`/`DU`) conflicts** — always a deliberate human call
- **Squashed migrations** (`replaces = [...]`)
- **Data migrations in conflict** (`RunPython` / `RunSQL`)
- **Genuine incompatible-design conflicts** (different signatures, different data flows)
- Anything in **auth/authz, crypto, secrets, billing, deployment manifests**

The plugin is opinionated about when to defer to a human. That's the point.

## Why this exists

Built during a real 102-commit merge in a Django + React monorepo. Each section was patched based on what actually happened during resolution:

- **Defender-pair pattern** caught a CSRF resolution where the naive read would have favored "ours" without articulating what each side intended.
- **Pre-existing debt disambiguation** added after 33 pre-existing test failures looked like merge breakage until we sampled them against pre-merge HEAD and found they were branch debt unrelated to the merge.
- **Integration-overlap modifier** added after observing that textual conflict count (1) wildly underestimated risk when 13 of our touched files lived in the same subsystem main reshaped.
- **Orienting summaries** added after defender-pair latency on a 7K-line file with a 123 KB diff log was painful; commit-subject synopsis + per-commit stat summary lets the defender skip the linear scan.

The bias-prevention defender-pair pattern (Step 4 in the skill) is the load-bearing piece. Everything else is calibration.

## Customize

The skill is stack-agnostic out of the box — Step 7 in [`SKILL.md`](plugins/merge-conflict-tool/skills/merge-conflict-tool/SKILL.md) covers conflict patterns by category (lockfiles, dependency manifests, generated artifacts, migrations, config/build files, routing tables, UI files) with examples drawn from many ecosystems. The few heuristics worth tuning for your team are tier thresholds, the risky-surface list, and the verification command specifics in Step 8.

## Layout

This repo is both a single-plugin marketplace and the plugin itself.

```text
.
├── .claude-plugin/
│   └── marketplace.json          # marketplace manifest
└── plugins/
    └── merge-conflict-tool/
        ├── .claude-plugin/
        │   └── plugin.json       # plugin manifest
        ├── hooks/
        │   └── hooks.json        # auto-invoke hooks
        ├── scripts/              # detection scripts (chmod +x)
        ├── skills/
        │   └── merge-conflict-tool/
        │       └── SKILL.md      # the actual workflow
        └── README.md
```

## License

MIT
