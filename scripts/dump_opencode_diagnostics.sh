#!/usr/bin/env bash

set -euo pipefail

echo "opencode action outcome: ${AI_REVIEW_OUTCOME:-unknown}"
echo "runner: ${RUNNER_NAME:-unknown} (${RUNNER_OS:-unknown}/${RUNNER_ARCH:-unknown})"
echo "workspace: ${GITHUB_WORKSPACE:-unknown}"
echo "XDG_CACHE_HOME: ${XDG_CACHE_HOME:-unset}"

for dir in "${XDG_CACHE_HOME:-}" "$HOME/.cache" "$HOME/.local/share/opencode"; do
    [[ -n "$dir" ]] || continue

    echo "Inspecting $dir"
    if [[ ! -e "$dir" ]]; then
        echo "  missing"
        continue
    fi

    du -sh "$dir" 2>/dev/null || true
    find "$dir" -maxdepth 3 -mindepth 1 -printf '  %y %p\n' 2>/dev/null | sort | head -200 || true
done
