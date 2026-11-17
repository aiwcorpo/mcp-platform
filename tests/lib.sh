# Shared setup of the tests in this directory: nginx with this repository's files, mounted and started as compose.yaml does, in
# front of stand-in containers for gateway, portal and keycloak. Everything runs in an internal Docker network of its own that
# takes the subnet and the fixed addresses of the network edge from compose.yaml, and nothing is published, so a running platform
# on the same host is not touched. Source this file from a test.
#
# Before proxy_up a test may set:
#   PROXY_TMPFS        the tmpfs of nginx (default /tmp)
#   PROXY_NGINX_ARGS   array of further docker run arguments for nginx
#   PROXY_ALLOW_CONF   a file mounted in place of nginx/keycloak-admin-allow.conf
#   PROXY_STANDIN      0 to start nginx without the stand-ins (standin <name> starts one later)

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_name="$(basename "$0" .sh)"
prefix="mcp-platform-test-$test_name"
net="$prefix"
nginx_image="$(grep -o 'nginx:[^ ]*@sha256:[0-9a-f]*' "$root/compose.yaml" | head -1)"
python_image=python:3.12-alpine@sha256:0687a6bc9716edc2a6ee0fbfb0f87e7ee358b262b67c9215de91bc9b2d38ba71
base=https://mcp.test:8443
tmp="$(mktemp -d)"
compose_json="$(MCP_DOMAIN=mcp.test docker compose -f "$root/compose.yaml" config --format json)" || exit 1
# "name address" per fixed upstream address that nginx gets through extra_hosts, then the subnet of edge if compose.yaml sets one.
mapfile -t upstream_hosts < <(python3 -I -c '
import json, sys
nginx = json.load(sys.stdin)["services"]["nginx"]
hosts = nginx.get("extra_hosts") or {}
pairs = hosts.items() if isinstance(hosts, dict) else (h.split("=", 1) for h in hosts)
for name, addr in pairs:
    print(name, addr[0] if isinstance(addr, list) else addr)' <<<"$compose_json")
edge_subnet="$(python3 -I -c '
import json, sys
cfg = json.load(sys.stdin)["networks"]["edge"].get("ipam", {}).get("config") or [{}]
print(cfg[0].get("subnet", ""))' <<<"$compose_json")"
pass=0
fail=0

proxy_down() {
  docker rm -f $(docker ps -aq --filter "name=^$prefix-") >/dev/null 2>&1
  docker network rm "$net" >/dev/null 2>&1
}
trap 'proxy_down; rm -rf "$tmp"' EXIT
# Leftovers of an interrupted run.
proxy_down

# standin <name>: starts the stand-in for one upstream, at its fixed address when compose.yaml gives one.
standin() {
  local name="$1" args=(--network-alias "$1") h
  for h in "${upstream_hosts[@]}"; do [[ "${h% *}" == "$name" ]] && args+=(--ip "${h#* }"); done
  docker run -d --name "$prefix-upstream-$name" --network "$net" "${args[@]}" \
    -v "$root/tests/echo.py:/echo.py:ro" "$python_image" python3 -I /echo.py >/dev/null || exit 1
}

proxy_up() {
  local h host_args=()
  for h in "${upstream_hosts[@]}"; do host_args+=(--add-host "${h% *}:${h#* }"); done
  docker network create --internal ${edge_subnet:+--subnet "$edge_subnet"} "$net" >/dev/null || exit 1
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mcp.test -addext subjectAltName=DNS:mcp.test \
    -keyout "$tmp/tls.key" -out "$tmp/tls.crt" >/dev/null 2>&1 || exit 1
  # nginx runs as uid 101; the throw-away key may be world readable.
  chmod 644 "$tmp/tls.key"
  if [[ "${PROXY_ALLOW_CONF:-}" ]]; then allow_conf="$PROXY_ALLOW_CONF"; else allow_conf="$root/nginx/keycloak-admin-allow.conf"; fi

  if [[ "${PROXY_STANDIN:-1}" == 1 ]]; then
    standin gateway; standin portal; standin keycloak
  fi
  docker run -d --name "$prefix-nginx" --network "$net" --network-alias mcp.test \
    --read-only --tmpfs "${PROXY_TMPFS:-/tmp}" --user 101:101 \
    -e MCP_DOMAIN=mcp.test -e MCP_PUBLIC_ORIGIN=https://mcp.test -e MCP_HTTPS_PORT=8443 -e MCP_HTTP_PORT=8080 \
    -v "$root/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$root/nginx/servers.conf.template:/etc/nginx/servers.conf.template:ro" \
    -v "$root/nginx/routes.conf:/etc/nginx/routes.conf:ro" \
    -v "$root/nginx/proxy-common.conf:/etc/nginx/proxy-common.conf:ro" \
    -v "$root/nginx/to-portal.conf:/etc/nginx/to-portal.conf:ro" \
    -v "$root/nginx/to-gateway.conf:/etc/nginx/to-gateway.conf:ro" \
    -v "$root/nginx/to-keycloak.conf:/etc/nginx/to-keycloak.conf:ro" \
    -v "$allow_conf:/etc/nginx/keycloak-admin-allow.conf:ro" \
    -v "$root/nginx/gateway-headers.conf:/etc/nginx/gateway-headers.conf:ro" \
    -v "$root/nginx/errors:/etc/nginx/errors:ro" \
    -v "$tmp/tls.crt:/etc/nginx/tls/tls.crt:ro" -v "$tmp/tls.key:/etc/nginx/tls/tls.key:ro" \
    ${host_args[@]+"${host_args[@]}"} ${PROXY_NGINX_ARGS[@]+"${PROXY_NGINX_ARGS[@]}"} --entrypoint /bin/sh "$nginx_image" -c '
      PUBLIC_HOST="${MCP_PUBLIC_ORIGIN#https://}"; export PUBLIC_HOST
      envsubst '"'"'${MCP_DOMAIN} ${MCP_HTTPS_PORT} ${MCP_HTTP_PORT} ${MCP_PUBLIC_ORIGIN} ${PUBLIC_HOST}'"'"' \
        < /etc/nginx/servers.conf.template > /tmp/servers.conf
      exec nginx -g "daemon off;"' >/dev/null || exit 1
  # The client is a container of its own on the test network: its address is not on any allow list.
  docker run -d --name "$prefix-client" --network "$net" --entrypoint sleep "$nginx_image" 900 >/dev/null || exit 1

  for _ in $(seq 1 60); do
    if docker exec "$prefix-client" curl -sf -o /dev/null http://mcp.test:8080/__proxy/health 2>/dev/null; then
      if [[ "${PROXY_STANDIN:-1}" != 1 ]] || docker exec "$prefix-client" curl -skf -o /dev/null "$base/" 2>/dev/null; then
        return 0
      fi
    fi
    sleep 0.5
  done
  echo "proxy did not start:" >&2
  docker logs "$prefix-nginx" 2>&1 | tail -5 >&2
  exit 1
}

# status <curl args...>: prints the status code of one request to the TLS server.
status() { docker exec "$prefix-client" curl -sk --path-as-is -o /dev/null -w '%{http_code}' "$@"; }
client() { docker exec "$prefix-client" "$@"; }
upstream_log() {
  local c
  for c in $(docker ps -aq --filter "name=^$prefix-upstream-"); do docker logs "$c" 2>&1; done
}

check() {
  local description="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1)); echo "ok    $description"
  else
    fail=$((fail + 1)); echo "FAIL  $description: got $actual, expected $expected"
  fi
}

finish() {
  echo "$test_name: $pass passed, $fail failed"
  [[ "$fail" == 0 ]]
}
