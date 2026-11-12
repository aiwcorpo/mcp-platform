# Security policy

## Reporting a vulnerability

Do not open a public issue for a vulnerability. Use the private vulnerability reporting of the repository (the
"Security" tab, "Report a vulnerability"). Include the commit, the service of the bundle involved and the steps that show the
problem. Do not attach real secrets or tokens.

A vulnerability in a component (gateway, credential broker, portal, an MCP server) belongs to the repository of that
component. This repository covers the Compose bundle: `compose.yaml`, the init scripts, the nginx, Keycloak and OpenBao
configuration.

This repository has no bug bounty.
