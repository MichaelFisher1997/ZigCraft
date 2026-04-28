#!/usr/bin/env bash

set -euo pipefail

max_retries="${MAX_RETRIES:-8}"
head_sha="$(git rev-parse HEAD)"
pr_num=""

for i in $(seq 1 "$max_retries"); do
    sleep $((i * 3))
    printf 'Attempt %s/%s: searching for PR for commit %s...\n' "$i" "$max_retries" "$head_sha"
    pr_num=$(gh api \
        "repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}/commits/${head_sha}/pulls" \
        --jq '[.[] | select(.state == "open")] | .[0].number // empty' 2>/dev/null || true)
    if [[ -n "$pr_num" ]]; then
        break
    fi
done

if [[ -n "$pr_num" ]]; then
    printf 'Found newly created PR #%s for commit %s\n' "$pr_num" "$head_sha"
    label_error="$(mktemp)"
    if ! gh pr edit "$pr_num" --add-label automated-test 2>"$label_error"; then
        printf '::warning::Failed to add automated-test label to PR #%s: %s\n' "$pr_num" "$(tr '\n' ' ' < "$label_error")"
    fi
    rm -f "$label_error"
else
    printf '::warning::No open PR found for commit %s after %s attempts\n' "$head_sha" "$max_retries"
fi
