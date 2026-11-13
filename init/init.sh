#!/bin/sh
# The one entry point of the platform's setup. Runs in the "init" service (eclipse-temurin image: openssl, keytool, bash) and,
# as "openbao", in the "openbao-unseal" service (OpenBao image).
#
#   init.sh                  every start: check the configuration, generate what is missing, keep what exists
#   init.sh show <what>      print one generated value: admin-password, keycloak-admin, client-secret <client>, ca
#   init.sh openbao          initialise, unseal and provision OpenBao, then keep it unsealed (never returns)
#   init.sh recover          new provisioner token after it expired or was lost; runs in the "openbao-recover" service
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
# Services whose certificate or trust store this run replaced on an existing installation: Java and the TLS servers read them only
# at start, so they keep the old ones until restarted.
restart=""

say()  { printf '%s\n' "$*"; }
ok()   { printf 'ok    %s\n' "$*"; }
new()  { printf 'new   %s\n' "$*" >&2; }
warn() { printf 'warn  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
needs_restart() { for s in "$@"; do case " $restart " in *" $s "*) ;; *) restart="${restart:+$restart }$s" ;; esac; done; }

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

# issue_cert <name> <serverAuth|clientAuth|both> <subjectAltName list> <owner> <dir> <service> [days]
# The certificate is made again when it is missing, expires within 30 days, or the names or the CA changed. A directory that
# holds the certificate of another name is never overwritten.
issue_cert() {
  name="$1"; role="$2"; sans="$3"; owner="$4"; d="$5"; service="$6"; days="${7:-730}"
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
  [ -f "$d/tls.crt" ] && needs_restart "$service"
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
  sig="$(cat "$PKI/ca/ca.crt" "$JAVA_HOME/lib/security/cacerts" 2>/dev/null | sha256sum | cut -d' ' -f1)-$company-outbound"
  [ "$company" = 1 ] && sig="$sig-$(sha256sum < "$OPERATOR/company-ca.crt" | cut -d' ' -f1)"
  [ -f "$t/truststore.p12" ] && [ "$(cat "$t/signature" 2>/dev/null)" = "$sig" ] && return 0
  [ -f "$t/truststore.p12" ] && needs_restart gateway mcp-credential-broker portal

  work="$(mktemp -d)"
  keytool -importcert -noprompt -alias mcp-internal-ca -file "$PKI/ca/ca.crt" -keystore "$work/truststore.p12" \
    -storetype PKCS12 -storepass "$pw" >/dev/null 2>&1
  # The broker's connections out (identity provider, OpenBao, gateway, the systems behind it) trust this one; truststore.p12
  # decides the client certificates the gateway and the broker accept and keeps the internal CA alone.
  cp "$work/truststore.p12" "$work/broker-outbound-truststore.p12"
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
      keytool -importcert -noprompt -alias "$n" -file "$c" -keystore "$work/broker-outbound-truststore.p12" -storetype PKCS12 -storepass "$pw" >/dev/null 2>&1
    done
  fi
  for f in truststore.p12 broker-outbound-truststore.p12 jvm-truststore.p12; do
    mv "$work/$f" "$t/$f"
    chmod 444 "$t/$f"
  done
  # Before 2.0 the broker had one store for both directions, with the company CA in it on request.
  rm -f "$t/broker-truststore.p12"
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

  # Names are the contract between the components: every client verifies the broker and the gateway by these names (compose.yaml sets the matching network aliases).
  issue_cert mcp-gateway both "DNS:mcp-gateway.internal,DNS:mcp-gateway" 999:999 "$gw/mcp-gateway" gateway
  issue_cert mcp-credential-broker serverAuth "DNS:mcp-credential-broker.internal,DNS:mcp-credential-broker" 100:101 "$gw/mcp-credential-broker" mcp-credential-broker
  issue_cert mcp-portal-bff clientAuth "" 100:101 "$gw/mcp-portal-bff" portal
  issue_cert keycloak serverAuth "DNS:keycloak.internal,DNS:keycloak,DNS:localhost,IP:127.0.0.1" 1000:0 "$gw/keycloak" keycloak
  issue_cert openbao serverAuth "DNS:openbao.internal,DNS:openbao,DNS:localhost,IP:127.0.0.1" 100:1000 "$gw/openbao" openbao

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
  # The marker of keycloak-config (keycloak/configure.sh) that its one run happened.
  dir "$S/keycloak-config" 1000:0 700

  say
  ok "configuration, certificates and secrets are in place"
  if [ -n "$restart" ]; then
    warn "certificates or trust stores changed; these services still use the old ones until: docker compose restart $restart"
  fi
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

show() {
  what="${1:-}"
  case "$what" in
    admin-password) printf '%s\n' "$(cat "$STATE/admin-initial-password")" ;;
    keycloak-admin) printf 'bootstrap-admin\n%s\n' "$(cat "$STATE/keycloak-bootstrap-admin")" ;;
    client-secret) [ -s "$STATE/kc-client-${2:-}" ] || die "no such client"; printf '%s\n' "$(cat "$STATE/kc-client-$2")" ;;
    ca) cat "$PKI/ca/ca.crt" ;;
    *) die "show: admin-password | keycloak-admin | client-secret <client> | ca" ;;
  esac
}

