#!/bin/sh
# Runs the server and restarts it when the recovery listener is switched on or off. `init.sh recover` (service openbao-recover)
# creates the flag file /openbao/recovery/enabled for the length of the command. A flag older than 10 minutes, or dated in the
# future, counts as absent, so a recovery that was killed cannot leave the listener open. The server is sealed after each restart;
# openbao-unseal unseals it.
conf=/openbao/server.hcl
listener=/openbao/recovery-listener.hcl
flag=/openbao/recovery/enabled

recovery_on() {
  m="$(stat -c %Y "$flag" 2>/dev/null)" || return 1
  age=$(( $(date +%s) - m ))
  [ "$age" -ge 0 ] && [ "$age" -lt 600 ]
}

pid=""
stop() { [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; exit 0; }
trap stop TERM INT

while :; do
  if recovery_on; then mode=on; bao server -config="$conf" -config="$listener" & else mode=off; bao server -config="$conf" & fi
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
