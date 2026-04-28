#!/usr/bin/env bash

set -euo pipefail

source scripts/github_actions_common.sh

base_branch="${BASE_BRANCH:?BASE_BRANCH is required}"
input_module="${INPUT_MODULE:-}"

existing=$(gh pr list \
    --base "$base_branch" \
    --state open \
    --limit 50 \
    --json number,headRefName,labels \
    --jq '.[] | select((.headRefName | startswith("opencode/schedule-")) or ((.labels | map(.name)) | index("automated-test"))) | "#\(.number) (\(.headRefName))"' || true)

if [[ -n "$existing" && -z "$input_module" ]]; then
    write_output skip true
    printf 'Existing automated test PRs already open:\n%s\n' "$existing"
else
    write_output skip false
fi
