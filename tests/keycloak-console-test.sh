#!/usr/bin/env bash
# Administrators of the realm mcp can create users and add them to mcp-platform-admin in the realm's console, so the console asks
# for a fresh OTP instead of taking an SSO session of any age. Imports keycloak/realm-mcp.json into the Keycloak image of
# compose.yaml, runs keycloak/configure.sh as keycloak-config does, and signs in a dummy administrator.
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

# Before configure.sh: afterwards the bootstrap administrator has a pending OTP enrollment and kcadm cannot sign in.
docker exec "$prefix-keycloak" bash -c '
  kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
  kc config credentials --server http://localhost:8080/auth --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" &&
  kc create users -r mcp -s username=admin-a -s enabled=true -s firstName=Admin -s lastName=Test \
    -s email=admin-a@test.invalid -s "groups=[\"/mcp-platform-admin\"]" &&
  kc set-password -r mcp --username admin-a --new-password test-password-admin-a' >/dev/null 2>&1 || { echo "user setup failed" >&2; exit 1; }
docker run --rm --name "$prefix-config" --network "$net" -v "$root/keycloak/configure.sh:/configure.sh:ro" \
  -v "$tmp/secrets:/secrets:ro" -v "$tmp/state:/state" --entrypoint /bin/bash "$keycloak_image" /configure.sh

result="$(docker run --rm --name "$prefix-browser" --network "$net" -v "$root/tests/console-login.py:/console-login.py:ro" \
  "$python_image" python3 -I /console-login.py http://keycloak.internal:8080 admin-a test-password-admin-a)"
check "the administrator signs in with password and OTP" "$(grep '^login=' <<<"$result")" login=code
check "the realm's console asks for the OTP again" "$(grep '^console=' <<<"$result")" console=otp
finish
