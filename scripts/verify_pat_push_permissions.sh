#!/usr/bin/env bash

set -euo pipefail

base_branch="${BASE_BRANCH:?BASE_BRANCH is required}"

if ! git push --dry-run origin "HEAD:${base_branch}" 2>/dev/null; then
    printf "::error::OPENCODE_PAT cannot push to repository. Ensure the PAT has 'repo' scope (classic) or Contents: Read & Write (fine-grained).\n" >&2
    exit 1
fi

printf 'PAT has push permissions.\n'
