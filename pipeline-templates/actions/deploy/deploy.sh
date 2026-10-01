#!/usr/bin/env bash
# Runs on the deploy runner. See action.yml for the contract.
set -euo pipefail
info()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
note()  { echo "    $*"; }
fail()  { echo "::error::$*"; exit 1; }
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

eval "$(python3 - <<'PY'
import json, os, shlex
c = json.loads(os.environ["COMPONENT_JSON"])
for k, v in c.items():
    if isinstance(v, (list, dict)): v = " ".join(v) if isinstance(v, list) else json.dumps(v)
    elif isinstance(v, bool): v = "true" if v else "false"
    print(f"C_{k.upper()}={shlex.quote(str(v))}")
PY
)"
source "$ACTION_DIR/db.sh"

# ------------------------------------------------------------------ hosts of this component's role
role_var="$(echo "$C_SERVER_ROLE" | tr '[:lower:]' '[:upper:]')_HOSTS"
HOSTS="${!role_var:-}"
[[ -z "$HOSTS" && "$C_SERVER_ROLE" == "integration" ]] && HOSTS="${API_HOSTS:-}"   # integration defaults to api servers
HOSTS="$(echo "$HOSTS" | tr ',' ' ')"
MODE="${DEPLOY_MODE:-ssh}"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/deploy-$C_NAME.XXXX")"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ SSH setup (non-local hosts)
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
setup_ssh() {
  [[ -n "${SSH_READY:-}" ]] && return
  [[ -n "${DEPLOY_SSH_KEY:-}" ]] || fail "secrets.DEPLOY_SSH_KEY is required for DEPLOY_MODE=ssh"
  install -m 600 /dev/null "$WORK/id_deploy"; printf '%s\n' "$DEPLOY_SSH_KEY" > "$WORK/id_deploy"
  if [[ -n "${DEPLOY_SSH_KNOWN_HOSTS:-}" ]]; then
    printf '%s\n' "$DEPLOY_SSH_KNOWN_HOSTS" > "$WORK/known_hosts"
    SSH_OPTS+=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$WORK/known_hosts")
  else
    echo "::warning::vars.DEPLOY_SSH_KNOWN_HOSTS not set – accepting host keys on first use"
    SSH_OPTS+=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$WORK/known_hosts")
  fi
  SSH_OPTS+=(-i "$WORK/id_deploy")
  SSH_READY=1
}
is_local() { [[ "$MODE" == "local" || "$1" == "localhost" || "$1" == "127.0.0.1" ]]; }
host_run() {  # host, command...
  local h="$1"; shift
  if is_local "$h"; then sudo -n "$@"; else setup_ssh; ssh "${SSH_OPTS[@]}" "${DEPLOY_SSH_USER:-deploy}@$h" sudo -n "$@"; fi
}
host_copy() { # host, local dir, remote dir
  local h="$1" src="$2" dst="$3"
  if is_local "$h"; then echo "$src"; return; fi
  setup_ssh
  ssh "${SSH_OPTS[@]}" "${DEPLOY_SSH_USER:-deploy}@$h" "rm -rf '$dst' && mkdir -p '$dst'"
  scp "${SSH_OPTS[@]}" -q -r "$src/." "${DEPLOY_SSH_USER:-deploy}@$h:$dst/"
  echo "$dst"
}

