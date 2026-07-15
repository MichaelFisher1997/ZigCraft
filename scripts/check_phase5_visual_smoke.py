#!/usr/bin/env python3
"""Validate deterministic Phase 5 visual-capture evidence without a golden.

The gate is intentionally tolerant of small Vulkan-driver differences, but it
rejects empty images, unhealthy regions, scene-scale compact divergence, and
missing runtime evidence for the compact/water/handoff paths.
"""

import argparse
import json
import os
import re
import struct
import sys
import tempfile
import zlib


MOTION_SCENE_KINDS = {
    "lod-handoff-traversal": "traversal",
    "fog-rapid-turn": "rapid-turn",
    "teleport-handoff": "teleport",
}
GPU_VALIDATION_SCENES = {"lod-handoff", "saved-world-reload", *MOTION_SCENE_KINDS}


def read_png(path):
    with open(path, "rb") as source:
        data = source.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")

    offset = 8
    chunks = []
    width = height = color_type = bit_depth = None
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        if len(payload) != length:
            raise ValueError("truncated PNG chunk")
        offset += length + 12
        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if (bit_depth, color_type, compression, filtering, interlace) != (8, 2, 0, 0, 0):
                raise ValueError("expected non-interlaced 8-bit RGB PNG")
        elif kind == b"IDAT":
            chunks.append(payload)
        elif kind == b"IEND":
            break
    if not width or not height or not chunks:
        raise ValueError("missing PNG image data")

    raw = zlib.decompress(b"".join(chunks))
    stride = width * 3
    if len(raw) != height * (stride + 1):
        raise ValueError("unexpected PNG scanline size")
    rows = []
    previous = bytearray(stride)
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        current = bytearray(raw[cursor:cursor + stride])
        cursor += stride
        for index in range(stride):
            left = current[index - 3] if index >= 3 else 0
            above = previous[index]
            upper_left = previous[index - 3] if index >= 3 else 0
            if filter_type == 1:
                current[index] = (current[index] + left) & 0xff
            elif filter_type == 2:
                current[index] = (current[index] + above) & 0xff
            elif filter_type == 3:
                current[index] = (current[index] + ((left + above) // 2)) & 0xff
            elif filter_type == 4:
                p = left + above - upper_left
                pa, pb, pc = abs(p - left), abs(p - above), abs(p - upper_left)
                predictor = left if pa <= pb and pa <= pc else (above if pb <= pc else upper_left)
                current[index] = (current[index] + predictor) & 0xff
            elif filter_type != 0:
                raise ValueError("unsupported PNG filter")
        rows.append(bytes(current))
        previous = current
    return width, height, rows


def sampled_rgb(image, sample_width=128, sample_height=72, roi=None):
    width, height, rows = image
    if roi is None:
        roi = (0.0, 0.0, 1.0, 1.0)
    left, top, roi_width, roi_height = roi
    samples = []
    for y in range(sample_height):
        source_y = min(height - 1, int((top + (y + 0.5) * roi_height / sample_height) * height))
        row = rows[source_y]
        for x in range(sample_width):
            source_x = min(width - 1, int((left + (x + 0.5) * roi_width / sample_width) * width))
            offset = source_x * 3
            samples.append((row[offset], row[offset + 1], row[offset + 2]))
    return samples


def image_metrics(image):
    samples = sampled_rgb(image)
    luma = sorted((54 * red + 183 * green + 19 * blue) // 256 for red, green, blue in samples)
    luma_bins = {value // 16 for value in luma}
    non_black = sum(value > 12 for value in luma) / len(luma)
    p05 = luma[len(luma) * 5 // 100]
    p95 = luma[len(luma) * 95 // 100]
    p01 = luma[len(luma) // 100]
    p99 = luma[len(luma) * 99 // 100]
    mean = sum(luma) / len(luma)
    saturated = sum(max(pixel) - min(pixel) >= 24 for pixel in samples) / len(samples)
    return {
        "width": image[0],
        "height": image[1],
        "mean_luma": round(mean, 3),
        "p05_luma": p05,
        "p95_luma": p95,
        "luma_range_p05_p95": p95 - p05,
        "luma_range_p01_p99": p99 - p01,
        "luma_bin_count": len(luma_bins),
        "non_black_fraction": round(non_black, 5),
        "saturated_fraction": round(saturated, 5),
    }


def normalized_mae(first, second, roi=None):
    first_samples = sampled_rgb(first, roi=roi)
    second_samples = sampled_rgb(second, roi=roi)
    return sum(abs(a - b) for first_pixel, second_pixel in zip(first_samples, second_samples) for a, b in zip(first_pixel, second_pixel)) / (len(first_samples) * 3 * 255)


def require_healthy(name, image, metrics):
    if metrics["non_black_fraction"] < float(os.environ.get("PHASE5_VISUAL_MIN_NON_BLACK", "0.12")):
        raise ValueError(f"{name} is black or nearly black")
    if metrics["luma_range_p01_p99"] < int(os.environ.get("PHASE5_VISUAL_MIN_LUMA_RANGE", "22")):
        raise ValueError(f"{name} has insufficient image variation")
    if metrics["luma_bin_count"] < int(os.environ.get("PHASE5_VISUAL_MIN_LUMA_BINS", "5")):
        raise ValueError(f"{name} is visually empty")
    if metrics["saturated_fraction"] < float(os.environ.get("PHASE5_VISUAL_MIN_SATURATED", "0.01")):
        raise ValueError(f"{name} has no material or sky colour")

    # A central ROI catches a valid sky clear paired with missing terrain, and
    # a lower ROI catches a presentation path that only clears the top half.
    for roi_name, roi in (("central", (0.20, 0.20, 0.60, 0.60)), ("lower", (0.10, 0.55, 0.80, 0.40))):
        roi_metrics = image_metrics_from_samples(sampled_rgb(image, roi=roi))
        if roi_metrics["non_black_fraction"] < 0.10 or roi_metrics["luma_range_p01_p99"] < 10:
            raise ValueError(f"{name} has an unhealthy {roi_name} ROI")


def image_metrics_from_samples(samples):
    luma = sorted((54 * red + 183 * green + 19 * blue) // 256 for red, green, blue in samples)
    return {
        "non_black_fraction": sum(value > 12 for value in luma) / len(luma),
        "luma_range_p01_p99": luma[len(luma) * 99 // 100] - luma[len(luma) // 100],
    }


def parse_evidence(path, scene, run_id):
    with open(path, encoding="utf-8", errors="replace") as source:
        log = source.read()
    escaped_run = re.escape(run_id)
    captures = re.findall(rf"PHASE5_CAPTURE: run={escaped_run} scene=([^ ]+) chunks_rendered=([0-9]+) compact_allocated=([0-9]+) compact_submissions=([0-9]+)", log)
    matching = [(int(chunks), int(allocated), int(submissions)) for name, chunks, allocated, submissions in captures if name == scene]
    return {
        "compact_allocated_bytes": max((allocated for _, allocated, _ in matching), default=0),
        "compact_submissions": max((submissions for _, _, submissions in matching), default=0),
        "capture_counters": matching,
        "fixture_applied": bool(re.search(rf"PHASE5_FIXTURE: run={escaped_run} scene={re.escape(scene)} applied=1", log)),
        "settled": bool(re.search(rf"PHASE5_READY: run={escaped_run} scene={re.escape(scene)} stable_frames=[1-9][0-9]*", log)),
        "water_fixture_observations": max((int(value) for value in re.findall(rf"PHASE5_WATER_FIXTURE: run={escaped_run} scene={re.escape(scene)} observations=([0-9]+)", log)), default=0),
        "gpu_culling": [
            {"candidates": int(candidates), "validation_mismatches": int(mismatches), "overflows": int(overflows)}
            for candidates, mismatches, overflows in re.findall(rf"PHASE5_GPU_CULLING: run={escaped_run} scene={re.escape(scene)} candidates=([0-9]+) validation_mismatches=([0-9]+) overflows=([0-9]+)", log)
        ],
        "gpu_validation_complete": [
            {"generation": int(generation), "validations": int(validations), "validation_mismatches": int(mismatches)}
            for generation, validations, mismatches in re.findall(rf"PHASE5_GPU_VALIDATION_COMPLETE: run={escaped_run} scene={re.escape(scene)} generation=([1-9][0-9]*) validations=([1-9][0-9]*) validation_mismatches=([0-9]+)", log)
        ],
        "motion": [
            {
                "kind": kind,
                "frames": int(frames),
                "distance": float(distance),
                "yaw_degrees": float(yaw_degrees),
            }
            for kind, frames, distance, yaw_degrees in re.findall(rf"PHASE5_MOTION: run={escaped_run} scene={re.escape(scene)} kind=([^ ]+) completed=1 frames=([1-9][0-9]*) distance=([0-9]+(?:\.[0-9]+)?) yaw_degrees=([0-9]+(?:\.[0-9]+)?)", log)
        ],
        "save_flushed": bool(re.search(rf"PHASE5_SAVE_FLUSH: run={escaped_run} scene=saved-world-create saved=1 failures=0", log)),
        "save_loaded": [
            {"wet_cells": int(wet_cells), "dry_cells": int(dry_cells)}
            for wet_cells, dry_cells in re.findall(rf"PHASE5_SAVE_LOADED: run={escaped_run} scene=saved-world-reload wet_cells=([1-9][0-9]*) dry_cells=([1-9][0-9]*)", log)
        ],
        "compact_wet_dry": [
            {
                "dry_compact_bytes": int(dry_compact),
                "wet_fallback_bytes": int(wet_fallback),
                "wet_cells": int(wet_cells),
                "dry_cells": int(dry_cells),
            }
            for dry_compact, wet_fallback, wet_cells, dry_cells in re.findall(rf"PHASE5_COMPACT_WET_DRY: run={escaped_run} scene=saved-world-reload dry_compact_bytes=([0-9]+) wet_fallback_bytes=([0-9]+) wet_cells=([0-9]+) dry_cells=([0-9]+)", log)
        ],
    }


def require_capture_evidence(name, evidence):
    if evidence["compact_allocated_bytes"] <= 0:
        raise ValueError(f"{name}: compact-auto capture did not allocate compact residency")
    if not evidence["fixture_applied"]:
        raise ValueError(f"{name}: production-world fixture was never applied")
    if not evidence["settled"]:
        raise ValueError(f"{name}: fixture/LOD queues never reached consecutive-frame readiness")
    if not evidence["capture_counters"]:
        raise ValueError(f"{name}: missing Phase 5 capture counters")
    if max(chunks for chunks, _, _ in evidence["capture_counters"]) <= 0:
        raise ValueError(f"{name}: no full-detail chunks were rendered")
    if max(allocated for _, allocated, _ in evidence["capture_counters"]) <= 0:
        raise ValueError(f"{name}: compact allocation was not present at capture")
    if evidence["compact_submissions"] <= 0:
        raise ValueError(f"{name}: compact-auto capture made no compact submission")
    if name == "water":
        if evidence["water_fixture_observations"] <= 0:
            raise ValueError("water: deterministic water fixture was never resident")
    if name in GPU_VALIDATION_SCENES:
        if not evidence["gpu_culling"]:
            raise ValueError(f"{name}: GPU culling never activated")
        if max(gpu["candidates"] for gpu in evidence["gpu_culling"]) <= 0:
            raise ValueError(f"{name}: GPU culling submitted no candidates")
        if any(gpu["validation_mismatches"] != 0 for gpu in evidence["gpu_culling"]):
            raise ValueError(f"{name}: GPU culling validation reported mismatches")
        if any(gpu["overflows"] != 0 for gpu in evidence["gpu_culling"]):
            raise ValueError(f"{name}: GPU culling reported overflows")
        if not evidence["gpu_validation_complete"]:
            raise ValueError(f"{name}: delayed GPU validation readback never completed")
        if any(validation["validations"] <= 0 for validation in evidence["gpu_validation_complete"]):
            raise ValueError(f"{name}: delayed GPU validation readback has no completed validations")
        if any(validation["validation_mismatches"] != 0 for validation in evidence["gpu_validation_complete"]):
            raise ValueError(f"{name}: completed GPU validation readback reported mismatches")
    if name in MOTION_SCENE_KINDS:
        motions = evidence["motion"]
        if not motions:
            raise ValueError(f"{name}: deterministic motion never completed")
        motion = motions[-1]
        if motion["kind"] != MOTION_SCENE_KINDS[name]:
            raise ValueError(f"{name}: incorrect motion evidence kind")
        if motion["frames"] <= 0:
            raise ValueError(f"{name}: motion evidence has no frames")
        if name == "fog-rapid-turn":
            if motion["yaw_degrees"] <= 0:
                raise ValueError(f"{name}: turn evidence has no yaw change")
        elif motion["distance"] <= 0:
            raise ValueError(f"{name}: movement evidence has no displacement")


def check_scene(name, off_path, force_path, force_log, run_id):
    off = read_png(off_path)
    force = read_png(force_path)
    if off[:2] != force[:2]:
        raise ValueError(f"{name}: capture dimensions differ: {off[:2]} vs {force[:2]}")
    off_metrics = image_metrics(off)
    force_metrics = image_metrics(force)
    require_healthy(f"{name} expanded capture", off, off_metrics)
    require_healthy(f"{name} compact-auto capture", force, force_metrics)

    full_difference = normalized_mae(off, force)
    # Horizon and foreground ROIs make a partially blank compact stream fail
    # even when its whole-frame average is hidden by a large sky clear.
    roi_differences = {
        "horizon": normalized_mae(off, force, (0.05, 0.20, 0.90, 0.35)),
        "foreground": normalized_mae(off, force, (0.10, 0.50, 0.80, 0.45)),
    }
    max_difference = float(os.environ.get("PHASE5_VISUAL_MAX_NMAE", "0.32"))
    max_roi_difference = float(os.environ.get("PHASE5_VISUAL_MAX_ROI_NMAE", "0.38"))
    if full_difference > max_difference:
        raise ValueError(f"{name}: compact-auto image diverges from expanded fallback ({full_difference:.3f})")
    if max(roi_differences.values()) > max_roi_difference:
        raise ValueError(f"{name}: a compact comparison ROI diverges grossly")

    evidence = parse_evidence(force_log, name, run_id)
    require_capture_evidence(name, evidence)
    if name == "water":
        # The lower-center water fixture must contribute colour, not merely be
        # generated off camera. This ROI intentionally permits lighting/texture
        # variation while rejecting a flat clear or missing fluid pass.
        water_metrics = image_metrics_from_samples(sampled_rgb(force, roi=(0.20, 0.35, 0.60, 0.60)))
        if water_metrics["non_black_fraction"] < 0.20 or water_metrics["luma_range_p01_p99"] < 14:
            raise ValueError("water: fixture ROI does not contain a healthy rendered surface")
    return {
        "expanded": off_metrics,
        "compact_auto": force_metrics,
        "normalized_mae": round(full_difference, 6),
        "roi_normalized_mae": {key: round(value, 6) for key, value in roi_differences.items()},
        "evidence": evidence,
    }


def check_handoff(path, log_path, run_id):
    image = read_png(path)
    metrics = image_metrics(image)
    require_healthy("lod-handoff compact-auto capture", image, metrics)
    evidence = parse_evidence(log_path, "lod-handoff", run_id)
    require_capture_evidence("lod-handoff", evidence)
    return {"compact_auto": metrics, "evidence": evidence}


def check_motion(name, path, log_path, run_id):
    image = read_png(path)
    metrics = image_metrics(image)
    require_healthy(f"{name} compact-auto capture", image, metrics)
    evidence = parse_evidence(log_path, name, run_id)
    require_capture_evidence(name, evidence)
    return {"compact_auto": metrics, "evidence": evidence}


def check_saved_world(create_log_path, reload_path, reload_log_path, run_id):
    image = read_png(reload_path)
    metrics = image_metrics(image)
    require_healthy("saved-world reload compact-auto capture", image, metrics)

    create_evidence = parse_evidence(create_log_path, "saved-world-create", run_id)
    if not create_evidence["save_flushed"]:
        raise ValueError("saved-world: creator did not flush a clean save")

    evidence = parse_evidence(reload_log_path, "saved-world-reload", run_id)
    require_capture_evidence("saved-world-reload", evidence)
    if not evidence["save_loaded"]:
        raise ValueError("saved-world: reload did not prove persisted wet/dry cells")
    if not evidence["compact_wet_dry"]:
        raise ValueError("saved-world: missing compact dry/wet fallback evidence")
    wet_dry = evidence["compact_wet_dry"][-1]
    if wet_dry["dry_compact_bytes"] <= 0:
        raise ValueError("saved-world: dry terrain had no compact residency after reload")
    if wet_dry["wet_fallback_bytes"] <= 0:
        raise ValueError("saved-world: wet shoreline fallback was not retained after reload")
    if wet_dry["wet_cells"] <= 0 or wet_dry["dry_cells"] <= 0:
        raise ValueError("saved-world: wet/dry fixture evidence is empty")
    return {
        "compact_auto": metrics,
        "creator_evidence": create_evidence,
        "evidence": evidence,
    }


def failed_scene_metrics(name, off_path, auto_path, auto_log, run_id, error):
    """Keep the image/evidence record when a strict check rejects a scene."""
    result = {"error": str(error), "evidence": parse_evidence(auto_log, name, run_id)}
    try:
        result["expanded"] = image_metrics(read_png(off_path))
    except (OSError, ValueError, zlib.error) as read_error:
        result["expanded_error"] = str(read_error)
    try:
        result["compact_auto"] = image_metrics(read_png(auto_path))
    except (OSError, ValueError, zlib.error) as read_error:
        result["compact_auto_error"] = str(read_error)
    return result


def write_png(path, pixels, width=32, height=24):
    raw = b"".join(b"\0" + bytes(pixels[y * width * 3:(y + 1) * width * 3]) for y in range(height))
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)
    with open(path, "wb") as output:
        output.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def self_test():
    with tempfile.TemporaryDirectory() as directory:
        good = []
        for y in range(24):
            for x in range(32):
                good.extend((20 + x * 6, 35 + y * 7, 170 - x * 3))
        good_path = os.path.join(directory, "good.png")
        black_path = os.path.join(directory, "black.png")
        write_png(good_path, good)
        write_png(black_path, [0] * len(good))
        require_healthy("self-test", read_png(good_path), image_metrics(read_png(good_path)))
        try:
            require_healthy("black self-test", read_png(black_path), image_metrics(read_png(black_path)))
        except ValueError:
            pass
        else:
            raise AssertionError("black image unexpectedly passed health checks")

        evidence_path = os.path.join(directory, "evidence.log")
        with open(evidence_path, "w", encoding="utf-8") as output:
            output.write("PHASE5_CAPTURE: run=fresh scene=lod-handoff chunks_rendered=1 compact_allocated=64 compact_submissions=1\n")
            output.write("PHASE5_FIXTURE: run=fresh scene=lod-handoff applied=1\n")
            output.write("PHASE5_READY: run=fresh scene=lod-handoff stable_frames=180 chunks_rendered=1 lod_loaded=1\n")
            output.write("PHASE5_GPU_CULLING: run=fresh scene=lod-handoff candidates=1 validation_mismatches=0 overflows=0\n")
            output.write("PHASE5_GPU_VALIDATION_COMPLETE: run=fresh scene=lod-handoff generation=6 validations=5 validation_mismatches=0\n")
        require_capture_evidence("lod-handoff", parse_evidence(evidence_path, "lod-handoff", "fresh"))
        try:
            require_capture_evidence("lod-handoff", parse_evidence(evidence_path, "lod-handoff", "stale"))
        except ValueError:
            pass
        else:
            raise AssertionError("stale evidence unexpectedly passed")
        with open(evidence_path, "w", encoding="utf-8") as output:
            output.write("PHASE5_CAPTURE: run=fresh scene=lod-handoff chunks_rendered=1 compact_allocated=64 compact_submissions=1\n")
            output.write("PHASE5_FIXTURE: run=fresh scene=lod-handoff applied=1\n")
            output.write("PHASE5_READY: run=fresh scene=lod-handoff stable_frames=180 chunks_rendered=1 lod_loaded=1\n")
            output.write("PHASE5_GPU_CULLING: run=fresh scene=lod-handoff candidates=1 validation_mismatches=0 overflows=0\n")
        try:
            require_capture_evidence("lod-handoff", parse_evidence(evidence_path, "lod-handoff", "fresh"))
        except ValueError:
            pass
        else:
            raise AssertionError("missing GPU validation completion unexpectedly passed")

        create_path = os.path.join(directory, "saved-create.log")
        reload_path = os.path.join(directory, "saved-reload.log")
        with open(create_path, "w", encoding="utf-8") as output:
            output.write("PHASE5_SAVE_FLUSH: run=fresh scene=saved-world-create saved=1 failures=0\n")
        with open(reload_path, "w", encoding="utf-8") as output:
            output.write("PHASE5_CAPTURE: run=fresh scene=saved-world-reload chunks_rendered=1 compact_allocated=64 compact_submissions=1\n")
            output.write("PHASE5_FIXTURE: run=fresh scene=saved-world-reload applied=1\n")
            output.write("PHASE5_READY: run=fresh scene=saved-world-reload stable_frames=180 chunks_rendered=1 lod_loaded=1\n")
            output.write("PHASE5_SAVE_LOADED: run=fresh scene=saved-world-reload wet_cells=3 dry_cells=3\n")
            output.write("PHASE5_COMPACT_WET_DRY: run=fresh scene=saved-world-reload dry_compact_bytes=64 wet_fallback_bytes=32 wet_cells=3 dry_cells=3\n")
            output.write("PHASE5_GPU_CULLING: run=fresh scene=saved-world-reload candidates=1 validation_mismatches=0 overflows=0\n")
            output.write("PHASE5_GPU_VALIDATION_COMPLETE: run=fresh scene=saved-world-reload generation=6 validations=5 validation_mismatches=0\n")
        check_saved_world(create_path, good_path, reload_path, "fresh")
        with open(reload_path, "w", encoding="utf-8") as output:
            output.write("PHASE5_CAPTURE: run=fresh scene=saved-world-reload chunks_rendered=1 compact_allocated=64 compact_submissions=1\n")
            output.write("PHASE5_FIXTURE: run=fresh scene=saved-world-reload applied=1\n")
            output.write("PHASE5_READY: run=fresh scene=saved-world-reload stable_frames=180 chunks_rendered=1 lod_loaded=1\n")
            output.write("PHASE5_GPU_CULLING: run=fresh scene=saved-world-reload candidates=1 validation_mismatches=0 overflows=0\n")
            output.write("PHASE5_GPU_VALIDATION_COMPLETE: run=fresh scene=saved-world-reload generation=6 validations=5 validation_mismatches=0\n")
        try:
            check_saved_world(create_path, good_path, reload_path, "fresh")
        except ValueError:
            pass
        else:
            raise AssertionError("missing saved-world reload evidence unexpectedly passed")

        with open(evidence_path, "w", encoding="utf-8") as output:
            output.write("PHASE5_CAPTURE: run=fresh scene=fog-rapid-turn chunks_rendered=1 compact_allocated=64 compact_submissions=1\n")
            output.write("PHASE5_FIXTURE: run=fresh scene=fog-rapid-turn applied=1\n")
            output.write("PHASE5_MOTION: run=fresh scene=fog-rapid-turn kind=rapid-turn completed=1 frames=160 distance=0.0 yaw_degrees=720.0\n")
            output.write("PHASE5_READY: run=fresh scene=fog-rapid-turn stable_frames=180 chunks_rendered=1 lod_loaded=1\n")
            output.write("PHASE5_GPU_CULLING: run=fresh scene=fog-rapid-turn candidates=1 validation_mismatches=0 overflows=0\n")
            output.write("PHASE5_GPU_VALIDATION_COMPLETE: run=fresh scene=fog-rapid-turn generation=6 validations=5 validation_mismatches=0\n")
        check_motion("fog-rapid-turn", good_path, evidence_path, "fresh")
        overflow_evidence = parse_evidence(evidence_path, "fog-rapid-turn", "fresh")
        overflow_evidence["gpu_culling"][0]["overflows"] = 1
        try:
            require_capture_evidence("fog-rapid-turn", overflow_evidence)
        except ValueError:
            pass
        else:
            raise AssertionError("GPU culling overflow unexpectedly passed")
        try:
            check_motion("teleport-handoff", good_path, evidence_path, "fresh")
        except ValueError:
            pass
        else:
            raise AssertionError("cross-scene motion evidence unexpectedly passed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest")
    parser.add_argument("--run-id")
    parser.add_argument("--scene", action="append", nargs=4, metavar=("NAME", "EXPANDED_PNG", "COMPACT_PNG", "COMPACT_LOG"))
    parser.add_argument("--handoff", nargs=2, metavar=("COMPACT_PNG", "COMPACT_LOG"))
    parser.add_argument("--motion", action="append", nargs=3, metavar=("NAME", "COMPACT_PNG", "COMPACT_LOG"))
    parser.add_argument("--saved-world", nargs=3, metavar=("CREATE_LOG", "RELOAD_PNG", "RELOAD_LOG"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("Phase 5 visual checker self-test passed")
        return
    if not args.manifest or not args.run_id or (not args.scene and not args.handoff and not args.motion and not args.saved_world):
        parser.error("--run-id, --manifest, and at least one --scene, --handoff, --motion, or --saved-world are required")

    metrics = {"scenes": {}, "scene_distances": {}, "thresholds": {"max_normalized_mae": float(os.environ.get("PHASE5_VISUAL_MAX_NMAE", "0.32")), "max_roi_normalized_mae": float(os.environ.get("PHASE5_VISUAL_MAX_ROI_NMAE", "0.38")), "min_scene_normalized_mae": float(os.environ.get("PHASE5_VISUAL_MIN_SCENE_NMAE", "0.015"))}}
    try:
        expanded_images = {}
        for scene in args.scene or []:
            name, off_path, force_path, force_log = scene
            try:
                metrics["scenes"][name] = check_scene(name, off_path, force_path, force_log, args.run_id)
            except (OSError, ValueError, zlib.error) as error:
                metrics["scenes"][name] = failed_scene_metrics(name, off_path, force_path, force_log, args.run_id, error)
                raise
            expanded_images[name] = read_png(off_path)
        if args.handoff:
            handoff_path, handoff_log = args.handoff
            try:
                metrics["scenes"]["lod-handoff"] = check_handoff(handoff_path, handoff_log, args.run_id)
            except (OSError, ValueError, zlib.error) as error:
                metrics["scenes"]["lod-handoff"] = failed_scene_metrics("lod-handoff", handoff_path, handoff_path, handoff_log, args.run_id, error)
                raise
        for motion in args.motion or []:
            name, motion_path, motion_log = motion
            if name not in MOTION_SCENE_KINDS:
                raise ValueError(f"unknown Phase 5 motion scene: {name}")
            try:
                metrics["scenes"][name] = check_motion(name, motion_path, motion_log, args.run_id)
            except (OSError, ValueError, zlib.error) as error:
                metrics["scenes"][name] = failed_scene_metrics(name, motion_path, motion_path, motion_log, args.run_id, error)
                raise
        if args.saved_world:
            create_log, reload_path, reload_log = args.saved_world
            try:
                metrics["scenes"]["saved-world-reload"] = check_saved_world(create_log, reload_path, reload_log, args.run_id)
            except (OSError, ValueError, zlib.error) as error:
                metrics["scenes"]["saved-world-reload"] = {
                    "error": str(error),
                    "creator_evidence": parse_evidence(create_log, "saved-world-create", args.run_id),
                    "evidence": parse_evidence(reload_log, "saved-world-reload", args.run_id),
                }
                try:
                    metrics["scenes"]["saved-world-reload"]["compact_auto"] = image_metrics(read_png(reload_path))
                except (OSError, ValueError, zlib.error) as read_error:
                    metrics["scenes"]["saved-world-reload"]["compact_auto_error"] = str(read_error)
                raise
        names = sorted(expanded_images)
        for first_index, first_name in enumerate(names):
            for second_name in names[first_index + 1:]:
                distance = normalized_mae(expanded_images[first_name], expanded_images[second_name])
                metrics["scene_distances"][f"{first_name}:{second_name}"] = round(distance, 6)
                if distance < metrics["thresholds"]["min_scene_normalized_mae"]:
                    raise ValueError(f"{first_name} and {second_name} are unexpectedly the same scene")
    finally:
        # Preserve diagnostics and parsed evidence on failure for CI artifacts.
        with open(args.manifest, "w", encoding="utf-8") as output:
            json.dump(metrics, output, indent=2, sort_keys=True)
            output.write("\n")
    print(json.dumps(metrics, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zlib.error) as error:
        print(f"Phase 5 visual smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
