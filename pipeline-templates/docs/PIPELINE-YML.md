# `pipeline.yml` reference

One file in the root of every application repository. It lists the deployable **components**; each has a
**type** (`types/<type>.yml`) that decides what CI runs and which deploy tasks apply.

```yaml
version: 1
defaults:              # optional – merged into every component
  dotnet_version: "10.0.x"
components:            # deployment order = list order (databases first, web last)
  - name: taskmanager-api
    type: backend-dotnet
    path: .
    ...
```

## Component fields

| Field | Default | Used for |
|---|---|---|
| `name` | **required** | lowercase `a-z0-9-`; artifact, service user, folder names; `<SLUG>` = UPPER_SNAKE of it |
| `type` | **required** | `backend-dotnet` · `integration-api` · `frontend-angular` · `database` · `ai-service` |
| `path` | `.` | component folder (monorepo); CI only runs when files below it change |
| **Build** | | |
| `solution` | – | `.sln`/`.slnx` for build, tests and SonarQube (.NET) |
| `publish_project` | – | `.csproj` published as the app (.NET, required) |
| `test_projects` | `**/*Tests.csproj` | test projects (.NET) |
| `abp_install_libs` | `false` | run `abp install-libs` before build/publish (ABP MVC/host `wwwroot/libs`) |
| `angular_dist` | auto | folder with `index.html` after the build |
| `build_command` / `test_command` | type default | override build / test commands (Angular, Python) |
| `requirements` | `requirements.txt` | Python dependencies |
| `app_module` | `app.main:app` | uvicorn target (Python) |
| `sql_dir` | `sql/migrations` | `NNN_description.sql` scripts (database type) |
| `openapi_file` | – | build-time OpenAPI document; enables the breaking-change gate (`integration-api`) |
| `dotnet_version` / `node_version` / `python_version` | `10.0.x` / `24` / `3.12` | toolchains |
| `sonar_project_key` | `<repo>-<name>` | SonarQube project |
| **Database** | | |
| `owns_database` | `false` (`true` for `database`) | enables DB backup + migrations for .NET types |
| `migrator_project` | – | ABP DbMigrator `.csproj` – run on the deploy runner |
| `ef_project` | – | EF Core project – pending-migration detection, idempotent script, destructive-change guard |
| `backup` | `always` if it owns a DB | `always` · `on_migration` (only when something is pending) · `never` |
| `always_run_migrator` | `false` | run the migrator even with no pending migration (ABP data seeding) |
| `db_name_var` | `DB_NAME__<SLUG>` | name of the environment variable holding the DB name |
| **Runtime** | | |
| `server_role` | type default | `web` · `api` · `integration` · `db` · `ai` → hosts from `<ROLE>_HOSTS` |
| `service_name` | `name` | systemd unit + service user |
| `deploy_path` | `/var/www/<name>` | under `/var/www`, `/opt` or `/srv` |
| `port` | `5000` | Kestrel/uvicorn port on 127.0.0.1 (unique per server!) |
| `health_path` | `/health` | checked by `app-deploy` after the switch (auto-rollback) and by the smoke test |
| `openapi_path` | – | live OpenAPI URL path – contract smoke + ZAP API scan |
| `dast` | type default | `api` · `web` · `none` |
| `keep_releases` | `5` | releases kept on each server |
| `public_url_var` / `server_name_var` | `URL__<SLUG>` / `SERVER_NAME__<SLUG>` | variable names (rarely changed) |

## Types

```yaml
# types/backend-dotnet.yml
type: backend-dotnet
toolchain: [dotnet, node]
ci:      { build: dotnet, sonar: dotnet, snyk: dotnet, checks: [ef-migrations], contract: false }
package: dotnet
cd:
  runner_tasks: [db-backup, db-migrate]   # on the deploy runner (DB network access)
  host_tasks:   [install, health]         # on every host of the role, one by one
  post_tasks:   [smoke]                   # from the runner against the public URL
default_role: api
dast: api
```

| Task | Where | What |
|---|---|---|
| `db-backup` | runner → DB server | `BACKUP DATABASE … COPY_ONLY, CHECKSUM` + `RESTORE VERIFYONLY`, retention on the DB host |
| `db-migrate` | runner | pending EF migrations? → DbMigrator (or idempotent script) |
| `db-scripts` | runner | apply `sql_dir` scripts not yet in `dbo.__ScriptHistory` (checksum-tracked, in order) |
| `install` | each host | `app-deploy install`: unpack release, config, systemd/Nginx, atomic switch |
| `health` | each host | local health check; failure → automatic rollback to the previous release |
| `smoke` | runner | HTTPS GET `URL__<SLUG>` + `health_path` |
| `contract-smoke` | runner | live OpenAPI contains every path of the release contract; `/health/ready` OK |
| `db-verify` | runner | every packaged script recorded with the same checksum |

## Version and branches
* CI stage 1 – **CI SAST** (`ci.yml`, `stage: sast`): every PR into `develop`, `main`, `release/**`, `hotfix/**` –
  SAST, unit tests, checks; merge needs `CI / Summary` + 2 approvals. No packages.
* CI stage 2 – **Build** (`build.yml`, `stage: build`, manual): input `release/X.Y.Z` or `hotfix/X.Y.Z` →
  SAST gate = proof that a CI SAST run succeeded for the PR behind the branch head (or `sast_run_id`) and that the
  PR had 2 approvals → build → artifacts `pkg-*`, `db-*` (DB changes since the latest `vX.Y.Z` tag, or `main`),
  `release-manifest`. Feature branches are rejected.
* **CD** (`cd.yml`, manual): inputs = the release/hotfix branch (*Use workflow from*) + the build `version`
  (or the Build run id).
* Version = `X.Y.Z-b<Build run number>` (optional `v` in the branch name). Production success tags `vX.Y.Z`;
  without production a pre-release `vX.Y.Z-rc.<Build run id>` is created after staging.
* CD never builds: it deploys the artifacts of a Build run on the same branch and commit (a newer commit on the
  branch → Build again).

## Database script rules (`database` type)
* File names `NNN_description.sql` (`001_…`, `002_…`), never renamed or edited after release
  (the checksum is verified) – fix forward with a new script.
* Additive changes only; use `GO` batch separators; make scripts idempotent (`IF OBJECT_ID … IS NULL`).
* A destructive EF migration (drop/rename) needs the PR label `destructive-migration`.
