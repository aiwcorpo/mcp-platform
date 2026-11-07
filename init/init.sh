#!/bin/sh
# The one entry point of the platform's setup. Runs in the "init" service (eclipse-temurin image: openssl, keytool, bash) and,
# as "openbao", in the "openbao-unseal" service (OpenBao image).
#
#   init.sh                  every start: check the configuration, generate what is missing, keep what exists
#   init.sh issue <id> [uid] certificate, Redis account and secrets of an MCP server; uid is the user the server image runs as (999)
#   init.sh export <id>      tar on stdout with everything a server on another host needs (certs/, server.env); issues if needed
#   init.sh ci <id>          client certificate mcp-registry-ci-<id> for the pipeline that registers the manifest of <id>
#   init.sh show <what>      print one generated value: admin-password, keycloak-admin, client-secret <client>, ca,
#                            ci-cert <id>, ci-key <id>
#   init.sh openbao          initialise, unseal and provision OpenBao, then keep it unsealed (never returns)
#
# Everything generated lives in the volume "secrets" (/secrets), laid out per consumer so that a service mounts only its own
# directory (compose.yaml, volume subpath). state/ holds the single copy of every generated value and is mounted nowhere else.
set -eu
umask 077

S=/secrets
PKI="$S/pki"
STATE="$S/state"
OPERATOR=/operator-certs
failures=0

say()  { printf '%s\n' "$*"; }
ok()   { printf 'ok    %s\n' "$*"; }
new()  { printf 'new   %s\n' "$*" >&2; }
warn() { printf 'warn  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---- files

# Directories a service mounts must be traversable by it whatever the umask.
mk() { (umask 022; mkdir -p "$@"); }

# put <file> <owner uid:gid> <mode>: content from stdin; the file is replaced only when the content differs.
put() {
  tmp="$1.tmp.$$"
  mk "$(dirname "$1")"
  cat > "$tmp"
  if [ -f "$1" ] && cmp -s "$tmp" "$1"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$1"
  fi
  chown "$2" "$1"
  chmod "$3" "$1"
}

# dir <path> <owner> [mode]: a directory a service mounts as the root of its volume subpath (mode 755 unless given).
dir() {
  mk "$1"
  chown "$2" "$1"
  chmod "${3:-755}" "$1"
}

# value <name> [base64]: a generated secret, created on the first call and kept in state/.
value() {
  f="$STATE/$1"
  if [ ! -s "$f" ]; then
    mkdir -p "$(dirname "$f")"
    if [ "${2:-}" = base64 ]; then openssl rand -base64 32 | tr -d '\n' > "$f"; else openssl rand -hex 24 | tr -d '\n' > "$f"; fi
    chmod 400 "$f"
    new "$1"
  fi
  cat "$f"
}

# ---- certificates

# issue_cert <name> <serverAuth|clientAuth|both> <subjectAltName list> <owner> <dir> [days]
# The certificate is made again when it is missing, expires within 30 days, or the names or the CA changed. A directory that
# holds the certificate of another name is never overwritten.
issue_cert() {
  name="$1"; role="$2"; sans="$3"; owner="$4"; d="$5"; days="${6:-730}"
  if [ -f "$d/tls.crt" ]; then
    cn="$(openssl x509 -in "$d/tls.crt" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')"
    [ "$cn" = "$name" ] || die "$d holds the certificate of $cn, not of $name"
  fi
  case "$role" in
    serverAuth) eku="serverAuth" ;;
    clientAuth) eku="clientAuth" ;;
    *) eku="serverAuth,clientAuth" ;;
  esac
  want="$role $sans"
  if [ -f "$d/tls.crt" ] && [ "$(cat "$d/spec" 2>/dev/null)" = "$want" ] \
     && openssl verify -CAfile "$PKI/ca/ca.crt" "$d/tls.crt" >/dev/null 2>&1 \
     && openssl x509 -in "$d/tls.crt" -noout -checkend $((30 * 86400)) >/dev/null; then
    chown -R "$owner" "$d"
    return 0
  fi
  mk "$d"
  printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" "extendedKeyUsage=$eku" \
    ${sans:+"subjectAltName=$sans"} > "$d/ext.cnf"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$d/tls.key" 2>/dev/null
  openssl req -new -key "$d/tls.key" -subj "/O=MCP platform/CN=$name" -out "$d/tls.csr"
  openssl x509 -req -in "$d/tls.csr" -CA "$PKI/ca/ca.crt" -CAkey "$PKI/ca/ca.key" -set_serial "0x$(openssl rand -hex 16)" \
    -days "$days" -sha256 -extfile "$d/ext.cnf" -out "$d/tls.crt" 2>/dev/null
  STOREPW="$(cat "$PKI/store-password")" openssl pkcs12 -export -name "$name" -inkey "$d/tls.key" -in "$d/tls.crt" \
    -certfile "$PKI/ca/ca.crt" -passout env:STOREPW -out "$d/keystore.p12"
  cp "$PKI/ca/ca.crt" "$d/ca.crt"
  printf '%s' "$want" > "$d/spec"
  rm -f "$d/tls.csr" "$d/ext.cnf"
  chown -R "$owner" "$d"
  chmod 755 "$d"
  chmod 400 "$d/tls.key" "$d/keystore.p12" "$d/spec"
  chmod 444 "$d/tls.crt" "$d/ca.crt"
  new "certificate $name ($role${sans:+, $sans})"
}

