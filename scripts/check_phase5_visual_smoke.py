#!/usr/bin/env python3
"""Reject empty Phase 5 captures and catastrophic compact-path divergence.

This deliberately compares coarse image statistics rather than a golden image:
the two capture modes may differ at far LOD boundaries, across Vulkan drivers,
or as lighting evolves, while a black frame or a wholly different scene is
always actionable.
"""

import json
import os
import struct
import sys
import zlib


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


def sampled_rgb(image, sample_width=96, sample_height=54):
    width, height, rows = image
    samples = []
    for y in range(sample_height):
        source_y = min(height - 1, y * height // sample_height)
        row = rows[source_y]
        for x in range(sample_width):
            source_x = min(width - 1, x * width // sample_width)
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
    }


def normalized_mae(first, second):
    first_samples = sampled_rgb(first)
    second_samples = sampled_rgb(second)
    return sum(abs(a - b) for first_pixel, second_pixel in zip(first_samples, second_samples) for a, b in zip(first_pixel, second_pixel)) / (len(first_samples) * 3 * 255)


def require_non_empty(name, metrics):
    if metrics["non_black_fraction"] < float(os.environ.get("PHASE5_VISUAL_MIN_NON_BLACK", "0.02")):
        raise ValueError(f"{name} is black or nearly black")
    if metrics["luma_range_p01_p99"] < int(os.environ.get("PHASE5_VISUAL_MIN_LUMA_RANGE", "12")):
        raise ValueError(f"{name} has insufficient image variation")
    if metrics["luma_bin_count"] < int(os.environ.get("PHASE5_VISUAL_MIN_LUMA_BINS", "3")):
        raise ValueError(f"{name} is visually empty")


def main():
    if len(sys.argv) != 4:
        raise SystemExit(f"usage: {sys.argv[0]} off.png auto.png metrics.json")
    off_path, auto_path, metrics_path = sys.argv[1:]
    off = read_png(off_path)
    auto = read_png(auto_path)
    if off[:2] != auto[:2]:
        raise ValueError(f"capture dimensions differ: {off[:2]} vs {auto[:2]}")

    metrics = {"off": image_metrics(off), "auto": image_metrics(auto)}
    metrics["normalized_mae"] = round(normalized_mae(off, auto), 6)
    # The same fixed seed can settle at a different far-LOD upload boundary on
    # different drivers. Keep this intentionally broad: image health catches
    # empty output, while this only rejects a scene-scale mismatch.
    metrics["max_normalized_mae"] = float(os.environ.get("PHASE5_VISUAL_MAX_NMAE", "0.55"))

    # Preserve evidence even when the gate rejects the captures.
    with open(metrics_path, "w", encoding="utf-8") as output:
        json.dump(metrics, output, indent=2, sort_keys=True)
        output.write("\n")

    require_non_empty("compact-off capture", metrics["off"])
    require_non_empty("compact-auto capture", metrics["auto"])
    if metrics["normalized_mae"] > metrics["max_normalized_mae"]:
        raise ValueError("compact-auto capture diverges grossly from the maintained CPU fallback")
    print(json.dumps(metrics, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zlib.error) as error:
        print(f"Phase 5 visual smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
