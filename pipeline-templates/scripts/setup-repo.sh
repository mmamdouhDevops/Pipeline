#!/usr/bin/env bash
# =============================================================================================
#  setup-repo.sh – one-time governance setup of a CONSUMER repository (needs the GitHub CLI `gh`,
#  logged in as a repo admin:  gh auth login -s repo,workflow,admin:org).
#
#    scripts/setup-repo.sh --repo mmamdouhDevops/TaskManager-backend \
#        --approvers-test alice \
#        --approvers-staging alice,bob \
#        --approvers-production carol,dave \
#        [--config pipeline.yml] [--templates-repo mmamdouhDevops/pipeline-templates] [--dry-run]
#
#  What it does (idempotent – safe to re-run):
#    1. develop branch (created from main if missing) + default branch = develop
#    2. rulesets from ./rulesets/*.json (create or update by name): 2 approvals, CI / Summary required
#    3. labels: destructive-migration, breaking-change
#    4. environments test / staging / production: required reviewers, wait timer, only release/* + hotfix/*
#       → if GitHub refuses reviewers (plan limit) the script switches APPROVAL_MODE=issue
#    5. repository variables (runners, approval mode, approvers) + test-environment defaults (local VM)
#    6. prints the checklist of secrets/variables per component of pipeline.yml
#  --templates-repo additionally allows other repos of the owner to call the private templates repo.
# =============================================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO=""; CONFIG=""; TEMPLATES_REPO=""; DRY=0
APPR_TEST=""; APPR_STAGING=""; APPR_PROD=""
RUNNER_CI='["self-hosted","linux","ci"]'
WAIT_PROD=5

usage() { sed -n '2,22p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --templates-repo) TEMPLATES_REPO="$2"; shift 2 ;;
    --approvers-test) APPR_TEST="$2"; shift 2 ;;
    --approvers-staging) APPR_STAGING="$2"; shift 2 ;;
    --approvers-production) APPR_PROD="$2"; shift 2 ;;
    --runner-ci) RUNNER_CI="$2"; shift 2 ;;
    --wait-production) WAIT_PROD="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option $1"; usage ;;
  esac