ensure_ca() {
  if [ ! -f "$PKI/ca/ca.crt" ]; then
    mk "$PKI/ca"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$PKI/ca/ca.key" 2>/dev/null
    openssl req -x509 -new -key "$PKI/ca/ca.key" -sha256 -days 3650 -subj "/O=MCP platform/CN=MCP platform internal CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$PKI/ca/ca.crt"
    chmod 400 "$PKI/ca/ca.key"
    new "internal CA $PKI/ca/ca.crt (valid 10 years)"
  fi
  [ -s "$PKI/store-password" ] || { openssl rand -hex 24 | tr -d '\n' > "$PKI/store-password"; chmod 400 "$PKI/store-password"; }
  if ! openssl x509 -in "$PKI/ca/ca.crt" -noout -checkend $((365 * 86400)) >/dev/null; then
    warn "the internal CA expires within a year: replacing it means new certificates everywhere (README, Certificates)"
  fi
}

# keytool refuses to overwrite a store, so the stores are rebuilt in a temporary file and moved into place.
trust_stores() {
  pw="$(cat "$PKI/store-password")"
  t="$PKI/trust"
  mk "$t"
  chmod 755 "$t"
  cp "$PKI/ca/ca.crt" "$t/ca.crt"
  chmod 444 "$t/ca.crt"

  company=0
  [ -s "$OPERATOR/company-ca.crt" ] && company=1
  sig="$(cat "$PKI/ca/ca.crt" "$JAVA_HOME/lib/security/cacerts" 2>/dev/null | sha256sum | cut -d' ' -f1)-$company-${MCP_BROKER_TRUST_COMPANY_CA:-false}"
  [ "$company" = 1 ] && sig="$sig-$(sha256sum < "$OPERATOR/company-ca.crt" | cut -d' ' -f1)"
  [ -f "$t/truststore.p12" ] && [ "$(cat "$t/signature" 2>/dev/null)" = "$sig" ] && return 0

  work="$(mktemp -d)"
  keytool -importcert -noprompt -alias mcp-internal-ca -file "$PKI/ca/ca.crt" -keystore "$work/truststore.p12" \
    -storetype PKCS12 -storepass "$pw" >/dev/null 2>&1
  cp "$work/truststore.p12" "$work/broker-truststore.p12"
  # The JVM default store: the public CAs of this JDK, the internal CA (the identity provider answers there with an internal
  # certificate) and the company CA, so that a name that goes through nginx can be verified too.
  cp "$JAVA_HOME/lib/security/cacerts" "$work/jvm-truststore.p12"
  chmod 600 "$work/jvm-truststore.p12"
  keytool -importcert -noprompt -alias mcp-internal-ca -file "$PKI/ca/ca.crt" -keystore "$work/jvm-truststore.p12" \
    -storetype PKCS12 -storepass changeit >/dev/null 2>&1
  if [ "$company" = 1 ]; then
    awk -v d="$work" '/BEGIN CERTIFICATE/ { n++ } n { print > (d "/company-" n ".crt") }' "$OPERATOR/company-ca.crt"
    for c in "$work"/company-*.crt; do
      n="$(basename "$c" .crt)"
      keytool -importcert -noprompt -alias "$n" -file "$c" -keystore "$work/jvm-truststore.p12" -storetype PKCS12 -storepass changeit >/dev/null 2>&1
      # The broker's HTTP client trusts only its truststore, so systems behind the company CA need it there. The same store
      # also decides which client certificates the broker accepts: off unless the operator asks for it.
      if [ "${MCP_BROKER_TRUST_COMPANY_CA:-false}" = true ]; then
        keytool -importcert -noprompt -alias "$n" -file "$c" -keystore "$work/broker-truststore.p12" -storetype PKCS12 -storepass "$pw" >/dev/null 2>&1
      fi
    done
  fi
  for f in truststore.p12 broker-truststore.p12 jvm-truststore.p12; do
    mv "$work/$f" "$t/$f"
    chmod 444 "$t/$f"
  done
  printf '%s' "$sig" > "$t/signature"
  rm -rf "$work"
  new "truststores in $t (internal CA$([ "$company" = 1 ] && echo ', company CA'))"
}

