#!/usr/bin/env bash
# nginx writes a log line for every request, before any login. Every service, the example server included, rotates its log in
# compose itself, so the disk under the Docker data root does not depend on the daemon's log options.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

rendered="$(MCP_DOMAIN=mcp.test MCP_GITLAB_URL=https://gitlab.test \
  docker compose -f "$root/compose.yaml" -f "$root/servers.example.yaml" config --format json)" || exit 1
unrotated="$(python3 -I -c '
import json, sys
services = json.load(sys.stdin)["services"]
print(" ".join(sorted(name for name, svc in services.items()
                      if not (svc.get("logging") or {}).get("options", {}).get("max-size"))))' <<<"$rendered")"
check "every service sets a log size limit (without one: ${unrotated:-none})" "$unrotated" ""
finish
