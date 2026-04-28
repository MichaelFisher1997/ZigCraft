#!/usr/bin/env bash

set -euo pipefail

source scripts/github_actions_common.sh

input_module="${INPUT_MODULE:-}"
modules=(
    "engine/graphics"
    "engine/core"
    "engine/math"
    "engine/input"
    "engine/ui"
    "engine/atmosphere"
    "engine/audio"
    "engine/ecs"
    "engine/physics"
    "world"
    "world/meshing"
    "world/worldgen"
    "game"
)

if [[ -n "$input_module" ]]; then
    if ! [[ "$input_module" =~ ^[a-zA-Z0-9_\ /-]+$ ]]; then
        printf "ERROR: Invalid module input: '%s'\n" "$input_module" >&2
        exit 1
    fi
    selected="$input_module"
    printf 'Manual dispatch: scanning %s\n' "$selected"
else
    day=$((10#$(date +%j)))
    index=$((day % ${#modules[@]}))
    selected="${modules[$index]}"
    printf 'Scheduled run: day=%s index=%s -> %s\n' "$day" "$index" "$selected"
fi

write_output module "$selected"
write_output module_path "src/${selected}"
