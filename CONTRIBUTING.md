# Contributing

Changes go through a pull request. The repository holds the Compose bundle only (no application code): the components and their
contracts live in the repositories listed in the README.

- Interfaces follow `mcp-contracts` (`openapi/`, `schemas/`, `test-vectors/`). A change of what the gateway, the broker, the portal
  or a server exchange (a claim, a scope, a header, a policy name) is made there first (`CONTRACT_CHANGES.md`) and in the component;
  this repository only follows it, with a new default version or a changed setting.
- Commits: English subject up to 72 characters in the imperative mood, a body that says what changed and why. One change per PR.
- User-visible changes (a variable, a service, a port, a step, a default version) go under `## Unreleased` in `CHANGELOG.md` and into
  the README in the same commit.
- Changes to the OpenBao policies (`init/init.sh`) or `openbao/` need a person's review before merge.
- Never commit `.env`, anything from `certs/`, generated passwords, tokens or keys, internal host names or IP addresses. Examples use
  `mcp.corp.test` and dummy values.

## Setup and checks

Docker with Compose v2, `sh`, `bash`, `perl` and, for the full check, `shellcheck`. Nothing is built.

```bash
scripts/verify.sh
```

CI runs exactly this script. It renders `compose.yaml` alone and with `servers.example.yaml` (dummy values, own project name),
checks that a missing `MCP_DOMAIN` fails, runs `sh -n`, `bash -n` and shellcheck on the scripts, requires a digest on every image,
checks `compose.offline.yaml` against `compose.yaml` and rejects no-break spaces and typographic quotes. Without shellcheck installed the script skips it; CI does not.

Do not run `docker compose up`, `down`, `restart`, `pull` or `run` for a check. `compose.yaml` fixes the project name to
`mcp-platform`, so from any checkout these act on the containers and volumes of an installation on the same machine. To try a
change on a real stack, use a separate machine or pass `-p <own name>` and a free `MCP_HTTPS_PORT`, and remove it with
`docker compose -p <own name> down -v`.

## Images and digests

Every image is pinned by tag and `@sha256:` digest. The aiwcorpo images default to `<tag>@<digest>` in `compose.yaml`
(`MCP_GATEWAY_VERSION`, `MCP_BROKER_VERSION`, `MCP_PORTAL_VERSION`, `MCP_EXAMPLE_VERSION`), and the commented lines of `platform.env`
show the same values. Never edit them by hand: after the images of a version are on ghcr.io, run

```bash
scripts/pin-images.sh gateway=2.0.1 broker=2.0.0 portal=2.0.1
```

It asks the registry for the digest of each tag and rewrites the three files, or changes nothing when a tag cannot be resolved.
`scripts/check-image-pins.sh` fails on an image without a digest.
`compose.offline.yaml` is the exception by design: `docker load` keeps no registry digest, so it names the same images by repository
and tag (the pinned bytes are checked by the checksums of the offline package). `scripts/check-offline-images.sh` fails when its
images differ from `compose.yaml` across all profiles, `pin-images.sh` updates its versions, and a new service or a changed
third-party tag needs the same change in both files. `mcp-server-example` is the one exception until its image can
be read anonymously; remove it from the list in that script when it can. For a third-party image, change tag and digest together
(`docker buildx imagetools inspect <image>:<tag>`). Images are published to ghcr.io only.

## Release

A person does these steps; an agent does not tag, release or change the default versions without an explicit yes.

1. Publish the images of the components (their own release workflows) and decide which versions the bundle defaults to. Raise the
   broker and gateway before or with the portal, never the portal alone.
2. Run `scripts/pin-images.sh` with those versions, then `scripts/verify.sh`. Review the diff of `compose.yaml` and `platform.env`.
3. In `CHANGELOG.md` rename `## Unreleased` to `## <version> - <date>`.
4. Merge, then tag `v<version>` on main.
5. Refresh the offline package: `aiwcorpo/mcp-platform-offline` packs the images named in `compose.yaml` and ships
   `compose.offline.yaml` from this repository; it needs the new versions.

## License

Contributions are licensed under Apache-2.0 (see `LICENSE`).