# ---- OpenBao (runs in the OpenBao image, which is Alpine: POSIX sh only)

keys=/keys

# The init output (unseal key, root token) is parsed from a variable and written with umask 077; neither is ever printed.
store_init_output() {
  key="$(printf '%s' "$1" | sed -n '/unseal_keys_b64/,/\]/{/unseal_keys_b64/d;/\]/d;s/^ *"\([^"]*\)".*/\1/p;}' | head -1)"
  root="$(printf '%s' "$1" | sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$key" ] && [ -n "$root" ] || return 1
  printf '%s\n' "$key" > "$keys/unseal-key.tmp" && printf '%s\n' "$root" > "$keys/root-token.tmp" || return 1
  mv "$keys/unseal-key.tmp" "$keys/unseal-key" && mv "$keys/root-token.tmp" "$keys/root-token"
}

# What provisioning needs and nothing else: no read or write of any secret, no Transit use, no write of any policy or of the broker's
# AppRole settings (those are written with the root token only: bootstrap_provisioner and `recover`). It creates the two mounts and
# the two Transit keys, reads both policies and the role to check them, and checks or sets the broker's secret_id, which lets it act as
# the broker (read connection credentials and service-account keys) but not as anything with a wider policy. It reads a Raft snapshot,
# which holds every secret in encrypted form. sys/auth is read-only: enabling a method needs sudo, so the AppRole method is enabled with root.
provisioner_policy() {
  cat <<'HCL'
path "sys/mounts"         { capabilities = ["read"] }
path "sys/mounts/secret"  { capabilities = ["create", "read", "update"] }
path "sys/mounts/transit" { capabilities = ["create", "read", "update"] }
path "sys/auth"           { capabilities = ["read"] }
path "sys/policies/acl/mcp-credential-broker" { capabilities = ["read"] }
path "sys/policies/acl/mcp-provisioner"       { capabilities = ["read"] }
path "auth/approle/role/mcp-credential-broker"                  { capabilities = ["read"] }
path "auth/approle/role/mcp-credential-broker/role-id"          { capabilities = ["read"] }
path "auth/approle/role/mcp-credential-broker/secret-id/lookup" { capabilities = ["update"] }
path "auth/approle/role/mcp-credential-broker/custom-secret-id" { capabilities = ["update"] }
path "transit/keys/mcp-credential-broker" { capabilities = ["create", "read", "update"] }
path "transit/keys/mcp-authenticators"    { capabilities = ["create", "read", "update"] }
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
HCL
}

broker_policy() {
  cat <<'HCL'
path "secret/data/mcp/connections/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/mcp/connections/*" { capabilities = ["read", "list", "delete"] }
path "secret/data/mcp/system-clients/*"     { capabilities = ["create", "read", "update"] }
path "secret/metadata/mcp/system-clients/*" { capabilities = ["read"] }
path "secret/destroy/mcp/system-clients/*"  { capabilities = ["update"] }
path "secret/data/mcp/oauth-clients/*"      { capabilities = ["read"] }
path "secret/data/mcp/service-accounts/*"     { capabilities = ["create", "read", "update"] }
path "secret/metadata/mcp/service-accounts/*" { capabilities = ["read", "delete"] }
path "transit/encrypt/mcp-credential-broker" { capabilities = ["update"] }
path "transit/decrypt/mcp-credential-broker" { capabilities = ["update"] }
path "secret/data/mcp/authenticators/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/mcp/authenticators/*" { capabilities = ["read", "list", "delete"] }
path "transit/encrypt/mcp-authenticators" { capabilities = ["update"] }
path "transit/decrypt/mcp-authenticators" { capabilities = ["update"] }
HCL
}

