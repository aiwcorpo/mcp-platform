#!/usr/bin/env bash
# The gateway finds its stores by the bare names postgres and redis, the broker by broker-postgres and broker-redis; only Docker answers
# them. Both are also on the network egress,
# so Docker passes a name it cannot answer (a store container that is stopped) to the host's resolvers, and the glibc resolver of
# the Java images retries it under the container's DNS search domains. compose.yaml leaves both services no search domain.
# Here a resolver answers <store>.test.invalid for the four names; the host's search domain is test.invalid.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

glibc_image="$(grep -o 'eclipse-temurin:[^ ]*@sha256:[0-9a-f]*' "$root/compose.yaml" | head -1)"
search_domains() {
  python3 -I -c '
import json, sys
for d in json.load(sys.stdin)["services"][sys.argv[1]].get("dns_search") or []:
    print(d)' "$1" <<<"$compose_json"
}
# Without dns_search the container takes the host's search domains; test.invalid stands in for them.
search_args_of() {
  local domains=() d
  mapfile -t domains < <(search_domains "$1")
  if [[ ${#domains[@]} == 0 ]]; then echo "--dns-search test.invalid"; return; fi
  for d in "${domains[@]}"; do echo -n "--dns-search $d "; done
}

docker network create "$net" >/dev/null || exit 1
docker run -d --name "$prefix-dns" --network "$net" -v "$root/tests/dummy-dns.py:/dummy-dns.py:ro" "$python_image" \
  python3 -I /dummy-dns.py 192.0.2.10 redis.test.invalid postgres.test.invalid broker-redis.test.invalid broker-postgres.test.invalid >/dev/null || exit 1
dns_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$prefix-dns")"

lookup() {
  local service="$1" name="$2" search_args
  read -r -a search_args <<<"$(search_args_of "$service")"
  docker run --rm --network "$net" --dns "$dns_ip" "${search_args[@]}" --entrypoint getent "$glibc_image" hosts "$name" \
    | awk '{ print $1 }'
}
for service in gateway mcp-credential-broker; do
  check "$service sets dns_search in compose.yaml" "$([[ -n "$(search_domains "$service")" ]] && echo yes || echo no)" yes
done
check "redis does not resolve outside Docker" "$(lookup gateway redis)" ""
check "postgres does not resolve outside Docker" "$(lookup gateway postgres)" ""
check "broker-redis does not resolve outside Docker" "$(lookup mcp-credential-broker broker-redis)" ""
check "broker-postgres does not resolve outside Docker" "$(lookup mcp-credential-broker broker-postgres)" ""
finish
