#!/usr/bin/env bash

set -euo pipefail

source scripts/github_actions_common.sh

if [[ "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}" == "workflow_dispatch" ]]; then
    pr_number="${INPUT_PR_NUMBER:?INPUT_PR_NUMBER is required for workflow_dispatch}"
    head_sha="${INPUT_HEAD_SHA:?INPUT_HEAD_SHA is required for workflow_dispatch}"
else
    pr_number="${EVENT_PR_NUMBER:?EVENT_PR_NUMBER is required}"
    head_sha="${EVENT_HEAD_SHA:?EVENT_HEAD_SHA is required}"
fi

write_output pr_number "$pr_number"
write_output pr_head_sha "$head_sha"
write_env PR_NUMBER "$pr_number"
write_env HEAD_SHA "$head_sha"
