#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BRANCH="dev"
STALE_DAYS=7

deleted=()
skipped=()

if ! command -v gh &>/dev/null; then
    echo "error: gh CLI is required" >&2
    exit 1
fi

stale_ts=$(date -d "-${STALE_DAYS} days" --iso-8601=seconds 2>/dev/null || date -v-${STALE_DAYS}d --iso-8601=seconds)

branches=$(gh api "repos/{owner}/{repo}/branches" --paginate --jq '.[].name')

for name in ${branches}; do
    if [[ "$name" == "$DEFAULT_BRANCH" || "$name" == "main" || "$name" == "master" ]]; then
        skipped+=("$name: protected")
        continue
    fi

    last_date=$(gh api "repos/{owner}/{repo}/commits?sha=${name}&per_page=1" \
        --jq '.[0].commit.committer.date' 2>/dev/null || true)

    if [[ -z "$last_date" ]]; then
        skipped+=("$name: no commits found")
        continue
    fi

    if [[ "$last_date" > "$stale_ts" ]]; then
        skipped+=("$name: last commit $last_date is within ${STALE_DAYS} days")
        continue
    fi

    status=$(gh api "repos/{owner}/{repo}/compare/${DEFAULT_BRANCH}...${name}" \
        --jq '{ahead: .ahead_by, behind: .behind_by, status: .status}')

    ahead=$(echo "$status" | jq -r '.ahead')
    comp_status=$(echo "$status" | jq -r '.status')

    if [[ "$ahead" -gt 0 ]]; then
        skipped+=("$name: ${ahead} commit(s) ahead of ${DEFAULT_BRANCH}")
        continue
    fi

    if [[ "$comp_status" == "diverged" ]]; then
        skipped+=("$name: diverged from ${DEFAULT_BRANCH}")
        continue
    fi

    gh api "repos/{owner}/{repo}/git/refs/heads/${name}" -X DELETE --silent
    deleted+=("$name (last commit: ${last_date%%T*})")
done

echo "Deleted branches:"
printf '  - %s\n' "${deleted[@]}" 2>/dev/null || true
echo ""
echo "Skipped branches:"
printf '  - %s\n' "${skipped[@]}" 2>/dev/null || true

if [[ ${#deleted[@]} -gt 0 ]]; then
    body=$(printf '### Stale Branch Cleanup Report\n\n')
    body+=$(printf '**%d** branch(es) deleted (no commits ahead of `%s`, last activity > %d days ago):\n\n' "${#deleted[@]}" "$DEFAULT_BRANCH" "$STALE_DAYS")
    for d in "${deleted[@]}"; do
        body+=$(printf -- '- `%s`\n' "$d")
    done
    body+=$(printf '\nSkipped **%d** branch(es):\n\n' "${#skipped[@]}")
    for s in "${skipped[@]}"; do
        body+=$(printf -- '- `%s`\n' "$s")
    done

    today=$(date +%Y-%m-%d)
    gh issue create \
        --title "Stale branch cleanup - ${today}" \
        --body "$body" \
        --label "automation"
else
    echo "No stale branches to delete."
fi
