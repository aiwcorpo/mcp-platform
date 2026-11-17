#!/bin/sh
# Fails when compose.offline.yaml names other images than compose.yaml. docker load keeps no registry digest, so the offline file
# names every image by repository and tag; with the digest stripped, the two must be the same set across all profiles.
set -eu
cd "$(dirname "$0")/.."

project=mcp-platform-offline-check
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'MCP_DOMAIN=mcp.corp.test\n' > "$work/env"

docker compose -p "$project" --env-file "$work/env" -f compose.yaml --profile '*' config --images |
  sed 's/@sha256:[0-9a-f]*$//' | sort -u > "$work/base"
docker compose -p "$project" --env-file "$work/env" -f compose.yaml -f compose.offline.yaml --profile '*' config --images |
  sort -u > "$work/offline"

if ! diff -u "$work/base" "$work/offline" >&2; then
  echo "compose.offline.yaml names other images than compose.yaml (- compose.yaml without digests, + merged with the offline file)" >&2
  exit 1
fi
