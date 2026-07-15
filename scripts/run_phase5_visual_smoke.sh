#!/usr/bin/env bash
# Captures deterministic production-world fixtures through expanded and
# production compact-auto paths. This is deliberately a bounded
# smoke/regression gate rather than a driver-specific pixel golden.
set -euo pipefail

output_dir=${PHASE5_VISUAL_OUTPUT_DIR:-zig-out/phase5-visual-smoke}
run_id=${PHASE5_VISUAL_RUN_ID:-"$(date -u +%Y%m%dT%H%M%SZ)-$$"}
run_dir="$output_dir/run-$run_id"
save_dir="$run_dir/saved-world"
frame=${PHASE5_VISUAL_SCREENSHOT_FRAME:-900}
delay=${PHASE5_VISUAL_SCREENSHOT_DELAY_SECONDS:-5}
capture_timeout=${PHASE5_VISUAL_CAPTURE_TIMEOUT:-110s}
mkdir -p "$run_dir"
# A re-used run ID must not silently reload an older qualification save.
rm -rf "$save_dir"

capture() {
    local scene=$1
    local mode=$2
    local output="$run_dir/$scene-$mode.png"
    local capture_log="$run_dir/$scene-$mode.log"
    # The scope is unique per gate. Remove exact target artifacts as an
    # additional guard when a caller deliberately reuses a run identifier.
    rm -f "$output" "$capture_log" "$run_dir/$scene-$mode.engine.log"
    echo "Phase 5 visual capture: run=$run_id scene=$scene mode=$mode" | tee "$capture_log"
    local gpu_culling=0
    local disable_lod_mdi=1
    local scene_frame="$frame"
    local scene_delay="$delay"
    local save_environment=()
    if [[ ( "$scene" == "lod-handoff" || "$scene" == "lod-handoff-traversal" || "$scene" == "fog-rapid-turn" || "$scene" == "teleport-handoff" || "$scene" == "saved-world-reload" ) && "$mode" == "auto" ]]; then
        gpu_culling=1
        disable_lod_mdi=0
    fi
    if [[ "$scene" == saved-world-* ]]; then
        save_environment+=("ZIGCRAFT_SAVE_DIR=$save_dir")
    fi
    # Motion completes after 180 rendered frames, then streaming at the final
    # pose must drain and remain stable for another 180 frames. Give real world
    # generation wall-clock time to settle instead of racing a fast GPU's frame
    # counter and failing the readiness assertion at frame 900.
    if [[ "$scene" == "lod-handoff-traversal" || "$scene" == "fog-rapid-turn" || "$scene" == "teleport-handoff" ]]; then
        scene_frame="${PHASE5_VISUAL_MOTION_SCREENSHOT_FRAME:-2400}"
        scene_delay="${PHASE5_VISUAL_MOTION_SCREENSHOT_DELAY_SECONDS:-15}"
    fi
    env "${save_environment[@]}" \
        ZIGCRAFT_LOD_COMPACT="$mode" \
        ZIGCRAFT_LOD_PROFILE=1 \
        ZIGCRAFT_LOD_UPLOAD_BUDGET_MB=4 \
        ZIGCRAFT_LOD_GPU_CULLING="$gpu_culling" \
        ZIGCRAFT_LOD_GPU_CULLING_THRESHOLD=1 \
        ZIGCRAFT_LOD_GPU_CULLING_VALIDATE="$gpu_culling" \
        ZIGCRAFT_DISABLE_LOD_MDI="$disable_lod_mdi" \
        ZIGCRAFT_PHASE5_SETTLE_FRAMES="${PHASE5_VISUAL_SETTLE_FRAMES:-180}" \
        timeout --preserve-status "$capture_timeout" nix develop --command zig build run \
        -Dskip-present \
        -Dauto-preset=low \
        -Dauto-world=flat \
        -Dphase5-visual-scene="$scene" \
        -Dphase5-visual-run-id="$run_id" \
        -Dscreenshot-path="$output" \
        -Dscreenshot-frame="$scene_frame" \
        -Dscreenshot-delay-seconds="$scene_delay" 2>&1 | tee -a "$capture_log"
}

# `seam` mutates both sides of x=16 in the production flat world. `water` adds
# a deterministic full-detail water pool. `lod-handoff` looks from full detail
# into the LOD horizon and enables GPU culling/MDI in its compact-auto run.
# The three motion scenes use production compact-auto only: their session
# scripts change the real player/camera pose before a settled capture.
# Keep each capture separate: this prevents one healthy scene from
# hiding a regression in another feature.
for scene in seam water; do
    capture "$scene" off
    capture "$scene" auto
done
capture lod-handoff auto
capture lod-handoff-traversal auto
capture fog-rapid-turn auto
capture teleport-handoff auto

# Production compact-auto qualification needs a second process. The creator
# persists deterministic wet/dry edits and the LOD source cache; the reload is
# the only capture that exercises those same on-disk artifacts with MDI/GPU
# validation enabled.
capture saved-world-create off
test -f "$save_dir/level.dat"
shopt -s globstar nullglob
lod_cache_files=("$save_dir/lod"/**/*.zlod)
(( ${#lod_cache_files[@]} > 0 ))
shopt -u globstar nullglob
capture saved-world-reload auto

python3 scripts/check_phase5_visual_smoke.py \
    --run-id "$run_id" \
    --manifest "$run_dir/manifest.json" \
    --scene seam \
        "$run_dir/seam-off.png" \
        "$run_dir/seam-auto.png" \
        "$run_dir/seam-auto.log" \
    --scene water \
        "$run_dir/water-off.png" \
        "$run_dir/water-auto.png" \
        "$run_dir/water-auto.log" \
    --handoff "$run_dir/lod-handoff-auto.png" "$run_dir/lod-handoff-auto.log" \
    --motion lod-handoff-traversal "$run_dir/lod-handoff-traversal-auto.png" "$run_dir/lod-handoff-traversal-auto.log" \
    --motion fog-rapid-turn "$run_dir/fog-rapid-turn-auto.png" "$run_dir/fog-rapid-turn-auto.log" \
    --motion teleport-handoff "$run_dir/teleport-handoff-auto.png" "$run_dir/teleport-handoff-auto.log" \
    --saved-world "$run_dir/saved-world-create-off.log" "$run_dir/saved-world-reload-auto.png" "$run_dir/saved-world-reload-auto.log"
