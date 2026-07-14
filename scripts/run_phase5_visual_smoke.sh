#!/usr/bin/env bash
# Captures a fixed world through the CPU fallback and compact auto paths, then
# applies stable image-health and coarse-divergence checks. No binary golden is
# required or maintained.
set -euo pipefail

output_dir=${PHASE5_VISUAL_OUTPUT_DIR:-zig-out/phase5-visual-smoke}
frame=${PHASE5_VISUAL_SCREENSHOT_FRAME:-180}
delay=${PHASE5_VISUAL_SCREENSHOT_DELAY_SECONDS:-3}
mkdir -p "$output_dir"

capture() {
    local mode=$1
    local output=$2
    local capture_log=$3
    ZIGCRAFT_LOD_COMPACT="$mode" ZIGCRAFT_DISABLE_LOD_MDI=1 ZIGCRAFT_LOD_UPLOAD_BUDGET_MB=4 nix develop --command zig build run \
        -Dskip-present \
        -Dauto-world=flat \
        -Dauto-preset=medium \
        -Dscreenshot-path="$output" \
        -Dscreenshot-frame="$frame" \
        -Dscreenshot-delay-seconds="$delay" 2>&1 | tee "$capture_log"
}

capture off "$output_dir/compact-off.png" "$output_dir/compact-off.log"
capture force "$output_dir/compact-auto.png" "$output_dir/compact-auto.log"
if ! grep -Eq 'COMPACT_CAPTURE: allocated=[1-9][0-9]*' "$output_dir/compact-auto.log"; then
    echo "Phase 5 visual smoke failed: forced capture did not exercise compact residency" >&2
    exit 1
fi
PHASE5_VISUAL_MIN_LUMA_BINS=2 PHASE5_VISUAL_MIN_LUMA_RANGE=4 PHASE5_VISUAL_MAX_NMAE=0.70 \
python3 scripts/check_phase5_visual_smoke.py \
    "$output_dir/compact-off.png" \
    "$output_dir/compact-auto.png" \
    "$output_dir/metrics.json"
