# AGENTS.md

mcp-platform is the Docker Compose bundle that runs the whole [MCP Platform](https://github.com/aiwcorpo/mcp-platform) on
one host: nginx, Keycloak, OpenBao, the gateway, the credential broker and the portal, each with its PostgreSQL or Redis.
It holds no application code and no test suite; the components and their contracts live in their own repositories (table
in README). `mcp-platform-offline` packages the images this file names. Operator docs: [README.md](README.md).

## Checks

There is no CI workflow and no build. Before a commit run, with a throwaway env file outside the repository:

```bash
envfile=$(mktemp) && printf 'MCP_DOMAIN=mcp.corp.test\n' > "$envfile"
docker compose --env-file "$envfile" config -q
sh -n init/init.sh && bash -n keycloak/configure.sh
```

`config -q` prints nothing on success; without `MCP_DOMAIN` it fails on purpose. To check the server overlay add
`-f compose.yaml -f servers.example.yaml` and `MCP_EXAMPLE_URL=https://backend.corp.test` to the env file.
Do not run `docker compose up`, `down`, `restart`, `pull` or `run`: `compose.yaml` fixes the project name to
`mcp-platform`, so from any checkout or worktree these act on the same containers and volumes as a real installation
on this machine. `down -v` deletes all platform data.

## Layout

- `compose.yaml`: every service, network and volume; the anchors at the top (`x-hardened`, `x-java`, `x-store`) carry the
  shared hardening (`cap_drop: [ALL]`, `no-new-privileges`, read-only root for Java). New services use them.
- `init/init.sh`: the single setup entry point. Runs in `init` (checks `certs/`, generates the internal CA, certificates,
  passwords, keys) and as `init.sh openbao` in `openbao-unseal` (initialise, unseal, provision). The OpenBao policies
  `mcp-provisioner` and `mcp-credential-broker` are written here.
- `openbao/server.hcl`, `openbao/run.sh` (starts the server, restarts it while `openbao-recover` holds the recovery listener open), `keycloak/realm-mcp.json` (imported only when the realm does not exist yet), `keycloak/configure.sh`
  (one-time `keycloak-config`), `nginx/` (`servers.conf.template` is rendered with envsubst at start), `portal/iga-catalog.yaml`.
- `platform.env`: the committed template users copy to `.env`. `servers.example.yaml`: example MCP server overlay.
- `.env` and `certs/` (except `.gitkeep`) are git-ignored and hold a real installation's domain, certificates and keys.
  Never read, print or commit them.

## Rules

- Third-party images are pinned by tag and `@sha256:` digest; change both together. The aiwcorpo images use
  `MCP_GATEWAY_VERSION`, `MCP_BROKER_VERSION`, `MCP_PORTAL_VERSION` with the default in `compose.yaml`; keep the commented
  defaults in `platform.env` equal. Raise the broker and gateway defaults before or with the portal, never the portal alone.
- `init` must stay idempotent: a second start keeps every generated value and changes nothing. A failed check prints
  `FAIL  <reason>` and stops the start; use the existing `ok`/`new`/`warn`/`fail` helpers for output. Never print a
  generated secret to the log; an operator reads one with
  `docker compose run --rm init show <what>`.
- Only nginx publishes ports; every network except `public` and `egress` is `internal: true`. OpenBao stays on `secrets`,
  reachable by the broker only. The broker's client trust store holds only the internal CA; `company-ca.crt` goes to its
  outbound store and the JVM trust stores.
- Changes to the OpenBao policies (`init/init.sh`) or `openbao/` need a person's review before merge.
- `keycloak/realm-mcp.json` does not reach existing installations; say in README how an operator applies a change by hand.
- README is the operator manual: update it in the same commit when a variable, a service, a port or a step changes.

## Boundaries

Do not do any of this without a person's explicit yes: tag, release, push to main, change the default component versions,
start or stop any Compose project on this machine, touch real Keycloak, OpenBao or user accounts. Never commit `.env`,
anything from `certs/`, generated passwords, tokens, keys, internal host names or IP addresses. Examples use
`mcp.corp.test` and dummy values only.

## Pull requests

One change per PR. Commit subject in English, imperative, up to 72 characters; the body says what changed and why (link the
component issue when a default version moves). The checks above must pass. There is no CONTRIBUTING.md or CHANGELOG in this
repository; SECURITY.md says which reports belong here.
