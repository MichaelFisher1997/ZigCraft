#!/usr/bin/env bash

set -euo pipefail

source scripts/github_actions_common.sh

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
pr_number="${PR_NUMBER:?PR_NUMBER is required}"

echo "Fetching previous automated reviews..."

gh api "/repos/${repo}/pulls/${pr_number}/reviews" \
    --jq '.[] | select(.user.login == "opencode-agent[bot]") | {body: .body, submitted_at: .submitted_at}' > /tmp/opencode_reviews.json 2>/dev/null || echo "[]" > /tmp/opencode_reviews.json

gh api "/repos/${repo}/pulls/${pr_number}/comments" \
    --jq '.[] | select(.user.login == "opencode-agent[bot]") | {body: .body, path: .path, line: .line, created_at: .created_at}' > /tmp/opencode_comments.json 2>/dev/null || echo "[]" > /tmp/opencode_comments.json

review_content=$'## Previous Automated Reviews from opencode-agent:\n\n'

if [[ -s /tmp/opencode_reviews.json && "$(cat /tmp/opencode_reviews.json)" != "[]" ]]; then
    while IFS= read -r review; do
        if [[ -n "$review" && "$review" != "null" ]]; then
            body="$(printf '%s' "$review" | jq -r '.body // empty')"
            date="$(printf '%s' "$review" | jq -r '.submitted_at // empty')"
            if [[ -n "$body" && "$body" != "null" ]]; then
                review_content+="### Review from ${date}"$'\n'
                review_content+="${body}"$'\n\n---\n\n'
            fi
        fi
    done < /tmp/opencode_reviews.json
else
    review_content+=$'No previous automated reviews found.\n'
fi

write_multiline_env PREVIOUS_REVIEWS "$review_content"
echo "Previous reviews fetched and formatted for context"
