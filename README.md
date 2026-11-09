# The MCP platform on one Docker host

Gateway, credential broker, portal, Keycloak and OpenBao with their databases, behind one nginx, as one Compose project on one Linux
host. Only nginx publishes ports: 443 for all user traffic and 80, which redirects to https. Every internal certificate, password
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

    On an https port other than 443 also set `MCP_PUBLIC_ORIGIN=https://<domain>:<port>`; without it the addresses the platform hands
    out (and the redirect from port 80) drop the port.

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

A second `docker compose up -d` changes nothing: `init` keeps every generated value. The first start takes a few minutes (the gateway
and the broker wait for Keycloak and OpenBao); on it `gateway-init` may print `warn  broker ...: connection refused`, because the
broker is still starting.

4. The first platform administrator is `mcp-admin` (`MCP_ADMIN_USERNAME`). Its initial password is in the `secrets` volume, never in a log:

    ```bash
    docker compose run --rm init show admin-password
    ```

    Open `https://<domain>/auth/realms/mcp/account`, sign in, and Keycloak asks for a new password and for an OTP (a code from an
    authenticator app). Then `https://<domain>/` is the portal. The administration of servers and policies asks for a fresh login with the OTP.

Platform administrators (group `mcp-platform-admin`) manage users and groups in the console of their own realm,
`https://<domain>/auth/admin/mcp/console/`, signing in with their usual account and OTP. The bootstrap account of the master realm
(`docker compose run --rm init show keycloak-admin`) is for emergencies: the one-time `keycloak-config` service
(`keycloak/configure.sh`) makes it enroll an OTP at its next login and gives the master realm the password policy and lockout of the
realm `mcp`, with an OTP as a default required action for any administrator created there. Whoever signs in first with the bootstrap
password enrolls that OTP, so do it right after the installation.

Both consoles are open to every network, because every administrator there needs an OTP. To narrow them, list your networks in
`nginx/keycloak-admin-allow.conf` (`allow <network>;` lines, then `deny all;`) and run `docker compose restart nginx`. The rule
also covers matrix-parameter variants such as `/auth/admin;x/`.

`keycloak-config` runs once and keeps a marker in the volume. nginx starts only after it succeeded, because the open consoles rely on
the OTP it requires. If the bootstrap account already had an OTP before it ran, it cannot sign in and says so, and nginx stays down.
Then start nginx alone (`docker compose up -d --no-deps nginx`) and do its steps by hand in the consoles: in the realm `mcp`, the client roles `query-groups`, `query-users`, `view-users`
and `manage-users` of `realm-management` for the group `mcp-platform-admin`; in the realm `master`, brute force detection with 10
failures, the password policy `length(12)`, `notUsername`, `passwordHistory(5)`, the required action Configure OTP enabled and set as
default action, and an OTP on every administrator. Only then `docker compose run --rm keycloak-config mark-done`, which records that
the run is no longer needed and checks nothing; from then on `docker compose up -d` starts nginx as usual.

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
a system through groups (`mcp-<system>-read` and so on, the names the policies of the server use). The realm in
`keycloak/realm-mcp.json` defines only `mcp-platform-admin`: create the groups of a server in the console when you add it.

## What runs