# ---- the configuration the operator gave

check_configuration() {
  case "${MCP_DOMAIN:-}" in
    "") fail "MCP_DOMAIN is not set"; return ;;
    *[!a-z0-9.-]*|.*|-*|*.|*-) fail "MCP_DOMAIN $MCP_DOMAIN is not a DNS name in lower case"; return ;;
  esac
  quoted="$(printf '%s' "$MCP_DOMAIN" | sed 's/\./\\./g')"
  printf '%s' "${MCP_PUBLIC_ORIGIN:-}" | grep -Eq "^https://$quoted(:[0-9]{1,5})?\$" \
    || { fail "MCP_PUBLIC_ORIGIN ${MCP_PUBLIC_ORIGIN:-} must be https://$MCP_DOMAIN, with :port when the https port is not 443"; return; }
  case "${MCP_ADMIN_USERNAME:-}" in
    [a-z]*) printf '%s' "$MCP_ADMIN_USERNAME" | grep -Eq '^[a-z][a-z0-9._-]{2,30}$' || fail "MCP_ADMIN_USERNAME must be 3 to 31 characters of a-z 0-9 . _ -" ;;
    *) fail "MCP_ADMIN_USERNAME must start with a letter" ;;
  esac

  crt="$OPERATOR/tls.crt"; key="$OPERATOR/tls.key"
  for f in "$crt" "$key"; do
    [ -s "$f" ] || { fail "$f does not exist (put the certificate chain of $MCP_DOMAIN in certs/tls.crt and its key in certs/tls.key)"; return; }
  done
  openssl x509 -in "$crt" -noout 2>/dev/null || { fail "certs/tls.crt is not a PEM certificate"; return; }
  if ! pub="$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null)"; then
    fail "certs/tls.key is not a PEM private key, or it is encrypted (nginx reads it without a password)"; return
  fi
  [ "$pub" = "$(openssl x509 -in "$crt" -noout -pubkey)" ] || { fail "certs/tls.key does not belong to certs/tls.crt"; return; }
  openssl x509 -in "$crt" -noout -checkhost "$MCP_DOMAIN" | grep -q 'does match' \
    || { fail "certs/tls.crt does not name $MCP_DOMAIN in subjectAltName"; return; }
  openssl x509 -in "$crt" -noout -checkend 0 >/dev/null || { fail "certs/tls.crt has expired"; return; }
  if [ -s "$OPERATOR/company-ca.crt" ]; then
    if openssl verify -CAfile "$OPERATOR/company-ca.crt" -untrusted "$crt" "$crt" >/dev/null 2>&1; then
      ok "nginx certificate for $MCP_DOMAIN, signed by the company CA in certs/company-ca.crt"
    else
      fail "certs/tls.crt is not signed by the CA in certs/company-ca.crt (an intermediate certificate missing from tls.crt?)"
    fi
  elif openssl verify -untrusted "$crt" "$crt" >/dev/null 2>&1; then
    ok "nginx certificate for $MCP_DOMAIN, signed by a public CA"
  else
    fail "certs/tls.crt is not signed by a public CA: put the CA certificate in certs/company-ca.crt"
  fi
  openssl x509 -in "$crt" -noout -checkend $((14 * 86400)) >/dev/null || warn "certs/tls.crt expires within 14 days"
  # nginx runs as uid 101 and must not depend on the permissions of files on the host.
  put "$S/nginx/tls.crt" 101:101 444 < "$crt"
  put "$S/nginx/tls.key" 101:101 400 < "$key"
}

# ---- first start