done
[[ -n "$REPO" ]] || usage
command -v gh >/dev/null || { echo "Install the GitHub CLI: https://cli.github.com"; exit 1; }
command -v jq >/dev/null || { echo "Install jq"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run: gh auth login -s repo,workflow"; exit 1; }

step() { echo; echo "==> $*"; }
ok()   { echo "    ✔ $*"; }
warn() { echo "    ⚠ $*"; }
run()  { if [[ $DRY -eq 1 ]]; then echo "    [dry-run] $*"; else "$@"; fi; }
api()  { gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

OWNER="${REPO%%/*}"
INFO=$(api "repos/$REPO")
VISIBILITY=$(jq -r .visibility <<<"$INFO")
DEFAULT=$(jq -r .default_branch <<<"$INFO")
echo "Repository $REPO ($VISIBILITY, default branch: $DEFAULT)"

# --------------------------------------------------------------------- 0. templates repo access
if [[ -n "$TEMPLATES_REPO" ]]; then
  step "Allow workflows of $OWNER to use $TEMPLATES_REPO"
  tvis=$(api "repos/$TEMPLATES_REPO" -q .visibility)
  if [[ "$tvis" == "public" ]]; then ok "templates repo is public – nothing to do"
  else
    owner_type=$(api "users/$OWNER" -q .type)
    level=$([[ "$owner_type" == "Organization" ]] && echo organization || echo user)
    run api -X PUT "repos/$TEMPLATES_REPO/actions/permissions/access" -f access_level="$level" >/dev/null \
      && ok "access_level=$level" || warn "could not set access – Settings › Actions › General › Access"
  fi
fi

# --------------------------------------------------------------------- 1. branches
step "Git Flow branches"
main_sha=$(api "repos/$REPO/git/ref/heads/main" -q .object.sha 2>/dev/null || true)
[[ -n "$main_sha" ]] || main_sha=$(api "repos/$REPO/git/ref/heads/$DEFAULT" -q .object.sha)
if api "repos/$REPO/git/ref/heads/develop" >/dev/null 2>&1; then ok "develop exists"
else run api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/develop -f sha="$main_sha" >/dev/null && ok "develop created"; fi
if [[ "$DEFAULT" != "develop" ]]; then
  run api -X PATCH "repos/$REPO" -f default_branch=develop >/dev/null && ok "default branch → develop"
fi
run api -X PATCH "repos/$REPO" -F delete_branch_on_merge=false -F allow_auto_merge=false \
  -F allow_merge_commit=true -F allow_squash_merge=true -F allow_rebase_merge=false >/dev/null && ok "merge settings"

# --------------------------------------------------------------------- 2. rulesets
step "Rulesets (2 approvals + required check 'CI / Summary')"
RULESETS_OK=1
existing=$(api "repos/$REPO/rulesets" --paginate 2>/dev/null || echo "[]")
for f in "$HERE"/rulesets/*.json; do
  name=$(jq -r .name "$f")
  id=$(jq -r --arg n "$name" '.[] | select(.name==$n) | .id' <<<"$existing" | head -1)
  if [[ -n "$id" ]]; then
    out=$(run api -X PUT "repos/$REPO/rulesets/$id" --input "$f" 2>&1) && ok "updated $name" || { warn "$name: $out"; RULESETS_OK=0; }
  else
    out=$(run api -X POST "repos/$REPO/rulesets" --input "$f" 2>&1) && ok "created $name" || { warn "$name: $out"; RULESETS_OK=0; }
  fi
done
if [[ $RULESETS_OK -eq 0 ]]; then
  warn "Rulesets on PRIVATE repos need GitHub Pro / Team / Enterprise."
  warn "Options: make the repo public, upgrade the plan, or rely on CI / Summary + CODEOWNERS review discipline."
fi

# --------------------------------------------------------------------- 3. labels
step "Labels"
run gh label create destructive-migration -R "$REPO" --color B60205 --force \
  --description "Approves a migration that drops/renames columns or tables" >/dev/null && ok destructive-migration
run gh label create breaking-change -R "$REPO" --color D93F0B --force \
  --description "Approves a breaking OpenAPI contract change" >/dev/null && ok breaking-change

# --------------------------------------------------------------------- 4. environments
user_ids() {   # "alice,bob" → JSON reviewers array
  local out="[]" u id
  IFS=',' read -ra arr <<<"$1"
  for u in "${arr[@]}"; do
    u="${u// /}"; [[ -z "$u" ]] && continue
    id=$(api "users/$u" -q .id 2>/dev/null) || { warn "unknown GitHub user $u"; continue; }
    out=$(jq --argjson id "$id" '. + [{"type":"User","id":$id}]' <<<"$out")
  done
  echo "$out"
}

APPROVAL_MODE=environment
setup_env() {
  local env="$1" approvers="$2" wait="$3"
  local reviewers body
  reviewers=$(user_ids "$approvers")
  body=$(jq -n --argjson r "$reviewers" --argjson w "$wait" '{
      wait_timer: $w, prevent_self_review: true, reviewers: $r,
      deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}')
  if [[ $DRY -eq 1 ]]; then echo "    [dry-run] PUT environments/$env $body"; return; fi
  if ! api -X PUT "repos/$REPO/environments/$env" --input - <<<"$body" >/dev/null 2>&1; then
    warn "$env: reviewers/wait timer refused (plan limit for private repos) – creating without them"
    APPROVAL_MODE=issue
    jq -n '{deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}' \
      | api -X PUT "repos/$REPO/environments/$env" --input - >/dev/null 2>&1 \
      || api -X PUT "repos/$REPO/environments/$env" >/dev/null
  fi
  local have; have=$(api "repos/$REPO/environments/$env/deployment-branch-policies" -q '.branch_policies[].name' 2>/dev/null || true)
  for p in 'release/*' 'hotfix/*'; do
    grep -qxF "$p" <<<"$have" || api -X POST "repos/$REPO/environments/$env/deployment-branch-policies" \
      -f name="$p" -f type=branch >/dev/null 2>&1 || warn "$env: branch policy $p not set"
  done
  ok "$env (approvers: ${approvers:-none}, wait ${wait} min, branches release/* hotfix/*)"
}
step "Environments"
setup_env test       "$APPR_TEST"    0
setup_env staging    "$APPR_STAGING" 0
setup_env production "$APPR_PROD"    "$WAIT_PROD"
[[ "$APPROVAL_MODE" == "issue" ]] && warn "APPROVAL_MODE=issue → approvals happen in an auto-created issue (comment 'approve')"

# --------------------------------------------------------------------- 5. variables
step "Repository variables"
setvar() { run gh variable set "$1" -R "$REPO" --body "$2" >/dev/null && ok "$1=$2"; }
setenvvar() { run gh variable set "$2" -R "$REPO" --env "$1" --body "$3" >/dev/null && ok "[$1] $2=$3"; }
setvar APPROVAL_MODE "$APPROVAL_MODE"
setvar PRODUCTION_ENABLED "${PRODUCTION_ENABLED:-false}"   # CD stops after staging until production is decided
setvar RUNNER_CI "$RUNNER_CI"
setvar RUNNER_DEPLOY_TEST '["self-hosted","linux","env-test"]'
setvar RUNNER_DEPLOY_STAGING '["self-hosted","linux","env-staging"]'
setvar RUNNER_DEPLOY_PRODUCTION '["self-hosted","linux","env-production"]'
[[ -n "$APPR_TEST" ]]    && setvar APPROVERS_TEST "$APPR_TEST"
[[ -n "$APPR_STAGING" ]] && setvar APPROVERS_STAGING "$APPR_STAGING"
[[ -n "$APPR_PROD" ]]    && setvar APPROVERS_PRODUCTION "$APPR_PROD"

step "Test environment defaults (single VM: runner + all roles on the same machine)"
for v in WEB_HOSTS API_HOSTS INTEGRATION_HOSTS DB_HOSTS AI_HOSTS; do setenvvar test "$v" localhost; done
setenvvar test DEPLOY_MODE local
setenvvar test DB_SERVER "localhost,1433"
setenvvar test DB_BACKUP_DIR /var/opt/mssql/backup
setenvvar test DB_BACKUP_KEEP 5

# --------------------------------------------------------------------- 6. checklist
step "Checklist – values only you can provide"
cfg_src=""
if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then cfg_src=$(cat "$CONFIG")
else cfg_src=$(gh api "repos/$REPO/contents/${CONFIG:-pipeline.yml}?ref=develop" -q .content 2>/dev/null | base64 -d 2>/dev/null || true); fi
cat <<'EOF'
  Organization or repository level (shared by every component):
    secrets  SONAR_TOKEN  CHECKMARX_CLIENT_ID  CHECKMARX_CLIENT_SECRET  SNYK_TOKEN
    vars     SONAR_HOST_URL  CHECKMARX_BASE_URI  CHECKMARX_TENANT  SNYK_ORG  [UPLOAD_SARIF=true]  [ATTEST_BUILDS=true]
  Per environment (test / staging / production):
    vars     DEPLOY_MODE (local|ssh)  WEB_HOSTS  API_HOSTS  INTEGRATION_HOSTS  DB_HOSTS  AI_HOSTS
             DEPLOY_SSH_USER  DEPLOY_SSH_KNOWN_HOSTS  DB_SERVER  DB_BACKUP_DIR  DB_BACKUP_KEEP
             [TLS_CERT  TLS_KEY]  [DAST_TOKEN_URL  DAST_SCOPE  DAST_EXTRA_HOSTS  DAST_FAIL_ON_HIGH]  (test only for DAST)
    secrets  DEPLOY_SSH_KEY (ssh mode)  DB_ADMIN_USER  DB_ADMIN_PASSWORD  [DAST_CLIENT_ID  DAST_CLIENT_SECRET]
EOF
if [[ -n "$cfg_src" ]] && command -v python3 >/dev/null; then
  echo "  Per component (from pipeline.yml):"
  python3 - "$cfg_src" <<'PY' || warn "could not parse pipeline.yml (pip install pyyaml)"
import sys, re, yaml
cfg = yaml.safe_load(sys.argv[1]) or {}
for c in cfg.get("components", []):
    slug = re.sub(r"[^A-Z0-9]+", "_", c["name"].upper()).strip("_")
    t = c.get("type", "")
    print(f"    · {c['name']}  ({t})")
    print(f"        vars     URL__{slug}  SERVER_NAME__{slug}  [APP_SETTINGS__{slug}]  [RUNTIME_CONFIG__{slug}]")
    print(f"        secrets  [APP_ENV__{slug}]  [FILES__{slug}]  [SMOKE_TOKEN__{slug}]")
    if c.get("owns_database") or t == "database":
        print(f"        vars     DB_NAME__{slug}  [MIGRATOR_SETTINGS__{slug}]")
        print(f"        secrets  DB_CONNECTION__{slug}")
PY
else
  echo "  (commit pipeline.yml to develop or pass --config to list per-component values)"
fi
echo
echo "Done. Details: docs/ROLLOUT.md and docs/SECRETS.md"
