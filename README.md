# The MCP platform on one Docker host

Gateway, credential broker, portal, Keycloak and OpenBao with their databases, behind one nginx, as one Compose project on one Linux
host. Only two nginx containers publish ports: 443 for all user traffic and 80, which redirects to https, and 8443, a TCP passthrough
to the gateway's mTLS port for MCP servers and pipelines on other hosts. Every internal certificate, password
and key is generated on the first start and kept in Docker volumes. MCP servers are added afterwards (see below).

## Prerequisites

- Linux, Docker Engine 26 or newer with Compose v2.23 or newer (volume subpaths), 8 GiB of memory.
- A DNS name for the platform, for example `mcp.corp.test`, pointing at the host. The same name serves the portal (`/`), the gateway
  (`/mcp`), and the identity provider (`/auth`), so no second host name is needed.
- A certificate for that name from your company CA or a public CA: the chain in `certs/tls.crt`, the key in `certs/tls.key`. When the
  CA is not a public one, its certificate goes in `certs/company-ca.crt`.
- Access to the images (`ghcr.io/aiwcorpo`, Docker Hub, quay.io), or your own registry (below).

## Install

1. Put `tls.crt`, `tls.key` and, if needed, `company-ca.crt` in `certs/`.
2. Copy the environment template and fill in the domain:

    ```bash
    cp platform.env .env
    # edit .env: MCP_DOMAIN=mcp.corp.test
    ```

3. Start:

    ```bash
    docker compose up -d
    ```

The `init` service runs first on every start. It checks the certificate (it names the domain, the key fits, the chain verifies
against `company-ca.crt` or a public CA), generates what is missing, and stops the start with the reason when something is wrong:

```console
$ docker compose logs init
ok    nginx certificate for mcp.corp.test, signed by the company CA in certs/company-ca.crt
new   internal CA /secrets/pki/ca/ca.crt (valid 10 years)
...
ok    configuration, certificates and secrets are in place
```

A second `docker compose up -d` changes nothing: `init` keeps every generated value.

4. The first platform administrator is `mcp-admin` (`MCP_ADMIN_USERNAME`). Its initial password is in the `secrets` volume, never in a log:

    ```bash
    docker compose run --rm init show admin-password
    ```

    Open `https://<domain>/auth/realms/mcp/account`, sign in, and Keycloak asks for a new password and for an OTP (a code from an
    authenticator app). Then `https://<domain>/` is the portal. The administration of servers and policies asks for a fresh login with the OTP.

The Keycloak administration console (`https://<domain>/auth/admin/`) and the master realm answer only the networks in
`nginx/keycloak-admin-allow.conf`, which ships with `127.0.0.1` only: add one `allow <network>;` line for the network your administrators
come from, before `deny all;`, and run `docker compose restart nginx`. The rule also covers matrix-parameter variants such as
`/auth/admin;x/`. The bootstrap account is `docker compose run --rm init show keycloak-admin`; create a named
administrator there and delete the bootstrap account.

### Users and the two authenticators

A user without an OTP enrolls one at the first login (CONFIGURE_TOTP is a default required action of the realm). From then on the OTP is
asked after the password at every login, for every client including the AI clients, and before any required action: someone who knows
only the password cannot reach the OTP setup page, neither through the account console nor through an application-initiated action
(`kc_action=CONFIGURE_TOTP`), so cannot add a second OTP of their own. Step-up, which the administration and the portal's Authenticator
need, takes the OTP entered in the same authentication (a step-up with `max_age=0` always authenticates again, so an OTP from an earlier
login in the same SSO session never counts), or asks for it and refuses a user who has none: it never offers enrollment, so a password alone cannot
reach the level `mfa`. A user therefore has two entries in the authenticator app: the OTP of the login, and the platform
Authenticator that the portal registers for confirming destructive actions.

Passwords need 12 characters and may not equal the user name or e-mail, the last 5 passwords cannot be reused, and an account is locked
after 10 failed attempts (`passwordPolicy` and `failureFactor` of the realm).

Residual risk: until the first login, whoever knows a user's initial password enrolls the OTP. Give initial passwords out of band, or
federate the users from your company directory (Keycloak, User federation) so that no initial password exists. Users get access to
a system through groups (`mcp-<system>-read` and so on); the realm in `keycloak/realm-mcp.json` defines the ones of the standard
servers, add your own in the console.

