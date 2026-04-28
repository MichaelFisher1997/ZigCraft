#!/usr/bin/env bash

set -euo pipefail

module_path="${MODULE_PATH:?MODULE_PATH is required}"

if [[ ! -d "$module_path" ]]; then
    printf "::warning::Module directory '%s' does not exist; audit may be limited to partial or no source files\n" "$module_path"
    printf 'Listing parent directory:\n'
    parent="$(dirname "$module_path")"
    ls -la "$parent" 2>/dev/null || printf "Parent directory '%s' also missing\n" "$parent"
else
    printf 'Module directory confirmed: %s\n' "$module_path"
    printf 'Files in module:\n'
    find "$module_path" -name '*.zig' | head -20
fi
