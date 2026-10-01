# Rollout guide – putting the templates on GitHub, step by step

Order: **templates repo → scanners → test VM (runner + servers) → each application repo → first PR → first
release → Alibaba staging/production → drills.** Each step ends with a check.

Names used below (replace with yours):

| Thing | Value |
|---|---|
| GitHub owner | `mmamdouhDevops` |
| Templates repo | `mmamdouhDevops/pipeline-templates` |
| App repos | `TaskManager-backend`, `TaskManager-frontend`, `integration-api` (sample), later `reporting-db`, `vlm-service` |
| Test VM | VirtualBox VM `mmostafa`, host-only IP `192.168.56.10`, hostnames `taskmanager.local`, `api.taskmanager.local` |
| Staging / production | Alibaba Cloud ECS, **Ubuntu 24.04 LTS** |

---

## 0. Decide two things first (GitHub plan limits)

| Feature | Public repo | Private repo, Free | Private, Pro/Team | Private, Enterprise Cloud |
|---|---|---|---|---|
| Rulesets (2 approvals, required check) | ✅ | ❌ | ✅ | ✅ |
| Environment *required reviewers* | ✅ | ❌ | ❌ | ✅ |
| Environment branch policy (release/*, hotfix/*) | ✅ | ❌ | ✅ | ✅ |
| Self-hosted runners | ✅ | ✅ | ✅ | ✅ |
| Reusable workflows from a private repo | ✅ | ✅ (same owner, access setting) | ✅ | ✅ |

* Where environment reviewers are not available, `setup-repo.sh` sets **`APPROVAL_MODE=issue`**: each stage
  opens an issue and waits until the approvers comment `approve` (production needs 2).
* A free **GitHub organization** (instead of a personal account) lets one runner serve all repositories
  (runner groups) and keeps variables/secrets at org level. Recommended – but everything also works on a
  personal account (one runner instance per repo, see step 3).

---

## 1. Publish the templates repository

On the VM (all tooling runs there; the Windows laptop blocks unsigned tools):

```bash
# GitHub CLI
sudo apt-get install -y gh && gh auth login -s repo,workflow,admin:org

unzip pipeline-templates.zip -d ~/src && cd ~/src/pipeline-templates
# only if your owner is not mmamdouhDevops:
scripts/rename-owner.sh <owner>

git init -b main && git add . && git commit -m "feat: pipeline templates v1"
gh repo create mmamdouhDevops/pipeline-templates --private --source . --push
git tag -a v1.0.0 -m "v1.0.0" && git tag -f v1 && git push origin v1.0.0 && git push -f origin v1
```

Private templates repo → allow the other repos to call it:
**Settings › Actions › General › Access → "Accessible from repositories owned by the user/organization"**
(or `scripts/setup-repo.sh --repo … --templates-repo mmamdouhDevops/pipeline-templates` does it).

Versioning: consumers use `@v1` (moving major tag). Release template changes as `v1.x.y` and move `v1`;
breaking changes become `v2`. For maximum supply-chain safety consumers may pin a commit SHA instead.

✅ Check: `gh api repos/mmamdouhDevops/pipeline-templates/git/ref/tags/v1`

---

## 2. Scanners (once, shared by every repo)

Details per tool in [TOOLS.md](TOOLS.md). Results go into repo/org variables and secrets:

| Tool | Create | Variable(s) | Secret(s) |
|---|---|---|---|
| SonarQube Server | a project per component (key = `sonar_project_key`), a *Global Analysis* or project token, quality gate | `SONAR_HOST_URL` | `SONAR_TOKEN` |
| Checkmarx One | OAuth client (role `ast-scanner`) | `CHECKMARX_BASE_URI`, `CHECKMARX_TENANT` | `CHECKMARX_CLIENT_ID`, `CHECKMARX_CLIENT_SECRET` |
| Snyk | service account token | `SNYK_ORG` | `SNYK_TOKEN` |
| OWASP ZAP | nothing (Docker image) | `DAST_*` (optional auth) | `DAST_CLIENT_ID/SECRET` (optional) |

Personal account: set them per repository (`gh secret set SONAR_TOKEN -R <repo>`); organization:
`gh secret set SONAR_TOKEN --org <org> --visibility all`.

> The self-hosted runner must reach your SonarQube server URL. If SonarQube runs on the same VM, use its
> LAN/host-only URL, not `localhost`, when GitHub-hosted runners are also used.

---

## 3. Test VM = CI runner + test environment (my device)

The VM plays every role in **test**: runner, web, api, integration, db (`DEPLOY_MODE=local`).

### 3.1 Prepare the VM
```bash
cd ~/src/pipeline-templates
# VM on Ubuntu 24.04:
sudo scripts/prepare-server-ubuntu2404.sh --roles web,api,integration,db,ci --env test \
     --server-names taskmanager.local,api.taskmanager.local,integration.taskmanager.local \
     --sa-password '<SA password>'
# Existing VM on 26.04 (SQL Server in Docker): keep it, skip the SQL install
sudo ALLOW_UNSUPPORTED=1 scripts/prepare-server-ubuntu2404.sh --roles web,api,integration,db,ci --env test
```
Re-use the local CA certificate from the manual setup so browsers keep trusting it:
`sudo install -m644 /etc/ssl/taskmanager/<cert>.crt /etc/ssl/app/server.crt` and the key likewise
(or pass `--tls-cert/--tls-key`).

### 3.2 Hand the manual deployment over to the pipeline (important on the existing VM)
The pipeline generates its own systemd units and Nginx sites (`app-<component>.conf`). Remove the manual
ones so ports/hostnames don't clash – after the first successful pipeline deployment you can delete them:
```bash
sudo systemctl disable --now taskmanager-api        # manual service on 127.0.0.1:5000
sudo rm -f /etc/nginx/sites-enabled/taskmanager      # manual site (keep the file as reference)
sudo nginx -t && sudo systemctl reload nginx
```
The pipeline then installs to `/var/www/taskmanager-api` and `/var/www/taskmanager-web`
(releases + `current` symlink) with secrets in `/etc/app-deploy/<component>.env`.

### 3.3 Register the runner
```bash
TOKEN=$(gh api -X POST repos/mmamdouhDevops/TaskManager-backend/actions/runners/registration-token -q .token)
sudo scripts/install-runner.sh --url https://github.com/mmamdouhDevops/TaskManager-backend \
     --token "$TOKEN" --labels ci,env-test --name vm-mmostafa --instance 1
# personal account: one instance per repository
TOKEN=$(gh api -X POST repos/mmamdouhDevops/TaskManager-frontend/actions/runners/registration-token -q .token)
sudo scripts/install-runner.sh --url https://github.com/mmamdouhDevops/TaskManager-frontend \
     --token "$TOKEN" --labels ci,env-test --name vm-mmostafa --instance 2
# organization: a single runner for all repos → --url https://github.com/<org>
```
Runner sizing on the VM: ≥ 4 vCPU / 8 GB RAM recommended (dotnet build + Angular build + SQL Server).

✅ Check: `gh api repos/mmamdouhDevops/TaskManager-backend/actions/runners -q '.runners[]|[.name,.status]'` → `online`.

---

## 4. Onboard each application repository

### 4.1 Add the files
```bash
cd ~/src/TaskManager-backend
cp -r ~/src/pipeline-templates/examples/taskmanager-backend/{pipeline.yml,.github} .
git checkout -b feature/ci-cd && git add pipeline.yml .github && git commit -m "ci: adopt pipeline templates"
git push -u origin feature/ci-cd
```
Same for the frontend (`examples/taskmanager-frontend`) and the Integration API
(`samples/integration-api` is a complete repo – `gh repo create mmamdouhDevops/integration-api --private --source samples/integration-api --push` after `git init`).
Check `solution:` in the backend `pipeline.yml` (`TaskManager.sln` or `.slnx`).

### 4.2 Governance + environments
```bash
cd ~/src/pipeline-templates
scripts/setup-repo.sh --repo mmamdouhDevops/TaskManager-backend \
   --approvers-test mmamdouhDevops \
   --approvers-staging mmamdouhDevops,<lead> \
   --approvers-production <lead>,<manager> \
   --config ~/src/TaskManager-backend/pipeline.yml
```
It creates `develop` (default branch), imports the rulesets (**2 approvals**, code owners, required check
**`CI / Summary`**), labels, environments `test/staging/production` limited to `release/*` and `hotfix/*`,
the runner/approval variables and test defaults, and prints the list of values you still have to set.

> Two approvals need at least **two other people** with write access (the author can't approve their own PR,
> and "last push approval" is on). With fewer collaborators, temporarily lower
> `required_approving_review_count` in `rulesets/*.json` and re-run the script.

### 4.3 Values for the test environment (backend example)
```bash
R=mmamdouhDevops/TaskManager-backend
gh variable set URL__TASKMANAGER_API          -R $R --env test --body https://api.taskmanager.local
gh variable set SERVER_NAME__TASKMANAGER_API  -R $R --env test --body api.taskmanager.local
gh variable set DB_NAME__TASKMANAGER_API      -R $R --env test --body TaskManagerProd
gh variable set APP_SETTINGS__TASKMANAGER_API -R $R --env test --body '{"App":{"SelfUrl":"https://api.taskmanager.local","CorsOrigins":"https://taskmanager.local","RedirectAllowedUrls":"https://taskmanager.local"},"AuthServer":{"Authority":"https://api.taskmanager.local","RequireHttpsMetadata":true}}'
gh variable set MIGRATOR_SETTINGS__TASKMANAGER_API -R $R --env test --body '{"OpenIddict":{"Applications":{"TaskManager_App":{"RootUrl":"https://taskmanager.local"},"TaskManager_Swagger":{"RootUrl":"https://api.taskmanager.local"}}}}'
gh secret   set DB_ADMIN_USER                 -R $R --env test --body sa
gh secret   set DB_ADMIN_PASSWORD             -R $R --env test        # prompts
gh secret   set DB_CONNECTION__TASKMANAGER_API -R $R --env test --body 'Server=localhost,1433;Database=TaskManagerProd;User Id=taskmanager_app;Password=…;TrustServerCertificate=true'
gh secret   set APP_ENV__TASKMANAGER_API      -R $R --env test < ~/.taskmanager/api.env   # KEY=VALUE lines, see SECRETS.md
gh secret   set FILES__TASKMANAGER_API        -R $R --env test --body "{\"openiddict.pfx\":\"$(base64 -w0 openiddict.pfx)\"}"
```
Frontend: `URL__TASKMANAGER_WEB`, `SERVER_NAME__TASKMANAGER_WEB`, `RUNTIME_CONFIG__TASKMANAGER_WEB`
(the dynamic-env.json content – example in `examples/taskmanager-frontend/pipeline.yml`).
The runner must resolve the hostnames: add them to `/etc/hosts` on the VM (`127.0.0.1 api.taskmanager.local …`).

✅ Check: open the PR `feature/ci-cd → develop`. Expect: Plan, Branch & PR policy, SAST jobs, Build, Summary.

---

## 5. First PR → develop

1. PR title like `ci: adopt pipeline templates` (Conventional Commits; pattern configurable).
2. CI runs only for components whose folder changed (`pipeline.yml`/`.github` changes run everything).
3. Two reviewers approve → merge (merge commit or squash).

Typical first-run fixes: Sonar project key missing (create it), Checkmarx/Snyk credentials,
ChromeHeadless missing for Angular tests (`sudo apt-get install -y chromium-browser` or use
`test_command`), tests path pattern.

---

## 6. First release → test

```bash
git checkout develop && git pull
git checkout -b release/1.0.0 && git push -u origin release/1.0.0
```
The push starts **CD**: plan (version `1.0.0-b<run>`) → build once (package, SBOM, sha256, artifact) →
**test** approval → DB backup → DbMigrator/SQL scripts → install on the role hosts (health check,
automatic rollback) → smoke/contract tests → **DAST**. Staging waits for its approval.

✅ Check: `sudo app-deploy status` on the VM, open `https://taskmanager.local`, read the run summary
(steps table + ZAP report artifact).

Changes during the release go through PRs into `release/1.0.0` (2 approvals) and re-run CD.

---

## 7. Alibaba Cloud – staging and production (Ubuntu 24.04)

### 7.1 Infrastructure (per environment)
| Item | Staging | Production |
|---|---|---|
| VPC + vSwitch | 1 VPC, private vSwitch | separate VPC (or account) |
| ECS image | **Ubuntu 24.04 64-bit** | **Ubuntu 24.04 64-bit** |
| web + api + integration | 1× ecs.g8i.large (2 vCPU/8 GB) combined | 2× per role behind SLB/ALB |
| db | ecs.r8i.large + ESSD PL1 data disk (`/var/opt/mssql`) | ecs.r8i.xlarge, ESSD PL1/PL2, snapshots |
| ai (when needed) | GPU instance (gn7i / gn8is) | GPU instance |
| runner | ecs.c8i.large, **in the same VPC**, label `env-staging` | separate runner, label `env-production` |
| access | Security groups: 22 from runner SG only; 443 from ALB/Internet; 1433 from runner + api SGs | same, stricter |
| TLS | Alibaba Certificate Service / Let's Encrypt on the web/api hosts (or on ALB) | same |

The runner only needs **outbound HTTPS to github.com** (NAT gateway / EIP) and SSH to the servers –
no inbound port is opened for GitHub.

### 7.2 Prepare the servers
```bash
ssh-keygen -t ed25519 -N '' -f deploy_staging -C github-deploy-staging   # key used by the runner
# on every staging server (as root) – roles as planned
sudo scripts/prepare-server-ubuntu2404.sh --roles web,api,integration --env staging \
     --deploy-key "$(cat deploy_staging.pub)" --server-names taskmanager-stg.example.com,api-stg.example.com \
     --tls-cert fullchain.pem --tls-key privkey.pem
sudo scripts/prepare-server-ubuntu2404.sh --roles db --env staging \
     --deploy-key "$(cat deploy_staging.pub)" --db-allow-from 10.10.0.0/16 --sa-password '…' --sql-edition Standard
# runner ECS
sudo scripts/prepare-server-ubuntu2404.sh --roles ci --env staging
sudo scripts/install-runner.sh --url https://github.com/<org-or-repo> --token … --labels env-staging --name ali-stg
```
> SQL Server editions: Developer is for test only. Staging/production need a licensed edition
> (Standard/Enterprise; Express for very small DBs) – or ApsaraDB RDS for SQL Server (then set `backup: never`
> and rely on RDS backups, because `BACKUP DATABASE TO DISK` is not allowed on RDS).

### 7.3 Environment values
```bash
R=mmamdouhDevops/TaskManager-backend
for v in "DEPLOY_MODE ssh" "DEPLOY_SSH_USER deploy" "API_HOSTS 10.10.1.11" "WEB_HOSTS 10.10.1.11" \
         "INTEGRATION_HOSTS 10.10.1.11" "DB_HOSTS 10.10.1.21" "DB_SERVER 10.10.1.21,1433" \
         "DB_BACKUP_DIR /var/opt/mssql/backup" "DB_BACKUP_KEEP 10"; do
  set -- $v; gh variable set "$1" -R $R --env staging --body "$2"; done
gh variable set DEPLOY_SSH_KNOWN_HOSTS -R $R --env staging --body "$(ssh-keyscan -t ed25519 10.10.1.11 10.10.1.21 2>/dev/null)"
gh secret   set DEPLOY_SSH_KEY        -R $R --env staging < deploy_staging
# + URL__*, SERVER_NAME__*, APP_SETTINGS__*, APP_ENV__*, DB_* as for test (staging values)
```
Repeat for **production** with its own key, hosts and secrets. Several hosts per role: `API_HOSTS="10.20.1.11 10.20.1.12"`
→ rolling deployment, one host at a time (put the hosts behind the ALB health check).

✅ Check: approve **staging** in the running CD → summary shows each host ✅ and the smoke test.

---

## 8. Production and release closing

Approve **production** (2 approvers; with `APPROVAL_MODE=environment` the wait timer runs first).
After success the pipeline:
* creates tag `v1.0.0` and a GitHub Release with the packages, SBOMs and checksums;
* opens PRs `release/1.0.0 → main` and `release/1.0.0 → develop` (Git Flow back-merge, 2 approvals each).

Merge both, delete the release branch.

---

## 9. Drills (do them once before going live)

**Hotfix**
```bash
git checkout main && git pull && git checkout -b hotfix/1.0.1
# fix + PR into hotfix/1.0.1 (or commit directly if allowed) → push
```
CD runs the same three stages; afterwards PRs to main and develop.

**Rollback** – Actions › *Rollback* › environment + component. Switches the `current` symlink back to the
previous release on all hosts of the role and restarts. The database is **not** rolled back – see
[RUNBOOK.md](RUNBOOK.md#restore-a-database-backup).

**Failed deployment** – break the health endpoint on a test branch: `app-deploy` must roll back
automatically and the job must fail.

---

## 10. Day-2

| Task | How |
|---|---|
| Change a template | PR in pipeline-templates → tag `v1.x.y` → move `v1` (`git tag -f v1 && git push -f origin v1`) |
| New component | add it to `pipeline.yml` + its `URL__/SERVER_NAME__/APP_*` values |
| New component type | add `types/<type>.yml` (and package/deploy support if it is a new runtime) |
| New approver | `vars.APPROVERS_<ENV>` and/or environment reviewers |
| More CI capacity | more runner instances with label `ci` (or `--ephemeral` runners + an autoscaler) |
| Rotate secrets | `gh secret set …` then re-run the last CD for that environment |
| Pin third-party actions | replace `@v4`-style refs with commit SHAs (see TOOLS.md) |