| Service | What | Networks |
| --- | --- | --- |
| `nginx` | TLS, routes `/auth`, `/api`, `/mcp`, `/s/`, `/.well-known/mcp-jwks.json`, `/`; publishes 443 and 80 | public, edge, servers |
| `keycloak`, `keycloak-postgres` | identity provider, production mode, realm `mcp` | edge, keycloak-stores |
| `gateway`, `gateway-postgres`, `gateway-redis`, `gateway-redis-replica` | MCP gateway (the replica is required in production) | edge, servers, egress, gateway-stores |
| `mcp-credential-broker`, `broker-postgres`, `broker-redis` | credential broker | edge, secrets, broker-stores, egress |
| `openbao`, `openbao-unseal` | secret store | secrets (reachable by the broker only) |
| `portal` | BFF with the single-page application | edge |
| `init`, `gateway-init` | one-shot setup (the second one is the gateway's own `init` command) | |

`gateway-init` writes the files it shares with the gateway's PostgreSQL and Redis (their passwords, the Redis configuration and ACL) as mode 0640 in group 10001, the fixed group of the gateway image, and the Redis ACL holds only password hashes. The two gateway Redis services join that group (`group_add` in `compose.yaml`) and `init` keeps the directories at 0750 for owner and group. A gateway image built before that group id was fixed runs with gid 999 and does not fit this layout.

All networks are internal except `public` (nginx) and `egress` (the broker, for the systems behind it, and the gateway, for servers on other hosts). The gateway, broker and portal
reach Keycloak at `https://keycloak.internal:8443` with a certificate of the internal CA, so token checks and token exchange never
depend on the public certificate; the domain name also resolves to nginx inside Docker. Tokens carry the public issuer
`https://<domain>/auth/realms/mcp`.

## Traffic

| From | To | Port | What |
| --- | --- | --- | --- |
| users, AI clients | platform host | 443 (80 redirects) | portal, `/mcp`, `/auth` |
| MCP server (any host) | platform host | 443 | `/.well-known/mcp-jwks.json`, the gateway's public keys |
| platform host (gateway) | MCP server host | the server's port (8443 by default) | manifest, policy data, tool calls |
| platform host (broker) | systems behind it | 443 | token checks and OAuth of the systems |
| MCP server host | its backend system | 443 | the system's API |

The platform host publishes nothing but 443 and 80. Both hosts need DNS and NTP, and the server host must resolve the platform's domain
to the platform host. Nothing else crosses: no client certificate on either side, no token handed out by hand, no pipeline.

## Add an MCP server

The author of the server runs it, the operator of the platform adds its address and approves. Nothing is issued on the platform side
for the server, and the gateway pulls everything (the certificate, the manifest) and pushes the policy data itself.

The example is the `mcp-example` image with its stub backend, inside this Docker.

1. Copy `servers.example.yaml` to `servers.yaml`, adapt it, and add it to `.env`:

    ```bash
    COMPOSE_FILE=compose.yaml:servers.yaml
    MCP_EXAMPLE_URL=https://backend.corp.test              # the backend system, https
    ```

    The server speaks plain http on the internal `servers` network (`MCP_PLAIN_HTTP=true`), keeps its state in a volume, and fetches the
    gateway's keys from `https://<domain>/.well-known/mcp-jwks.json`. That name reaches nginx through its alias on the `servers` network, so
    the server needs the JVM trust store that the bundle builds (public CAs, internal CA, `certs/company-ca.crt`); `servers.example.yaml`
    mounts it.

    For a test stack with the stub backend of `mcp-e2e` (`make stub-test` there builds it) also set `COMPOSE_PROFILES=stub`, `MCP_EXAMPLE_URL=http://stub-backend:18081`,
    `MCP_EXAMPLE_ALLOW_PLAIN_HTTP=true` and `MCP_STUB_BACKEND_JAR=<path of mcp-e2e/stub-backend/target/mcp-stub-backend.jar>`. Then `docker compose up -d`.

2. Add it. The portal (Administration, Servers) or the admin APIs do the same; the calls need a token of a fresh login with OTP
   (`auth_time` within 5 minutes, `acr` `mfa`) and the portal's client certificate, so the portal is the easy way. In order:
    1. Broker, system: `PUT /v1/admin/systems/example` (`baseUrl`, `adapter`, `supportedTypes`, `defaultType`, `secretScheme`).
    2. Gateway, server: "Add server" with the address `http://mcp-example:8443/mcp` and "allow plain http" (`POST /admin/v1/servers` with
       `{"internalUrl": "http://mcp-example:8443/mcp", "allowPlainHttp": true}`). Plain http is for servers on the platform's own Docker
       network only; without the flag the gateway refuses the address (`plain_http_not_allowed`). The gateway pulls the manifest and the
       server appears as `pending_approval`. The `serverId` (`mcp-example`) comes from the manifest.
    3. Approve the connection (fresh OTP): for plain http there is nothing to compare. Then the policies (`POST .../policies/approve` with the
       pending `policiesHash`) and the tools. Every tool waits for an administrator, the read-only ones too. Every later change of a policy
       or a tool (the gateway pulls the manifest again every minute or so, and on "refresh") is pending again: while the policies are
       `pending_approval` the tools of the server are hidden and refused (`tool_disabled`), until an administrator approves the change.
    4. Groups of the system in Keycloak, and the scope mapping (Administration, Scope mapping).

   The broker calls the base URL of the system only to check a token (`whoami`) and for OAuth, and requires https for it.

An address that resolves to loopback, link-local (including `169.254.169.254`), unspecified or multicast is refused when it is added and
again before every connection of the gateway; private ranges are allowed.

### Remove an MCP server

1. `DELETE /admin/v1/servers/mcp-example` in the gateway (its tools leave every `tools/list`; approvals, policies and scope mapping
   entries go with it), and `DELETE /v1/admin/systems/example` in the broker (the users' connections and the client secret go with it).
2. Remove the service from `servers.yaml` and run `docker compose up -d --remove-orphans`, or `docker compose rm -sf mcp-example`.

The same address can be added again afterwards.

### MCP server on another host

The author starts the server from the `deploy/` directory of the server's repository. The platform is not touched.

1. On the server host, fill in `server.env` (`MCP_GATEWAY_JWKS_URI=https://<domain>/.well-known/mcp-jwks.json`, `MCP_CONNECT_URL`, the URL of the
   backend system) and run `docker compose up -d`. Without a certificate of its own the server generates a self-signed one on its first
   start, keeps it in its state volume and logs the fingerprint:

    ```bash
    docker compose logs mcp-example | grep event=tls_certificate
    # event=tls_certificate source=generated fingerprint=sha256:9f2c...e1 detail="..."
    ```

   The server host must reach `https://<domain>` on 443 and open the server's port (8443) to the platform host only. When the certificate of
   the platform comes from a company CA, the JVM of the server must trust it to fetch the keys: a trust store with that CA
   (`JAVA_TOOL_OPTIONS=-Djavax.net.ssl.trustStore=<file> -Djavax.net.ssl.trustStoreType=PKCS12 -Djavax.net.ssl.trustStorePassword=<password>`
   in `server.env`, the file mounted into the container).
2. The author gives the operator the address, `https://<host name or IP>:8443/mcp`, and the fingerprint.
3. The operator adds the address in the portal (Administration, Servers, "Add server", fresh OTP). The gateway connects, reads the
   certificate, pulls the manifest, and shows a card with the system, the certificate (subject, issuer, names, validity, fingerprint) and the
   tools and policies. The operator compares the fingerprint on the card with the one from the server log and approves the connection:
    - a certificate that a CA trusted by the gateway signed, for the host name of the address, is trusted as `ca`: renewals need nothing;
    - any other certificate, a self-signed one included, is pinned by its fingerprint. If the server later presents another certificate it
      becomes unreachable (`certificate_changed`) and the portal shows the new fingerprint for approval.
4. System in the broker, policies, tools, groups and scope mapping as for a server on the platform host (Add an MCP server, step 2).

### Platform and server on one computer, without a domain

For a test on one machine with Docker Desktop (macOS, Windows). Checked on macOS with a server as a second Compose project.

- `MCP_DOMAIN` cannot be `localhost`: the server container would fetch the keys from itself, and nginx refuses a TLS name other
  than `MCP_DOMAIN`. Use `mcp.localhost`; browsers and Node resolve `*.localhost` to the loopback address. A certificate with
  `subjectAltName=DNS:mcp.localhost` from a CA of your own, the CA in `certs/company-ca.crt`.
- `.env`: `MCP_DOMAIN=mcp.localhost`, `MCP_BIND=127.0.0.1`, and on other ports also `MCP_HTTPS_PORT`, `MCP_HTTP_PORT` and
  `MCP_PUBLIC_ORIGIN=https://mcp.localhost:<port>`.
- The server: the CA in its trust store (step 1 above), `MCP_GATEWAY_JWKS_URI=https://mcp.localhost:<port>/.well-known/mcp-jwks.json`,
  and in a `compose.override.yaml` of its `deploy/` directory `extra_hosts: ["mcp.localhost:host-gateway"]` on the server service,
  so that the name leads to the host from inside its container.
- In the portal the address of the server is `https://host.docker.internal:<published port>/mcp`.
- Claude Code: `NODE_EXTRA_CA_CERTS=<the CA file>` and the address `https://mcp.localhost:<port>/mcp`.

On Linux `host.docker.internal` is not defined: the gateway would need `extra_hosts: ["host.docker.internal:host-gateway"]` too.

For `ca` mode with a CA that is neither public nor `certs/company-ca.crt`, set `MCP_SERVER_TRUSTED_CAS_FILE` in `.env` to a PEM file with that
CA and run `docker compose up -d`; the gateway then also trusts it for servers. It is optional: without it, servers with a certificate of a
public CA or the company CA are `ca`, the others pinned. A server keeps working only while the gateway can reach its address: the
gateway has its route out through the `egress` network.

## Certificates

- nginx: yours (`certs/`). After renewing it run `docker compose up -d` (init copies it) and `docker compose restart nginx`.
- Internal: one CA (10 years) and certificates of 2 years for the gateway, broker, portal, Keycloak and OpenBao. `init`
  makes a certificate again when it expires within 30 days (see the next point on restarting). Replacing the CA itself means deleting
  `pki/` in the `secrets` volume. MCP servers have no certificate from this CA.
- `company-ca.crt` also goes into the JVM trust store of the gateway, broker and portal, and into the broker's outbound trust store,
  so that systems behind the broker with a company certificate (GitLab, Jira...) work. The broker accepts client certificates only
  from the internal CA: that store is a separate one.
- `init` replaces certificates and trust stores on a running installation without restarting anything. When it does, it ends with
  `warn  certificates or trust stores changed` and the `docker compose restart` command for the services that still use the old
  ones.

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
- The broker's outbound trust store holds the company CA for all of its connections, including Keycloak, OpenBao and the gateway on
  the internal network, not only for the systems behind it. A company certificate for one of those internal names would let whoever
  can also redirect that name inside Docker impersonate it to the broker.
- The broker, the gateway and the MCP servers of `servers.example.yaml` share the network `egress` (the Docker address pool of a host with many
  networks may not have room for a second one).
- The gateway's plain-http port 8080 and Keycloak's and the portal's are reachable on the networks they share with the services that do not
  need them (edge, and servers for the gateway and nginx): only nginx is meant to call them, nothing else is blocked.
- The gateway has no setting for trusted proxies; it builds every address it hands out from `MCP_PUBLIC_URL`, never from `X-Forwarded-*`.
