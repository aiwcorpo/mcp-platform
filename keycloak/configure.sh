#!/bin/bash
# Realm settings that the import (keycloak/realm-mcp.json) cannot give: the master realm is not imported, and the mcp realm
# keeps the database's settings once it exists. Runs once, as the bootstrap administrator before it has an OTP; after this the
# bootstrap password alone no longer signs in, so a later run could not either, and a failed login on every start would count
# towards the lockout. The marker in /state keeps it to one run.
set -euo pipefail

marker=/state/configured-v1
if [ "${1:-}" = mark-done ]; then
  touch "$marker"
  exit 0
fi
if [ -e "$marker" ]; then
  echo "ok    keycloak realm settings applied earlier"
  exit 0
fi

set -a; . /secrets/env; set +a
kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }

if ! kc config credentials --server http://keycloak.internal:8080/auth --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/tmp/login.log 2>&1; then
  echo "FAIL  keycloak: $KC_BOOTSTRAP_ADMIN_USERNAME cannot sign in with its password ($(tail -1 /tmp/login.log))."
  echo "      If it already has an OTP, do by hand in the console what this script does (README, the administration consoles):"
  echo "      realm mcp, group mcp-platform-admin: client roles query-groups, query-users, view-users, manage-users of realm-management;"
  echo "      realm master: brute force detection with 10 failures, password policy length(12), notUsername, passwordHistory(5),"
  echo "      required action Configure OTP enabled and set as default action, an OTP on every administrator. Then run"
  echo "      docker compose run --rm keycloak-config mark-done"
  exit 1
fi

# Platform administrators manage users and groups in the console of their own realm (/auth/admin/mcp/console/), with the OTP
# that realm asks at every login, so daily work needs neither the master realm nor a list of networks in nginx.
kc add-roles -r mcp --gname mcp-platform-admin --cclientid realm-management \
  --rolename query-groups --rolename query-users --rolename view-users --rolename manage-users
echo "ok    mcp-platform-admin manages users and groups of the realm mcp"

# The master realm gets the rules of the mcp realm, and every administrator there an OTP: new ones at their first login
# (default action), the bootstrap one at its next.
kc update realms/master -s bruteForceProtected=true -s failureFactor=10 \
  -s 'passwordPolicy=length(12) and notUsername and passwordHistory(5)'
kc update authentication/required-actions/CONFIGURE_TOTP -r master -s enabled=true -s defaultAction=true
admin_id="$(kc get users -r master -q exact=true -q username="$KC_BOOTSTRAP_ADMIN_USERNAME" --fields id --format csv --noquotes)"
kc update "users/$admin_id" -r master -s 'requiredActions=["CONFIGURE_TOTP"]'
echo "ok    master realm: OTP for every administrator, $KC_BOOTSTRAP_ADMIN_USERNAME enrolls it at its next login"

touch "$marker"
