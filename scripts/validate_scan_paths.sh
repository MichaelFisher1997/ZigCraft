#!/usr/bin/env bash

set -euo pipefail

scan_paths="${SCAN_PATHS:?SCAN_PATHS is required}"
missing=0

for path in $scan_paths; do
    if [[ ! -e "$path" ]]; then
        printf 'WARNING: scan path does not exist: %s\n' "$path"
        missing=$((missing + 1))
    fi
done

if [[ "$missing" -gt 0 ]]; then
    printf '::warning::%d scan path(s) missing; update workflow scan-path mapping if needed\n' "$missing"
fi
