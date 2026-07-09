#!/usr/bin/env bash
set -euo pipefail

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

for shader in assets/shaders/vulkan/sky.frag assets/shaders/vulkan/terrain.frag; do
    generated="$tmp_dir/$(basename "$shader").spv"
    reflection=$(glslangValidator -V -l -q --reflect-all-block-variables "$shader" -o "$generated")

    expected=(
        "ShadowUniforms.light_space_matrices: offset 0, type 8b5c, size 4"
        "ShadowUniforms.cascade_splits: offset 256"
        "ShadowUniforms.shadow_texel_sizes: offset 272"
        "ShadowUniforms.shadow_params: offset 288"
        "ShadowUniforms: offset -1, type ffffffff, size 304"
        "binding 2, stages 16, numMembers 4"
    )

    for contract in "${expected[@]}"; do
        if [[ "$reflection" != *"$contract"* ]]; then
            printf 'Shadow ABI mismatch in %s: missing reflection contract: %s\n' "$shader" "$contract" >&2
            exit 1
        fi
    done

    if ! cmp -s "$generated" "$shader.spv"; then
        printf 'Stale runtime SPIR-V: %s does not match %s\n' "$shader.spv" "$shader" >&2
        exit 1
    fi
done

printf 'Shadow ABI reflection: 4 matrices, 304-byte block, offsets 0/256/272/288\n'
