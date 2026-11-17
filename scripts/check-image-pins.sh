#!/bin/sh
# Fails when an image in compose.yaml or servers.example.yaml has no @sha256 digest. An image that is not in the list of
# exceptions below must be pinned; scripts/pin-images.sh writes the digests of the aiwcorpo images.
set -eu
cd "$(dirname "$0")/.."

# mcp-server-example is not readable anonymously on ghcr.io yet, so no digest can be resolved for it. Remove it from this list
# when the image is public and pin-images.sh example=<version> has been run.
unpinned_allowed='mcp-server-example'

status=0
for file in compose.yaml servers.example.yaml; do
  # "image: *alias" reuses an anchor and is checked at the anchor.
  grep -nE '^[[:space:]]*image:[[:space:]]' "$file" | grep -vE 'image:[[:space:]]+\*' | while IFS= read -r line; do
    case "$line" in
      *@sha256:????????????????????????????????????????????????????????????????*) continue ;;
    esac
    for name in $unpinned_allowed; do
      case "$line" in *"/$name:"*) continue 2 ;; esac
    done
    echo "$file:$line: image without @sha256 digest" >&2
    exit 1
  done || status=1
done
exit $status
