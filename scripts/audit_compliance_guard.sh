#!/usr/bin/env bash

set -euo pipefail

echo "=== Checking for audit compliance violations ==="

bot_login="github-actions[bot]"
violations=0
cutoff="$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
new_prs=$(gh pr list --author "$bot_login" --state open --limit 20 \
    --json number,title,headRefName,createdAt,body \
    --jq '.[] | select(.createdAt >= "'"$cutoff"'") | select(.title | startswith("[Audit]"))')

if [[ -n "$new_prs" ]]; then
    echo "::error::Compliance violation detected: agent created pull request(s) instead of issue(s)"
    while IFS= read -r pr_num; do
        pr_num="${pr_num//\"/}"
        [[ -n "$pr_num" ]] || continue
        printf '  Closing rogue PR #%s\n' "$pr_num"

        pr_body="$(gh pr view "$pr_num" --json body --jq '.body')"
        pr_title="$(gh pr view "$pr_num" --json title --jq '.title')"

        issue_title="[Audit] ${pr_title}"
        issue_body=$(cat <<ISSUE_EOF
## Auto-converted from rogue PR #$pr_num

The audit agent incorrectly created a pull request instead of a GitHub issue.
The finding has been automatically converted below.

---

$pr_body
ISSUE_EOF
)

        echo "  Creating issue from PR content..."
        gh issue create \
            --label automated-audit \
            --title "$issue_title" \
            --body "$issue_body" || echo "  Failed to create issue from PR"

        gh pr close "$pr_num" --comment "Auto-closed by compliance guard: audit workflow must create issues, not PRs." --delete-branch
        violations=$((violations + 1))
    done < <(printf '%s\n' "$new_prs" | jq -c '.number')
fi

bot_branches=$(gh api "repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}/branches" \
    --jq '.[] | select(.name | startswith("opencode/")) | .name' 2>/dev/null || echo "")

if [[ -n "$bot_branches" ]]; then
    echo "::warning::Found opencode/ branches that may be audit violations:"
    while IFS= read -r branch; do
        [[ -n "$branch" ]] || continue
        printf '  Branch: %s\n' "$branch"
    done <<< "$bot_branches"
fi

if [[ "$violations" -gt 0 ]]; then
    printf '::error::Compliance guard corrected %d violation(s). PR(s) closed and converted to issue(s).\n' "$violations"
else
    echo "No compliance violations detected."
fi