# ------------------------------------------------------------------ post tasks
smoke() {
  [[ -n "${PUBLIC_URL:-}" ]] || { echo "::warning::vars.$C_PUBLIC_URL_VAR not set – public smoke test skipped"; return; }
  local url="${PUBLIC_URL%/}" path="$C_HEALTH_PATH"
  [[ "$C_PACKAGE" == "static" ]] && path="/"
  info "Smoke test $url$path"
  local hdr=(); [[ -n "${SMOKE_BEARER_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer $SMOKE_BEARER_TOKEN")
  for i in {1..20}; do
    code=$(curl -ks -o "$WORK/smoke.out" -w '%{http_code}' "${hdr[@]}" "$url$path" || true)
    [[ "$code" =~ ^2 ]] && { note "HTTP $code"; echo "| smoke | ✅ $url$path → $code |" >> "$SUMMARY"; return; }
    sleep 3
  done
  fail "Smoke test failed: $url$path returned $code"
}
contract_smoke() {
  [[ -n "${PUBLIC_URL:-}" && -n "$C_OPENAPI_PATH" ]] || { note "contract smoke skipped (no PUBLIC_URL/openapi_path)"; return; }
  info "Contract smoke: $PUBLIC_URL$C_OPENAPI_PATH"
  curl -kfsS "${PUBLIC_URL%/}$C_OPENAPI_PATH" -o "$WORK/live-openapi.json" || fail "OpenAPI document not reachable"
  if [[ -f "$PKG/openapi.json" ]]; then
    python3 - "$PKG/openapi.json" "$WORK/live-openapi.json" <<'PY' || exit 1
import json, sys
a, b = (set(json.load(open(p)).get("paths", {})) for p in sys.argv[1:3])
missing = a - b
if missing:
    print(f"::error::Deployed API is missing paths from the release contract: {sorted(missing)}"); sys.exit(1)
print(f"    contract ok: {len(b)} paths")
PY
  fi
  # dependency health (DB, queue, partner reachability) when the API exposes /health/ready
  code=$(curl -ks -o "$WORK/ready.json" -w '%{http_code}' "${PUBLIC_URL%/}/health/ready" || true)
  if [[ "$code" == "404" ]]; then note "/health/ready not exposed"; elif [[ "$code" =~ ^2 ]]; then note "dependencies healthy";
  else cat "$WORK/ready.json" || true; fail "Dependency health check failed (HTTP $code)"; fi
  echo "| contract | ✅ OpenAPI + dependencies |" >> "$SUMMARY"
}

{
  echo "### 🚀 $TARGET_ENV · $C_NAME · $VERSION"
  echo "| Step | Result |"; echo "|---|---|"
} >> "$SUMMARY"

# ================================================================== ROLLBACK
if [[ "$ACTION" == "rollback" ]]; then
  [[ -n "$HOSTS" ]] || fail "No hosts for role '$C_SERVER_ROLE' (vars.$role_var)"
  for h in $HOSTS; do
    info "Rollback $C_NAME on $h"
    host_run "$h" /usr/local/sbin/app-deploy rollback "$C_NAME"
    echo "| rollback $h | ✅ |" >> "$SUMMARY"
  done
  smoke
  echo "url=${PUBLIC_URL:-}" >> "$GITHUB_OUTPUT"
  exit 0
fi

# ================================================================== DEPLOY
FILE="$PACKAGE_DIR/$C_NAME-$VERSION.tar.gz"
[[ -f "$FILE" ]] || fail "Package not found: $FILE"
info "Verify package checksum"
(cd "$PACKAGE_DIR" && sha256sum -c "$C_NAME-$VERSION.tar.gz.sha256")
PKG="$WORK/pkg"; mkdir -p "$PKG"; tar -xzf "$FILE" -C "$PKG"

# ------------------------------------------------------------------ runner tasks (database)
for task in $C_RUNNER_TASKS; do
  case "$task" in
    db-backup)  ;;  # handled together with migrate/scripts so "on_migration" can see pending work
    db-migrate)
      [[ -d "$PKG/migrator" ]] || { note "no migrator in package – skipped"; continue; }
      db_require
      pending=$(ef_pending_count "$PKG/migrations.json")
      note "pending EF migrations: $pending"
      if [[ "$C_BACKUP" == "always" || ( "$C_BACKUP" == "on_migration" && "$pending" != "0" ) ]]; then
        db_backup "$VERSION"; echo "| db backup | ✅ $LAST_BACKUP |" >> "$SUMMARY"
      fi
      if [[ "$pending" != "0" || "$C_ALWAYS_RUN_MIGRATOR" == "true" ]]; then
        run_migrator "$PKG/migrator"; echo "| migrations | ✅ $pending applied |" >> "$SUMMARY"
      else
        echo "| migrations | ⏭️ none pending |" >> "$SUMMARY"
      fi ;;
    db-scripts)
      db_require
      pending=$(sql_pending "$PKG/sql")
      note "pending SQL scripts: ${pending:-none}"
      if [[ "$C_BACKUP" == "always" || ( "$C_BACKUP" == "on_migration" && -n "$pending" ) ]]; then
        db_backup "$VERSION"; echo "| db backup | ✅ $LAST_BACKUP |" >> "$SUMMARY"
      fi
      if [[ -n "$pending" ]]; then sql_apply "$PKG/sql" $pending; echo "| sql scripts | ✅ $(echo $pending | wc -w) applied |" >> "$SUMMARY"
      else echo "| sql scripts | ⏭️ none pending |" >> "$SUMMARY"; fi ;;
    *) fail "unknown runner task $task" ;;
  esac
