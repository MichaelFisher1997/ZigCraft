#!/usr/bin/env bash
set -euo pipefail

duration=60
presets="low,medium,high"
scenarios="stationary,traversal,rapid-turn,teleport-eviction"
compact_modes="off,auto"
benchmark_world="overworld"
benchmark_fixture=""
output_dir="docs/benchmarks/results"
per_preset_timeout=600
overwrite=false
gpu_adapter="${ZIGCRAFT_BENCHMARK_GPU_ADAPTER:-unknown}"
gpu_driver="${ZIGCRAFT_BENCHMARK_GPU_DRIVER:-unknown}"
runner="${ZIGCRAFT_BENCHMARK_RUNNER:-unknown}"
zig_toolchain="${ZIGCRAFT_BENCHMARK_ZIG_TOOLCHAIN:-unknown}"
gpu_culling=off
gpu_culling_threshold=1
benchmark_horizon_distance=0
benchmark_lod_memory_budget_mb=0
benchmark_require_gpu_candidates=0

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
        --scenarios) scenarios="$2"; shift 2 ;;
        --compact-modes) compact_modes="$2"; shift 2 ;;
        --benchmark-world) benchmark_world="$2"; shift 2 ;;
        --benchmark-fixture) benchmark_fixture="$2"; shift 2 ;;
        --gpu-adapter) gpu_adapter="$2"; shift 2 ;;
        --gpu-driver) gpu_driver="$2"; shift 2 ;;
        --runner) runner="$2"; shift 2 ;;
        --zig-toolchain) zig_toolchain="$2"; shift 2 ;;
        --gpu-culling) gpu_culling="$2"; shift 2 ;;
        --gpu-culling-threshold) gpu_culling_threshold="$2"; shift 2 ;;
        --benchmark-horizon-distance) benchmark_horizon_distance="$2"; shift 2 ;;
        --benchmark-lod-memory-budget-mb) benchmark_lod_memory_budget_mb="$2"; shift 2 ;;
        --benchmark-require-gpu-candidates) benchmark_require_gpu_candidates="$2"; shift 2 ;;
        --overwrite) overwrite=true; shift ;;
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --per-preset-timeout)
            per_preset_timeout="$2"
            shift 2
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

case "$gpu_culling" in off|on) ;; *) printf 'Unknown GPU culling mode: %s (expected off or on)\n' "$gpu_culling" >&2; exit 2 ;; esac
[[ "$gpu_culling_threshold" =~ ^[1-9][0-9]*$ ]] || { printf 'GPU culling threshold must be a positive integer: %s\n' "$gpu_culling_threshold" >&2; exit 2; }
[[ "$benchmark_horizon_distance" =~ ^(0|[1-9][0-9]*)$ ]] || { printf 'Benchmark horizon distance must be zero or a positive integer: %s\n' "$benchmark_horizon_distance" >&2; exit 2; }
[[ "$benchmark_lod_memory_budget_mb" =~ ^[0-9]+$ ]] && (( benchmark_lod_memory_budget_mb <= 4096 )) || { printf 'Benchmark LOD memory budget must be an integer from 0 to 4096 MiB: %s\n' "$benchmark_lod_memory_budget_mb" >&2; exit 2; }
[[ "$benchmark_require_gpu_candidates" =~ ^[0-9]+$ ]] || { printf 'Benchmark GPU candidate readiness target must be a nonnegative integer: %s\n' "$benchmark_require_gpu_candidates" >&2; exit 2; }
gpu_culling_enabled=0
gpu_culling_validate=0
benchmark_gpu_culling=false
if [[ "$gpu_culling" == on ]]; then
    gpu_culling_enabled=1
    gpu_culling_validate=1
    benchmark_gpu_culling=true
fi

mkdir -p "$output_dir"

for label_name in gpu_adapter gpu_driver runner zig_toolchain; do
    label="${!label_name}"
    case "${label,,}" in
        ""|unknown|unspecified|n/a)
            printf 'Evidence mode requires a known %s label (CLI flag or ZIGCRAFT_BENCHMARK_* env).\n' "$label_name" >&2
            exit 2
            ;;
    esac
done

IFS=',' read -r -a preset_list <<< "$presets"
IFS=',' read -r -a scenario_list <<< "$scenarios"
IFS=',' read -r -a compact_mode_list <<< "$compact_modes"

for compact_mode in "${compact_mode_list[@]}"; do
case "$compact_mode" in off|auto) ;; *) printf 'Unknown compact mode: %s\n' "$compact_mode" >&2; exit 2;; esac
for preset in "${preset_list[@]}"; do
    for scenario in "${scenario_list[@]}"; do
    output_file="$output_dir/$compact_mode/$preset/$scenario.json"
    [[ ! -e "$output_file" || "$overwrite" == true ]] || { printf 'Refusing to overwrite %s\n' "$output_file" >&2; exit 1; }
    mkdir -p "$(dirname "$output_file")"
    printf 'Running benchmark preset %s -> %s\n' "$preset" "$output_file"
    benchmark_cmd=(zig build benchmark -Doptimize=ReleaseFast -Dbenchmark-gpu-culling="$benchmark_gpu_culling" -Dbenchmark-preset="$preset" -Dbenchmark-scenario="$scenario" -Dbenchmark-world="$benchmark_world" -Dbenchmark-fixture="$benchmark_fixture" -Dbenchmark-horizon-distance="$benchmark_horizon_distance" -Dbenchmark-lod-memory-budget-mb="$benchmark_lod_memory_budget_mb" -Dbenchmark-require-gpu-candidates="$benchmark_require_gpu_candidates" -Dbenchmark-duration="$duration" -Dbenchmark-output="$output_file")
    require_compact=0
    if [[ "$compact_mode" == auto ]]; then require_compact=1; fi
    benchmark_env=(
        "ZIGCRAFT_LOD_COMPACT=$compact_mode"
        "ZIGCRAFT_LOD_GPU_CULLING=$gpu_culling_enabled"
        "ZIGCRAFT_LOD_GPU_CULLING_VALIDATE=$gpu_culling_validate"
        "ZIGCRAFT_LOD_GPU_CULLING_THRESHOLD=$gpu_culling_threshold"
        "ZIGCRAFT_BENCHMARK_EVIDENCE=1"
        "ZIGCRAFT_BENCHMARK_REQUIRE_COMPACT=$require_compact"
        "ZIGCRAFT_BENCHMARK_GPU_ADAPTER=$gpu_adapter"
        "ZIGCRAFT_BENCHMARK_GPU_DRIVER=$gpu_driver"
        "ZIGCRAFT_BENCHMARK_RUNNER=$runner"
        "ZIGCRAFT_BENCHMARK_ZIG_TOOLCHAIN=$zig_toolchain"
    )
    if [[ -n "${IN_NIX_SHELL:-}" ]]; then
        env "${benchmark_env[@]}" timeout --preserve-status "${per_preset_timeout}s" "${benchmark_cmd[@]}"
    else
        env "${benchmark_env[@]}" timeout --preserve-status "${per_preset_timeout}s" nix develop --command "${benchmark_cmd[@]}"
    fi
    python3 "$(dirname "$0")/benchmark_baseline.py" validate-result "$output_file"
    python3 "$(dirname "$0")/benchmark_baseline.py" stamp-compact "$output_file" "$compact_mode"
    done
done
done
