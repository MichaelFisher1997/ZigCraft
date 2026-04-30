#!/usr/bin/env bash

set -euo pipefail

config_dir="${HOME:?HOME is required}/.config/opencode"
mkdir -p "$config_dir"

cat > "$config_dir/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "external_directory": {
      "/tmp/*": "allow",
      "/tmp/**": "allow"
    }
  }
}
JSON

echo "Configured opencode CI permissions at $config_dir/opencode.json"