provisioner_valid() {
  [ -s "$keys/provisioner-token" ] && BAO_TOKEN="$(cat "$keys/provisioner-token")" bao token lookup >/dev/null 2>&1
}

# True only when OpenBao answered and refused the token (expired, revoked) or there is none: not while the server is restarting.
provisioner_dead() {
  [ -s "$keys/provisioner-token" ] || return 0
  BAO_TOKEN="$(cat "$keys/provisioner-token")" bao token lookup 2>&1 | grep -q 'permission denied'
}

# mint_provisioner <root token>: everything that needs root. Writes both policies and the broker's AppRole settings, enables AppRole,
# creates the provisioner token. A release that changes any of these needs one `recover` run (README, Upgrade).
mint_provisioner() {
  provisioner_policy | BAO_TOKEN="$1" bao policy write mcp-provisioner - >/dev/null || return 1
  broker_policy | BAO_TOKEN="$1" bao policy write mcp-credential-broker - >/dev/null || return 1
  BAO_TOKEN="$1" bao auth list -format=json | grep -q '"approle/"' || BAO_TOKEN="$1" bao auth enable approle >/dev/null || return 1
  # The broker keeps one secret_id and logs in with it whenever its token ends, so the secret_id does not expire. Replacing
  # it is a decision of the operator (README, Rotate the broker's secret_id).
  BAO_TOKEN="$1" bao write auth/approle/role/mcp-credential-broker token_policies=mcp-credential-broker token_ttl=1h token_max_ttl=4h >/dev/null || return 1
  BAO_TOKEN="$1" bao write auth/approle/role/mcp-credential-broker/role-id role_id="$(cat /approle/role-id)" >/dev/null || return 1
  out="$(BAO_TOKEN="$1" bao token create -orphan -policy=mcp-provisioner -period=768h -display-name=provisioner -format=json 2>/dev/null)" || return 1
  tok="$(printf '%s' "$out" | sed -n 's/.*"client_token": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$tok" ] || return 1
  printf '%s\n' "$tok" > "$keys/provisioner-token.tmp" && mv "$keys/provisioner-token.tmp" "$keys/provisioner-token"
}

bootstrap_provisioner() {
  [ -s "$keys/root-token" ] || return 1
  mint_provisioner "$(cat "$keys/root-token")"
}

# An installation made before the restriction holds a token whose policy can still rewrite mcp-provisioner: do it once, with
# that token, so that the narrowed policy applies from the next request on. A failing capability lookup is an error, not "nothing to do".
narrow_provisioner_policy() {
  caps="$(bao token capabilities sys/policies/acl/mcp-provisioner 2>/dev/null)" || return 1
  printf '%s' "$caps" | grep -Eq 'create|update' || return 0
  provisioner_policy | bao policy write mcp-provisioner - >/dev/null || return 1
  say "openbao-unseal: policy mcp-provisioner narrowed"
}

squeeze() { tr -s ' \t\n' ' ' | sed 's/^ //; s/ $//'; }

# check_policy <name> <generator>: a policy that is not the one of this release is reported, not rewritten (only root can).
# Returns 1 when OpenBao could not be asked.
check_policy() {
  have="$(bao policy read "$1" 2>/dev/null)" || return 1
  if [ "$(printf '%s' "$have" | squeeze)" != "$("$2" | squeeze)" ]; then
    say "FAIL policy $1 differs from this release: docker compose run --rm openbao-recover"
    drift=1
  fi
}

