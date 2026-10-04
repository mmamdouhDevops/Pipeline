# Variables and secrets

`<SLUG>` = component name in UPPER_SNAKE (`taskmanager-api` → `TASKMANAGER_API`).
**Env** = set on the GitHub Environment (`test`, `staging`, `production`) – different value per stage.
Never commit any of these; `scripts/setup-repo.sh` prints the list for a given `pipeline.yml`.

## Shared (organization or repository)

| Name | Kind | Used by | Example / note |
|---|---|---|---|
| `RUNNER_CI` | var | CI, CD build | `["self-hosted","linux","ci"]` (unset → `ubuntu-latest`) |
| `RUNNER_DEPLOY_TEST` / `_STAGING` / `_PRODUCTION` | var | deploy jobs | `["self-hosted","linux","env-test"]` … |
| `APPROVAL_MODE` | var | stages | `environment` (default) · `issue` · `none` |
| `APPROVERS_TEST` / `_STAGING` / `_PRODUCTION` | var | issue mode | `alice,bob` (production needs 2 approvals) |
| `PRODUCTION_ENABLED` | var | CD | `false` (default) → CD ends after staging with an `-rc` pre-release; `true` → production stage |
| `ALLOW_SKIP_STAGING` | var | CD | `true` only during an incident |
| `ATTEST_BUILDS` | var | CD build | `true` → build provenance attestation (public repos / Enterprise) |
| `UPLOAD_SARIF` | var | CI | `true` → SARIF to code scanning (public repos / GitHub Advanced Security) |
| `SONAR_HOST_URL` | var | CI | `https://sonar.example.com` |
| `SONAR_TOKEN` | secret | CI | analysis token |
| `CHECKMARX_BASE_URI`, `CHECKMARX_TENANT` | var | CI | `https://eu.ast.checkmarx.net`, tenant name |
| `CHECKMARX_CLIENT_ID`, `CHECKMARX_CLIENT_SECRET` | secret | CI | OAuth client |
| `SNYK_ORG` | var | CI | org slug or id |
| `SNYK_TOKEN` | secret | CI | service account token |

## Per environment – topology and database server

| Name | Kind | Example (test VM) | Example (Alibaba) |
|---|---|---|---|
| `DEPLOY_MODE` | var | `local` | `ssh` |
| `WEB_HOSTS` `API_HOSTS` `INTEGRATION_HOSTS` `DB_HOSTS` `AI_HOSTS` | var | `localhost` | `10.10.1.11 10.10.1.12` (space separated) |
| `DEPLOY_SSH_USER` | var | – | `deploy` |
| `DEPLOY_SSH_KNOWN_HOSTS` | var | – | output of `ssh-keyscan -t ed25519 <hosts>` |
| `DEPLOY_SSH_KEY` | secret | – | private key (ed25519) of the runner |
| `TLS_CERT` / `TLS_KEY` | var | – | paths on the servers if not `/etc/ssl/app/server.{crt,key}` |
| `DB_SERVER` | var | `localhost,1433` | `10.10.1.21,1433` |
| `DB_ADMIN_USER` / `DB_ADMIN_PASSWORD` | secret | `sa` / … | a login with `db_backupoperator` + `db_owner` on app DBs (avoid `sa` in prod) |
| `DB_BACKUP_DIR` | var | `/var/opt/mssql/backup` | same (on the DB server) |
| `DB_BACKUP_KEEP` | var | `5` | `10`–`30` |
| `DAST_TOKEN_URL`, `DAST_SCOPE` | var (test) | `https://api.taskmanager.local/connect/token`, `TaskManager` | – |
| `DAST_CLIENT_ID` / `DAST_CLIENT_SECRET` | secret (test) | OpenIddict client-credentials client for the scan | – |
| `DAST_EXTRA_HOSTS` | var (test) | `api.taskmanager.local:127.0.0.1 taskmanager.local:127.0.0.1` | – |
| `DAST_FAIL_ON_HIGH` | var | `true` (default) / `false` | – |

## Per environment – per component

| Name | Kind | Content |
|---|---|---|
| `URL__<SLUG>` | var | public URL – smoke test, DAST, environment link: `https://api.taskmanager.local` |
| `SERVER_NAME__<SLUG>` | var | Nginx `server_name`: `api.taskmanager.local` (empty = no Nginx site) |
| `APP_SETTINGS__<SLUG>` | var | non-secret JSON → `appsettings.<Env>.json` (dotnet) |
| `APP_ENV__<SLUG>` | secret | `KEY=VALUE` lines → `/etc/app-deploy/<name>.env` (systemd `EnvironmentFile`) |
| `FILES__<SLUG>` | secret | JSON `{"file-name":"<base64>"}` → `<deploy_path>/shared/` and linked into the app (e.g. `openiddict.pfx`) |
| `RUNTIME_CONFIG__<SLUG>` | var | front-end runtime config → `dynamic-env.json` served at `/getEnvConfig` |
| `SMOKE_TOKEN__<SLUG>` | secret | bearer token for the smoke test (protected health endpoints, integration keys) |
| `DB_NAME__<SLUG>` | var | database name: `TaskManagerProd` |
| `DB_CONNECTION__<SLUG>` | secret | connection string used by the DbMigrator / EF |
| `MIGRATOR_SETTINGS__<SLUG>` | var | JSON → `appsettings.Production.json` of the DbMigrator (OpenIddict client root URLs …) |

### `APP_ENV__TASKMANAGER_API` example (secret)
```
ConnectionStrings__Default=Server=localhost,1433;Database=TaskManagerProd;User Id=taskmanager_app;Password=…;TrustServerCertificate=true
Redis__Configuration=127.0.0.1:6379,password=…,defaultDatabase=1
StringEncryption__DefaultPassPhrase=…
AuthServer__CertificatePassPhrase=…
```
`__` is the .NET configuration separator, so these override `appsettings.json` keys.

### `RUNTIME_CONFIG__TASKMANAGER_WEB` example (variable)
```json
{"production":true,
 "application":{"baseUrl":"https://taskmanager.local","name":"TaskManager"},
 "oAuthConfig":{"issuer":"https://api.taskmanager.local/","redirectUri":"https://taskmanager.local",
                "clientId":"TaskManager_App","responseType":"code","scope":"offline_access TaskManager","requireHttps":true},
 "apis":{"default":{"url":"https://api.taskmanager.local","rootNamespace":"TaskManager"}}}
```

## Least privilege notes
* `deploy` (servers) and `gh-runner` (runner) may run **only** `/usr/local/sbin/app-deploy` with sudo.
* App processes run as their own system user (`service_name`), secrets are `root:<app> 0640`.
* Production secrets live only in the `production` environment, which only `release/*`/`hotfix/*`
  can use and which needs the production approvers.
