# Database helpers used by deploy.sh (sourced). Runs on the deploy runner with sqlcmd.
# Env: DB_SERVER, DB_NAME, DB_ADMIN_USER, DB_ADMIN_PASSWORD, DB_CONNECTION, DB_BACKUP_DIR, DB_BACKUP_KEEP

SQLCMD=""
db_require() {
  [[ -n "${DB_NAME:-}" ]] || fail "Database name missing: set environment variable ${C_DB_NAME_VAR}"
  [[ -n "${DB_ADMIN_USER:-}" && -n "${DB_ADMIN_PASSWORD:-}" ]] || fail "secrets.DB_ADMIN_USER / DB_ADMIN_PASSWORD required for database tasks"
  for c in sqlcmd /opt/mssql-tools18/bin/sqlcmd; do command -v "$c" >/dev/null 2>&1 && { SQLCMD="$c"; break; }; done
  [[ -n "$SQLCMD" ]] || fail "sqlcmd not found on the runner (install mssql-tools18 – see scripts/prepare-server-ubuntu2404.sh)"
}
sql() {  # sql [-d db] "T-SQL"   -> prints rows (no headers)
  local db=master; [[ "$1" == "-d" ]] && { db="$2"; shift 2; }
  SQLCMDPASSWORD="$DB_ADMIN_PASSWORD" "$SQLCMD" -S "${DB_SERVER:-localhost}" -U "$DB_ADMIN_USER" -C -b \
    -d "$db" -h -1 -W -s '|' -Q "SET NOCOUNT ON; $1"
}

LAST_BACKUP=""
db_backup() {  # copy-only full backup on the DB server's disk + verify
  local dir="${DB_BACKUP_DIR:-/var/opt/mssql/backup}" ts; ts=$(date -u +%Y%m%d-%H%M%S)
  local exists; exists=$(sql "SELECT COUNT(*) FROM sys.databases WHERE name = N'$DB_NAME'")
  [[ "$exists" == "1" ]] || { note "database $DB_NAME does not exist yet – backup skipped"; LAST_BACKUP="(new database)"; return; }
  LAST_BACKUP="$dir/${DB_NAME}_${1}_${ts}.bak"
  info "Backup $DB_NAME → $LAST_BACKUP"
  sql "BACKUP DATABASE [$DB_NAME] TO DISK = N'$LAST_BACKUP' WITH COPY_ONLY, CHECKSUM, INIT, STATS = 25;" \
    || sql "BACKUP DATABASE [$DB_NAME] TO DISK = N'$LAST_BACKUP' WITH COPY_ONLY, CHECKSUM, INIT;"
  sql "RESTORE VERIFYONLY FROM DISK = N'$LAST_BACKUP' WITH CHECKSUM;" >/dev/null
  note "backup verified"
  # retention: keep the newest N backups of this database – runs on the DB host via app-deploy
  local keep="${DB_BACKUP_KEEP:-10}" dbh
  dbh=$(echo "${DB_HOSTS:-localhost}" | tr ',' ' ' | awk '{print $1}')
  host_run "$dbh" /usr/local/sbin/app-deploy prune-backups "$dir" "$DB_NAME" "$keep" \
    || echo "::warning::backup retention could not run on $dbh (backups are kept)"
}

ef_pending_count() {  # migrations.json (from package) vs __EFMigrationsHistory
  local file="$1"
  [[ -f "$file" ]] || { echo "unknown"; return; }
  local applied
  applied=$(sql -d "$DB_NAME" "IF OBJECT_ID(N'__EFMigrationsHistory') IS NOT NULL SELECT MigrationId FROM __EFMigrationsHistory" 2>/dev/null || true)
  python3 - "$file" <<PY
import json, sys
ids = [m["id"] for m in json.load(open(sys.argv[1]))]
applied = set("""$applied""".split())
print(len([i for i in ids if i not in applied]))
PY
}

run_migrator() {  # ABP DbMigrator: applies migrations + seeds; must run from its own folder
  local dir="$1" entry; entry=$(cat "$dir/.entry")
  [[ -n "${DB_CONNECTION:-}" ]] || fail "secrets.DB_CONNECTION__${C_SLUG} (app connection string) required for migrations"
  [[ -n "${MIGRATOR_SETTINGS_JSON:-}" ]] && printf '%s\n' "$MIGRATOR_SETTINGS_JSON" > "$dir/appsettings.Production.json"
  info "Run DbMigrator ($entry)"
  ( cd "$dir" && DOTNET_ENVIRONMENT=Production ConnectionStrings__Default="$DB_CONNECTION" dotnet "$entry" )
}

sql_history_init() {
  sql -d "$DB_NAME" "IF OBJECT_ID(N'dbo.__ScriptHistory') IS NULL
    CREATE TABLE dbo.__ScriptHistory (ScriptName nvarchar(260) NOT NULL PRIMARY KEY, Checksum char(64) NOT NULL,
      AppliedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(), AppliedBy nvarchar(128) NOT NULL DEFAULT SUSER_SNAME(),
      Version nvarchar(64) NULL);" >/dev/null
}
sql_pending() {  # prints names of scripts not yet in __ScriptHistory (creates the DB if missing)
  local dir="$1"
  sql "IF DB_ID(N'$DB_NAME') IS NULL CREATE DATABASE [$DB_NAME];" >/dev/null
  sql_history_init
  local applied; applied=$(sql -d "$DB_NAME" "SELECT ScriptName FROM dbo.__ScriptHistory")
  for f in $(ls -1 "$dir" | grep -E '\.sql$' | sort -V); do
    grep -qxF "$f" <<< "$applied" || echo -n "$f "
  done
}
sql_apply() {  # dir, scripts...
  local dir="$1"; shift
  for f in "$@"; do
    info "Apply $f"
    SQLCMDPASSWORD="$DB_ADMIN_PASSWORD" "$SQLCMD" -S "${DB_SERVER:-localhost}" -U "$DB_ADMIN_USER" -C -b -d "$DB_NAME" -i "$dir/$f"
    sum=$(sha256sum "$dir/$f" | cut -d' ' -f1)
    sql -d "$DB_NAME" "INSERT dbo.__ScriptHistory (ScriptName, Checksum, Version) VALUES (N'$f', '$sum', N'$VERSION');" >/dev/null
  done
}
sql_verify() {  # every packaged script applied and unchanged
  local dir="$1" bad=0
  while IFS='|' read -r name sum; do
    [[ -z "$name" ]] && continue
    [[ -f "$dir/$name" ]] || continue
    now=$(sha256sum "$dir/$name" | cut -d' ' -f1)
    [[ "$now" == "$sum" ]] || { echo "::error::$name changed after it was applied (checksum mismatch)"; bad=1; }
  done < <(sql -d "$DB_NAME" "SELECT ScriptName, Checksum FROM dbo.__ScriptHistory")
  [[ -z "$(sql_pending "$dir")" ]] || { echo "::error::pending scripts remain"; bad=1; }
  return $bad
}
