#!/usr/bin/env bash
set -euo pipefail

duration=60
presets="low,medium,high"
output_dir="docs/benchmarks/results"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)
            duration="$2"
            shift 2
            ;;
        --presets)
            presets="$2"
            shift 2
            ;;
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

mkdir -p "$output_dir"

IFS=',' read -r -a preset_list <<< "$presets"

for preset in "${preset_list[@]}"; do
    output_file="$output_dir/$preset.json"
    printf 'Running benchmark preset %s -> %s\n' "$preset" "$output_file"
    benchmark_cmd=(zig build benchmark -Doptimize=ReleaseFast -Dbenchmark-preset="$preset" -Dbenchmark-duration="$duration" -Dbenchmark-output="$output_file")
    if [[ -n "${IN_NIX_SHELL:-}" ]]; then
        ZIGCRAFT_SAFE_MODE=1 "${benchmark_cmd[@]}"
    else
        ZIGCRAFT_SAFE_MODE=1 nix develop --command "${benchmark_cmd[@]}"
    fi
done
