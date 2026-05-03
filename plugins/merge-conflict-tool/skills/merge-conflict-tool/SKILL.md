---
name: merge-conflict-tool
description: Carefully resolve git merge, rebase, or cherry-pick conflicts. Tiers the merge by scope, clusters related conflicts, then uses paired defender subagents per cluster to evaluate both sides without bias toward "ours." Frontend conflicts always receive extra care including mandatory visual verification. Triggers when git reports CONFLICT, when you land in a halted merge/rebase/cherry-pick state, or when the user asks to "fix conflicts" / "resolve merge conflicts" / "finish this merge".
---

# merge-conflict-tool

Resolve git conflicts with a scalpel, not an axe — preserve both sides' intent, scale caution with scope, treat frontend changes with extra care.

## Why this skill exists

The naive failure mode is to favor "ours" because it's the side you've been working on, and silently drop "theirs" to make the markers go away. That's fast and almost always wrong. Both sides represent real engineering work; picking one means deleting the other's contribution, often without realizing it.

Mechanism:
1. **Inventory and tier before resolving.** Know scope and divergence depth before touching anything.
2. **Cluster related conflicts.** Files in the same module/feature/import-graph are usually one semantic conflict expressed across files.
3. **Argue both sides independently.** Spawn paired subagents — one defending each side — without seeing each other's analysis. This is the structural mechanism that prevents bias toward the current branch.
4. **Synthesize, don't pick.** Default resolution preserves both intents.
5. **Verify with tests, not just markers.** Frontend changes need visual verification — typecheck pass ≠ UI works.

## When to use this skill

Auto-invoke when:
- A `git merge`, `git rebase`, `git pull`, or `git cherry-pick` reports `CONFLICT` and halts.
- You enter a working directory and find `.git/MERGE_HEAD`, `.git/rebase-merge/`, `.git/rebase-apply/`, or `.git/CHERRY_PICK_HEAD` already present.
- The user asks to "fix the merge conflicts," "resolve conflicts," "finish this merge/rebase," etc.

Do NOT use this skill when the user has explicitly said to take one side ("just take theirs everywhere," "discard my changes and take main"). Honor the override; state once that you're skipping the careful-resolution mode.

## Step 0 — Detect the operation in flight

```bash
ls -d .git/MERGE_HEAD .git/CHERRY_PICK_HEAD .git/rebase-merge .git/rebase-apply 2>/dev/null
```

| Marker | Operation | Continue | Abort |
|---|---|---|---|
| `MERGE_HEAD` | merge | `git merge --continue` | `git merge --abort` |
| `rebase-merge/` or `rebase-apply/` | rebase | `git rebase --continue` | `git rebase --abort` |
| `CHERRY_PICK_HEAD` | cherry-pick | `git cherry-pick --continue` | `git cherry-pick --abort` |

**Rebase reverses ours/theirs.** During a rebase, `HEAD` is the upstream you're rebasing onto, and the commit being applied is the "incoming" side. Git's index uses `:2:` for HEAD and `:3:` for the commit being applied — opposite of the merge convention from the user's perspective. Throughout this skill the labels refer to git's index numbers (`:2:` = current tree = HEAD, `:3:` = incoming change). For merges this matches "ours/theirs"; for rebase it's flipped. Always speak to the user in terms of which *branch* each side represents, not abstract "ours/theirs."

## Step 1 — Inventory & divergence metrics

```bash
git status --porcelain
git diff --name-only --diff-filter=U
git rev-parse HEAD MERGE_HEAD CHERRY_PICK_HEAD 2>/dev/null
git log --oneline -1 HEAD
git log --oneline -1 MERGE_HEAD 2>/dev/null || git log --oneline -1 CHERRY_PICK_HEAD 2>/dev/null

MB=$(git merge-base HEAD MERGE_HEAD 2>/dev/null)
git rev-list --count HEAD ^MERGE_HEAD     # commits unique to current side
git rev-list --count MERGE_HEAD ^HEAD     # commits unique to incoming side
git log -1 --format="%ai (%ar)" "$MB"      # merge base age
git diff --name-only "$MB"...HEAD | wc -l         # files current side touched
git diff --name-only "$MB"...MERGE_HEAD | wc -l   # files incoming side touched

# Per-subsystem integration overlap
for dir in $(git diff --name-only "$MB"...MERGE_HEAD | awk -F/ '{print $1}' | sort -u); do
    ours=$(git diff --name-only "$MB"...HEAD -- "$dir" | wc -l)
    theirs=$(git diff --name-only "$MB"...MERGE_HEAD -- "$dir" | wc -l)
    echo "$dir: ours=$ours theirs=$theirs"
done
```

