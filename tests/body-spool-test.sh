#!/usr/bin/env bash
# nginx keeps request bodies in its tmpfs until they are complete, before an upstream sees the request. The tmpfs, the memory of
# the container and the requests one address keeps open at a time are bounded, so slow clients cannot take the host's memory.
# The tmpfs and the memory limit are read from compose.yaml.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

nginx_settings="$(python3 -I -c '
import json, sys
nginx = json.load(sys.stdin)["services"]["nginx"]
print(nginx["tmpfs"][0], nginx.get("mem_limit") or 0)' <<<"$compose_json")"
PROXY_TMPFS="${nginx_settings% *}"
mem_limit="${nginx_settings##* }"
PROXY_NGINX_ARGS=()
[[ "$mem_limit" != 0 ]] && PROXY_NGINX_ARGS=(--memory "$mem_limit")
proxy_up

check "compose.yaml gives nginx a memory limit" "$([[ "$mem_limit" != 0 ]] && echo yes || echo no)" yes
tmpfs_kb="$(docker exec "$prefix-nginx" df -k /tmp | awk 'NR == 2 { print $2 }')"
check "the tmpfs of nginx holds at most 256 MiB (it has $tmpfs_kb KiB)" "$([[ "$tmpfs_kb" -le 262144 ]] && echo yes || echo no)" yes

holder() {
  docker run -d --name "$prefix-holder" --network "$net" -v "$root/tests/hold-bodies.py:/hold-bodies.py:ro" "$python_image" \
    python3 -I /hold-bodies.py "$@" >/dev/null
}
holder_result() { docker wait "$prefix-holder" >/dev/null; docker logs "$prefix-holder"; docker rm "$prefix-holder" >/dev/null; }

# Eight bodies of almost 4 MiB stay in the spool while the client waits, and no request reaches the gateway yet: the spool works.
holder 8 4194304 4194000 8
sleep 5
used_kb="$(docker exec "$prefix-nginx" df -k /tmp | awk 'NR == 2 { print $3 }')"
result="$(holder_result)"
check "8 slow bodies are held in the spool ($used_kb KiB, $result)" "$([[ "$used_kb" -ge 30000 && "$result" == "held=8 answered=0 " ]] && echo yes || echo no)" yes
check "no slow body reached the gateway" "$(upstream_log | grep -c 'REQ POST /mcp')" 0

holder 51 1000 10 4
result="$(holder_result)"
check "one address keeps at most 50 requests open ($result)" "${result%% *}" held=50
finish
