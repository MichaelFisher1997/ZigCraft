#!/usr/bin/env bash

set -euo pipefail

pat_user_id="$(gh api user --jq '.id')"
pat_user_login="$(gh api user --jq '.login')"

git config user.name "$pat_user_login"
git config user.email "${pat_user_id}+${pat_user_login}@users.noreply.github.com"
