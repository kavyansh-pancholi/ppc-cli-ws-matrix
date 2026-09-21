# ppc-cli-ws-matrix

Postman CLI collection runs against a PPC cluster, driven from GitHub Actions.

## Required repo configuration

Secret:

| Name | Value |
| --- | --- |
| `POSTMAN_API_KEY` | A `PMAK-...` key issued **by the target PPC cluster** (public-cloud keys 401 here) |

Variables:

| Name | Example |
| --- | --- |
| `POSTMAN_API_BASE_URL` | `https://api-public.dev01.postmanlabs.com` |
| `POSTMAN_GATEWAY_BASE_URL` | `https://gateway.dev01.postmanlabs.com` |
| `POSTMAN_IAPUB_BASE_URL` | `https://api-public.dev01.postmanlabs.com` (no public iapub exists; harmless for API-key auth) |
| `COLLECTION_UID` | `10000000000129-8a5b90d2-dc7d-4a9b-be2f-c6a4ee7d2a36` |
| `ENVIRONMENT_UID` | `10000000000129-73b5abde-976e-4062-9ae3-5b0969ad66da` |
| `RUNNER_LABEL` | label of a runner inside the network (defaults to `self-hosted`) |

## Why the base URLs are required

The Postman CLI defaults to the US public cloud. `region-util.js` resolves both
endpoints from env vars before falling back to region defaults:

```js
getAPIBaseURL:     if (process.env.POSTMAN_API_BASE_URL)     return process.env.POSTMAN_API_BASE_URL;
getGatewayBaseURL: if (process.env.POSTMAN_GATEWAY_BASE_URL) return process.env.POSTMAN_GATEWAY_BASE_URL;
```

Without them the run hits `api.getpostman.com` and 404s on the PPC collection UID.

## Runner choice

A **GitHub-hosted runner works**, provided the base URLs use the publicly routable
hosts. Verified from `ubuntu-latest`:

| Host | Public DNS | Reachable from cloud |
| --- | --- | --- |
| `api-public.dev01.postmanlabs.com` | 18.225.137.55 | yes (HTTP 401) |
| `gateway.dev01.postmanlabs.com` | 3.147.134.87 | yes (HTTP 404) |
| `api.dev01.postmanlabs.com` | 10.130.89.207 | no — RFC1918 |
| `iapub.dev01.postmanlabs.com` | 10.130.x.x | no — RFC1918 |

`api-public` does not serve gateway routes, so both must be set: pointing the
gateway at `api-public` fails with `Error: collection could not be loaded`.

Public DNS publishes RFC1918 addresses for the internal hosts, so a misconfigured
base URL fails as a 20-second timeout rather than a DNS error. The preflight step
exists to make that obvious.

A self-hosted or in-network containerized runner also works and is required if you
need `iapub` (browser/PKCE login) or a cluster with no public endpoint.

## Reproducing locally

```bash
export POSTMAN_API_BASE_URL=https://api-public.dev01.postmanlabs.com
export POSTMAN_GATEWAY_BASE_URL=https://gateway.dev01.postmanlabs.com
export POSTMAN_IAPUB_BASE_URL=https://api-public.dev01.postmanlabs.com
postman login --with-api-key "$PMAK"
postman collection run "$COLLECTION_UID" -e "$ENVIRONMENT_UID"
```

## Self-hosted runner

PPC clusters are on private addresses, so the job needs a runner inside the
network. Register one, label it (e.g. `ppc-dev01`), then point the
`RUNNER_LABEL` repo variable at that label.

The workflow installs the Postman CLI into `$RUNNER_TEMP` and adds it to
`$GITHUB_PATH` rather than `sudo mv`-ing the binary to `/usr/bin`. The binary
loads its sibling `lib/` directory at runtime, so relocating it on its own
fails with a `pkg/prelude/bootstrap.js` error. This also means no sudo is
needed, and it works on both Linux and macOS runners.
