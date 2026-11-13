#!/usr/bin/env bash
# Keycloak counts failed logins per account and locks the account for everyone, after two failures within a second or after ten in
# a row. One address must not be able to post the login form at that pace; other Keycloak requests stay unlimited.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
proxy_up

burst() {
  local path="$1"
  client sh -c "seq 1 12 | xargs -P 12 -I{} curl -sk -o /dev/null -w '%{http_code}\n' -X POST -d username=user1 '$base$path'" | sort | uniq -c
}
forwarded() { upstream_log | grep -c "REQ POST $1" ; }

login=/auth/realms/mcp/login-actions/authenticate
codes="$(burst "$login")"
check "a burst of login posts from one address gets 429" "$(grep -c ' 429$' <<<"$codes")" 1
check "at most 6 of 12 login posts reach Keycloak" "$([[ $(forwarded "$login") -le 6 ]] && echo yes || echo "no ($(forwarded "$login"))")" yes
check "the master realm login is limited too" "$(burst /auth/realms/master/login-actions/authenticate | grep -c ' 429$')" 1
token=/auth/realms/mcp/protocol/openid-connect/token
burst "$token" >/dev/null
check "token requests are not limited" "$(forwarded "$token")" 12
finish
