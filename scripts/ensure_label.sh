#!/usr/bin/env bash

set -euo pipefail

label="${1:?label required}"
description="${2:?description required}"
color="${3:?color required}"

if ! gh label list --json name --jq '.[].name' | grep -qxF "$label"; then
    gh label create "$label" --description "$description" --color "$color" || true
fi
