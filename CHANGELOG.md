# Changelog

The bundle follows SemVer; its version is the tag of this repository, and the image versions it defaults to are in
`compose.yaml` (`MCP_GATEWAY_VERSION`, `MCP_BROKER_VERSION`, `MCP_PORTAL_VERSION`). Newest first.

## 2.1.0 - 2026-11-17

- The aiwcorpo images are pinned by digest like the third-party ones: the defaults are `<tag>@<digest>` (gateway 2.0.1, broker 2.1.0,
  portal 2.1.0). A value in `.env` replaces the whole default, so `MCP_GATEWAY_VERSION=2.0.1-local` still runs a local image, now
  without a digest. A registry copy whose digest differs needs the plain tag. `scripts/pin-images.sh` writes the digests at a release.
- `servers.example.yaml` is the GitLab server (`ghcr.io/aiwcorpo/mcp-server-gitlab`, serverId `mcp-gitlab`, system `gitlab`) instead of
  the never published `mcp-server-example`: `MCP_GITLAB_URL` replaces `MCP_EXAMPLE_URL`, `MCP_GITLAB_VERSION` and `MCP_GITLAB_MEM_LIMIT`
  replace the `MCP_EXAMPLE_*` ones, and the credential type is `user-secret` (a GitLab personal access token; `user-oauth` needs an OAuth client). The image is pinned by digest too
  (2.0.0). README, "Add an MCP server", uses the new names; an existing `servers.yaml` that is a copy of the old file keeps working only
  with an image you built yourself.
- `compose.offline.yaml` (moved here from `mcp-platform-offline`): the same images by tag without digest, for images loaded with
  `docker load`; use `COMPOSE_FILE=compose.yaml:compose.offline.yaml`. It sets `pull_policy: never`: a missing image is an error, not a pull by tag. CI checks that it names the same images as
  `compose.yaml` and that every service has that policy.
- The OpenBao provisioner can no longer write policies or role settings: its token was root in practice. The policies
  `mcp-provisioner` and `mcp-credential-broker` and the broker's AppRole settings are written with the root token only (first start,
  and the new `docker compose run --rm openbao-recover`); provisioning compares them with the release and prints `FAIL` with the
  recover hint when they differ. `openbao-recover` replaces an expired or lost provisioner token (OpenBao 2.6+ makes root tokens only
  through an authenticated endpoint, so `openbao/run.sh` restarts the server with a loopback listener for the length of the command,
  at most 10 minutes). An installation from before this change narrows the policy itself at the first provisioning after the upgrade
  and needs no recover run; a later release that changes the policies does. The broker policy gains create and update on
  `secret/data/mcp/service-accounts/*` (keys written from the portal) and delete of their metadata.
- After unpacking a new package run `docker compose up -d --force-recreate openbao-unseal`: the service runs `init/init.sh` from a bind
  mount and keeps the old script until it is recreated (README, Upgrade). `openbao-unseal` provisions again after any restart.
- README: a "Try it locally" section with mkcert (TLS stays on for a local run), and an opening that says what the platform does, with
  a portal screenshot and the list of repositories.
- The `stub` profile of `servers.example.yaml` and the README steps and comments that sent readers to the private `mcp-e2e` repository are
  removed; the profile mounted a jar only that repository could build.
- CI (`.github/workflows/ci.yml`, `scripts/verify.sh`): renders `compose.yaml` alone and with `servers.example.yaml`, parses and
  shellchecks the scripts, requires a digest on every image (no exceptions) and rejects no-break spaces and typographic quotes.
- Added `LICENSE` (Apache-2.0), `NOTICE`, `SECURITY.md`, issue templates (questions go to Discussions, vulnerabilities to private
  reporting), `AGENTS.md` and `CONTRIBUTING.md`.
- Defaults moved to gateway 2.0.1 (MCP 2026-07-28 fields `ttlMs` and `cacheScope`), broker 2.1.0 and portal 2.1.0 (service account keys
  written from the portal, CC-251, on `mcp-contracts` 7.1.0). Portal 2.1.0 needs broker 2.1.0.

## 2.0.0 - 2026-11-09

First release of the bundle: nginx on 443 with a redirect on 80, Keycloak with the production realm and one first administrator,
OpenBao, the gateway, the credential broker and the portal, each with its PostgreSQL or Redis. `init` generates the internal CA,
certificates, passwords and keys and is idempotent; `keycloak-config` runs once; `servers.example.yaml` adds an MCP server.

- Only nginx publishes ports. The mTLS port of the gateway is no longer published and servers need no certificate from the internal CA
  (CC-249): the gateway pulls the manifest from the server's address, and an administrator approves the connection in the portal.
- The Keycloak consoles are open behind an OTP instead of a network list; step-up is refused to a user without an OTP, and the OTP is
  enrolled at the first login. The realm import takes only the group `mcp-platform-admin`.
- The broker has its own outbound trust store: its client trust store holds only the internal CA, and `company-ca.crt` goes to the
  outbound store and the JVM trust stores.
- nginx starts only after `keycloak-config` succeeded. `MCP_PUBLIC_ORIGIN` names another port or origin; the README describes the broker
  warning at the first start, the platform on one computer without a domain, and every step of `keycloak-config` for the manual path.
- Security review fixes: hardened containers (`cap_drop: [ALL]`, `no-new-privileges`, read-only root for Java), internal-only networks
  except `public` and `egress`.
- `.gitattributes` keeps LF endings in a Windows checkout, since the scripts run in Linux containers.
