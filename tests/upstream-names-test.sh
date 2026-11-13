#!/usr/bin/env bash
# nginx reaches keycloak, gateway and portal at the fixed addresses compose.yaml gives them on the network edge, never by a DNS
# answer. Here the three upstreams are stopped, nginx can also reach a network with a way out, and Docker forwards the names it
# cannot answer to a resolver that answers them with the address of a foreign listener. That listener must receive nothing.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

outside="$net-outside"
docker network rm "$outside" >/dev/null 2>&1
docker network create "$outside" >/dev/null || exit 1
trap 'proxy_down; docker network rm "$outside" >/dev/null 2>&1; rm -rf "$tmp"' EXIT
docker run -d --name "$prefix-foreign" --network "$outside" -v "$root/tests/echo.py:/echo.py:ro" "$python_image" \
  python3 -I /echo.py >/dev/null || exit 1
foreign_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$outside\").IPAddress}}" "$prefix-foreign")"
docker run -d --name "$prefix-dns" --network "$outside" -v "$root/tests/dummy-dns.py:/dummy-dns.py:ro" "$python_image" \
  python3 -I /dummy-dns.py "$foreign_ip" gateway portal keycloak >/dev/null || exit 1
dns_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$outside\").IPAddress}}" "$prefix-dns")"

PROXY_STANDIN=0
PROXY_NGINX_ARGS=(--dns "$dns_ip")
proxy_up
docker network connect "$outside" "$prefix-nginx" || exit 1

check "compose.yaml gives nginx the addresses of keycloak, gateway and portal" "${#upstream_hosts[@]}" 3
check "gateway route answers 502 while the gateway is stopped" \
  "$(status -X POST -H 'Authorization: Bearer dummy-token' "$base/mcp" --max-time 20)" 502
check "portal route answers 502 while the portal is stopped" "$(status -H 'Cookie: dummy=1' "$base/" --max-time 20)" 502
check "keycloak route answers 502 while keycloak is stopped" "$(status "$base/auth/realms/mcp/" --max-time 20)" 502
check "the foreign listener received no request" "$(docker logs "$prefix-foreign" 2>&1 | grep -c '^REQ')" 0

standin gateway
sleep 1
check "gateway route reaches the gateway once it runs" "$(status -X POST "$base/mcp" --max-time 20)" 200
check "the request arrived at the gateway's address" "$(upstream_log | grep -c 'REQ POST /mcp')" 1
finish
