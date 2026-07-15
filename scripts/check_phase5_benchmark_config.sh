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

zig build -Dbenchmark-horizon-distance=4096 --help >/dev/null

zig build -Dbenchmark=true -Dbenchmark-fixture=gpu-culling-scale -Dbenchmark-horizon-distance=4096 -Dbenchmark-lod-memory-budget-mb=2048 -Dbenchmark-require-gpu-candidates=1024 --help >/dev/null

if zig build -Dbenchmark-fixture=gpu-culling-scale --help >/dev/null 2>&1; then
    printf 'gpu-culling-scale fixture was accepted outside benchmark mode\n' >&2
    exit 1
fi

if zig build -Dbenchmark=true -Dbenchmark-fixture=gpu-culling-scale -Dbenchmark-horizon-distance=4096 -Dbenchmark-lod-memory-budget-mb=2048 -Dbenchmark-require-gpu-candidates=512 --help >/dev/null 2>&1; then
    printf 'gpu-culling-scale fixture accepted a sub-target readiness gate\n' >&2
    exit 1
fi

if zig build -Dbenchmark-horizon-distance=-1 --help >/dev/null 2>&1; then
    printf 'benchmark build configuration accepted a negative horizon override\n' >&2
    exit 1
fi
