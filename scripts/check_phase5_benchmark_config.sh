#!/usr/bin/env bash
# Validates the build-time benchmark scenario contract without starting Vulkan.
set -euo pipefail

scenarios=(stationary traversal rapid-turn teleport-eviction)

for scenario in "${scenarios[@]}"; do
    zig build -Dbenchmark-scenario="$scenario" --help >/dev/null
done

if zig build -Dbenchmark-scenario=unbounded --help >/dev/null 2>&1; then
    printf 'benchmark build configuration accepted an unbounded scenario\n' >&2
    exit 1
fi
