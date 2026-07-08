#!/usr/bin/env bash
set -euo pipefail

SPIRV_UPDATE_BASELINE=1 bash scripts/check_spirv_sizes.sh "${1:-docs/shaders/spirv-sizes.json}"
