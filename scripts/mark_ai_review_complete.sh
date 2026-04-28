#!/usr/bin/env bash

set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
pr_number="${PR_NUMBER:?PR_NUMBER is required}"
head_sha="${HEAD_SHA:?HEAD_SHA is required}"
outcome="${AI_REVIEW_OUTCOME:?AI_REVIEW_OUTCOME is required}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
short_sha="${head_sha:0:7}"
state="success"

if [[ "$outcome" != "success" ]]; then
    state="failure"
fi

gh api "repos/${repo}/statuses/${head_sha}" \
    -f state="$state" \
    -f context=ai-review \
    -f description="AI review ${state} for ${short_sha}" \
    -f target_url="${server_url}/${repo}/pull/${pr_number}"