Group conflicts by status code:

| Code | Type | Default approach |
|---|---|---|
| `UU` | both modified | Defender pair (default for non-trivial) |
| `AA` | both added | Often migrations or generated files — see Step 7 |
| `DD` | both deleted | Confirm intent, `git rm` |
| `UD` / `DU` | modify/delete | **Stop and ask** — semantic disagreement |
| `AU` / `UA` | one added, the other treats as modified | Rare — investigate |

Note any **frontend files** in the conflict set — they get extra care regardless of size (Step 3). Frontend = `*.tsx`, `*.jsx`, `*.ts`/`*.js` under UI dirs, `*.css`/`*.scss`, `*.html`, route definitions, build/theme config, Storybook stories.

## Step 2 — Tier and cluster

### 2a. Tier the merge

| Tier | Signal | Strategy |
|---|---|---|
| **0** | ≤3 conflicts, 1 subsystem, ≤1 week base age, no frontend, no risky surfaces | Standard workflow per file; defender pair on anything not truly mechanical. |
| **1** | 4–10 conflicts, ≤2 subsystems, ≤1 month base age | Standard workflow. Cluster lightly. |
| **2** | 11–25 conflicts, OR 2+ subsystems, OR 1–3 month base age | Cluster aggressively. Worktree isolation. Stage-and-verify per cluster. |
| **3** | >25 conflicts, OR many subsystems, OR >3 months base age, OR severely asymmetric (one side 10×+ commits) | **HALT.** Surface scope to user, recommend alternatives (smaller-batch merges, rebase-to-flatten, pair-resolve with the other branch's author) BEFORE resolving anything. Only proceed with explicit user approval. |

**Risky-surface modifier** (bumps tier +1): auth/authz, crypto, secrets handling, billing, migration logic, build/CI config, deployment manifests, infrastructure-as-code.

**Integration-overlap modifier** (bumps tier +1): if any subsystem main touched has the current side touching > 5× more files than main did in that subsystem, OR > 30% of subsystem total. Captures the case where textual conflict count is low but our work depends heavily on areas main reshaped — silent breakage risk.

Print the tier and reasoning to the user. If Tier 3, halt and wait for approval.

### 2b. Cluster the conflicts

Group conflicted files by:
1. Directory proximity
2. Import graph (`grep -l "<basename>" <other-conflicted-files>`)
3. Shared commit history (`git log --oneline --name-only HEAD ^MERGE_HEAD -- <file>`)
4. Path/feature pattern

Each cluster gets ONE defender pair seeing ALL files in it — preserves cross-file reasoning. **When in doubt, merge clusters** — over-large defender pair costs slightly more reading; missed cross-file relationships cost silent breakage.

After resolving each cluster (Step 5), grep for references to its files in unresolved clusters' files; any match = missed clustering, merge and re-pair.

### 2c. Worktree isolation (Tier 2 recommended, Tier 3 mandatory)

Do the merge in a dedicated worktree rather than directly on the working branch. Workspace-level isolation lets you run full verification, dev server, and browser checks without disturbing the original — and abandon cleanly if it goes sideways. Not redundant with `git merge --abort` / `git reset --hard ORIG_HEAD` — those handle ref recovery; worktrees add filesystem isolation.

```bash
git worktree add /path/to/merge-attempt-<branch>-<date> <current-branch>
cd /path/to/merge-attempt-<branch>-<date>
```

Perform Steps 3–9 inside the merge-attempt worktree. On success: push from the worktree, then tear down. On failure: just tear down — the original branch is pristine.

Tier 0/1: skip — in-place merge with `git merge --abort` as the safety net is sufficient.

## Step 3 — Triage simple vs complex (per cluster)

### Auto-merged files: distinguish two cases

`git status` shows auto-merged files as `M` (staged-modified), distinct from `UU`. Two cases:

- **Both-sides auto-merge** — both branches modified the file but git's textual heuristic resolved without markers. **This is the silent-semantic-conflict risk class.** Defender pair to verify the auto-merge captured both intents.
- **Main-only auto-merge** — only the incoming side modified the file; current side never touched it. Read main's diff, verify your branch's calling code still resolves with main's signature changes. No defender pair needed.

Distinguish via `git diff --name-only "$MB"...HEAD -- <file>` (empty = current side untouched = main-only).

### Triage rules

- **Frontend files**: always complex (UU or both-sides auto-merge). Frontend bugs are silent — typecheck and unit tests rarely catch a missing dep array, a Tailwind class war, a dropped a11y attribute, or a context provider that lost a wrapper.
- **Risky surfaces**: always complex.
- **Truly mechanical** (skip pair, see Step 6) — only when ALL FOUR hold AND you post the justification:
  1. No frontend / risky-surface files
  2. Each conflicted hunk is purely additive on both sides (both added imports, both added a dict entry)
  3. Resolution describable in one sentence without reading commit history
  4. < 5 lines per side AND < 10 lines total in the cluster

  Justification format (post to user verbatim):
  > Skipping defender pair on cluster `<name>`: (1) no frontend/risky — `<files>`; (2) purely additive — `<description>`; (3) one-sentence resolution — `<sentence>`; (4) `<N>`/`<N>` lines, `<total>` total.

  If you can't fill all four with concrete content, dispatch the pair.

- **Everything else: complex.** Defender pair via Step 4.

## Step 4 — Dispatch defender pairs (per cluster)

Both subagents are spawned in a single message with two parallel `Agent` calls. Each receives only its own side. Neither sees the other's analysis until you (the parent) synthesize.

### 4a. Prepare inputs

```bash
# For each file in the cluster:
git show :2:<file> > /tmp/mc-current-<basename>
git show :3:<file> > /tmp/mc-incoming-<basename>
git show :1:<file> > /tmp/mc-base-<basename>
git log -p --no-merges HEAD ^MERGE_HEAD -- <file> > /tmp/mc-current-log-<basename>
git log -p --no-merges MERGE_HEAD ^HEAD -- <file> > /tmp/mc-incoming-log-<basename>

# Orienting summaries — cheap on small files, save substantial wall-clock on big ones:
git log --oneline HEAD ^MERGE_HEAD -- <file> > /tmp/mc-current-msgs-<basename>
git log --oneline MERGE_HEAD ^HEAD -- <file> > /tmp/mc-incoming-msgs-<basename>
git log --stat --no-merges HEAD ^MERGE_HEAD -- <file> > /tmp/mc-current-stat-<basename>
git log --stat --no-merges MERGE_HEAD ^HEAD -- <file> > /tmp/mc-incoming-stat-<basename>
```

### 4b. Subagent prompt — current-side defender (Agent A)

> You are analyzing one side of a git conflict cluster. The cluster contains: `<list>`. You will see only this side's content and history. Do NOT speculate about what the other side did.
>
> Your job: articulate what this side accomplishes across the cluster, and what would be lost if it were dropped wholesale.
>
> **Inputs (read in this order):**
> 1. **Commit-subject synopsis** (READ FIRST): `/tmp/mc-current-msgs-<basename>` — commit subjects often encode themes/phases. Build a mental ToC before diving in.
> 2. **Per-commit stat summary**: `/tmp/mc-current-stat-<basename>` — which line ranges and files moved most.
> 3. **This side's version of each file** (no markers): `/tmp/mc-current-<basename>` for each file in the cluster.
> 4. **Conflicted file with markers** (line-number context): the actual paths.
> 5. **Full diff log**: `/tmp/mc-current-log-<basename>`. For files where this is large (>50 KB), do NOT linearly scan — use synopsis + stat to identify relevant commits, read those selectively.
>
> [Frontend cluster] Additionally read: components that import any cluster file (`grep -rl "from.*<cluster-file>" src/`); referenced hooks/contexts; related test files.
>
> **Return a structured report with EVIDENCE for every claim** (concise — under 600 words):
>
> 1. **Intent.** What is this side trying to do? (1–3 sentences)
> 2. **Mechanism.** Cite **file:line** for each. Quote exact lines. No "around line N."
> 3. **Loss if dropped.** Name the BEHAVIOR in user/system-facing terms. Cite lines that implement it.
> 4. **Hard requirements.** Lines/expressions that MUST appear. Quote verbatim with file:line.
> 5. **Negotiable parts.** What could be reformulated/absorbed.
> 6. **External dependencies.** Show the grep command AND results (or "no results"). Format: `I ran "grep -rn '<symbol>' --include='*.py' ." and found <paths>`.
> 7. [Frontend only] **UX-affecting changes.** Visual/behavioral/a11y differences with `file:line`.
> 8. **What I did NOT verify.** Honest list. MANDATORY — empty list triggers re-spawn.
>
> Do not propose a final resolution. Do not consider the other side. Just defend this one.

### 4c. Incoming-side defender (Agent B)

Symmetric prompt with `mc-incoming-*` inputs and the symmetric framing. Spawn both in **one message** with two parallel `Agent` calls.

## Step 5 — Synthesize

Categorize every hunk:
1. **Overlap** — both sides try to do the same thing → pick the cleaner formulation; both intents preserved.
2. **Complement** — each side does something the other doesn't → both must appear.
3. **Genuine conflict** — incompatible designs (different signatures, different data flows) → **stop and ask the user.** Show both reports summarized in branch-vocabulary terms; do NOT pick.

Edits via `Edit` (not `Write`). Re-read each file after — confirm no stranded markers, no orphaned references, no half-merged structure (an `if` from one side and an `else` from the other that don't compose; a hook called conditionally; a JSX element with an opener from one side and a closer from the other).

## Step 6 — Mechanical inline

Only after the Step 3 four-slot justification was posted. Common cases: union of imports, union of dict/list entries, comment merges (take the more informative one), whitespace match.

If a "mechanical" conflict reveals hidden semantics during edit (imports shadowing each other, conflicting dict keys), promote to complex and dispatch a pair.

## Step 7 — Project-specific patterns

Detect repo type from root files; adapt the language-specific commands to your stack.

### Python / Django (`manage.py` present)

- **Migration AA on `*/migrations/0XXX_*.py`** (Scenario A — both sides created `0042_*.py` with non-overlapping models): rename incoming side's migration to come *after* the current side's; update its `dependencies = [(...)]` to point at the latest current-side migration; verify with `python manage.py makemigrations --check`.
- **Model UU + migration AA** (Scenario B — both sides edited the same model AND each generated a migration): the migrations are downstream of incompatible model states. Resolve `models.py` UU via defender pair, then `git rm` BOTH new migrations, run `makemigrations` against merged model state to produce ONE coherent migration, read manually before committing.
- **Data migration in conflict** (Scenario C — `RunPython` / `RunSQL` migration where both sides created or modified one): always defender-pair. Check whether the migration uses `apps.get_model('app', 'Model')` (historical pattern, safe under reordering) or raw `from app.models import Model` (current-state import, fragile). Run `python manage.py migrate --plan` and read it. **Halt and ask if uncertain — data migrations break behavior silently.**
- **Squashed migrations** (Scenario D — `replaces = [...]` on either side): **HALT and ask the user.** The replaces machinery doesn't autonomously merge with manually-renumbered conflicts.
- **Cross-app dependency rename** (Scenario E): after any renumbering walk every app's migrations folder (`grep -rn "<old-migration-name>" */migrations/`). Cross-app dependencies break silently — `--check` won't fail; `migrate` will.
- **`requirements.txt` / `requirements-dev.txt`**: union the package list; same package, different pins → take the higher unless one is known-broken.
- **`settings.py`**: always defender pair (settings encode intent — silent drops cause runtime errors).

### JavaScript / Node (`package.json` present)

- **Hook discipline**: when synthesizing TSX/JSX with React hooks, verify hook **call order is preserved** (rules of hooks); `useEffect`/`useMemo`/`useCallback` **dependency arrays** still match captured closures.
- **Class/style merging**: no contradictory Tailwind utilities (`flex` and `block` together); no CSS-specificity wars; theme tokens still resolve.
- **A11y preservation**: keyboard handlers (`onKeyDown`), ARIA attrs (`aria-*`, `role`), focus management (`tabIndex`, `autoFocus`, refs), alt text, semantic HTML.
- **Prop contracts**: if a component's prop signature changed, find importers (`grep -rl "from.*<Component>" src/`) and verify TypeScript catches all consumers; runtime-only contracts (default props, render-prop shapes) won't be caught.
- **Route / navigation**: if route definitions changed, manually trace each route after merge.
- **`package.json`**: union dependencies, take higher pins.
- **`package-lock.json` / `yarn.lock` / `pnpm-lock.yaml`**: do NOT hand-merge. `git checkout --theirs <lock>` and run `npm install` / `yarn install` / `pnpm install` to regenerate from merged `package.json`. (One legitimate use of `--theirs`.)
- **`tsconfig.json` / build config**: always defender pair.

### Other languages

The patterns generalize: lockfiles regenerate, build configs need defender-pair scrutiny, tests should run against the merged state. Adapt the commands to your stack.

### Generated artifacts (any repo)

Auto-generated migrations, OpenAPI specs, type stubs, GraphQL schemas: regenerate after merging the source-of-truth files. Do not hand-merge generated output.

## Step 8 — Verify (do not skip this)

For Tier 2/3 with cluster-level checkpoints, run verification per cluster before `git add`-ing that cluster's files.

### 8a. Static verification (touched files only)

- Python: `python -m py_compile <file>` per touched `.py`
- TypeScript: `tsc --noEmit -p <tsconfig>` (project-scoped, not whole monorepo)
- Linter on touched files only — never the whole repo (slow, dilutes signal)

### 8b. Targeted tests

Find tests that exercise the conflicted modules:
- Python: `grep -rl "from <module>\|import <module>" tests/`
- JS/TS: `grep -rl "from .*<module>" __tests__/ src/**/*.test.* src/**/*.spec.*`

Run those. **Do NOT run the full suite by default** — slow, dilutes signal, makes you tolerant of unrelated failures. Targeted tests fail loudly when *your* resolution is wrong.

### 8c. Migration check (if migrations were touched)

- `python manage.py makemigrations --check` — must report "no changes needed." If it reports changes, you're in Scenario B (Step 7) — regenerate, don't paper over.
- `python manage.py migrate --plan` — review forward plan for ordering surprises, especially around data migrations.

### 8d. Build (frontend changes)

`npm run build` (or your project's build script). Mandatory — typecheck alone is insufficient.

### 8e. Visual verification (frontend changes — MANDATORY)

Required for any frontend file in the merge result with (a) UU resolved on this side, OR (b) both-sides auto-merge, OR (c) main-only auto-merge of a file consumed/imported by code on this side. Skip only when main-only auto-merged frontend files have no integration with this side's frontend code.

1. Start dev server.
2. Use the Playwright MCP if available:
   - `browser_navigate` to affected routes
   - `browser_snapshot` for accessibility tree
   - `browser_take_screenshot` for visual diff
   - `browser_console_messages` for runtime errors
3. Walk **golden path** of the affected feature.
4. Walk **adjacent UI** for regressions (touched a Button component? check pages that use it).
5. Test interactions: clicks, keyboard navigation, focus rings, form submission.
6. Check console for errors and warnings.

If Playwright is unavailable, tell the user explicitly and ask them to verify in browser before continuing.

### 8f. Pre-existing debt disambiguation

If verification surfaces failures, **do not assume they are merge-induced.** Branches at scale carry pre-existing debt (failing tests using retired types, missing dev dependencies, lint warnings) that the merge surfaces because verification runs in a clean environment.

Reactive baseline check:

1. Sample 1–3 of the failing tests / lint errors / typecheck errors.
2. Re-run those samples against the **pre-merge HEAD** — if you used worktree isolation (Step 2c), the original worktree is already at the pre-merge HEAD; otherwise `git stash` your merge state.
3. Classify:
   - **Fail in both** → pre-existing debt. Document, surface to user, do NOT halt — merge is clean, branch was already broken.
   - **Pass on pre-merge, fail post-merge** → merge-induced. Halt and re-investigate (back to Step 5).

The single biggest source of friction in merge resolution is mistaking pre-existing branch debt for merge breakage. Always run the baseline check before treating verification failures as merge problems.

### Failure handling

If verification fails AND baseline confirms merge-induced: do NOT continue. Back to Step 5.

If verification fails but baseline confirms pre-existing: continue, document, surface. Don't fix pre-existing debt as part of the merge unless the user explicitly asks (out of scope, expanding scope risks more issues).

## Step 9 — Continue

```bash
git status         # confirm no UU/AA/UD/DU
git diff --check   # whitespace + stranded markers
git diff --cached  # last scan of what's about to commit

git merge --continue          # for merges
# or: git rebase --continue   # for rebases
# or: git cherry-pick --continue
```

For merges: let git open the editor for the commit message OR pre-write with `-m` summarizing what was reconciled. Don't `--no-edit` blindly — the default merge message rarely captures what was reconciled.

For rebases / cherry-picks: original commit messages are reused.

After: `git log --oneline -5` and tell the user what landed plus a one-line summary per cluster.

### Push pattern

For Tier 0/1: push directly to feature branch — `git push origin HEAD:<feature-branch>`.

For Tier 2/3 OR if verification surfaced any pre-existing debt or noise: push to a NEW backup branch FIRST, then fast-forward the feature branch:

```bash
git push -u origin HEAD:merge-attempt-<branch>-<YYYYMMDD>
git push origin HEAD:<feature-branch>
```

The backup branch lets reviewers inspect the merge state independently before it lands on the production-track branch — and gives a clean rollback point if the merge needs to be reverted later.

## Stop-and-ask conditions

Halt and confirm before proceeding when:
- **Tier 3 merge** (Step 2a): always halt before resolving anything; recommend alternatives.
- Any **`UD` / `DU`** (modify/delete) conflict — always a deliberate human call.
- Subagent reports show **incompatible designs** (Step 5, category 3).
- Any conflict in: auth/authz, crypto, secrets, billing, migration logic, build/CI config, deployment manifests.
- **Squashed migrations** or genuinely-uncertain **data migrations** (Step 7 Scenarios C/D).
- Verification fails 3+ times for the same cluster AFTER baseline check rules out pre-existing debt.
- Visual verification reveals a regression you can't trace to a specific resolution.
- Tier 2/3: check in with user every 2–3 clusters resolved.

## Anti-patterns — never do these silently

- **`git checkout --ours/--theirs`** on content conflicts — silently discards the other side's work. (Lockfiles excepted.)
- **Deleting conflict markers without re-reading** surrounding code — markers aren't the conflict, semantics are.
- **Treating frontend conflicts as "simple"** because line count is low — frontend bugs are silent.
- **Skipping visual verification** because typecheck passed — typecheck doesn't catch broken layouts, dropped a11y, lost focus.
- **`git merge --abort`** as a panic button — only after surfacing state and confirming with user.
- **Picking a side because diff is "cleaner"** — cleanness ≠ correctness; messy side often does more.
- **Skipping the defender pair on a complex conflict** to save time — this skill exists specifically to prevent this.
- **Analyzing clustered files independently** when they belong to one feature — cross-file semantics get lost.
- **Adjusting a failing test to make merge pass** — the test is reflecting incorrectness; fix the merge, not the test.
- **Renumbering migrations when models also conflict** — Scenario B; regenerate from merged model state.
- **Treating verification failures as merge-induced without a baseline check** — wastes time on pre-existing debt.
