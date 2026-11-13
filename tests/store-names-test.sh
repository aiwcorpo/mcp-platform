#!/usr/bin/env bash
# The gateway finds its stores by the bare names postgres and redis, which only Docker answers. It is also on the network egress,
# so Docker passes a name it cannot answer (a store container that is stopped) to the host's resolvers, and the glibc resolver of
# the gateway image retries it under the container's DNS search domains. compose.yaml leaves the gateway no search domain.
# Here a resolver answers redis.test.invalid and postgres.test.invalid; the host's search domain is test.invalid.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

glibc_image="$(grep -o 'eclipse-temurin:[^ ]*@sha256:[0-9a-f]*' "$root/compose.yaml" | head -1)"
mapfile -t gateway_search < <(python3 -I -c '
import json, sys
for d in json.load(sys.stdin)["services"]["gateway"].get("dns_search") or []:
    print(d)' <<<"$compose_json")
search_args=()
for d in "${gateway_search[@]}"; do search_args+=(--dns-search "$d"); done
# Without dns_search the container takes the host's search domains; test.invalid stands in for them.
[[ ${#search_args[@]} == 0 ]] && search_args=(--dns-search test.invalid)

docker network create "$net" >/dev/null || exit 1
docker run -d --name "$prefix-dns" --network "$net" -v "$root/tests/dummy-dns.py:/dummy-dns.py:ro" "$python_image" \
  python3 -I /dummy-dns.py 192.0.2.10 redis.test.invalid postgres.test.invalid >/dev/null || exit 1
dns_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$prefix-dns")"

lookup() {
  docker run --rm --network "$net" --dns "$dns_ip" "${search_args[@]}" --entrypoint getent "$glibc_image" hosts "$1" \
    | awk '{ print $1 }'
}
check "the gateway sets dns_search in compose.yaml" "$([[ ${#gateway_search[@]} -gt 0 ]] && echo yes || echo no)" yes
check "redis does not resolve outside Docker" "$(lookup redis)" ""
check "postgres does not resolve outside Docker" "$(lookup postgres)" ""
finish
