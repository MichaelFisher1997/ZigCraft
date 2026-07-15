#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 ]] || exit 2
kind=$1 file=$2
case "$kind" in
  --baseline) exec python3 "$(dirname "$0")/benchmark_baseline.py" validate "$file" ;;
  --result) exec python3 "$(dirname "$0")/benchmark_baseline.py" validate-result "$file" ;;
  *) exit 2 ;;
esac
