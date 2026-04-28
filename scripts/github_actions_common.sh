#!/usr/bin/env bash

set -euo pipefail

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        printf 'error: required environment variable %s is not set\n' "$name" >&2
        exit 2
    fi
}

write_output() {
    local name="$1"
    local value="$2"
    require_env GITHUB_OUTPUT
    if [[ "$value" == *$'\n'* ]]; then
        {
            printf '%s<<OUTEOF\n' "$name"
            printf '%s\n' "$value"
            printf 'OUTEOF\n'
        } >> "$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
    fi
}

write_env() {
    local name="$1"
    local value="$2"
    require_env GITHUB_ENV
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_ENV"
}

write_multiline_env() {
    local name="$1"
    local value="$2"
    require_env GITHUB_ENV
    {
        printf '%s<<ENVEOF\n' "$name"
        printf '%s\n' "$value"
        printf 'ENVEOF\n'
    } >> "$GITHUB_ENV"
}
