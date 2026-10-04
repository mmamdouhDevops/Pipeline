#!/usr/bin/env bash
# Environment readiness check. Env: TARGET_ENV, DEPLOY_MODE, <ROLE>_HOSTS, DEPLOY_SSH_*, DB_SERVER, DB_ADMIN_*
set -uo pipefail
MODE="${DEPLOY_MODE:-ssh}"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/envcheck.XXXX")"; trap 'rm -rf "$WORK"' EXIT
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
FAILED=0
declare -A ROLES   # host -> comma list of roles

for role in web api integration db ai; do
  var="$(echo "$role" | tr '[:lower:]' '[:upper:]')_HOSTS"
  for h in $(echo "${!var:-}" | tr ',' ' '); do
    [[ "$MODE" == "local" || "$h" == "localhost" || "$h" == "127.0.0.1" ]] && h="localhost"
    ROLES[$h]="${ROLES[$h]:+${ROLES[$h]},}$role"
  done
done
# the runner always gets the ci checks (sqlcmd, toolchain, runner service)
ROLES[localhost]="ci${ROLES[localhost]:+,${ROLES[localhost]}}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
if [[ "$MODE" != "local" ]]; then
  if [[ -n "${DEPLOY_SSH_KEY:-}" ]]; then
    install -m 600 /dev/null "$WORK/id"; printf '%s\n' "$DEPLOY_SSH_KEY" > "$WORK/id"; SSH_OPTS+=(-i "$WORK/id")
  fi
  if [[ -n "${DEPLOY_SSH_KNOWN_HOSTS:-}" ]]; then
    printf '%s\n' "$DEPLOY_SSH_KNOWN_HOSTS" > "$WORK/kh"; SSH_OPTS+=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$WORK/kh")
  else
    SSH_OPTS+=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$WORK/kh")
  fi
fi

{
  echo "## 🩺 Environment check · \`$TARGET_ENV\` (mode: $MODE)"
  echo
  echo "| Server | Roles | Result |"
  echo "|---|---|---|"
} >> "$SUMMARY"

for h in "${!ROLES[@]}"; do
  roles="${ROLES[$h]}"
  echo "::group::$h ($roles)"
  if [[ "$h" == "localhost" ]]; then
    out=$(sudo -n /usr/local/sbin/app-deploy check "$roles" 2>&1); rc=$?
  else
    out=$(ssh "${SSH_OPTS[@]}" "${DEPLOY_SSH_USER:-deploy}@$h" sudo -n /usr/local/sbin/app-deploy check "$roles" 2>&1); rc=$?
  fi
  echo "$out"
  echo "::endgroup::"
  if [[ $rc -eq 0 ]]; then res="✅ $(grep -c '^OK' <<<"$out") ok, $(grep -c '^WARN' <<<"$out") warn"
  elif grep -q '^== result' <<<"$out"; then
    res="❌ $(grep '^FAIL' <<<"$out" | awk '{print $2}' | paste -sd, -)"; FAILED=1
  else
    res="❌ not reachable / app-deploy missing: $(tail -1 <<<"$out" | cut -c1-120)"; FAILED=1
  fi
  name="$h"; [[ "$h" == "localhost" ]] && name="runner $(hostname)"
  echo "| $name | $roles | $res |" >> "$SUMMARY"
  grep -E '^(FAIL|WARN)' <<<"$out" | sed 's/^/    /' >> "$WORK/details" || true
done

# ------------------------------------------------------------------ SQL Server login from the runner
if [[ -n "${DB_SERVER:-}" && -n "${DB_ADMIN_USER:-}" ]]; then
  SQLCMD=$(command -v sqlcmd || echo /opt/mssql-tools18/bin/sqlcmd)
  if v=$(SQLCMDPASSWORD="${DB_ADMIN_PASSWORD:-}" "$SQLCMD" -S "$DB_SERVER" -U "$DB_ADMIN_USER" -C -b -h -1 -W \
          -Q "SET NOCOUNT ON; SELECT CONCAT(SERVERPROPERTY('ProductVersion'),' ',SERVERPROPERTY('Edition'),' · ',(SELECT COUNT(*) FROM sys.databases WHERE database_id>4),' user DBs')" 2>&1); then
    echo "| SQL login \`$DB_SERVER\` | db | ✅ $(echo "$v" | head -1) |" >> "$SUMMARY"
  else
    echo "| SQL login \`$DB_SERVER\` | db | ❌ $(echo "$v" | tail -1 | cut -c1-120) |" >> "$SUMMARY"; FAILED=1
  fi
else
  echo "| SQL login | db | ⚠️ DB_SERVER / DB_ADMIN_USER not set – skipped |" >> "$SUMMARY"
fi

if [[ -s "$WORK/details" ]]; then
  { echo; echo "<details><summary>Failures and warnings</summary>"; echo; echo '```'; cat "$WORK/details"; echo '```'; echo "</details>"; } >> "$SUMMARY"
fi
[[ $FAILED -eq 0 ]] && echo "Environment $TARGET_ENV is ready." || { echo "::error::Environment $TARGET_ENV is NOT ready – see the summary"; exit 1; }