bootstrap() {
  check_configuration
  if [ "$failures" -gt 0 ]; then
    say
    say "$failures problem(s): fix them in platform.env and certs/, then start again. Generated values are kept."
    exit 1
  fi

  mkdir -p "$STATE"
  chmod 700 "$STATE"
  mk "$PKI"
  ensure_ca
  trust_stores
  pw="$(cat "$PKI/store-password")"
  gw="$PKI/certs"
  mk "$gw"

  # Names are the contract between the components: the gateway pins the SAN of every server it calls, and every client
  # verifies the broker and the gateway by these names (compose.yaml sets the matching network aliases).
  issue_cert mcp-gateway both "DNS:mcp-gateway.internal,DNS:mcp-gateway,DNS:$MCP_DOMAIN" 999:999 "$gw/mcp-gateway"
  issue_cert mcp-credential-broker serverAuth "DNS:mcp-credential-broker.internal,DNS:mcp-credential-broker" 100:101 "$gw/mcp-credential-broker"
  issue_cert mcp-portal-bff clientAuth "" 100:101 "$gw/mcp-portal-bff"
  issue_cert keycloak serverAuth "DNS:keycloak.internal,DNS:keycloak,DNS:localhost,IP:127.0.0.1" 1000:0 "$gw/keycloak"
  issue_cert openbao serverAuth "DNS:openbao.internal,DNS:openbao,DNS:localhost,IP:127.0.0.1" 100:1000 "$gw/openbao"

  # Per consumer, mounted read-only by that service only.
  dir "$S/gw" 0:0
  # The gateway image runs as uid 999 with the fixed gid 10001. Its own `init` (gateway-init) shares files with the gateway's
  # PostgreSQL and Redis as 0640 in that group, and keeps these directories at the modes set here, so they are not widened on
  # every start. The Redis services join the group (group_add in compose.yaml).
  dir "$S/gw/gateway" 999:10001 700
  dir "$S/gw/postgres" 999:10001 750
  dir "$S/gw/redis" 999:10001 750
  put "$S/gw/gateway/env/MCP_TLS_STORE_PASSWORD" 999:10001 400 < "$PKI/store-password"
  value kc-client-mcp-gateway > /dev/null
  value kc-client-mcp-portal-bff > /dev/null
  value kc-client-mcp-credential-broker > /dev/null
  value kc-client-mcp-gateway-admin > /dev/null
  value kc-client-opensearch > /dev/null
  chown 999:10001 "$S/gw/gateway/env"; chmod 755 "$S/gw/gateway/env"
  value kc-client-mcp-gateway | put "$S/gw/gateway/env/MCP_OIDC_CLIENT_SECRET" 999:10001 400

  dir "$S/portal" 0:0
  mk "$S/portal/env"; chown 100:101 "$S/portal/env"; chmod 755 "$S/portal/env"
  value kc-client-mcp-portal-bff | put "$S/portal/env/PORTAL_OIDC_CLIENT_SECRET" 100:101 400
  put "$S/portal/env/PORTAL_TLS_KEYSTORE_PASSWORD" 100:101 400 < "$PKI/store-password"
  put "$S/portal/env/PORTAL_TLS_TRUSTSTORE_PASSWORD" 100:101 400 < "$PKI/store-password"

  dir "$S/broker" 0:0
  mk "$S/broker/env"; chown 100:101 "$S/broker/env"; chmod 755 "$S/broker/env"
  put "$S/broker/env/MCP_TLS_STORE_PASSWORD" 100:101 400 < "$PKI/store-password"
  value broker-db | put "$S/broker/env/MCP_DB_PASSWORD" 100:101 400
  value broker-redis | put "$S/broker/env/MCP_REDIS_PASSWORD" 100:101 400
  value bao-role-id | put "$S/broker/env/MCP_BAO_ROLE_ID" 100:101 400
  value bao-secret-id | put "$S/broker/env/MCP_BAO_SECRET_ID" 100:101 400
  dir "$S/broker-postgres" 0:0
  value broker-db | put "$S/broker-postgres/password" 0:0 444

  dir "$S/broker-redis" 0:0
  broker_redis_password="$(value broker-redis)"
  # What the broker needs from Redis: its own keys, the jti store of internal tokens, locks (EVAL) and the publication of
  # credential.invalidated.
  put "$S/broker-redis/users.acl" 0:0 444 <<E
user default off resetkeys resetchannels -@all
user broker on >$broker_redis_password resetkeys ~broker:* ~jti:mcp-credential-broker:* resetchannels &credential.invalidated -@all +get +set +setnx +getdel +getex +mget +del +unlink +exists +expire +pexpire +ttl +pttl +incr +incrby +decr +hset +hget +hdel +hgetall +hexists +hincrby +multi +exec +discard +ping +auth +hello +client|setname +client|setinfo +reset +quit +publish +eval +evalsha
E
  redis_conf broker-redis

  dir "$S/openbao-approle" 0:0
  value bao-role-id | put "$S/openbao-approle/role-id" 0:0 400
  value bao-secret-id | put "$S/openbao-approle/secret-id" 0:0 400

  dir "$S/keycloak-postgres" 0:0
  value keycloak-db | put "$S/keycloak-postgres/password" 0:0 444
  dir "$S/keycloak" 1000:0
  put "$S/keycloak/env" 1000:0 400 <<E
KC_DB_PASSWORD=$(value keycloak-db)
KC_BOOTSTRAP_ADMIN_USERNAME=bootstrap-admin
KC_BOOTSTRAP_ADMIN_PASSWORD=$(value keycloak-bootstrap-admin)
MCP_ADMIN_INITIAL_PASSWORD=$(value admin-initial-password)
KC_CLIENT_MCP_GATEWAY_SECRET=$(value kc-client-mcp-gateway)
KC_CLIENT_MCP_PORTAL_BFF_SECRET=$(value kc-client-mcp-portal-bff)
KC_CLIENT_MCP_CREDENTIAL_BROKER_SECRET=$(value kc-client-mcp-credential-broker)
KC_CLIENT_MCP_GATEWAY_ADMIN_SECRET=$(value kc-client-mcp-gateway-admin)
KC_CLIENT_OPENSEARCH_SECRET=$(value kc-client-opensearch)
E

  dir "$S/servers-redis" 0:0
  servers_redis_acl
  redis_conf servers-redis

  say
  ok "configuration, certificates and secrets are in place"
  say "      first platform administrator: $MCP_ADMIN_USERNAME"
  say "      initial password: docker compose run --rm init show admin-password (valid until the first login)"
}

