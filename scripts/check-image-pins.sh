#!/bin/sh
# Fails when an image in compose.yaml or servers.example.yaml has no @sha256 digest.
# There are no exceptions; scripts/pin-images.sh writes the digests of the aiwcorpo images.
set -eu
cd "$(dirname "$0")/.."

status=0
for file in compose.yaml servers.example.yaml; do
  # "image: *alias" reuses an anchor and is checked at the anchor.
  grep -nE '^[[:space:]]*image:[[:space:]]' "$file" | grep -vE 'image:[[:space:]]+\*' | while IFS= read -r line; do
    case "$line" in
      *@sha256:????????????????????????????????????????????????????????????????*) continue ;;
    esac
    echo "$file:$line: image without @sha256 digest" >&2
    exit 1
  done || status=1
done
exit $status
