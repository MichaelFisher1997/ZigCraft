#!/usr/bin/env bash
set -euo pipefail

output_dir=${1:-screenshots/lighting-phase0}
mkdir -p "$output_dir"

scenes=(noon low-sun cave-entrance sealed-cave rgb-emitter foliage-cutout water cross-chunk-corridor)
channels=(final shadow-factor cascade-index caster-coverage rgb-light skylight ao)
channel_ids=(0 1 2 3 9 12 13)

for scene in "${scenes[@]}"; do
    mkdir -p "$output_dir/$scene"
    for i in "${!channels[@]}"; do
        ZIGCRAFT_DEBUG_SHADER=${channel_ids[$i]} devenv shell --profile graphics -- zig build run \
            -Dskip-present \
            -Dshadow-test-scene \
            -Dshadow-test-variant="$scene" \
            -Dscreenshot-path="$output_dir/$scene/${channels[$i]}.png" \
            -Dscreenshot-frame=180
    done
done
