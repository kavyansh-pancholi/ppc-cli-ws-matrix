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
| `POSTMAN_API_BASE_URL` | `https://api.dev01.postmanlabs.com` |
| `POSTMAN_GATEWAY_BASE_URL` | `https://gateway.dev01.postmanlabs.com` |
| `POSTMAN_IAPUB_BASE_URL` | `https://iapub.dev01.postmanlabs.com` (login / session validation) |
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

## Why a self-hosted runner

`gateway.dev01.postmanlabs.com` resolves to `10.130.48.22` (RFC1918). GitHub-hosted
runners cannot route there, so the job needs a runner inside the network.

## Reproducing locally

```bash
export POSTMAN_API_BASE_URL=https://api.dev01.postmanlabs.com
export POSTMAN_GATEWAY_BASE_URL=https://gateway.dev01.postmanlabs.com
export POSTMAN_IAPUB_BASE_URL=https://iapub.dev01.postmanlabs.com
postman login --with-api-key "$PMAK"
postman collection run "$COLLECTION_UID" -e "$ENVIRONMENT_UID"
```