# Idempotent: creates what is missing, never touches Transit keys or stored secrets, never writes a policy. Runs with the token of
# the provisioner policy; the root token only creates that token and is revoked once provisioning has worked with it. What differs
# from this release (policies, AppRole settings) sets $drift and prints a FAIL line, but does not fail the run: the broker keeps
# working on what is there.
provision() {
  export BAO_TOKEN
  drift=0
  provisioner_valid || bootstrap_provisioner || return 1
  BAO_TOKEN="$(cat "$keys/provisioner-token")"
  bao token renew >/dev/null 2>&1 || return 1
  narrow_provisioner_policy || return 1
  check_policy mcp-provisioner provisioner_policy || return 1
  role_id="$(cat /approle/role-id)"
  secret_id="$(cat /approle/secret-id)"
  bao secrets list -format=json | grep -q '"secret/"' || bao secrets enable -path=secret -version=2 kv >/dev/null || return 1
  bao secrets list -format=json | grep -q '"transit/"' || bao secrets enable transit >/dev/null || return 1
  bao read transit/keys/mcp-credential-broker >/dev/null 2>&1 || bao write -f transit/keys/mcp-credential-broker type=aes256-gcm96 >/dev/null || return 1
  # A separate key: seeds of the Authenticator can be rotated or revoked without touching stored credentials.
  bao read transit/keys/mcp-authenticators >/dev/null 2>&1 || bao write -f transit/keys/mcp-authenticators type=aes256-gcm96 >/dev/null || return 1
  check_policy mcp-credential-broker broker_policy || return 1
  if ! bao auth list -format=json | grep -q '"approle/"'; then
    say "FAIL the AppRole auth method is not enabled: docker compose run --rm openbao-recover"
    return 1
  fi
  role="$(bao read -format=json auth/approle/role/mcp-credential-broker 2>/dev/null)" || return 1
  if ! printf '%s' "$role" | tr -d ' \n' | grep -q '"token_policies":\["mcp-credential-broker"\]' \
     || ! printf '%s' "$role" | tr -d ' \n' | grep -q '"token_ttl":3600' || ! printf '%s' "$role" | tr -d ' \n' | grep -q '"token_max_ttl":14400' \
     || [ "$(bao read -field=role_id auth/approle/role/mcp-credential-broker/role-id 2>/dev/null)" != "$role_id" ]; then
    say "FAIL the broker's AppRole settings differ from this release: docker compose run --rm openbao-recover"
    drift=1
  fi
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

openbao() {
  set +e
  export BAO_ADDR="${BAO_ADDR:-https://openbao.internal:8200}"
  export BAO_CACERT=/trust/ca.crt
  ready=/tmp/ready
  last=""
  note() { [ "$last" = "$1" ] || { say "openbao-unseal: $1"; last="$1"; }; }

  provisioned_at=0
  while true; do
    status="$(bao status -format=json 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 1 ] || [ -z "$status" ]; then
      rm -f "$ready"
      # Whoever unseals during a restart (openbao-recover) can beat this loop to it: provision again once the server is back.
      provisioned_at=0
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
          if provisioner_dead && [ ! -s "$keys/root-token" ]; then
            note "FAIL the provisioner token has expired or is lost and there is no root token: docker compose run --rm openbao-recover"
          else
            note "provisioning failed, retrying"
          fi
        fi
      fi
    fi
    sleep 2
  done
}

# ---- recovery of the provisioner token

# recover: for a provisioner token that expired (period 768h: OpenBao was down for more than 32 days) or was lost, and for a release
# that changes a policy. Runs in openbao-recover, which shares the network of the openbao container. OpenBao 2.6 and later generate a
# root token only through an authenticated endpoint, unless a listener sets disable_unauthed_generate_root_endpoints = false. So:
# openbao/run.sh restarts the server with the loopback listener of openbao/recovery-listener.hcl while the flag file
# /recovery/enabled is fresh; the unseal key makes a root token through it, which is at once swapped for one that expires in 15
# minutes; that one writes the policies and mints the new provisioner token and is revoked; the flag goes and the server restarts
# without the listener. Nothing of this stays behind on failure: cleanup revokes both tokens, cancels a generation in progress and
# removes the flag; run.sh ignores a flag older than 10 minutes even when this process is killed, and every run revokes the root
# tokens a killed run left behind.
recover() {
  set +e
  export BAO_CACERT=/trust/ca.crt
  main_addr="${BAO_ADDR:-https://127.0.0.1:8200}"
  export BAO_ADDR="$main_addr"
  rec_addr=http://127.0.0.1:8300
  marker=/recovery/enabled
  lock=/recovery/lock
  gen_token=""
  root_token=""
  clean=0

  [ -s "$keys/unseal-key" ] || die "$keys/unseal-key is missing: openbao-keys is not the volume of this installation"
  status="$(bao status -format=json 2>/dev/null)"
  [ -n "$status" ] || die "OpenBao does not answer on $main_addr"
  printf '%s' "$status" | grep -q '"initialized": *true' || die "OpenBao is not initialised: start openbao-unseal first"

  unseal_at() {
    st="$(BAO_ADDR="$1" bao status -format=json 2>/dev/null)"
    printf '%s' "$st" | grep -q '"sealed": *true' || return 0
    BAO_ADDR="$1" bao write sys/unseal key=- < "$keys/unseal-key" >/dev/null 2>&1
  }
  # wait_state <addr> <up|down>: 90 seconds at most.
  wait_state() {
    n=0
    while [ "$n" -lt 90 ]; do
      BAO_ADDR="$1" bao status -format=json >/dev/null 2>&1
      rc=$?
      if [ "$2" = up ] && [ "$rc" -ne 1 ]; then return 0; fi
      if [ "$2" = down ] && [ "$rc" -eq 1 ]; then return 0; fi
      n=$((n + 1)); sleep 1
    done
    return 1
  }
  # revoke_token <token>: retried across the restarts; a token that is already gone counts as revoked.
  revoke_token() {
    n=0
    while [ "$n" -lt 20 ]; do
      for a in "$main_addr" "$rec_addr"; do
        unseal_at "$a"
        BAO_ADDR="$a" BAO_TOKEN="$1" bao token revoke -self >/dev/null 2>&1 && return 0
        BAO_ADDR="$a" BAO_TOKEN="$1" bao token lookup 2>&1 | grep -q 'permission denied' && return 0
      done
      n=$((n + 1)); sleep 2
    done
    return 1
  }
  # Root tokens a killed run left behind never expire: revoke every one except the current.
  sweep_root_tokens() {
    me="$(BAO_TOKEN="$root_token" bao token lookup 2>/dev/null | sed -n 's/^accessor  *//p')"
    list="$(BAO_TOKEN="$root_token" bao list -format=json auth/token/accessors 2>/dev/null)" || return 1
    [ -n "$me" ] || return 1
    swept=0
    for acc in $(printf '%s' "$list" | sed 's/[][",]/ /g'); do
      [ "$acc" = "$me" ] && continue
      pol="$(BAO_TOKEN="$root_token" bao token lookup -accessor "$acc" 2>/dev/null | sed -n 's/^policies  *//p')"
      if [ "$pol" = "[root]" ]; then
        BAO_TOKEN="$root_token" bao token revoke -accessor "$acc" >/dev/null 2>&1 || return 1
        swept=$((swept + 1))
      fi
    done
  }

  # One run at a time; the lock of a run that was killed goes stale after the 10 minutes in which its flag file expires.
  mk /recovery
  if ! mkdir "$lock" 2>/dev/null; then
    age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || echo 0) ))
    if [ "$age" -gt 600 ]; then rmdir "$lock" 2>/dev/null; mkdir "$lock" || die "cannot take $lock"
    else die "another recover is running, or one was killed less than 10 minutes ago: wait and run it again"; fi
  fi

  cleanup() {
    [ "$clean" -eq 0 ] || return 0
    clean=1
    trap '' INT TERM HUP
    trap - EXIT
    left=0
    for t in "$gen_token" "$root_token"; do
      [ -z "$t" ] || revoke_token "$t" || left=1
    done
    gen_token=""; root_token=""
    BAO_ADDR="$rec_addr" bao delete sys/generate-root/attempt >/dev/null 2>&1
    rm -f "$marker"
    if wait_state "$rec_addr" down && wait_state "$main_addr" up; then unseal_at "$main_addr"; else
      warn "the recovery listener may still be open: it closes by itself within 10 minutes (openbao/run.sh)"
    fi
    rmdir "$lock" 2>/dev/null
    [ "$left" -eq 0 ] || printf 'FAIL  a root token could not be revoked (the short-lived one expires within 15 minutes): run docker compose run --rm openbao-recover again, it revokes every other root token\n'
  }
  trap cleanup EXIT
  trap 'cleanup; exit 1' INT TERM HUP

  if provisioner_valid; then
    warn "the provisioner token is still valid: replacing it anyway"
  else
    ok "provisioner token is expired or missing"
  fi

  : > "$marker" || die "cannot write $marker"
  wait_state "$rec_addr" up || die "the recovery listener did not come up"
  unseal_at "$rec_addr" || die "unseal failed"
  wait_state "$rec_addr" up
  ok "recovery listener open on 127.0.0.1:8300 of the openbao container (closes at the end of this command)"

  # A generation left behind by an earlier, killed run would make this one fail with "already in progress".
  BAO_ADDR="$rec_addr" bao delete sys/generate-root/attempt >/dev/null 2>&1
  att="$(BAO_ADDR="$rec_addr" bao write -f -format=json sys/generate-root/attempt 2>/dev/null)"
  nonce="$(printf '%s' "$att" | sed -n 's/.*"nonce": *"\([^"]*\)".*/\1/p' | head -1)"
  otp="$(printf '%s' "$att" | sed -n 's/.*"otp": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$nonce" ] && [ -n "$otp" ] || die "could not start the root token generation"
  upd="$(BAO_ADDR="$rec_addr" bao write -format=json sys/generate-root/update key=- nonce="$nonce" < "$keys/unseal-key" 2>/dev/null)"
  enc="$(printf '%s' "$upd" | sed -n 's/.*"encoded_token": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$enc" ] || die "the unseal key was not accepted"
  gen_token="$(xor_decode "$enc" "$otp")"
  [ -n "$gen_token" ] || die "could not decode the root token"
  # The generated token never expires: use it for one call, which makes the one this run works with.
  out="$(BAO_TOKEN="$gen_token" bao token create -orphan -policy=root -ttl=15m -format=json 2>/dev/null)" || die "the generated root token does not work"
  root_token="$(printf '%s' "$out" | sed -n 's/.*"client_token": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$root_token" ] || die "could not create the short-lived root token"
  revoke_token "$gen_token" || die "could not revoke the generated root token"
  gen_token=""
  sweep_root_tokens || die "could not list or revoke the root tokens of earlier runs"
  [ "$swept" -eq 0 ] || ok "revoked $swept root token(s) left behind by an earlier run"

  old=""
  provisioner_valid && old="$(cat "$keys/provisioner-token")"
  mint_provisioner "$root_token" || die "could not write the policies or create the provisioner token"
  [ -z "$old" ] || BAO_TOKEN="$old" bao token revoke -self >/dev/null 2>&1
  revoke_token "$root_token" || die "could not revoke the root token"
  root_token=""
  ok "policies written, new provisioner token in the volume openbao-keys, root token revoked"

  cleanup
  provisioner_valid || die "the new provisioner token does not work"
  # openbao-unseal provisions too, as soon as it sees the new token; two runs at once can lose a storage transaction.
  n=0
  until provision && [ "$drift" -eq 0 ]; do
    n=$((n + 1))
    [ "$n" -lt 5 ] || die "provisioning failed with the new token (see the log of openbao-unseal)"
    sleep 3
  done
  ok "provisioning ran with the new token"
  ok "recovered: openbao-unseal renews the provisioner token from now on"
}

# xor_decode <base64 without padding> <otp>: the encoded root token is the token XOR the one-time password, byte by byte.
xor_decode() {
  case $(( ${#1} % 4 )) in 2) pad="==" ;; 3) pad="=" ;; *) pad="" ;; esac
  set -- "$(printf '%s%s' "$1" "$pad" | base64 -d | od -An -v -tu1 | tr -s ' \n' ' ')" "$(printf '%s' "$2" | od -An -v -tu1 | tr -s ' \n' ' ')"
  out=""
  i=1
  for b in $1; do
    o="$(printf '%s' "$2" | cut -d' ' -f$((i + 1)))"
    out="$out$(printf "\\$(printf '%03o' $(( b ^ o )))")"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

case "${1:-bootstrap}" in
  bootstrap) bootstrap ;;
  show) shift; show "$@" ;;
  openbao) openbao ;;
  recover)
    # The init image has neither the bao client nor the keys volume.
    if command -v bao >/dev/null 2>&1; then recover
    else die "recover runs in another service: docker compose run --rm openbao-recover"; fi ;;
  *) die "unknown command $1 (see the top of init/init.sh)" ;;
esac
