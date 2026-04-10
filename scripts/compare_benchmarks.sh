#!/usr/bin/env bash
set -euo pipefail

warn_threshold=10
fail_threshold=20
preset=""

if [[ $# -lt 2 ]]; then
    printf 'Usage: %s baseline.json new.json\n' "$0" >&2
    exit 2
fi

baseline="$1"
new="$2"
shift 2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --preset)
            preset="$2"
            shift 2
            ;;
        --warn)
            warn_threshold="$2"
            shift 2
            ;;
        --fail)
            fail_threshold="$2"
            shift 2
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

read_json() {
    jq -r "$1" "$2"
}

baseline_source="$baseline"
baseline_generated=$(read_json '.generated' "$baseline")
if [[ "$baseline_generated" != "true" ]]; then
    printf 'Baseline placeholder detected, skipping comparison.\n'
    exit 0
fi

if [[ -n "$preset" ]]; then
    baseline_source=$(mktemp)
    jq -c --arg preset "$preset" '.presets[$preset]' "$baseline" > "$baseline_source"
fi

cleanup() {
    if [[ -n "${baseline_source:-}" && "$baseline_source" == /tmp/* && -f "$baseline_source" ]]; then
        rm -f "$baseline_source"
    fi
}

trap cleanup EXIT

pct_change() {
    awk -v old="$1" -v new="$2" 'BEGIN {
        if (old == 0 && new == 0) { print 0; exit }
        if (old == 0) { print 100; exit }
        printf "%.2f", ((new - old) / old) * 100.0
    }'
}

baseline_fps=$(read_json '.fps.avg' "$baseline_source")
new_fps=$(read_json '.fps.avg' "$new")
baseline_gpu=$(read_json '.gpu_ms.total_avg' "$baseline_source")
new_gpu=$(read_json '.gpu_ms.total_avg' "$new")
baseline_draws=$(read_json '.draw_calls_avg' "$baseline_source")
new_draws=$(read_json '.draw_calls_avg' "$new")

fps_change=$(pct_change "$baseline_fps" "$new_fps")
gpu_change=$(pct_change "$baseline_gpu" "$new_gpu")
draw_change=$(pct_change "$baseline_draws" "$new_draws")

printf 'FPS avg: %s -> %s (%s%%)\n' "$baseline_fps" "$new_fps" "$fps_change"
printf 'GPU total avg: %s -> %s (%s%%)\n' "$baseline_gpu" "$new_gpu" "$gpu_change"
printf 'Draw calls avg: %s -> %s (%s%%)\n' "$baseline_draws" "$new_draws" "$draw_change"

fps_drop=$(awk -v change="$fps_change" 'BEGIN { if (change < 0) printf "%.2f", -change; else print 0 }')

if awk -v drop="$fps_drop" -v warn="$warn_threshold" 'BEGIN { exit !(drop >= warn) }'; then
    printf 'Warning: FPS regressed by %s%%\n' "$fps_drop"
fi

if awk -v drop="$fps_drop" -v fail="$fail_threshold" 'BEGIN { exit !(drop >= fail) }'; then
    printf 'Regression exceeds failure threshold (%s%% >= %s%%)\n' "$fps_drop" "$fail_threshold" >&2
    exit 1
fi
