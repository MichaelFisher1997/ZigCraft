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

require_non_black_image() {
    local image=$1
    local label=$2
    local mean
    mean=$(magick "$image" -colorspace RGB -format '%[fx:mean]' info:)
    if awk -v value="$mean" 'BEGIN { exit !(value <= 0.0001) }'; then
        printf '%s is effectively black (mean %s); refusing an invalid visual comparison\n' "$label" "$mean" >&2
        exit 1
    fi
}

# A black baseline can make the test look healthy while proving nothing about
# menu composition. Validate both inputs before calculating their difference.
require_non_black_image "$golden" "Golden screenshot"
require_non_black_image "$actual" "Actual screenshot"

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
