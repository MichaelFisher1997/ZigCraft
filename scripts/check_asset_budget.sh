#!/usr/bin/env bash
set -euo pipefail

base_ref="origin/dev"
budget_file="docs/assets/budget.json"
assets_dir="assets"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-ref)
            base_ref="$2"
            shift 2
            ;;
        --budget-file)
            budget_file="$2"
            shift 2
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

if [[ ! -f "$budget_file" ]]; then
    printf 'Asset budget config not found: %s\n' "$budget_file" >&2
    exit 2
fi

texture_budget=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("per_asset").fetch("texture_bytes")' "$budget_file")
model_budget=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("per_asset").fetch("model_bytes")' "$budget_file")
total_growth_budget=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("total_assets_growth_bytes")' "$budget_file")

failure=0

is_texture() {
    local path
    path=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

    case "$path" in
        *.png|*.jpg|*.jpeg|*.tga|*.bmp|*.webp|*.ktx|*.ktx2|*.dds) return 0 ;;
        *) return 1 ;;
    esac
}

is_model() {
    local path
    path=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

    case "$path" in
        *.obj|*.gltf|*.glb|*.fbx|*.dae|*.blend) return 0 ;;
        *) return 1 ;;
    esac
}

size_bytes() {
    if stat -c '%s' "$1" >/dev/null 2>&1; then
        stat -c '%s' "$1"
    else
        stat -f '%z' "$1"
    fi
}

changed_assets=$(git diff --name-only --diff-filter=AM "$base_ref" -- "$assets_dir" || true)

while IFS= read -r asset; do
    [[ -n "$asset" && -f "$asset" ]] || continue
    bytes=$(size_bytes "$asset")

    if is_texture "$asset" && (( bytes > texture_budget )); then
        printf 'Asset budget exceeded: texture %s is %d bytes, limit is %d bytes.\n' "$asset" "$bytes" "$texture_budget" >&2
        failure=1
    elif is_model "$asset" && (( bytes > model_budget )); then
        printf 'Asset budget exceeded: model %s is %d bytes, limit is %d bytes.\n' "$asset" "$bytes" "$model_budget" >&2
        failure=1
    fi
done <<< "$changed_assets"

current_total=0
while IFS= read -r -d '' asset; do
    [[ -f "$asset" ]] || continue
    bytes=$(size_bytes "$asset")
    current_total=$(( current_total + bytes ))
done < <(git ls-files -z "$assets_dir")

base_total=$(git ls-tree -r -l "$base_ref" "$assets_dir" 2>/dev/null | awk '{ total += $4 } END { print total + 0 }')
growth=$(( current_total - base_total ))

if (( growth > total_growth_budget )); then
    printf 'Asset budget exceeded: assets/ grew by %d bytes vs %s, limit is %d bytes.\n' "$growth" "$base_ref" "$total_growth_budget" >&2
    failure=1
fi

if (( failure != 0 )); then
    exit 1
fi

printf 'Asset budgets passed: %d bytes total, growth %d bytes vs %s.\n' "$current_total" "$growth" "$base_ref"
