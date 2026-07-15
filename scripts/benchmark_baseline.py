#!/usr/bin/env python3
"""Validate, pair, assemble, and compare reproducible benchmark evidence.

Steady-state counters in a result are sampled deltas.  `startup_evidence` is
intentionally cumulative at readiness, so a compact pair can make honest
startup and resident-geometry claims without treating warmup as steady state.
"""
from __future__ import annotations

import argparse
import json
import math
import tempfile
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 3
PRESETS = ("low", "medium", "high")
POLICY_PRESETS = PRESETS + ("ultra", "extreme")
SCENARIOS = ("stationary", "traversal", "rapid-turn", "teleport-eviction")
PROVENANCE_PATHS = (
    "world_seed", "build.mode", "build.world", "build.fixture", "build.headless",
    "build.resolution", "provenance.gpu_adapter", "provenance.gpu_driver",
    "provenance.runner", "provenance.zig_toolchain",
)
HORIZON_PROVENANCE_PATH = "build.horizon_distance"
LOD_MEMORY_BUDGET_PATH = "build.benchmark_lod_memory_budget_mb"
LOD_READINESS_TARGET_PATH = "build.benchmark_require_gpu_candidates"
PAIR_COMPATIBILITY_PATHS = ("preset", "scenario", *PROVENANCE_PATHS, "duration_s", "completion.requested_duration_s")
RESULT_COMPATIBILITY_PATHS = (*PROVENANCE_PATHS, "duration_s", "completion.requested_duration_s")
STARTUP_NUMERIC_PATHS = (
    "startup_evidence.readiness_elapsed_s", "startup_evidence.upload_total_bytes",
    "startup_evidence.far_expanded_upload_bytes", "startup_evidence.compact_upload_bytes",
    "startup_evidence.worker_generation_total_ms",
    "startup_evidence.worker_mesh_construction_total_ms",
    "startup_evidence.worker_far_expanded_mesh_construction_ms",
    "startup_evidence.worker_compact_encode_ms",
    "startup_evidence.compact_submissions",
    "startup_evidence.pool_gpu_allocated_bytes",
    "startup_evidence.direct_mesh_gpu_bytes",
    "startup_evidence.compact_pool_allocated_bytes",
    "startup_evidence.pool_cpu_shadow_bytes",
)
MATERIAL_REDUCTION = 0.20
GPU_CULLING_MIN_DURATION_S = 60
GPU_CULLING_MIN_HORIZON_DISTANCE = 4096
GPU_CULLING_FIXTURE = "gpu-culling-scale"
GPU_CULLING_MIN_READINESS_TARGET = 1024
GPU_CULLING_CPU_P95_IMPROVEMENT = 0.01
GPU_CULLING_CPU_P99_REGRESSION = 0.01
GPU_CULLING_TOTAL_GPU_P99_REGRESSION = 0.01


def get_path(value: dict[str, Any], path: str) -> Any:
    current: Any = value
    for part in path.split("."):
        current = current[part]
    return current


