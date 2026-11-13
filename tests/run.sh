#!/usr/bin/env bash
# Runs every test of this directory (needs Docker and openssl; pulls nothing that compose.yaml does not pin, except the stand-in's
# python image). Exit code 1 when any of them failed.
set -uo pipefail
failed=()
for t in "$(dirname "$0")"/*-test.sh; do
  bash "$t" || failed+=("$(basename "$t")")
done
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "failed: ${failed[*]}"
  exit 1
fi
echo "all tests passed"
