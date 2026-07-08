#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    printf 'Usage: %s actual.png golden.png [diff.png]\n' "$0" >&2
    exit 2
fi

actual=$1
golden=$2
diff=${3:-visual-diff.png}
tolerance=${VISUAL_DIFF_RMSE_TOLERANCE:-0.015}

if [[ ! -f "$actual" ]]; then
    printf 'Actual screenshot missing: %s\n' "$actual" >&2
    exit 2
fi

if [[ ! -f "$golden" ]]; then
    printf 'Golden screenshot missing: %s\n' "$golden" >&2
    exit 2
fi

metric_output=$(magick compare -metric RMSE "$golden" "$actual" "$diff" 2>&1 || true)
normalized=$(printf '%s\n' "$metric_output" | sed -n 's/.*(\([0-9.]*\)).*/\1/p')
if [[ -z "$normalized" ]]; then
    normalized=1
fi

printf 'Visual RMSE: %s (tolerance %s)\n' "$normalized" "$tolerance"

if awk -v value="$normalized" -v tolerance="$tolerance" 'BEGIN { exit !(value > tolerance) }'; then
    printf 'Visual golden diff exceeds tolerance: %s > %s\n' "$normalized" "$tolerance" >&2
    exit 1
fi
