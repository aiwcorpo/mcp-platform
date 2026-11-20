# Helm chart: mcp-platform

Runs the gateway, the credential broker, the portal and nginx of the MCP Platform on Kubernetes. PostgreSQL (two databases),
Redis (two instances), Keycloak and OpenBao are yours: the chart takes their addresses. It creates no Secret with values; every
secret is referenced by name.

Status: version 0.1.0, not released. Installed and run on a single-node kind cluster (Kubernetes 1.35, linux/amd64 images under
emulation on an arm64 host) against throwaway PostgreSQL, Redis and a stub in place of Keycloak. Not tested on OpenShift, on a
multi-node cluster, with a real Keycloak and OpenBao, or with the autoscaler acting (the kind cluster had no metrics server).

## What the chart contains

| Workload | Replicas | Notes |
| --- | --- | --- |
| gateway | 2 to 6 (HorizontalPodAutoscaler on CPU) | stateless: state is in PostgreSQL and Redis, the secret is shared; PodDisruptionBudget `minAvailable: 1` |
| credential broker | 1 | TCP probe, because its listener demands a client certificate |
| portal | 1 | login sessions live in the BFF's memory |
| nginx | 2 | TLS for the public name and the routes of `nginx/routes.conf` |

nginx is part of the chart because the routes are not only paths: nginx drops the portal's cookies and sets
`Content-Security-Policy` on gateway routes, refuses non-canonical paths, blocks `/admin/v1/`, rate-limits logins, answers
gateway errors in the JSON shape clients expect, and forwards the public host and port. An Ingress with the same paths gives none of that.
The files under `files/nginx/` are copies of `nginx/` in the repository; `scripts/check-chart.sh` fails when they differ.
Expose the nginx Service as you do others (LoadBalancer, an Ingress or a Route with TLS passthrough); nginx terminates TLS itself.

Every pod runs as the user of its image (gateway 999, broker 100, portal 10001, nginx 101; group 10001), non-root, with all
capabilities dropped, no privilege escalation, a read-only root file system (`/tmp` is an emptyDir) and the default seccomp profile.
The images are `ghcr.io/aiwcorpo` at the versions and digests `compose.yaml` pins, linux/amd64.

## What you provide

Names below are the values of `values.yaml`; each is documented there, together with the environment variables it derives.

1. DNS name and TLS certificate for it (`global.publicOrigin`, `global.publicDomain`, a `kubernetes.io/tls` Secret in `nginx.tlsSecretName`).
2. Keycloak with the realm of `keycloak/realm-mcp.json`: its http listener for nginx (`keycloak.host`, `keycloak.httpPort`; relative path
   `/auth`, `KC_HOSTNAME=<publicOrigin>/auth`) and its https listener for the components (`keycloak.internalBaseUrl`).
3. PostgreSQL databases and users for the gateway and the broker, Redis for each (`postgresql.*`, `redis.*`). The gateway's Redis needs a
   replica that confirms writes (`MCP_REDIS_WAIT_REPLICAS=1`); the gateway does not start without it.