## What runs

| Service | What | Networks |
| --- | --- | --- |
| `nginx` | TLS, routes `/auth`, `/api`, `/mcp`, `/s/`, `/`; publishes 443 and 80 | public, edge |
| `nginx-mtls` | TCP passthrough of the gateway's mTLS port for servers and pipelines on other hosts; publishes 8443 | public, edge |
| `keycloak`, `keycloak-postgres` | identity provider, production mode, realm `mcp` | edge, keycloak-stores |
| `gateway`, `gateway-postgres`, `gateway-redis`, `gateway-redis-replica` | MCP gateway (the replica is required in production) | edge, servers, egress, gateway-stores |
| `mcp-credential-broker`, `broker-postgres`, `broker-redis` | credential broker | edge, secrets, broker-stores, egress |
| `openbao`, `openbao-unseal` | secret store | secrets (reachable by the broker only) |
| `portal` | BFF with the single-page application | edge |
| `servers-redis` | Redis for the one-time jti of MCP servers | servers |
| `init`, `gateway-init` | one-shot setup (the second one is the gateway's own `init` command) | |

All networks are internal except `public` (the two nginx containers) and `egress` (the broker, for the systems behind it, and the gateway, for servers on other hosts). The gateway, broker and portal
reach Keycloak at `https://keycloak.internal:8443` with a certificate of the internal CA, so token checks and token exchange never
depend on the public certificate; the domain name also resolves to nginx inside Docker. Tokens carry the public issuer
`https://<domain>/auth/realms/mcp`.

## Add an MCP server

Servers are data of the gateway and the broker, added at run time. The example is the `mcp-example` image with its stub backend.

1. Issue what the server needs. `init` makes the certificate (CN `mcp-example`, SAN `mcp-example.internal`, serverAuth and
   clientAuth), its Redis account and its secrets, and loads the account into the running Redis:

    ```bash
    docker compose run --rm init issue mcp-example      # optional second argument: the uid the image runs as, 999 by default
    docker compose run --rm init ci mcp-example         # client certificate mcp-registry-ci-mcp-example for the pipeline
    ```

2. Copy `servers.example.yaml` to `servers.yaml`, adapt it, and add it to `.env`:

    ```bash
    COMPOSE_FILE=compose.yaml:servers.yaml
    MCP_EXAMPLE_URL=https://backend.corp.test              # the backend system, https
    ```

    For a test stack with the stub backend of `mcp-server-template` also set `COMPOSE_PROFILES=stub`, `MCP_EXAMPLE_URL=http://stub-backend:18081`,
    `MCP_EXAMPLE_ALLOW_PLAIN_HTTP=true` and `MCP_STUB_BACKEND_JAR=<path of mcp-stub-backend.jar>`. Then `docker compose up -d`.

3. Register it. The portal (Administration) or the admin APIs do the same; the calls need a token of a fresh login with OTP
   (`auth_time` within 5 minutes, `acr` `mfa`) and the portal's client certificate, so the portal is the easy way. In order:
    1. Broker, system: `PUT /v1/admin/systems/example` (`baseUrl`, `adapter`, `supportedTypes`, `defaultType`, `secretScheme`).
    2. Gateway, server: `POST /admin/v1/servers` with `serverId` `mcp-example`, `internalUrl` `https://mcp-example.internal:8443/mcp`,
       and the credential type of the system.
    3. The pipeline registers the manifest of the reviewed build, `PUT /admin/v1/registry/servers/mcp-example`, with the certificate from
       `init ci` (see MCP server on another host, step 5). Tools that only read are approved by that call.
    4. An administrator approves the policies (`POST .../policies/approve` with the pending `policiesHash`) and the remaining tools.
    5. Groups of the system in Keycloak, and the scope mapping (Administration, Scope mapping).

   The broker calls the base URL of the system only to check a token (`whoami`) and for OAuth, and requires https for it.

### Remove an MCP server

1. `DELETE /admin/v1/servers/mcp-example` in the gateway (its tools leave every `tools/list`; approvals, policies and scope mapping
   entries go with it), and `DELETE /v1/admin/systems/example` in the broker (the users' connections and the client secret go with it).
2. Remove the service from `servers.yaml` and run `docker compose up -d --remove-orphans`, or `docker compose rm -sf mcp-example`.

### MCP server on another host

The gateway's mTLS port is published by a second nginx container (`nginx-mtls`) on `MCP_MTLS_PORT` (8443), bound to `MCP_MTLS_BIND`
(0.0.0.0). nginx does not terminate TLS there: the gateway demands a client certificate issued by the platform's internal CA, so only
holders of one get in. The port is open to whoever can reach it at the network level, so open it in the firewall only for the hosts of
the MCP servers and the pipeline.

1. On the platform host, export what the server needs and copy it to the server host:

    ```bash
    docker compose run --rm -T init export mcp-example > mcp-example.tar      # issues the certificate if there is none
    scp mcp-example.tar server-host:
    ```

2. On the server host, in the `deploy/` directory of the server (its `compose.yaml` starts the server and its own Redis; the bundle's
   `servers-redis` cannot be used from another host):

    ```bash
    tar xf ~/mcp-example.tar        # certs/keystore.p12, certs/truststore.p12, server.env
    ```

   `server.env` has the passwords and keys, the Redis password of the server's own Redis, the gateway addresses
   (`https://<domain>:<MCP_MTLS_PORT>/...`, the gateway certificate names the domain), `MCP_CONNECT_URL` and `MCP_INTERNAL_URL`. Only
   the URL of the backend system is missing: add it (`MCP_EXAMPLE_URL=...` for this server). Keep `server.env` readable by you only.
3. Start it: `docker compose up -d`. It publishes 8443 for the gateway; open that port in the server host's firewall for the platform
   host only.
4. Register it in the portal (Administration, Servers) with the internal URL `https://<host name or IP of the server host>:8443/mcp`.
   The gateway pins the certificate name (`mcp-example.internal`), not the address, so an IP is fine. The system in the broker and the
   groups are as for a server on the platform host (Add an MCP server, step 3).
5. The pipeline registers the manifest through port 8443 with the client certificate of that server (`init ci`):

```bash
docker compose run --rm init ci mcp-example
docker compose run --rm -T init show ci-cert mcp-example > ci.crt
docker compose run --rm -T init show ci-key mcp-example  > ci.key && chmod 600 ci.key
docker compose run --rm -T init show ca > internal-ca.crt
curl --cacert internal-ca.crt --cert ci.crt --key ci.key -X PUT --data-binary @mcp-manifest.json \
  -H 'Content-Type: application/json' https://<domain>:8443/admin/v1/registry/servers/mcp-example
```

The gateway certificate names the domain, so the pipeline connects to the same name users use. A server keeps working only while the
gateway can reach its address: the gateway has a route out through the `egress` network.

## Certificates

- nginx: yours (`certs/`). After renewing it run `docker compose up -d` (init copies it) and `docker compose restart nginx`.
- Internal: one CA (10 years) and certificates of 2 years for the gateway, broker, portal, Keycloak, OpenBao and every server. `init`
  makes a certificate again when it expires within 30 days; restart the stack afterwards. Pipeline certificates (`init ci`) are valid 90
  days: run `docker compose run --rm init ci <serverId>` again before they expire (it renews when less than 30 days are left) and give the
  new files to the pipeline. Replacing the CA itself means deleting
  `pki/` in the `secrets` volume and issuing every server certificate again.
- `company-ca.crt` also goes into the JVM trust store of the gateway, broker and portal. Systems behind the broker that use the company
  CA need it in the broker's own trust store, which also decides which client certificates the broker accepts; set
  `MCP_BROKER_TRUST_COMPANY_CA=true` for that, and read the consequence under Known limits first.

## OpenBao after a restart

OpenBao starts sealed. `openbao-unseal` initialises it on the first start (one key share) and unseals it after every start of it, so the
platform comes back by itself after a restart of the host. The unseal key is in the volume `openbao-keys`, mounted by that service only.
The trade-off: whoever can read Docker volumes on the host can unseal OpenBao, so the host is the trust boundary, as it is for the other
generated secrets. To keep the key off the host: back up `openbao-keys`, delete it from the host
(`docker compose stop openbao-unseal && docker volume rm mcp-platform_openbao-keys`) and unseal by hand after each start with
`bao operator unseal` from a shell on the `secrets` network. The broker then fails to start until someone does.

The same service provisions OpenBao (policy, Transit keys, AppRole) with a token of the policy `mcp-provisioner`, which can manage mounts,
policies and the broker's AppRole but read or write no secret and use no Transit key. The root token exists only until the first provisioning
has worked with that token, then it is revoked and deleted; the provisioner token (period 768 h) is renewed at every provisioning, which
runs at every start of the service and every 6 hours. A new root token, if you ever need one, comes from `bao operator generate-root` with
the unseal key.

The broker logs in to OpenBao with a role_id and a secret_id that it reads from its environment. That secret_id does not expire: the broker
uses it again whenever its token ends, so a lifetime would only switch the broker off. Replacing it is a manual operation, not automated here.

## Backup

State is in these volumes (prefix `mcp-platform_`): `secrets`, `openbao-keys`, `openbao-data`, `keycloak-db`, `gateway-db`, `broker-db`
and the three Redis volumes. Back up `secrets` and `openbao-keys` together with the databases: without `secrets` the certificates and
passwords do not match the data.

```bash
for db in gateway-postgres:gateway keycloak-postgres:keycloak broker-postgres:broker; do
  docker compose exec -T "${db%%:*}" pg_dump -U "${db##*:}" "${db##*:}" > "${db##*:}.sql"
done
docker compose exec -e BAO_CACERT=/trust/ca.crt openbao-unseal sh -c \
  'BAO_TOKEN=$(cat /keys/provisioner-token) bao operator raft snapshot save /tmp/openbao.snap && cat /tmp/openbao.snap' > openbao.snap
docker run --rm -v mcp-platform_secrets:/s:ro -v mcp-platform_openbao-keys:/k:ro -v "$PWD":/b alpine tar czf /b/secrets.tgz -C / s k
```

The tarball holds every secret of the platform: keep it where only administrators read it.

## Upgrade

Set `MCP_GATEWAY_VERSION`, `MCP_BROKER_VERSION` and `MCP_PORTAL_VERSION` in `.env` (deploy the broker and the gateway before the portal)
and run `docker compose pull && docker compose up -d`. Generated keys and passwords stay. `openbao-unseal` rewrites the OpenBao policy.
The realm is imported only when it does not exist: later changes of `keycloak/realm-mcp.json` do not reach an existing realm, make them
in the console. Closed network: copy the images to your registry and set `MCP_REGISTRY` and `MCP_THIRD_PARTY_REGISTRY` in `.env`.

## After a host restart

Nothing, normally: the services restart by themselves and `openbao-unseal` unseals OpenBao. After `docker compose restart` or a
`down` and `up`, finish with `docker compose up -d`: `restart` restarts the one-shot `gateway-init` at the same time as Keycloak, so it
can report a failure although the platform is fine, and `up -d` runs it again in order. Data survive `down`; `down -v` deletes all of it.

## Known limits

- The gateway and the broker each have their own Redis, as asked. The broker publishes `credential.invalidated` on its Redis and the
  gateway subscribes on its own, so the gateway does not learn of a revoked credential at once; its cache keeps one for at most 60 s.
  Pointing both at one Redis closes the gap.
- Any certificate of the company CA with CN `mcp-offboarding` can purge users and reset authenticators at the broker without a token,
  if you set `MCP_BROKER_TRUST_COMPANY_CA=true`: the broker has one trust store for the certificates it accepts from clients and for the
  systems it calls. Enable the flag only if your company CA does not let requesters choose the subject of a certificate. The broker needs a
  separate outbound trust store; that is a limitation of the component, not of this bundle.
- The broker and the MCP servers share the network `egress` (the Docker address pool of a host with many networks may not have room for a
  second one).
- The gateway's plain-http port 8080 and Keycloak's and the portal's are reachable on the networks they share with the services that do not
  need them (edge, and servers for the gateway): only nginx is meant to call them, nothing else is blocked.
- The gateway has no setting for trusted proxies; it builds every address it hands out from `MCP_PUBLIC_URL`, never from `X-Forwarded-*`.
