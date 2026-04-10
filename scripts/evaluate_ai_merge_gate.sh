#!/usr/bin/env bash
set -euo pipefail

repo="${1:?repo required}"
pr_number="${2:?pr number required}"
head_sha="${3:?head sha required}"

review_body=$(gh api "/repos/${repo}/pulls/${pr_number}/reviews" \
  --jq '[.[] | select(.user.login == "opencode-agent[bot]")] | sort_by(.submitted_at) | last | .body // empty')

if [ -z "$review_body" ]; then
  printf '%s\n' '{"state":"failure","description":"AI merge gate missing opencode review"}'
  exit 0
fi

REVIEW_BODY="$review_body" HEAD_SHA="$head_sha" python - <<'PY'
import json
import os
import re
import sys

body = os.environ["REVIEW_BODY"]
head_sha = os.environ["HEAD_SHA"]

match = re.search(r"## Machine Readable Verdict\s*```json\s*(\{.*?\})\s*```", body, re.S)
if not match:
    print(json.dumps({"state": "failure", "description": "AI merge gate missing machine-readable verdict block"}))
    sys.exit(0)

try:
    verdict = json.loads(match.group(1))
except json.JSONDecodeError as exc:
    print(json.dumps({"state": "failure", "description": f"AI merge gate verdict JSON is invalid: {exc}"}))
    sys.exit(0)

errors = []

if verdict.get("reviewed_sha") != head_sha:
    errors.append("reviewed SHA does not match PR head SHA")

for field in ("critical_issues", "high_priority_issues", "medium_priority_issues"):
    value = verdict.get(field)
    if not isinstance(value, int):
        errors.append(f"{field} is missing or not an integer")
    elif value != 0:
        errors.append(f"{field} must be 0")

score = verdict.get("overall_confidence_score")
if not isinstance(score, int):
    errors.append("overall_confidence_score is missing or not an integer")
elif score < 80:
    errors.append("overall_confidence_score must be at least 80")

if errors:
    print(json.dumps({"state": "failure", "description": f"AI merge gate failed with {len(errors)} issue(s)"}))
else:
    print(json.dumps({"state": "success", "description": f"AI merge gate passed for {head_sha[:7]}"}))
PY
