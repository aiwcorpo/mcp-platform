#!/bin/sh
# The checks of AGENTS.md and CONTRIBUTING.md; CI runs this script. It starts nothing: `docker compose config` only renders the
# files, and the -p name keeps it away from a real installation (compose.yaml fixes the project name to mcp-platform).
# Set REQUIRE_SHELLCHECK=1 to fail when shellcheck is missing instead of skipping it.
set -eu
cd "$(dirname "$0")/.."

envfile=$(mktemp)
trap 'rm -f "$envfile"' EXIT
printf 'MCP_DOMAIN=mcp.corp.test\nMCP_GITLAB_URL=https://gitlab.corp.test\n' > "$envfile"

echo "compose.yaml"
docker compose -p mcp-platform-verify --env-file "$envfile" -f compose.yaml config -q
echo "compose.yaml with servers.example.yaml"
docker compose -p mcp-platform-verify --env-file "$envfile" -f compose.yaml -f servers.example.yaml config -q

echo "required variables"
# Without MCP_DOMAIN the render must fail: the check that nobody starts the bundle with an empty domain.
printf 'MCP_GITLAB_URL=https://gitlab.corp.test\n' > "$envfile"
if docker compose -p mcp-platform-verify --env-file "$envfile" config -q 2>/dev/null; then
  echo "compose.yaml renders without MCP_DOMAIN" >&2
  exit 1
fi

echo "shell syntax"
for script in init/init.sh openbao/run.sh scripts/*.sh; do sh -n "$script"; done
bash -n keycloak/configure.sh

if command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck"
  shellcheck -S warning init/init.sh openbao/run.sh keycloak/configure.sh scripts/*.sh
elif [ "${REQUIRE_SHELLCHECK:-}" = 1 ]; then
  echo "shellcheck is required and not installed" >&2
  exit 1
else
  echo "shellcheck not installed, skipped"
fi

echo "image digests"
scripts/check-image-pins.sh

echo "offline images"
scripts/check-offline-images.sh

echo "text characters"
scripts/check-text.sh
