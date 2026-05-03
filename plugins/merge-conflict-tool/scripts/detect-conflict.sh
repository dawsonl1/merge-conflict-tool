#!/bin/bash
# PostToolUse hook on Bash: detect merge-conflict signals in tool output and
# remind Claude to invoke the merge-conflict-tool skill.
# Quiet on the happy path — only emits JSON when a signal matches.

set -u

data=$(cat 2>/dev/null || echo '{}')
combined=$(echo "$data" | jq -r '(.tool_response.stdout // "") + "\n" + (.tool_response.stderr // "")' 2>/dev/null)

if echo "$combined" | grep -qE 'CONFLICT \(|Automatic merge failed|error: could not apply|Merge conflict in|fix conflicts and run'; then
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Git reports a merge/rebase/cherry-pick conflict in the tool output. You MUST invoke the merge-conflict-tool skill before resolving any conflicts. Do not proceed with git checkout --ours/--theirs, manual marker editing, or any other resolution path until the skill is loaded."}}
EOF
fi
exit 0
