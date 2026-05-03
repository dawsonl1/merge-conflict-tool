#!/bin/bash
# SessionStart hook: detect a halted git operation (merge/rebase/cherry-pick)
# in the session's working directory and remind Claude to invoke the
# merge-conflict-tool skill before doing other git work.
# Quiet on the happy path — only emits JSON when a halted state is detected.

set -u

data=$(cat 2>/dev/null || echo '{}')
cwd=$(echo "$data" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"

if [ -f "$cwd/.git/MERGE_HEAD" ] \
   || [ -d "$cwd/.git/rebase-merge" ] \
   || [ -d "$cwd/.git/rebase-apply" ] \
   || [ -f "$cwd/.git/CHERRY_PICK_HEAD" ]; then
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"This working directory has a halted git operation in progress (merge / rebase / cherry-pick). Invoke the merge-conflict-tool skill before doing any other git work — it provides scope-tiered, bias-mitigated conflict resolution with paired defender subagents and mandatory visual verification for frontend changes."}}
EOF
fi
exit 0
