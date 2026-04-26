#!/usr/bin/env bash
set -euo pipefail

out_path="${1:-screenshots/shadow-test.png}"
capture_delay_seconds="${ZIGCRAFT_SCREENSHOT_DELAY_SECONDS:-5}"
variant="${ZIGCRAFT_SHADOW_TEST_VARIANT:-dug-cave}"

case "${out_path,,}" in
  *.png) ;;
  *.jpg|*.jpeg|*.gif|*.webp)
    printf 'error: screenshot encoder currently writes PNG only; use a .png path\n' >&2
    exit 2
    ;;
  *)
    printf 'error: screenshot path must use .png, .jpg, .jpeg, .gif, or .webp\n' >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "$out_path")"
nix develop --command zig build run \
  -Dshadow-test-scene=true \
  -Dshadow-test-variant="$variant" \
  -Dscreenshot-path="$out_path" \
  -Dscreenshot-delay-seconds="$capture_delay_seconds"
