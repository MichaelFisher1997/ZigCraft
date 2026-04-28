#!/usr/bin/env bash
set -uo pipefail

DEFAULT_BRANCH="dev"
STALE_DAYS=7

deleted=()
skipped=()

if ! command -v gh &>/dev/null; then
    echo "error: gh CLI is required" >&2
    exit 1
fi

stale_epoch=$(date -d "-${STALE_DAYS} days" +%s 2>/dev/null || date -v-${STALE_DAYS}d +%s)

gh api "repos/{owner}/{repo}/branches" --paginate --jq '.[].name' | while IFS= read -r name; do
    if [[ "$name" == "$DEFAULT_BRANCH" || "$name" == "main" || "$name" == "master" ]]; then
        skipped+=("$name: protected")
        continue
    fi

    pr_count=$(gh pr list --head "$name" --state open --json number --jq 'length' 2>/dev/null || echo "0")
    if [[ "$pr_count" -gt 0 ]]; then
        skipped+=("$name: has open PR")
        continue
    fi

    last_date=$(gh api "repos/{owner}/{repo}/commits?sha=${name}&per_page=1" \
        --jq '.[0].commit.committer.date' 2>/dev/null || true)

    if [[ -z "$last_date" ]]; then
        skipped+=("$name: no commits found")
        continue
    fi

    last_epoch=$(date -d "$last_date" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_date" +%s 2>/dev/null || echo "0")
    if [[ "$last_epoch" -gt "$stale_epoch" ]]; then
        skipped+=("$name: last commit ${last_date%%T*} is within ${STALE_DAYS} days")
        continue
    fi

    if ! status=$(gh api "repos/{owner}/{repo}/compare/${DEFAULT_BRANCH}...${name}" \
        --jq '{ahead: .ahead_by, behind: .behind_by, status: .status}' 2>/dev/null); then
        skipped+=("$name: API error during compare")
        continue
    fi

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

    if ! gh api "repos/{owner}/{repo}/git/refs/heads/${name}" -X DELETE --silent 2>/dev/null; then
        skipped+=("$name: failed to delete")
        continue
    fi
    deleted+=("$name (last commit: ${last_date%%T*})")
done

echo "Deleted branches:"
printf '  - %s\n' "${deleted[@]+"${deleted[@]}"}"
echo ""
echo "Skipped branches:"
printf '  - %s\n' "${skipped[@]+"${skipped[@]}"}"

if [[ ${#deleted[@]} -gt 0 ]]; then
    gh label create automation --color "#0366d6" --description "Automated processes" 2>/dev/null || true

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
