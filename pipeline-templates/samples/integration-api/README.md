# Integration API (sample)

.NET 10 minimal API that connects TaskManager with a partner system. It is the reference
consumer of the **integration-api** pipeline type in `pipeline-templates`.

| Endpoint | Purpose |
|---|---|
| `GET /api/v1/partner/orders/{id}` | read an order from the partner system |
| `POST /api/v1/partner/tasks/sync` | push up to 500 TaskManager tasks to the partner |
| `GET /health` | liveness (used by `app-deploy` for health check + automatic rollback) |
| `GET /health/ready` | partner reachable (checked by the contract smoke after every deployment) |
| `GET /openapi/v1.json` | live contract (contract smoke + ZAP API scan) |

Inbound calls need `Authorization: Bearer <key>` or `X-Api-Key: <key>` when `Inbound:ApiKeys` is configured.

## Run locally (Ubuntu VM)
```bash
dotnet test IntegrationApi.slnx            # WireMock stands in for the partner
cd src/IntegrationApi && dotnet run        # http://localhost:5010/openapi/v1.json
```

## Configuration per environment
| Where | Name | Example |
|---|---|---|
| env var `APP_SETTINGS__INTEGRATION_API` | non-secret JSON → appsettings.json | `{"Partner":{"BaseUrl":"https://partner-sandbox.example.com/"}}` |
| env secret `APP_ENV__INTEGRATION_API` | secrets as env lines | `Partner__ApiKey=…` `Inbound__ApiKeys__0=…` |
| env secret `SMOKE_TOKEN__INTEGRATION_API` | key used by the post-deploy smoke test | one of the inbound keys |
| env var `URL__INTEGRATION_API` / `SERVER_NAME__INTEGRATION_API` | public URL / Nginx server_name | `https://integration.example.com` |

## Contract rules (enforced in CI)
`openapi/IntegrationApi.json` is regenerated on every build and compared with the base branch by
**oasdiff**. A breaking change (removed endpoint/field, new required parameter …) fails the PR unless
the label `breaking-change` is added after agreeing with partner consumers. Prefer adding `/api/v2/…`.