4. OpenBao with the broker's policy and AppRole (`openbao.addr`; its CA in the broker's trust stores).
5. Certificates of the internal CA, as PKCS12 keystores: gateway (names `mcp-gateway` and `mcp-gateway.internal`, server and client use),
   broker (`mcp-credential-broker`, `mcp-credential-broker.internal`) and portal (client certificate, CN `mcp-portal-bff`). The
   trust stores `truststore.p12`, `jvm-truststore.p12` (the JDK's CAs, the internal CA and the company CA, password `changeit`) and
   `broker-outbound-truststore.p12`. `init/init.sh` shows how the Compose bundle builds them.
6. The secrets, created before the install:

    ```bash
    kubectl -n mcp create secret tls mcp-tls --cert=tls.crt --key=tls.key
    kubectl -n mcp create secret generic mcp-trust --from-file=truststore.p12 --from-file=jvm-truststore.p12 \
      --from-file=broker-outbound-truststore.p12
    kubectl -n mcp create secret generic mcp-gateway-tls --from-file=keystore.p12=gateway.p12
    kubectl -n mcp create secret generic mcp-broker-tls --from-file=keystore.p12=broker.p12
    kubectl -n mcp create secret generic mcp-portal-tls --from-file=keystore.p12=portal.p12
    ```

    The gateway's generated values (internal JWT keys, cursor keys, database and Redis passwords) come from its own `init` command,
    which writes them into a directory and stops with `FAIL` on the checks it cannot pass yet; the files are kept:

    ```bash
    docker run --rm --platform linux/amd64 -v "$PWD/gw:/secrets" \
      -e MCP_PUBLIC_URL=https://mcp.corp.test -e MCP_OIDC_ISSUER=https://mcp.corp.test/auth/realms/mcp \
      -e MCP_OIDC_JWKS_URI=https://keycloak.corp.test:8443/auth/realms/mcp/protocol/openid-connect/certs \
      -e MCP_BROKER_URL=https://mcp-credential-broker:8443 -e MCP_BROKER_TLS_NAME=mcp-credential-broker \
      -e MCP_REDIS_WAIT_REPLICAS=1 -e MCP_REDIS_HOST=redis -e MCP_DB_URL=jdbc:postgresql://postgres:5432/gateway \
      -e MCP_TLS_KEYSTORE=/none -e MCP_TLS_TRUSTSTORE=/none \
      ghcr.io/aiwcorpo/mcp-gateway:2.1.0 init /secrets
    kubectl -n mcp create secret generic mcp-gateway-env \
      --from-file=gw/gateway/env/MCP_ACTIVITY_CURSOR_KEY --from-file=gw/gateway/env/MCP_LIST_CURSOR_KEY \
      --from-file=gw/gateway/env/MCP_INTERNAL_JWT_ACTIVE_KID --from-file=internal-jwt.jwks=gw/gateway/internal-jwt.jwks \
      --from-literal=MCP_DB_PASSWORD='<password of the gateway database user>' \
      --from-literal=MCP_REDIS_PASSWORD='<password of the gateway Redis user>' \
      --from-literal=MCP_TLS_STORE_PASSWORD='<password of the keystores>' \
      --from-literal=MCP_OIDC_CLIENT_SECRET='<secret of the client mcp-gateway>'
    kubectl -n mcp create secret generic mcp-broker-env \
      --from-literal=MCP_TLS_STORE_PASSWORD='<...>' --from-literal=MCP_DB_PASSWORD='<...>' --from-literal=MCP_REDIS_PASSWORD='<...>' \
      --from-literal=MCP_BAO_ROLE_ID='<...>' --from-literal=MCP_BAO_SECRET_ID='<...>'
    kubectl -n mcp create secret generic mcp-portal-env \
      --from-literal=PORTAL_OIDC_CLIENT_SECRET='<secret of the client mcp-portal-bff>' \
      --from-literal=PORTAL_TLS_KEYSTORE_PASSWORD='<...>' --from-literal=PORTAL_TLS_TRUSTSTORE_PASSWORD='<...>'
    ```

    The gateway's own Redis password and users come from the same run (`gw/redis/users.acl`) when you also use it for your Redis.
    Do not put `MCP_INTERNAL_JWT_KEYS_FILE` in the Secret: the chart sets it to the mounted `internal-jwt.jwks`.

## Install

```bash
helm install mcp ./charts/mcp-platform -n mcp -f my-values.yaml
```

A minimal `my-values.yaml`:

```yaml
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
```

`portal.trustedProxies` is the pod network of the nginx pods as a regular expression; the portal believes `X-Forwarded-*` from it
only. Compose resolves a name instead, which in a cluster would give the Service address, not the one nginx connects from.

The Services of the gateway and the broker are named `mcp-gateway` and `mcp-credential-broker`, because the components compare names
in certificates with the names in addresses (the broker refuses to start unless the host of the gateway's JWKS address equals the
gateway's TLS name). One release per namespace with the defaults; `gateway.serviceName` and `broker.serviceName` change them together with the
TLS names in `env`. The pods set `enableServiceLinks: false`: with a Service called `mcp-gateway` the kubelet would otherwise inject
`MCP_GATEWAY_PORT=tcp://...`, which is a setting of the gateway.

## Health checks

| Component | Probe |
| --- | --- |
| gateway | HTTPS `GET /actuator/health` on 8443 (the connector asks for a client certificate and does not require one) |
| portal | HTTP `GET /actuator/health` on 8080 |
| nginx | HTTP `GET /__proxy/health` on its http port |
| broker | TCP on 8443 (the listener demands a client certificate) |

## Autoscaling

`gateway.autoscaling` creates an `autoscaling/v2` HorizontalPodAutoscaler on CPU (70 percent of the request) with a slow scale-down,
because open event streams end with the pod. It needs a metrics server in the cluster. With `enabled: false` the Deployment uses
`gateway.replicaCount`. The broker and the portal stay at one replica.

## Checks

`scripts/check-chart.sh` (part of `scripts/verify.sh`) compares the copies and the image versions with the repository, runs `helm lint` and
`helm template` with dummy values and checks that the chart refuses to render without the required ones.
