#!/bin/sh
# Writes the default tag and digest of the aiwcorpo images into compose.yaml, servers.example.yaml and platform.env.
# Release step, run by a person after the images of the version are on ghcr.io:
#   scripts/pin-images.sh gateway=2.0.1 broker=2.0.0 portal=2.0.1 [example=2.0.0]
# The digest is the one the registry reports for the tag, so a later push to the same tag does not change what the bundle pulls.
set -eu

[ $# -gt 0 ] || { echo "usage: $0 gateway=<version> broker=<version> portal=<version> [example=<version>]" >&2; exit 2; }
cd "$(dirname "$0")/.."

registry=${MCP_REGISTRY:-ghcr.io/aiwcorpo}
plan=$(mktemp)
trap 'rm -f "$plan"' EXIT

for arg in "$@"; do
  name=${arg%%=*}
  version=${arg#*=}
  case "$name" in
    gateway)  image=mcp-gateway ;;
    broker)   image=mcp-credential-broker ;;
    portal)   image=mcp-portal ;;
    example)  image=mcp-server-example ;;
    *) echo "unknown image '$name'" >&2; exit 2 ;;
  esac
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "'$version' is not a release version" >&2; exit 2 ;;
  esac
  digest=$(docker buildx imagetools inspect "$registry/$image:$version" --format '{{println .Manifest.Digest}}') ||
    { echo "cannot resolve $registry/$image:$version; is it published?" >&2; exit 1; }
  case "$digest" in
    sha256:????????????????????????????????????????????????????????????????) ;;
    *) echo "unexpected digest '$digest' for $image:$version" >&2; exit 1 ;;
  esac
  echo "$name $version $digest" >> "$plan"
  echo "$image:$version -> $digest"
done

# Rewrites only after every digest resolved, so a failure leaves the files as they were.
while read -r name version digest; do
  var=MCP_$(echo "$name" | tr '[:lower:]' '[:upper:]')_VERSION
  value="$version@$digest" perl -0pi -e '
    s/(\$\{\Q'"$var"'\E:-)[^}]*\}/$1$ENV{value}}/g;
    s/^(# \Q'"$var"'\E=).*$/$1$ENV{value}/mg;
  ' compose.yaml servers.example.yaml platform.env
done < "$plan"