done

# ------------------------------------------------------------------ host tasks (rolling, one host at a time)
if [[ -n "$C_HOST_TASKS" ]]; then
  [[ -n "$HOSTS" ]] || fail "No hosts for role '$C_SERVER_ROLE' – set environment variable $role_var"
  BUNDLE="$WORK/bundle"; mkdir -p "$BUNDLE/files"
  cp "$FILE" "$BUNDLE/package.tar.gz"
  [[ -n "${APP_ENV_FILE:-}" ]]        && printf '%s\n' "$APP_ENV_FILE" > "$BUNDLE/app.env"
  [[ -n "${APP_SETTINGS_JSON:-}" ]]   && printf '%s\n' "$APP_SETTINGS_JSON" > "$BUNDLE/appsettings.json"
  [[ -n "${RUNTIME_CONFIG_JSON:-}" ]] && printf '%s\n' "$RUNTIME_CONFIG_JSON" > "$BUNDLE/runtime-config.json"
  if [[ -n "${SHARED_FILES_JSON:-}" ]]; then   # {"openiddict.pfx":"<base64>", ...} -> shared/ on the host
    python3 - "$BUNDLE/files" <<'PY'
import base64, json, os, sys
for name, b64 in json.loads(os.environ["SHARED_FILES_JSON"]).items():
    assert "/" not in name, name
    open(os.path.join(sys.argv[1], name), "wb").write(base64.b64decode(b64))
PY
  fi
  chmod -R go-rwx "$BUNDLE"
  python3 - "$BUNDLE/manifest.json" <<PY
import json, os, sys
c = json.loads(os.environ["COMPONENT_JSON"]); p = json.load(open("$PKG/package.json"))
json.dump({
  "name": c["name"], "package": c["package"], "type": c["type"], "version": os.environ["VERSION"],
  "environment": os.environ["TARGET_ENV"], "runtime_env": "Production",
  "service_name": c["service_name"], "service_user": c["service_name"], "deploy_path": c["deploy_path"],
  "port": c["port"], "health_path": c["health_path"], "keep_releases": c["keep_releases"],
  "entry": p.get("entry", ""), "app_module": c.get("app_module", ""),
  "server_name": os.environ.get("SERVER_NAME", ""), "tls_cert": os.environ.get("TLS_CERT", ""),
  "tls_key": os.environ.get("TLS_KEY", ""),
}, open(sys.argv[1], "w"), indent=2)
PY
  for h in $HOSTS; do
    info "Install $C_NAME $VERSION on $h ($MODE)"
    remote_dir="/tmp/app-deploy-$C_NAME-$VERSION"
    dir=$(host_copy "$h" "$BUNDLE" "$remote_dir")
    if ! host_run "$h" /usr/local/sbin/app-deploy install "$dir"; then
      echo "| install $h | ❌ failed – rolled back on host |" >> "$SUMMARY"
      fail "Deployment failed on $h (host was rolled back automatically)"
    fi
    is_local "$h" || ssh "${SSH_OPTS[@]}" "${DEPLOY_SSH_USER:-deploy}@$h" "rm -rf '$remote_dir'" || true
    echo "| install $h | ✅ |" >> "$SUMMARY"
  done
fi

# ------------------------------------------------------------------ post tasks
for task in $C_POST_TASKS; do
  case "$task" in
    smoke)          smoke ;;
    contract-smoke) contract_smoke ;;
    db-verify)      db_require; sql_verify "$PKG/sql"; echo "| db verify | ✅ |" >> "$SUMMARY" ;;
    *) fail "unknown post task $task" ;;
  esac
done
echo "url=${PUBLIC_URL:-}" >> "$GITHUB_OUTPUT"
