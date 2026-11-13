#!/usr/bin/env bash
# Each login start of the portal costs the BFF a server session, so one address may start only so many logins; the callback shares
# the limit and the rest of /api is not counted.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
proxy_up

burst() {
  client sh -c "seq 1 60 | xargs -P 30 -I{} curl -sk -o /dev/null -w '%{http_code}\n' '$base$1'" | sort | uniq -c
}
forwarded() { upstream_log | grep -c "REQ GET $1" ; }

codes="$(burst '/api/v1/auth/login?returnPath=/catalog')"
check "a burst of login starts from one address gets 429" "$(grep -c ' 429$' <<<"$codes")" 1
check "at most 32 of 60 login starts reach the portal" \
  "$([[ $(forwarded /api/v1/auth/login) -le 32 ]] && echo yes || echo "no ($(forwarded /api/v1/auth/login))")" yes
check "the callback is limited too" "$(burst '/api/v1/auth/callback?code=x&state=y' | grep -c ' 429$')" 1
burst /api/v1/me >/dev/null
check "other portal API requests are not limited" "$(forwarded /api/v1/me)" 60
finish