def load(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: JSON root must be an object")
    return value


def require(value: dict[str, Any], path: str, source: str) -> Any:
    try:
        return get_path(value, path)
    except (KeyError, TypeError) as exc:
        raise ValueError(f"{source}: missing {path}") from exc


def optional(value: dict[str, Any], path: str) -> Any | None:
    try:
        return get_path(value, path)
    except (KeyError, TypeError):
        return None


def require_compatible(left: dict[str, Any], right: dict[str, Any], paths: tuple[str, ...], source: str) -> None:
    for path in paths:
        if require(left, path, f"{source}/left") != require(right, path, f"{source}/right"):
            raise ValueError(f"{source}: incompatible {path}")
    # Schema-v3 captures before the independent horizon option lack this field.
    # Preserve validation of checked historical evidence, but never allow a new
    # horizon-recording result to be compared to such a legacy artifact.
    left_horizon = optional(left, HORIZON_PROVENANCE_PATH)
    right_horizon = optional(right, HORIZON_PROVENANCE_PATH)
    if left_horizon != right_horizon:
        raise ValueError(f"{source}: incompatible {HORIZON_PROVENANCE_PATH}")
    # Default new controls for schema-v3 captures that predate them, but never
    # pair explicit captures with a different override or readiness gate.
    for path in (LOD_MEMORY_BUDGET_PATH, LOD_READINESS_TARGET_PATH):
        if (optional(left, path) or 0) != (optional(right, path) or 0):
            raise ValueError(f"{source}: incompatible {path}")


def is_known_label(value: Any) -> bool:
    return isinstance(value, str) and value.strip() and value.strip().lower() not in {"unknown", "unspecified", "n/a"}


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate_result(value: dict[str, Any], source: str = "result") -> None:
    if value.get("schema_version") != SCHEMA_VERSION or value.get("artifact_type") != "benchmark-result":
        raise ValueError(f"{source}: requires benchmark-result schema_version {SCHEMA_VERSION}")
    if require(value, "preset", source) not in POLICY_PRESETS or require(value, "scenario", source) not in SCENARIOS:
        raise ValueError(f"{source}: unknown preset/scenario")
    if require(value, "completion.scenario_completed", source) is not True:
        raise ValueError(f"{source}: scenario completion evidence is absent")
    if require(value, "completion.warmup_ready", source) is not True or require(value, "completion.warmup_timed_out", source) is not False:
        raise ValueError(f"{source}: readiness warmup did not complete")
    if require(value, "completion.sampled_duration_s", source) < require(value, "completion.requested_duration_s", source) or require(value, "completion.sampled_frame_count", source) <= 0:
        raise ValueError(f"{source}: sampled duration/frame evidence is incomplete")
    if not is_number(require(value, "duration_s", source)) or require(value, "duration_s", source) != require(value, "completion.requested_duration_s", source):
        raise ValueError(f"{source}: configured duration must match requested duration evidence")
    if require(value, "lod.profiling_enabled", source) is not True or require(value, "lod.profiling_frame_count", source) != require(value, "completion.sampled_frame_count", source):
        raise ValueError(f"{source}: LOD profiling does not cover every sampled frame")
    result_horizon = optional(value, "horizon_distance")
    build_horizon = optional(value, HORIZON_PROVENANCE_PATH)
    if result_horizon is not None or build_horizon is not None:
        if not all(isinstance(entry, int) and not isinstance(entry, bool) and entry > 0 for entry in (result_horizon, build_horizon)) or result_horizon != build_horizon:
            raise ValueError(f"{source}: horizon_distance and {HORIZON_PROVENANCE_PATH} must be matching positive integers")
    memory_budget = optional(value, LOD_MEMORY_BUDGET_PATH) or 0
    readiness_target = optional(value, LOD_READINESS_TARGET_PATH) or 0
    if not isinstance(memory_budget, int) or isinstance(memory_budget, bool) or not 0 <= memory_budget <= 4096:
        raise ValueError(f"{source}: {LOD_MEMORY_BUDGET_PATH} must be an integer from 0 to 4096")
    if not isinstance(readiness_target, int) or isinstance(readiness_target, bool) or readiness_target < 0:
        raise ValueError(f"{source}: {LOD_READINESS_TARGET_PATH} must be a nonnegative integer")
    completion_region_target = optional(value, "completion.lod_renderable_region_target") or 0
    completion_candidate_target = optional(value, "completion.gpu_candidate_target") or 0
    if completion_region_target != readiness_target or completion_candidate_target != readiness_target:
        raise ValueError(f"{source}: completion readiness targets must match {LOD_READINESS_TARGET_PATH}")
    if readiness_target:
        if require(value, "startup_evidence.lod_renderable_regions", source) < readiness_target:
            raise ValueError(f"{source}: common renderable LOD-region readiness target was not met")
        if require(value, "lod.gpu_culling.requested", source) is True and require(value, "lod.gpu_culling.candidate_count_max", source) < readiness_target:
            raise ValueError(f"{source}: GPU candidate max is below its documented readiness target")
    for path in ("lod.pressure.wait_idle_count_total", "lod.pressure.gpu_culling_overflows_max", "lod.pressure.gpu_culling_validation_mismatches_max"):
        if require(value, path, source) != 0:
            raise ValueError(f"{source}: {path} must be zero")
    for path in ("gpu_ms.total.p95", "gpu_ms.total.p99", "lod.cpu_frame_ms.p95", "lod.cpu_frame_ms.p99", "lod.gpu_frame_ms.p95", "lod.gpu_frame_ms.p99", "lod.memory_bytes.logical_ram_bytes.p95_bytes", "lod.memory_bytes.logical_ram_bytes.p99_bytes", "lod.memory_bytes.logical_vram_bytes.p95_bytes", "lod.memory_bytes.logical_vram_bytes.p99_bytes"):
        if not is_number(require(value, path, source)):
            raise ValueError(f"{source}: {path} must be numeric")
    for path in ("lod.memory_bytes.logical_ram_bytes.max_bytes", "lod.memory_bytes.logical_vram_bytes.max_bytes", "lod.memory_bytes.logical_ram_bytes.p50_bytes", "lod.memory_bytes.logical_vram_bytes.p50_bytes"):
        if not is_number(require(value, path, source)) or require(value, path, source) <= 0:
            raise ValueError(f"{source}: {path} must be positive LOD memory evidence")
    if require(value, "completion.evidence_mode", source) is True:
        if require(value, "startup_evidence.readiness_observed", source) is not True:
            raise ValueError(f"{source}: readiness startup evidence is absent")
        for path in STARTUP_NUMERIC_PATHS:
            if not is_number(require(value, path, source)) or require(value, path, source) < 0:
                raise ValueError(f"{source}: {path} must be a nonnegative number")
        for path in PROVENANCE_PATHS[-4:]:
            if not is_known_label(require(value, path, source)):
                raise ValueError(f"{source}: evidence mode requires a known {path}")


def startup_far_geometry(value: dict[str, Any]) -> int:
    """Resident representation-owned far geometry, excluding the near pool."""
    return sum(int(require(value, f"startup_evidence.{field}", "result")) for field in ("direct_mesh_gpu_bytes", "compact_pool_allocated_bytes"))


def required_reduction(off: float, auto: float, label: str) -> dict[str, Any]:
    """Enforce a reduction only when the off run has a nonzero basis."""
    if off == 0:
        return {"off": off, "auto": auto, "status": "not-applicable-off-zero", "reduction_fraction": None, "delta": auto - off}
    fraction = (off - auto) / off
    if fraction + 1e-12 < MATERIAL_REDUCTION:
        raise ValueError(f"{label}: reduction {fraction:.2%} is below required {MATERIAL_REDUCTION:.0%}")
    return {"off": off, "auto": auto, "status": "measured", "reduction_fraction": fraction, "delta": auto - off}


def startup_comparison(off: dict[str, Any], auto: dict[str, Any], field: str) -> dict[str, Any]:
    off_value = require(off, f"startup_evidence.{field}", "off")
    auto_value = require(auto, f"startup_evidence.{field}", "auto")
    if off_value == 0 and auto_value == 0:
        return {"off": off_value, "auto": auto_value, "status": "not-applicable-both-zero", "delta": None}
    return {"off": off_value, "auto": auto_value, "status": "measured", "delta": auto_value - off_value}


def worker_representation_reduction(off: dict[str, Any], auto: dict[str, Any], label: str) -> dict[str, Any]:
    """Compare far worker work only when both representation clocks are usable."""
    off_value = (
        require(off, "startup_evidence.worker_far_expanded_mesh_construction_ms", "off")
        + require(off, "startup_evidence.worker_compact_encode_ms", "off")
    )
    auto_value = (
        require(auto, "startup_evidence.worker_far_expanded_mesh_construction_ms", "auto")
        + require(auto, "startup_evidence.worker_compact_encode_ms", "auto")
    )
    if off_value > 0 and auto_value > 0:
        return required_reduction(off_value, auto_value, label)
    return {
        "off": off_value,
        "auto": auto_value,
        "status": "not-comparable-missing-stable-worker-basis",
        "reduction_fraction": None,
        "delta": auto_value - off_value,
    }


def validate_compact_result(value: dict[str, Any], source: str = "result") -> None:
    validate_result(value, source)
    mode = value.get("compact_mode")
    if mode not in ("off", "auto"):
        raise ValueError(f"{source}: compact_mode must be off or auto")
    if require(value, "completion.evidence_mode", source) is not True:
        raise ValueError(f"{source}: compact evidence requires evidence mode")
    if mode == "auto" and require(value, "completion.compact_ready", source) is not True:
        raise ValueError(f"{source}: auto compact evidence did not become ready")


def validate_pair(off: dict[str, Any], auto: dict[str, Any], source: str) -> dict[str, Any]:
    validate_compact_result(off, f"{source}/off")
    validate_compact_result(auto, f"{source}/auto")
    if off.get("compact_mode") != "off" or auto.get("compact_mode") != "auto":
        raise ValueError(f"{source}: expected off/auto compact pair")
    require_compatible(off, auto, PAIR_COMPATIBILITY_PATHS, source)
    if require(off, "build.fixture", f"{source}/off") == GPU_CULLING_FIXTURE:
        raise ValueError(f"{source}: gpu-culling-scale is dedicated culling evidence, not a normal compact baseline")
    off_residency = require(off, "startup_evidence.compact_pool_allocated_bytes", "off")
    auto_residency = require(auto, "startup_evidence.compact_pool_allocated_bytes", "auto")
    off_submissions = require(off, "startup_evidence.compact_submissions", "off")
    auto_submissions = require(auto, "startup_evidence.compact_submissions", "auto")
    if off_residency != 0 or off_submissions != 0:
        raise ValueError(f"{source}: off must have zero compact readiness residency and submissions")
    if auto_residency <= 0 or auto_submissions <= 0:
        raise ValueError(f"{source}: auto requires nonzero compact readiness residency and submissions")
    comparisons = {
        "far_resident_geometry": required_reduction(startup_far_geometry(off), startup_far_geometry(auto), f"{source}: far resident geometry"),
        "far_representation_upload_bytes": required_reduction(
            require(off, "startup_evidence.far_expanded_upload_bytes", "off") + require(off, "startup_evidence.compact_upload_bytes", "off"),
            require(auto, "startup_evidence.far_expanded_upload_bytes", "auto") + require(auto, "startup_evidence.compact_upload_bytes", "auto"),
            f"{source}: far representation upload bytes",
        ),
        "worker_far_representation_work": worker_representation_reduction(off, auto, f"{source}: worker far representation work"),
        # Contextual totals are retained for diagnostics, but near streaming
        # makes them invalid acceptance metrics for the far representation.
        "near_pool_geometry": startup_comparison(off, auto, "pool_gpu_allocated_bytes"),
        "cpu_expanded_shadow": startup_comparison(off, auto, "pool_cpu_shadow_bytes"),
        "startup_upload_bytes": startup_comparison(off, auto, "upload_total_bytes"),
        "startup_worker_mesh_construction_ms": startup_comparison(off, auto, "worker_mesh_construction_total_ms"),
    }
    return comparisons


def stamp_compact(path: Path, mode: str) -> None:
    if mode not in ("off", "auto"):
        raise ValueError(f"unknown compact mode {mode}")
    value = load(path)
    value["compact_mode"] = mode
    validate_compact_result(value, str(path))
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def validate_compact_matrix(root: Path) -> None:
    for preset in PRESETS:
        for scenario in SCENARIOS:
            off = load(root / "off" / preset / f"{scenario}.json")
            auto = load(root / "auto" / preset / f"{scenario}.json")
            validate_pair(off, auto, f"compact pair {preset}/{scenario}")


def artifact_paths(inputs: list[Path]) -> list[Path]:
    paths: list[Path] = []
    for input_path in inputs:
        paths.extend(sorted(input_path.rglob("*.json")) if input_path.is_dir() else [input_path])
    return paths


def assemble(inputs: list[Path], output: Path, overwrite: bool) -> None:
    if output.exists() and not overwrite:
        raise ValueError(f"refusing to overwrite {output}; pass --overwrite")
    pairs: dict[str, dict[str, dict[str, dict[str, Any]]]] = {preset: {} for preset in PRESETS}
    provenance: dict[str, Any] | None = None
    capture_duration_s: float | int | None = None
    for path in artifact_paths(inputs):
        value = load(path)
        validate_compact_result(value, str(path))
        preset, scenario, mode = value["preset"], value["scenario"], value["compact_mode"]
        if preset not in PRESETS:
            continue
        slot = pairs[preset].setdefault(scenario, {})
        if mode in slot:
            raise ValueError(f"duplicate {mode} artifact for {preset}/{scenario}: {path}")
        current = {key: require(value, key, str(path)) for key in PROVENANCE_PATHS}
        if provenance is None:
            provenance = current
        elif current != provenance:
            raise ValueError(f"{path}: incompatible provenance {current!r}, expected {provenance!r}")
        duration = require(value, "completion.requested_duration_s", str(path))
        if capture_duration_s is None:
            capture_duration_s = duration
        elif duration != capture_duration_s:
            raise ValueError(f"{path}: incompatible requested duration {duration!r}, expected {capture_duration_s!r}")
        slot[mode] = value
    missing = [f"{preset}/{scenario}/{mode}" for preset in PRESETS for scenario in SCENARIOS for mode in ("off", "auto") if mode not in pairs[preset].get(scenario, {})]
    if missing:
        raise ValueError("missing required paired captures: " + ", ".join(missing))
    comparisons: dict[str, dict[str, Any]] = {preset: {} for preset in PRESETS}
    results: dict[str, dict[str, Any]] = {preset: {} for preset in PRESETS}
    for preset in PRESETS:
        for scenario in SCENARIOS:
            pair = pairs[preset][scenario]
            comparisons[preset][scenario] = {"off": pair["off"], "auto": pair["auto"], "comparison": validate_pair(pair["off"], pair["auto"], f"baseline pair {preset}/{scenario}")}
            results[preset][scenario] = pair["auto"]
    baseline = {
        "schema_version": SCHEMA_VERSION, "artifact_type": "benchmark-baseline", "status": "ready", "generated": True,
        "required_presets": list(PRESETS), "required_scenarios": list(SCENARIOS), "provenance": provenance,
        "capture_duration_s": capture_duration_s,
        "results": results, "compact_pairs": comparisons,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")


def validate_baseline(path: Path, allow_insufficient: bool) -> None:
    baseline = load(path)
    if baseline.get("status") == "insufficient":
        if allow_insufficient:
            return
        raise ValueError(f"{path}: baseline is insufficient: {baseline.get('reason', 'no reason supplied')}")
    if baseline.get("schema_version") != SCHEMA_VERSION or baseline.get("artifact_type") != "benchmark-baseline" or baseline.get("status") != "ready":
        raise ValueError(f"{path}: not a ready schema-v{SCHEMA_VERSION} benchmark baseline")
    for preset in PRESETS:
        for scenario in SCENARIOS:
            auto = require(baseline, f"results.{preset}.{scenario}", str(path))
            pair = require(baseline, f"compact_pairs.{preset}.{scenario}", str(path))
            if auto != require(pair, "auto", str(path)):
                raise ValueError(f"{path}: results {preset}/{scenario} is not its paired auto artifact")
            actual = validate_pair(require(pair, "off", str(path)), require(pair, "auto", str(path)), f"{path}:{preset}/{scenario}")
            if require(pair, "comparison", str(path)) != actual:
                raise ValueError(f"{path}: stored paired comparison does not match source evidence for {preset}/{scenario}")
            if require(auto, "completion.requested_duration_s", str(path)) != require(baseline, "capture_duration_s", str(path)):
                raise ValueError(f"{path}: baseline mixes requested benchmark durations")
            for key in PROVENANCE_PATHS:
                if require(auto, key, str(path)) != require(baseline, "provenance", str(path)).get(key):
                    raise ValueError(f"{path}: baseline provenance does not match {preset}/{scenario} {key}")


def require_positive_number(value: dict[str, Any], path: str, source: str) -> float:
    number = require(value, path, source)
    if not is_number(number) or number <= 0:
        raise ValueError(f"{source}: {path} must be a positive finite number")
    return float(number)


def culling_comparison(cpu: dict[str, Any], gpu: dict[str, Any], source: str) -> dict[str, Any]:
    """Validate a matched CPU/GPU culling pair and return its derived proof.

    Ratios intentionally use the raw artifact values: this is an acceptance
    gate, so there is no rounding or epsilon that could turn a near miss into a
    pass.
    """
    validate_result(cpu, f"{source}/cpu")
    validate_result(gpu, f"{source}/gpu")
    require_compatible(cpu, gpu, PAIR_COMPATIBILITY_PATHS, source)
    if require(cpu, "preset", f"{source}/cpu") not in ("high", "extreme") or require(cpu, "scenario", f"{source}/cpu") != "traversal":
        raise ValueError(f"{source}: requires high or extreme traversal results")
    for value, label in ((cpu, "cpu"), (gpu, "gpu")):
        if require(value, "build.fixture", f"{source}/{label}") != GPU_CULLING_FIXTURE:
            raise ValueError(f"{source}: {label} must use fixture {GPU_CULLING_FIXTURE!r}")
    if cpu.get("compact_mode") != "auto" or gpu.get("compact_mode") != "auto":
        raise ValueError(f"{source}: requires auto-compact source results")
    if require(cpu, "completion.requested_duration_s", f"{source}/cpu") < GPU_CULLING_MIN_DURATION_S:
        raise ValueError(f"{source}: requires at least {GPU_CULLING_MIN_DURATION_S} sampled seconds")
    horizon_distance = require(cpu, HORIZON_PROVENANCE_PATH, f"{source}/cpu")
    if not isinstance(horizon_distance, int) or isinstance(horizon_distance, bool) or horizon_distance < GPU_CULLING_MIN_HORIZON_DISTANCE:
        raise ValueError(f"{source}: requires a documented horizon distance of at least {GPU_CULLING_MIN_HORIZON_DISTANCE} chunks")
    memory_budget = require(cpu, LOD_MEMORY_BUDGET_PATH, f"{source}/cpu")
    readiness_target = require(cpu, LOD_READINESS_TARGET_PATH, f"{source}/cpu")
    if not isinstance(memory_budget, int) or isinstance(memory_budget, bool) or not 0 < memory_budget <= 4096:
        raise ValueError(f"{source}: requires a documented nonzero LOD memory budget no larger than 4096 MiB")
    if not isinstance(readiness_target, int) or isinstance(readiness_target, bool) or readiness_target < GPU_CULLING_MIN_READINESS_TARGET:
        raise ValueError(f"{source}: requires a documented readiness target of at least {GPU_CULLING_MIN_READINESS_TARGET}")
    for value, label in ((cpu, "cpu"), (gpu, "gpu")):
        if require(value, "completion.lod_renderable_region_target", f"{source}/{label}") != readiness_target or require(value, "completion.gpu_candidate_target", f"{source}/{label}") != readiness_target:
            raise ValueError(f"{source}: {label} completion readiness provenance differs from build target")
        if require(value, "startup_evidence.lod_renderable_regions", f"{source}/{label}") < readiness_target:
            raise ValueError(f"{source}: {label} did not meet the common renderable-region readiness target")
    if require(cpu, "lod.gpu_culling.requested", f"{source}/cpu") is not False:
        raise ValueError(f"{source}: CPU source must explicitly request GPU culling off")
    if require(gpu, "lod.gpu_culling.requested", f"{source}/gpu") is not True:
        raise ValueError(f"{source}: GPU source must explicitly request GPU culling on")

    threshold = require(gpu, "lod.gpu_culling.threshold", f"{source}/gpu")
    candidate_max = require(gpu, "lod.gpu_culling.candidate_count_max", f"{source}/gpu")
    candidate_total = require(gpu, "lod.gpu_culling.candidate_count_total", f"{source}/gpu")
    draw_submissions = require(gpu, "lod.gpu_culling.draw_submission_count_total", f"{source}/gpu")
    if not all(isinstance(entry, int) and not isinstance(entry, bool) for entry in (threshold, candidate_max, candidate_total, draw_submissions)):
        raise ValueError(f"{source}: GPU culling count evidence must be integer-valued")
    if threshold <= 0 or candidate_max < readiness_target or candidate_total <= threshold or draw_submissions <= 0:
        raise ValueError(f"{source}: GPU culling did not reach its documented candidate readiness target")
    completed_generation = require(gpu, "lod.gpu_culling.validation_completed_generation", f"{source}/gpu")
    completed_count = require(gpu, "lod.gpu_culling.validation_completed_count", f"{source}/gpu")
    generation = require(gpu, "lod.gpu_culling.validation_generation", f"{source}/gpu")
    if not all(isinstance(entry, int) and not isinstance(entry, bool) for entry in (generation, completed_generation, completed_count)):
        raise ValueError(f"{source}: delayed validation evidence must be integer-valued")
    if completed_count <= 0 or completed_generation <= 0 or generation < completed_generation:
        raise ValueError(f"{source}: delayed GPU validation did not complete")
    # Timestamp queries are consumed after frame-slot reuse, so short gaps can
    # legitimately make the median zero even while thousands of validated
    # dispatches are sampled. Keep p50/p95 reported and finite; positive average
    # and p99 plus dispatch/validation counters prove active compute work.
    for percentile in ("p50", "p95"):
        value = require(gpu, f"gpu_ms.lod_culling.{percentile}", f"{source}/gpu")
        if not is_number(value) or value < 0:
            raise ValueError(f"{source}/gpu: gpu_ms.lod_culling.{percentile} must be a nonnegative finite number")
    require_positive_number(gpu, "gpu_ms.lod_culling.avg", f"{source}/gpu")
    require_positive_number(gpu, "gpu_ms.lod_culling.p99", f"{source}/gpu")

    # `frame_ms` is the measured CPU frame duration. The LOD-only category is
    # retained in the source artifacts for attribution, but includes candidate
    # preparation that intentionally trades CPU setup for indirect submission.
    cpu_p95 = require_positive_number(cpu, "frame_ms.p95", f"{source}/cpu")
    cpu_p99 = require_positive_number(cpu, "frame_ms.p99", f"{source}/cpu")
    gpu_p95 = require_positive_number(gpu, "frame_ms.p95", f"{source}/gpu")
    gpu_p99 = require_positive_number(gpu, "frame_ms.p99", f"{source}/gpu")
    cpu_total_gpu_p99 = require_positive_number(cpu, "gpu_ms.total.p99", f"{source}/cpu")
    gpu_total_gpu_p99 = require_positive_number(gpu, "gpu_ms.total.p99", f"{source}/gpu")
    cpu_draw_calls = require_positive_number(cpu, "draw_calls_avg", f"{source}/cpu")
    gpu_draw_calls = require_positive_number(gpu, "draw_calls_avg", f"{source}/gpu")
    p95_improvement = (cpu_p95 - gpu_p95) / cpu_p95
    p99_regression = (gpu_p99 - cpu_p99) / cpu_p99
    total_gpu_p99_regression = (gpu_total_gpu_p99 - cpu_total_gpu_p99) / cpu_total_gpu_p99
    if p95_improvement < GPU_CULLING_CPU_P95_IMPROVEMENT:
        raise ValueError(f"{source}: CPU frame p95 improvement {p95_improvement:.2%} is below {GPU_CULLING_CPU_P95_IMPROVEMENT:.0%}")
    if p99_regression > GPU_CULLING_CPU_P99_REGRESSION:
        raise ValueError(f"{source}: CPU frame p99 regression {p99_regression:.2%} exceeds {GPU_CULLING_CPU_P99_REGRESSION:.0%}")
    if total_gpu_p99_regression > GPU_CULLING_TOTAL_GPU_P99_REGRESSION:
        raise ValueError(f"{source}: total GPU p99 regression {total_gpu_p99_regression:.2%} exceeds {GPU_CULLING_TOTAL_GPU_P99_REGRESSION:.0%}")
    return {
        "cpu_frame_ms": {"cpu": {"p95": cpu_p95, "p99": cpu_p99}, "gpu": {"p95": gpu_p95, "p99": gpu_p99}, "p95_improvement_fraction": p95_improvement, "p99_regression_fraction": p99_regression},
        "gpu_total_ms": {"cpu": {"p99": cpu_total_gpu_p99}, "gpu": {"p99": gpu_total_gpu_p99}, "p99_regression_fraction": total_gpu_p99_regression},
        "draw_calls": {"cpu": cpu_draw_calls, "gpu": gpu_draw_calls, "delta": gpu_draw_calls - cpu_draw_calls},
        "gpu_culling": {"fixture": GPU_CULLING_FIXTURE, "horizon_distance": horizon_distance, "lod_memory_budget_mb": memory_budget, "readiness_target": readiness_target, "threshold": threshold, "candidate_count_total": candidate_total, "candidate_count_max": candidate_max, "draw_submission_count_total": draw_submissions, "validation_generation": generation, "validation_completed_generation": completed_generation, "validation_completed_count": completed_count, "timestamp_ms": {key: require(gpu, f"gpu_ms.lod_culling.{key}", f"{source}/gpu") for key in ("p50", "p95", "p99")}},
    }


def assemble_gpu_culling(cpu_path: Path, gpu_path: Path, output: Path, overwrite: bool) -> None:
    if output.exists() and not overwrite:
        raise ValueError(f"refusing to overwrite {output}; pass --overwrite")
    cpu, gpu = load(cpu_path), load(gpu_path)
    comparison = culling_comparison(cpu, gpu, "GPU culling pair")
    artifact = {
        "schema_version": SCHEMA_VERSION,
        "artifact_type": "gpu-culling-baseline",
        "status": "ready",
        "generated": True,
        "policy": {"fixture": GPU_CULLING_FIXTURE, "minimum_duration_s": GPU_CULLING_MIN_DURATION_S, "minimum_horizon_distance_chunks": GPU_CULLING_MIN_HORIZON_DISTANCE, "minimum_readiness_target": GPU_CULLING_MIN_READINESS_TARGET, "cpu_frame_p95_improvement_min_fraction": GPU_CULLING_CPU_P95_IMPROVEMENT, "cpu_frame_p99_regression_max_fraction": GPU_CULLING_CPU_P99_REGRESSION, "total_gpu_p99_regression_max_fraction": GPU_CULLING_TOTAL_GPU_P99_REGRESSION},
        "sources": {"cpu": cpu, "gpu": gpu},
        "comparison": comparison,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(artifact, indent=2) + "\n", encoding="utf-8")


def validate_gpu_culling_baseline(path: Path, allow_insufficient: bool) -> None:
    artifact = load(path)
    if artifact.get("status") == "insufficient":
        if allow_insufficient:
            return
        raise ValueError(f"{path}: GPU culling baseline is insufficient: {artifact.get('reason', 'no reason supplied')}")
    if artifact.get("schema_version") != SCHEMA_VERSION or artifact.get("artifact_type") != "gpu-culling-baseline" or artifact.get("status") != "ready":
        raise ValueError(f"{path}: not a ready schema-v{SCHEMA_VERSION} GPU culling baseline")
    expected_policy = {"fixture": GPU_CULLING_FIXTURE, "minimum_duration_s": GPU_CULLING_MIN_DURATION_S, "minimum_horizon_distance_chunks": GPU_CULLING_MIN_HORIZON_DISTANCE, "minimum_readiness_target": GPU_CULLING_MIN_READINESS_TARGET, "cpu_frame_p95_improvement_min_fraction": GPU_CULLING_CPU_P95_IMPROVEMENT, "cpu_frame_p99_regression_max_fraction": GPU_CULLING_CPU_P99_REGRESSION, "total_gpu_p99_regression_max_fraction": GPU_CULLING_TOTAL_GPU_P99_REGRESSION}
    if require(artifact, "policy", str(path)) != expected_policy:
        raise ValueError(f"{path}: GPU culling policy differs from the checked gate")
    actual = culling_comparison(require(artifact, "sources.cpu", str(path)), require(artifact, "sources.gpu", str(path)), str(path))
    if require(artifact, "comparison", str(path)) != actual:
        raise ValueError(f"{path}: stored GPU culling comparison does not match full source artifacts")


def compatibility(baseline_path: Path, result_path: Path, preset: str, scenario: str) -> None:
    validate_baseline(baseline_path, False)
    result = load(result_path)
    validate_compact_result(result, str(result_path))
    if result.get("compact_mode") != "auto":
        raise ValueError(f"{result_path}: regression comparison requires intended auto compact evidence")
    baseline = load(baseline_path)
    expected = require(baseline, f"results.{preset}.{scenario}", str(baseline_path))
    if result.get("preset") != preset or result.get("scenario") != scenario:
        raise ValueError(f"{result_path}: does not match requested {preset}/{scenario}")
    require_compatible(result, expected, RESULT_COMPATIBILITY_PATHS, "benchmark provenance")


def self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        template: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION, "artifact_type": "benchmark-result", "preset": "low", "scenario": "stationary", "world_seed": 1,
            "duration_s": 5, "horizon_distance": 512,
            "build": {"mode": "ReleaseFast", "world": "overworld", "fixture": "", "headless": True, "resolution": [1920, 1080], "horizon_distance": 512, "benchmark_lod_memory_budget_mb": 0, "benchmark_require_gpu_candidates": 0},
            "provenance": {"gpu_adapter": "Lavapipe", "gpu_driver": "Mesa pinned by Nix", "runner": "test runner", "zig_toolchain": "Zig 0.16.0"},
            "completion": {"scenario_completed": True, "warmup_ready": True, "warmup_timed_out": False, "compact_ready": True, "evidence_mode": True, "sampled_duration_s": 5, "requested_duration_s": 5, "sampled_frame_count": 1, "lod_renderable_region_target": 0, "gpu_candidate_target": 0},
            "startup_evidence": {"readiness_observed": True, "readiness_elapsed_s": 2, "upload_total_bytes": 100, "far_expanded_upload_bytes": 100, "compact_upload_bytes": 0, "worker_generation_total_ms": 2, "worker_mesh_construction_total_ms": 10, "worker_far_expanded_mesh_construction_ms": 10, "worker_compact_encode_ms": 0, "compact_submissions": 0, "pool_gpu_allocated_bytes": 5000, "direct_mesh_gpu_bytes": 1000, "compact_pool_allocated_bytes": 0, "pool_cpu_shadow_bytes": 1000, "lod_renderable_regions": 0, "gpu_culling_candidate_count": 0},
            "gpu_ms": {"total": {"p95": 1, "p99": 1}}, "draw_calls_avg": 10, "lod": {"profiling_enabled": True, "profiling_frame_count": 1, "cpu_frame_ms": {"p95": 1, "p99": 1}, "gpu_frame_ms": {"p95": 1, "p99": 1}, "memory_bytes": {"logical_ram_bytes": {"p50_bytes": 1, "p95_bytes": 1, "p99_bytes": 1, "max_bytes": 1}, "logical_vram_bytes": {"p50_bytes": 1, "p95_bytes": 1, "p99_bytes": 1, "max_bytes": 1}}, "pressure": {"wait_idle_count_total": 0, "gpu_culling_overflows_max": 0, "gpu_culling_validation_mismatches_max": 0}},
        }
        for mode in ("off", "auto"):
            for preset in PRESETS:
                for scenario in SCENARIOS:
                    value = json.loads(json.dumps(template)); value["preset"] = preset; value["scenario"] = scenario; value["compact_mode"] = mode
                    if mode == "auto":
                        value["startup_evidence"].update({"compact_submissions": 2, "pool_gpu_allocated_bytes": 9000, "direct_mesh_gpu_bytes": 0, "compact_pool_allocated_bytes": 800, "far_expanded_upload_bytes": 0, "compact_upload_bytes": 80, "worker_far_expanded_mesh_construction_ms": 0, "worker_compact_encode_ms": 8, "pool_cpu_shadow_bytes": 2000})
                    path = root / mode / preset / f"{scenario}.json"; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(json.dumps(value), encoding="utf-8")
        validate_compact_matrix(root)
        output = root / "baseline.json"; assemble([root], output, False); validate_baseline(output, False)
        compatibility(output, root / "auto" / "low" / "stationary.json", "low", "stationary")
        # Near-pool and CPU-shadow changes are contextual only, whereas far
        # representation evidence remains an acceptance requirement.
        assert validate_pair(load(root / "off" / "low" / "stationary.json"), load(root / "auto" / "low" / "stationary.json"), "self-test")["near_pool_geometry"]["delta"] == 4000
        assert required_reduction(0, 1, "self-test")["status"] == "not-applicable-off-zero"
        try:
            required_reduction(100, 90, "self-test")
        except ValueError:
            pass
        else:
            raise AssertionError("insufficient far reduction accepted")
        cpu = load(root / "auto" / "high" / "traversal.json")
        gpu = json.loads(json.dumps(cpu))
        cpu["lod"].update({"cpu_frame_ms": {"p95": 0.9670, "p99": 1.3290}, "gpu_culling": {"requested": False, "threshold": 1, "candidate_count_total": 0, "candidate_count_max": 0, "draw_submission_count_total": 0, "validation_generation": 0, "validation_completed_generation": 0, "validation_completed_count": 0}})
        cpu["frame_ms"] = {"p95": 1.0, "p99": 2.0}
        cpu["gpu_ms"]["total"]["p99"] = 2.0
        gpu["lod"].update({"cpu_frame_ms": {"p95": 0.9251, "p99": 1.2137}, "gpu_culling": {"requested": True, "threshold": 1, "candidate_count_total": 1000, "candidate_count_max": GPU_CULLING_MIN_READINESS_TARGET, "draw_submission_count_total": 20, "validation_generation": 10, "validation_completed_generation": 9, "validation_completed_count": 9}})
        gpu["frame_ms"] = {"p95": 0.98, "p99": 2.01}
        gpu["gpu_ms"]["total"]["p99"] = 2.01
        gpu["gpu_ms"]["lod_culling"] = {"avg": 0.01, "p50": 0.01, "p95": 0.02, "p99": 0.03}
        for value in (cpu, gpu):
            value["duration_s"] = 60
            value["horizon_distance"] = GPU_CULLING_MIN_HORIZON_DISTANCE
            value["build"]["horizon_distance"] = GPU_CULLING_MIN_HORIZON_DISTANCE
            value["build"].update({"benchmark_lod_memory_budget_mb": 2048, "benchmark_require_gpu_candidates": GPU_CULLING_MIN_READINESS_TARGET})
            value["build"]["fixture"] = GPU_CULLING_FIXTURE
            value["completion"].update({"sampled_duration_s": 60, "requested_duration_s": 60, "lod_renderable_region_target": GPU_CULLING_MIN_READINESS_TARGET, "gpu_candidate_target": GPU_CULLING_MIN_READINESS_TARGET})
            value["startup_evidence"]["lod_renderable_regions"] = GPU_CULLING_MIN_READINESS_TARGET
        cpu_path, gpu_path = root / "cpu.json", root / "gpu.json"
        cpu_path.write_text(json.dumps(cpu), encoding="utf-8")
        gpu_path.write_text(json.dumps(gpu), encoding="utf-8")
        culling_output = root / "gpu-culling.json"
        assemble_gpu_culling(cpu_path, gpu_path, culling_output, False)
        validate_gpu_culling_baseline(culling_output, False)
        cpu["build"]["fixture"] = ""
        try:
            culling_comparison(cpu, gpu, "self-test")
        except ValueError:
            pass
        else:
            raise AssertionError("GPU culling baseline accepted a non-scale fixture")
        cpu["build"]["fixture"] = GPU_CULLING_FIXTURE
        gpu["frame_ms"]["p95"] = 0.995
        try:
            culling_comparison(cpu, gpu, "self-test")
        except ValueError:
            pass
        else:
            raise AssertionError("insufficient GPU culling p95 improvement accepted")
        gpu["frame_ms"]["p95"] = 0.98
        for value in (cpu, gpu): value["build"]["horizon_distance"] = GPU_CULLING_MIN_HORIZON_DISTANCE - 1
        try:
            culling_comparison(cpu, gpu, "self-test")
        except ValueError:
            pass
        else:
            raise AssertionError("small GPU culling horizon accepted")
        for value in (cpu, gpu):
            value["build"]["horizon_distance"] = GPU_CULLING_MIN_HORIZON_DISTANCE
            value["preset"] = "extreme"
        culling_comparison(cpu, gpu, "self-test")
        try:
            invalid_provenance = load(root / "off" / "low" / "stationary.json")
            invalid_provenance["provenance"]["gpu_adapter"] = "unknown"
            validate_compact_result(invalid_provenance)
        except ValueError:
            return
        raise AssertionError("unknown evidence provenance accepted")


def main() -> None:
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="command", required=True)
    assemble_parser = sub.add_parser("assemble"); assemble_parser.add_argument("--output", type=Path, required=True); assemble_parser.add_argument("--overwrite", action="store_true"); assemble_parser.add_argument("inputs", nargs="+", type=Path)
    validate_parser = sub.add_parser("validate"); validate_parser.add_argument("path", type=Path); validate_parser.add_argument("--allow-insufficient", action="store_true")
    result_parser = sub.add_parser("validate-result"); result_parser.add_argument("path", type=Path)
    stamp_parser = sub.add_parser("stamp-compact"); stamp_parser.add_argument("path", type=Path); stamp_parser.add_argument("mode")
    matrix_parser = sub.add_parser("validate-compact-matrix"); matrix_parser.add_argument("root", type=Path)
    compatibility_parser = sub.add_parser("compatibility"); compatibility_parser.add_argument("baseline", type=Path); compatibility_parser.add_argument("result", type=Path); compatibility_parser.add_argument("--preset", required=True); compatibility_parser.add_argument("--scenario", required=True)
    assemble_culling_parser = sub.add_parser("assemble-gpu-culling"); assemble_culling_parser.add_argument("--output", type=Path, required=True); assemble_culling_parser.add_argument("--overwrite", action="store_true"); assemble_culling_parser.add_argument("cpu", type=Path); assemble_culling_parser.add_argument("gpu", type=Path)
    validate_culling_parser = sub.add_parser("validate-gpu-culling"); validate_culling_parser.add_argument("path", type=Path); validate_culling_parser.add_argument("--allow-insufficient", action="store_true")
    sub.add_parser("self-test"); args = parser.parse_args()
    if args.command == "assemble": assemble(args.inputs, args.output, args.overwrite)
    elif args.command == "validate": validate_baseline(args.path, args.allow_insufficient)
    elif args.command == "validate-result": validate_result(load(args.path), str(args.path))
    elif args.command == "stamp-compact": stamp_compact(args.path, args.mode)
    elif args.command == "validate-compact-matrix": validate_compact_matrix(args.root)
    elif args.command == "compatibility": compatibility(args.baseline, args.result, args.preset, args.scenario)
    elif args.command == "assemble-gpu-culling": assemble_gpu_culling(args.cpu, args.gpu, args.output, args.overwrite)
    elif args.command == "validate-gpu-culling": validate_gpu_culling_baseline(args.path, args.allow_insufficient)
    else: self_test()


if __name__ == "__main__":
    try: main()
    except (ValueError, OSError, json.JSONDecodeError) as error: raise SystemExit(f"benchmark baseline validation failed: {error}")