redis_conf() {
  put "$S/$1/redis.conf" 0:0 444 <<E
aclfile /secrets/redis/users.acl
dir /data
appendonly yes
appendfsync everysec
maxmemory-policy noeviction
E
}

# One account per MCP server: its jti keys only, no key scan, no scripts.
servers_redis_acl() {
  cmds='-@all +get +set +setnx +getdel +getex +mget +del +unlink +exists +expire +pexpire +ttl +pttl +incr +incrby +decr +hset +hget +hdel +hgetall +hexists +hincrby +multi +exec +discard +ping +auth +hello +client|setname +client|setinfo +reset +quit'
  {
    echo "user default off resetkeys resetchannels -@all"
    echo "user admin on >$(value servers-redis-admin) resetkeys resetchannels -@all +acl|load +auth +hello +ping +quit"
    for f in "$STATE"/servers/*/redis-password; do
      [ -f "$f" ] || continue
      id="$(basename "$(dirname "$f")")"
      echo "user $id on >$(cat "$f") resetkeys ~jti:$id:* resetchannels $cmds"
    done
  } | put "$S/servers-redis/users.acl" 0:0 444
}

# RESP over /dev/tcp: the init image has no redis-cli. Returns 0 when the running Redis loaded the new account file.
servers_redis_load() {
  respond() { printf '*%d\r\n' "$#"; for a in "$@"; do printf '$%d\r\n%s\r\n' "${#a}" "$a"; done; }
  reply="$( { respond AUTH admin "$(value servers-redis-admin)"; respond ACL LOAD; respond QUIT; } \
    | bash -c 'exec 3<>/dev/tcp/servers-redis/6379 || exit 1; cat >&3; timeout 5 cat <&3' 2>/dev/null || true)"
  [ "$(printf '%s' "$reply" | grep -c '^+OK')" -ge 3 ]
}

# ---- MCP servers and the pipeline

# The reserved system ids of mcp-contracts (ReservedSystemIds), also enforced by the gateway and the broker: mcp-<id> is the
# name of a platform component, so a certificate for it must never be issued here.
valid_server_id() {
  printf '%s' "$1" | grep -Eq '^mcp-[a-z][a-z0-9]{1,30}$' || die "$1 is not a server id (mcp-<system>, lower case letters and digits)"
  case "${1#mcp-}" in
    gateway|offboarding|portal|broker|prometheus|platform|admin|registry|adapter|internal|ci)
      die "$1 is reserved: mcp-${1#mcp-} is the name of a platform component" ;;
  esac
}

issue_server() {
  id="${1:-}"; uid="${2:-999}"
  valid_server_id "$id"
  printf '%s' "$uid" | grep -Eq '^[0-9]+$' || die "the uid $uid is not a number"
  [ -f "$PKI/ca/ca.crt" ] || die "the platform is not initialised yet: run docker compose up -d first"
  mkdir -p "$STATE/servers/$id"
  chmod 700 "$STATE/servers" "$STATE/servers/$id"
  issue_cert "$id" both "DNS:$id.internal,DNS:$id" "$uid:$uid" "$PKI/certs/$id"
  [ -s "$STATE/servers/$id/redis-password" ] || { openssl rand -hex 24 | tr -d '\n' > "$STATE/servers/$id/redis-password"; chmod 400 "$STATE/servers/$id/redis-password"; }
  [ -s "$STATE/servers/$id/cursor-key" ] || { openssl rand -base64 32 | tr -d '\n' > "$STATE/servers/$id/cursor-key"; chmod 400 "$STATE/servers/$id/cursor-key"; }
  e="$S/servers/$id/env"
  mk "$e"
  chown "$uid:$uid" "$e"; chmod 755 "$e" "$S/servers" "$S/servers/$id"
  put "$e/MCP_TLS_STORE_PASSWORD" "$uid:$uid" 400 < "$PKI/store-password"
  put "$e/MCP_REDIS_PASSWORD" "$uid:$uid" 400 < "$STATE/servers/$id/redis-password"
  put "$e/MCP_PAGING_CURSOR_KEY" "$uid:$uid" 400 < "$STATE/servers/$id/cursor-key"
  servers_redis_acl
  if servers_redis_load; then ok "redis account $id loaded"; else warn "servers-redis is not running: it loads the account when it starts"; fi
  say
  say "$id: certificate, Redis account and secrets are in the volume (owner uid $uid)."
  say "Next: add the service to your servers file (servers.example.yaml) and register it (README, Add an MCP server)."
}

# For a server on another host: its certificate, the truststore and an env file, as a tar on stdout (certs/keystore.p12,
# certs/truststore.p12, server.env) to unpack into the server's deploy/ directory. Everything else on stdout would corrupt the tar,
# so messages go to stderr. The Redis password is for the Redis that the server's own deploy/compose.yaml starts; the bundle's
# servers-redis is not reachable from another host and gets no account.
export_server() {
  id="${1:-}"
  valid_server_id "$id"
  [ -f "$PKI/ca/ca.crt" ] || die "the platform is not initialised yet: run docker compose up -d first"
  mkdir -p "$STATE/servers/$id"
  chmod 700 "$STATE/servers" "$STATE/servers/$id"
  issue_cert "$id" both "DNS:$id.internal,DNS:$id" 0:0 "$PKI/certs/$id" >&2
  [ -s "$STATE/servers/$id/remote-redis-password" ] || { openssl rand -hex 24 | tr -d '\n' > "$STATE/servers/$id/remote-redis-password"; chmod 400 "$STATE/servers/$id/remote-redis-password"; }
  [ -s "$STATE/servers/$id/cursor-key" ] || { openssl rand -base64 32 | tr -d '\n' > "$STATE/servers/$id/cursor-key"; chmod 400 "$STATE/servers/$id/cursor-key"; }
  gateway="https://$MCP_DOMAIN:${MCP_MTLS_PORT:-8443}"
  work="$(mktemp -d)"
  mkdir "$work/certs"
  cp "$PKI/certs/$id/keystore.p12" "$work/certs/keystore.p12"
  cp "$PKI/trust/truststore.p12" "$work/certs/truststore.p12"
  chmod 755 "$work/certs"
  chmod 644 "$work/certs/keystore.p12" "$work/certs/truststore.p12"
  cat > "$work/server.env" <<ENVFILE
MCP_TLS_STORE_PASSWORD=$(cat "$PKI/store-password")
MCP_PAGING_CURSOR_KEY=$(cat "$STATE/servers/$id/cursor-key")
MCP_REDIS_HOST=redis
MCP_REDIS_PORT=6379
MCP_REDIS_USER=$id
MCP_REDIS_PASSWORD=$(cat "$STATE/servers/$id/remote-redis-password")
MCP_GATEWAY_JWKS_URI=$gateway/.well-known/jwks.json
MCP_GATEWAY_POLICY_DATA_URL=$gateway/internal/v1/policy-data
MCP_CONNECT_URL=$MCP_PUBLIC_ORIGIN/connections?system={system}
MCP_INTERNAL_URL=https://$id.internal:8443/mcp
ENVFILE
  chmod 600 "$work/server.env"
  tar -C "$work" --owner=0 --group=0 --numeric-owner -cf - certs server.env
  rm -rf "$work"
  say "exported $id: unpack the tar in the server's deploy/ directory, add the URL of its backend system to server.env" >&2
}

issue_ci() {
  id="${1:-}"
  valid_server_id "$id"
  [ -f "$PKI/ca/ca.crt" ] || die "the platform is not initialised yet: run docker compose up -d first"
  issue_cert "mcp-registry-ci-$id" clientAuth "" 0:0 "$PKI/ci/mcp-registry-ci-$id" 90
  say "pipeline certificate for $id (valid 90 days, made again by this command when less than 30 are left): docker compose run --rm -T init show ci-cert $id / ci-key $id / ca"
}

show() {
  what="${1:-}"
  case "$what" in
    admin-password) printf '%s\n' "$(cat "$STATE/admin-initial-password")" ;;
    keycloak-admin) printf 'bootstrap-admin\n%s\n' "$(cat "$STATE/keycloak-bootstrap-admin")" ;;
    client-secret) [ -s "$STATE/kc-client-${2:-}" ] || die "no such client"; printf '%s\n' "$(cat "$STATE/kc-client-$2")" ;;
    ca) cat "$PKI/ca/ca.crt" ;;
    ci-cert) valid_server_id "${2:-}"; cat "$PKI/ci/mcp-registry-ci-$2/tls.crt" ;;
    ci-key) valid_server_id "${2:-}"; cat "$PKI/ci/mcp-registry-ci-$2/tls.key" ;;
    *) die "show: admin-password | keycloak-admin | client-secret <client> | ca | ci-cert <id> | ci-key <id>" ;;
  esac
}

# ---- OpenBao (runs in the OpenBao image, which is Alpine: POSIX sh only)

openbao() {
  set +e
  export BAO_ADDR="${BAO_ADDR:-https://openbao.internal:8200}"
  export BAO_CACERT=/trust/ca.crt
  keys=/keys
  ready=/tmp/ready
  last=""
  note() { [ "$last" = "$1" ] || { say "openbao-unseal: $1"; last="$1"; }; }

  # The init output (unseal key, root token) is parsed from a variable and written with umask 077; neither is ever printed.
  store_init_output() {
    key="$(printf '%s' "$1" | sed -n '/unseal_keys_b64/,/\]/{/unseal_keys_b64/d;/\]/d;s/^ *"\([^"]*\)".*/\1/p;}' | head -1)"
    root="$(printf '%s' "$1" | sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$key" ] && [ -n "$root" ] || return 1
    printf '%s\n' "$key" > "$keys/unseal-key.tmp" && printf '%s\n' "$root" > "$keys/root-token.tmp" || return 1
    mv "$keys/unseal-key.tmp" "$keys/unseal-key" && mv "$keys/root-token.tmp" "$keys/root-token"
  }

  # What provisioning needs and nothing else: no read or write of any secret, no Transit use.
  bootstrap_provisioner() {
    [ -s "$keys/root-token" ] || return 1
    root="$(cat "$keys/root-token")"
    BAO_TOKEN="$root" bao policy write mcp-provisioner - >/dev/null <<'HCL' || return 1
path "sys/mounts"   { capabilities = ["read"] }
path "sys/mounts/*" { capabilities = ["create", "read", "update"] }
path "sys/auth"     { capabilities = ["read"] }
path "sys/auth/*"   { capabilities = ["create", "read", "update", "sudo"] }
path "sys/policies/acl/*" { capabilities = ["create", "read", "update"] }
path "auth/approle/role/mcp-credential-broker"   { capabilities = ["create", "read", "update"] }
path "auth/approle/role/mcp-credential-broker/*" { capabilities = ["create", "read", "update", "delete"] }
path "transit/keys/mcp-credential-broker" { capabilities = ["create", "read", "update"] }
path "transit/keys/mcp-authenticators"    { capabilities = ["create", "read", "update"] }
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
HCL
    out="$(BAO_TOKEN="$root" bao token create -orphan -policy=mcp-provisioner -period=768h -display-name=provisioner -format=json 2>/dev/null)" || return 1
    tok="$(printf '%s' "$out" | sed -n 's/.*"client_token": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$tok" ] || return 1
    printf '%s\n' "$tok" > "$keys/provisioner-token.tmp" && mv "$keys/provisioner-token.tmp" "$keys/provisioner-token"
  }

  # Idempotent: creates what is missing, rewrites the policy, never touches Transit keys or stored secrets. Runs with the
  # token of the provisioner policy; the root token only creates that token and is revoked once provisioning has worked with it.
  provision() {
    export BAO_TOKEN
    if ! [ -s "$keys/provisioner-token" ] || ! BAO_TOKEN="$(cat "$keys/provisioner-token")" bao token lookup >/dev/null 2>&1; then
      bootstrap_provisioner || return 1
    fi
    BAO_TOKEN="$(cat "$keys/provisioner-token")"
    bao token renew >/dev/null 2>&1 || return 1
    role_id="$(cat /approle/role-id)"
    secret_id="$(cat /approle/secret-id)"
    bao secrets list -format=json | grep -q '"secret/"' || bao secrets enable -path=secret -version=2 kv >/dev/null || return 1
    bao secrets list -format=json | grep -q '"transit/"' || bao secrets enable transit >/dev/null || return 1
    bao read transit/keys/mcp-credential-broker >/dev/null 2>&1 || bao write -f transit/keys/mcp-credential-broker type=aes256-gcm96 >/dev/null || return 1
    # A separate key: seeds of the Authenticator can be rotated or revoked without touching stored credentials.
    bao read transit/keys/mcp-authenticators >/dev/null 2>&1 || bao write -f transit/keys/mcp-authenticators type=aes256-gcm96 >/dev/null || return 1
    bao policy write mcp-credential-broker - >/dev/null <<'HCL' || return 1
path "secret/data/mcp/connections/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/mcp/connections/*" { capabilities = ["read", "list", "delete"] }
path "secret/data/mcp/system-clients/*"     { capabilities = ["create", "read", "update"] }
path "secret/metadata/mcp/system-clients/*" { capabilities = ["read"] }
path "secret/destroy/mcp/system-clients/*"  { capabilities = ["update"] }
path "secret/data/mcp/oauth-clients/*"      { capabilities = ["read"] }
path "secret/data/mcp/service-accounts/*"   { capabilities = ["read"] }
path "transit/encrypt/mcp-credential-broker" { capabilities = ["update"] }
path "transit/decrypt/mcp-credential-broker" { capabilities = ["update"] }
path "secret/data/mcp/authenticators/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/mcp/authenticators/*" { capabilities = ["read", "list", "delete"] }
path "transit/encrypt/mcp-authenticators" { capabilities = ["update"] }
path "transit/decrypt/mcp-authenticators" { capabilities = ["update"] }
HCL
    bao auth list -format=json | grep -q '"approle/"' || bao auth enable approle >/dev/null || return 1
    # The broker keeps one secret_id and logs in with it whenever its token ends, so the secret_id does not expire. Replacing
    # it is a decision of the operator (README, Rotate the broker's secret_id).
    bao write auth/approle/role/mcp-credential-broker token_policies=mcp-credential-broker token_ttl=1h token_max_ttl=4h >/dev/null || return 1
    bao write auth/approle/role/mcp-credential-broker/role-id role_id="$role_id" >/dev/null || return 1
    lookup="$(printf '%s' "$secret_id" | bao write -format=json auth/approle/role/mcp-credential-broker/secret-id/lookup secret_id=- 2>/dev/null || true)"
    if ! printf '%s' "$lookup" | grep -q '"secret_id_accessor"'; then
      printf '%s' "$secret_id" | bao write auth/approle/role/mcp-credential-broker/custom-secret-id secret_id=- >/dev/null || return 1
    fi
    if [ -s "$keys/root-token" ]; then
      BAO_TOKEN="$(cat "$keys/root-token")" bao token revoke -self >/dev/null 2>&1 && rm -f "$keys/root-token" && say "openbao-unseal: root token revoked"
    fi
    unset BAO_TOKEN
    return 0
  }

  provisioned_at=0
  while true; do
    status="$(bao status -format=json 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 1 ] || [ -z "$status" ]; then
      rm -f "$ready"
      note "waiting for the server"
    elif printf '%s' "$status" | grep -q '"initialized": *false'; then
      rm -f "$ready"
      if [ -s "$keys/unseal-key" ]; then
        # Overwriting would make the old volume impossible to unseal.
        note "REFUSING TO INIT: the server is empty but $keys/unseal-key exists (volume openbao-data lost or replaced)"
      else
        note "not initialised, running init"
        if out="$(bao operator init -key-shares=1 -key-threshold=1 -format=json 2>/dev/null)"; then
          if store_init_output "$out"; then note "initialised, key and root token stored in $keys"
          else note "INIT DONE BUT KEYS NOT STORED: remove the volume openbao-data and start again"; fi
        else
          note "init failed"
        fi
        out=""
      fi
    elif printf '%s' "$status" | grep -q '"sealed": *true'; then
      rm -f "$ready"
      provisioned_at=0
      if [ -s "$keys/unseal-key" ]; then
        note "sealed, unsealing"
        bao write sys/unseal key=- < "$keys/unseal-key" >/dev/null 2>&1 || note "unseal failed"
      else
        note "SEALED AND NO KEY in $keys/unseal-key: restore the volume openbao-keys, or remove openbao-data (secrets are lost)"
      fi
    else
      now="$(date +%s)"
      if [ "$provisioned_at" -eq 0 ] || [ $(( now - provisioned_at )) -ge 21600 ]; then
        if provision; then
          provisioned_at="$now"
          touch "$ready"
          note "unsealed and provisioned"
        else
          rm -f "$ready"
          note "provisioning failed, retrying"
        fi
      fi
    fi
    sleep 2
  done
}

case "${1:-bootstrap}" in
  bootstrap) bootstrap ;;
  issue) shift; issue_server "$@" ;;
  ci) shift; issue_ci "$@" ;;
  export) shift; export_server "$@" ;;
  show) shift; show "$@" ;;
  openbao) openbao ;;
  *) die "unknown command $1 (see the top of init/init.sh)" ;;
esac
