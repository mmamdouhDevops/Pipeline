# Runbook

## Where things are on a server

| What | Path |
|---|---|
| Releases | `<deploy_path>/releases/<version>/` (newest `keep_releases` kept) |
| Live release | `<deploy_path>/current` → `releases/<version>` |
| Persistent files | `<deploy_path>/shared/` (Logs, certificates, `dynamic-env.json`) |
| Secrets (env file) | `/etc/app-deploy/<name>.env` (root:<app> 0640) |
| State / history | `/var/lib/app-deploy/<name>/{manifest.json,previous,history}` |
| systemd unit | `/etc/systemd/system/<service_name>.service` (generated – don't edit) |
| Nginx site | `/etc/nginx/sites-enabled/app-<name>.conf` (generated – don't edit) |
| DB backups | `DB_BACKUP_DIR` on the DB server (`<db>_<version>_<utc>.bak`) |

```bash
sudo app-deploy status                 # all components: current, previous, version, health
journalctl -u taskmanager-api -n 200 --no-pager
tail -f /var/www/taskmanager-api/shared/Logs/logs.txt
```

## Deployment failed – what now?

| Symptom in the run | Meaning | Action |
|---|---|---|
| `Health check failed … rolled back` | new release didn't become healthy; previous one is live again | read the journal lines in the job log, fix, new commit on the release branch |
| failed on host 2 of 3 | hosts 1 is on the new version, 2 rolled back, 3 untouched | fix forward, or run **Rollback** for the component to align all hosts |
| `Smoke test failed` | app healthy locally but not via the public URL | Nginx/DNS/TLS/ALB; `curl -vk https://<url><health_path>` from the runner |
| `Deployed API is missing paths` | wrong version live or routing to old host | `app-deploy status` on every host |
| migration failed | DB unchanged if the migration was transactional; a backup was taken first | fix the migration; restore only if data was damaged |
| DAST failed | high-risk ZAP alert | report artifact → fix, or tune `.zap/rules.tsv` with justification |
| approval issue never closes | approvers didn't comment `approve` / wrong usernames | check `vars.APPROVERS_<ENV>`; the job times out after 6 h |

## Manual rollback
GitHub: *Actions › Rollback › Run workflow* (environment + component) – goes through the environment's
protection. On a server (emergency, no GitHub):
```bash
sudo app-deploy rollback taskmanager-api
```

## Restore a database backup
Code rollbacks do **not** revert the schema. Additive migrations stay compatible with the previous release,
so restoring is rarely needed. When it is:
```bash
# on the DB server; stop writers first (API service(s) on the api hosts)
sudo systemctl stop taskmanager-api            # on every api host
ls -lt /var/opt/mssql/backup/TaskManagerProd_*.bak | head
sqlcmd -S localhost -U sa -C -Q "ALTER DATABASE [TaskManagerProd] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
  RESTORE DATABASE [TaskManagerProd] FROM DISK=N'/var/opt/mssql/backup/TaskManagerProd_1.2.0-b41_20261001-101500.bak' WITH REPLACE, CHECKSUM;
  ALTER DATABASE [TaskManagerProd] SET MULTI_USER;"
sudo app-deploy rollback taskmanager-api       # matching code version, then start
```
SQL Server in Docker (test VM): run `sqlcmd` inside the container (`docker exec -it <container> /opt/mssql-tools18/bin/sqlcmd …`)
and keep `DB_BACKUP_DIR` on a volume mounted from the host so the retention job can see the files.

## Hotfix flow
`main` → `hotfix/X.Y.Z` → push → CD (test → staging → production) → PRs into `main` and `develop`.
If a release branch is open, also merge the hotfix into it.

## Runner maintenance
```bash
sudo /home/gh-runner/actions-runner-1/svc.sh status
sudo /home/gh-runner/actions-runner-1/svc.sh stop|start
docker system prune -af --filter "until=168h"   # ZAP images/layers on the test runner
```
Runners update themselves. Disk: `_work` grows with checkouts – clean with `rm -rf _work/*/` while the
runner is stopped.

## AI / GPU servers
`prepare-server-ubuntu2404.sh --roles ai` installs Python and build tools only. Install the NVIDIA driver
(`sudo ubuntu-drivers autoinstall && sudo reboot`) and the CUDA runtime matching your model framework.
Large model files: keep them in `<deploy_path>/shared/models` (persist across releases) and provide them
via an object store download step rather than inside the release package.
