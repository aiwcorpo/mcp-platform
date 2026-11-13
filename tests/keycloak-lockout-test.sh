#!/usr/bin/env bash
# Keycloak locks an account for everyone who tries it, so a short burst of wrong passwords for a published administrator name must
# not lock it, while a long run of them still does, for a short time. Imports keycloak/realm-mcp.json into the Keycloak image of
# compose.yaml, runs keycloak/configure.sh as keycloak-config does (it sets the master realm), and tries dummy users of both realms.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

keycloak_image="$(python3 -I -c 'import json, sys; print(json.load(sys.stdin)["services"]["keycloak"]["image"])' <<<"$compose_json")"
mkdir -p "$tmp/secrets" "$tmp/state"
chmod 777 "$tmp/state"
cat > "$tmp/secrets/env" <<'ENV'
KC_BOOTSTRAP_ADMIN_USERNAME=bootstrap-admin
KC_BOOTSTRAP_ADMIN_PASSWORD=test-bootstrap-password
MCP_ADMIN_INITIAL_PASSWORD=test-initial-password
KC_CLIENT_MCP_GATEWAY_SECRET=test-secret-1
KC_CLIENT_MCP_PORTAL_BFF_SECRET=test-secret-2
KC_CLIENT_MCP_CREDENTIAL_BROKER_SECRET=test-secret-3
KC_CLIENT_MCP_GATEWAY_ADMIN_SECRET=test-secret-4
KC_CLIENT_OPENSEARCH_SECRET=test-secret-5
ENV
chmod 644 "$tmp/secrets/env"

docker network create --internal "$net" >/dev/null || exit 1
docker run -d --name "$prefix-keycloak" --network "$net" --network-alias keycloak.internal --env-file "$tmp/secrets/env" \
  -e KC_HTTP_RELATIVE_PATH=/auth -e KC_PROXY_HEADERS=xforwarded -e MCP_ADMIN_USERNAME=mcp-admin \
  -e MCP_PUBLIC_ORIGIN=https://keycloak.internal:8080 -e MCP_CLAUDE_CODE_CALLBACK_PORT=33418 \
  -v "$root/keycloak/realm-mcp.json:/opt/keycloak/data/import/realm-mcp.json:ro" \
  "$keycloak_image" start-dev --import-realm >/dev/null || exit 1
for _ in $(seq 1 90); do
  docker exec "$prefix-keycloak" bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080 && printf "GET /auth/realms/mcp HTTP/1.0\r\n\r\n" >&3 &&
    head -1 <&3 | grep -q " 200 "' 2>/dev/null && break
  sleep 2
done

# Before configure.sh: afterwards the bootstrap administrator has a pending OTP enrollment and kcadm cannot sign in. The password
# grant reaches the same failure counter as the login form, without a browser.
docker exec "$prefix-keycloak" bash -c '
  kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
  kc config credentials --server http://localhost:8080/auth --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" &&
  kc create clients -r mcp -s clientId=lockout-test -s publicClient=true -s directAccessGrantsEnabled=true &&
  for realm in mcp master; do
    id=$(kc create users -r $realm -s username=user-$realm -s enabled=true -s firstName=User -s lastName=Test \
      -s email=user-$realm@test.invalid -i) &&
    # The realm mcp adds its default action Configure OTP on creation; the password grant would then never return a token.
    kc update users/$id -r $realm -s "requiredActions=[]" &&
    kc set-password -r $realm --username user-$realm --new-password test-password-$realm || exit 1
  done' >/dev/null 2>&1 || { echo "user setup failed" >&2; exit 1; }
docker run --rm --name "$prefix-config" --network "$net" -v "$root/keycloak/configure.sh:/configure.sh:ro" \
  -v "$tmp/secrets:/secrets:ro" -v "$tmp/state:/state" --entrypoint /bin/bash "$keycloak_image" /configure.sh >/dev/null

docker run -d --name "$prefix-client" --network "$net" --entrypoint sleep "$nginx_image" 900 >/dev/null || exit 1
# login <realm> <password...>: one password grant per password, back to back; prints "token" or the error of each.
# LOGIN_PARALLEL=1 sends them all at once instead.
login() {
  local realm="$1" client=lockout-test
  shift
  [[ "$realm" == master ]] && client=admin-cli
  client sh -c '
    realm="$1" client="$2" parallel="$3"; shift 3
    grant() {
      curl -s -H "X-Forwarded-Proto: https" -H "X-Forwarded-Host: keycloak.internal:8080" \
        -d grant_type=password -d client_id="$client" -d username="user-$realm" --data-urlencode password="$1" \
        "http://keycloak.internal:8080/auth/realms/$realm/protocol/openid-connect/token" |
        grep -o "\"access_token\"\|\"error_description\":\"[^\"]*\"" | sed "s/\"access_token\"/token/"
    }
    for password in "$@"; do
      if [ "$parallel" = 1 ]; then grant "$password" & else grant "$password"; fi
    done
    wait' sh "$realm" "$client" "${LOGIN_PARALLEL:-0}" "$@"
}
wrong() { local i; for i in $(seq 1 "$1"); do echo "wrong-password-$i"; done; }

for realm in mcp master; do
  # Also warms Keycloak up: on a cold start a single grant can take longer than the quick login window.
  check "realm $realm: the right password signs in" "$(login $realm test-password-$realm)" token
  LOGIN_PARALLEL=1 login $realm $(wrong 2) >/dev/null
  check "realm $realm: two wrong passwords at once, then the right one signs in" "$(login $realm test-password-$realm)" token
  check "realm $realm: 19 wrong passwords in a row, then the right one signs in" \
    "$(login $realm $(wrong 19) test-password-$realm | tail -1)" token
  check "realm $realm: 20 wrong passwords in a row lock the account" \
    "$(login $realm $(wrong 20) test-password-$realm | tail -1)" '"error_description":"Invalid user credentials"'
done
# The lock of the 20th failure lasts 30 s; the right password tried during the lock above does not extend it.
sleep 32
for realm in mcp master; do
  check "realm $realm: the lock ends after 30 s" "$(login $realm test-password-$realm)" token
done
finish
