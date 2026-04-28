#!/usr/bin/env bash

set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
pr_number="${PR_NUMBER:?PR_NUMBER is required}"
head_sha="${HEAD_SHA:?HEAD_SHA is required}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"

parse_json="$(bash scripts/evaluate_ai_merge_gate.sh "$repo" "$pr_number" "$head_sha")"
state="$(printf '%s' "$parse_json" | jq -r '.state')"
description="$(printf '%s' "$parse_json" | jq -r '.description')"

gh api "repos/${repo}/statuses/${head_sha}" \
    -f state="$state" \
    -f context=ai-merge-gate \
    -f description="$description" \
    -f target_url="${server_url}/${repo}/pull/${pr_number}"

if [[ "$state" == "success" ]]; then
    closing_refs="$(gh pr view "$pr_number" \
        --json closingIssuesReferences \
        --jq '[.closingIssuesReferences[].number] | map("Closes #" + tostring) | join("\n")')"

    if [[ -n "$closing_refs" ]]; then
        gh pr merge "$pr_number" --auto --squash --body "$closing_refs" || true
    else
        gh pr merge "$pr_number" --auto --squash || true
    fi
fi
