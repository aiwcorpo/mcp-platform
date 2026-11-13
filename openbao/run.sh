#!/bin/sh
# Runs the server and restarts it when the recovery listener is switched on or off. `init.sh recover` (service openbao-recover)
# creates /openbao/recovery/listener.hcl for the length of the command; a file older than 10 minutes counts as absent, so a
# recovery that was killed cannot leave the listener open. The server is sealed after each restart; openbao-unseal unseals it.
conf=/openbao/server.hcl
marker=/openbao/recovery/listener.hcl

recovery_on() { [ -n "$(find "$marker" -mmin -10 2>/dev/null)" ]; }

pid=""
stop() { [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; exit 0; }
trap stop TERM INT

while :; do
  if recovery_on; then mode=on; bao server -config="$conf" -config="$marker" & else mode=off; bao server -config="$conf" & fi
  pid=$!
  switched=0
  while kill -0 "$pid" 2>/dev/null; do
    cur=off
    recovery_on && cur=on
    if [ "$cur" != "$mode" ]; then switched=1; kill -TERM "$pid"; break; fi
    sleep 1 & wait $!
  done
  wait "$pid"
  rc=$?
  [ "$switched" -eq 1 ] || exit "$rc"
done
