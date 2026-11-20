#!/bin/sh
# The Helm chart in charts/mcp-platform: its copies of the nginx and portal files equal the originals, its image versions equal the
# defaults of compose.yaml, and it lints and renders with dummy values (no cluster, nothing is installed).
# Set REQUIRE_HELM=1 to fail when helm is missing instead of skipping the lint and render.
set -eu
cd "$(dirname "$0")/.."
chart=charts/mcp-platform

for f in nginx.conf servers.conf.template routes.conf proxy-common.conf to-portal.conf to-gateway.conf to-keycloak.conf \
         keycloak-admin-allow.conf gateway-headers.conf; do
  cmp -s "nginx/$f" "$chart/files/nginx/$f" || { echo "$chart/files/nginx/$f differs from nginx/$f" >&2; exit 1; }
done
diff -r nginx/errors "$chart/files/nginx/errors" >/dev/null || { echo "$chart/files/nginx/errors differs from nginx/errors" >&2; exit 1; }
cmp -s portal/iga-catalog.yaml "$chart/files/portal/iga-catalog.yaml" || { echo "$chart/files/portal/iga-catalog.yaml differs from portal/iga-catalog.yaml" >&2; exit 1; }

# compose.yaml carries each default as ${VAR:-<tag>@<digest>}; the chart values carry the same string.
for pair in MCP_GATEWAY_VERSION:gateway MCP_BROKER_VERSION:broker MCP_PORTAL_VERSION:portal; do
  var=${pair%%:*}
  key=${pair#*:}
  want=$(grep -oE "\\\$\{$var:-[^}]+\}" compose.yaml | head -n 1 | sed -e 's/^.*:-//' -e 's/}$//')
  have=$(awk -v key="$key:" '$0 == key { on = 1 } on && $1 == "version:" { print $2; exit }' "$chart/values.yaml")
  [ -n "$want" ] && [ "$want" = "$have" ] || { echo "$chart/values.yaml: $key image version '$have' differs from compose.yaml '$want'" >&2; exit 1; }
done
want=$(grep -oE 'nginx:[^ ]+@sha256:[0-9a-f]{64}' compose.yaml | head -n 1 | sed 's/^nginx://')
have=$(awk '$0 == "nginx:" { on = 1 } on && $1 == "version:" { print $2; exit }' "$chart/values.yaml")
[ "$want" = "$have" ] || { echo "$chart/values.yaml: nginx image version '$have' differs from compose.yaml '$want'" >&2; exit 1; }

if command -v helm >/dev/null 2>&1; then
  values=$(mktemp)
  trap 'rm -f "$values"' EXIT
  cat > "$values" <<'VALUES'
global: {publicOrigin: "https://mcp.corp.test", publicDomain: mcp.corp.test}
keycloak: {host: keycloak.idp.svc.cluster.local, internalBaseUrl: "https://keycloak.corp.test:8443"}
postgresql:
  gateway: {url: "jdbc:postgresql://postgres.data.svc:5432/gateway"}
  broker: {url: "jdbc:postgresql://postgres.data.svc:5432/broker"}
redis:
  gateway: {host: redis-gateway.data.svc}
  broker: {host: redis-broker.data.svc}
openbao: {addr: "https://openbao.corp.test:8200"}
tls: {trustSecretName: mcp-trust}
nginx: {tlsSecretName: mcp-tls}
gateway: {envSecretName: mcp-gateway-env, tlsSecretName: mcp-gateway-tls}
broker: {envSecretName: mcp-broker-env, tlsSecretName: mcp-broker-tls}
portal: {envSecretName: mcp-portal-env, tlsSecretName: mcp-portal-tls, trustedProxies: "10[.]244[.].*"}
VALUES
  echo "helm lint"
  helm lint "$chart" -f "$values"
  echo "helm template"
  rendered=$(helm template mcp "$chart" -f "$values")
  # The upstream names of the nginx files are replaced by the Service names of the release; an unchanged name means the
  # original file changed and the replacement no longer matches.
  for name in 'proxy_pass http://gateway:8080' 'proxy_pass http://portal:8080' 'proxy_pass http://keycloak:8080'; do
    if printf '%s\n' "$rendered" | grep -qF "$name"; then echo "$chart: nginx upstream '$name' was not replaced" >&2; exit 1; fi
  done
  if helm template mcp "$chart" >/dev/null 2>&1; then echo "$chart renders without the required values" >&2; exit 1; fi
elif [ "${REQUIRE_HELM:-}" = 1 ]; then
  echo "helm is required and not installed" >&2
  exit 1
else
  echo "helm not installed, lint and render skipped"
fi
