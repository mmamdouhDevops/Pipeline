#!/usr/bin/env bash
set -euo pipefail
NAME=$(python3 -c 'import json,os;print(json.loads(os.environ["COMPONENT_JSON"])["name"])')
KIND=$(python3 -c 'import json,os;print(json.loads(os.environ["COMPONENT_JSON"])["dast"])')
OPENAPI=$(python3 -c 'import json,os;print(json.loads(os.environ["COMPONENT_JSON"]).get("openapi_path",""))')
[[ -n "$TARGET" ]] || { echo "::warning::No public URL for $NAME – DAST skipped"; exit 0; }
command -v docker >/dev/null || { echo "::error::Docker is required on the DAST runner (scripts/prepare-server-ubuntu2404.sh --roles ci)"; exit 1; }
OUT="$RUNNER_TEMP/zap-$NAME"; mkdir -p "$OUT"; chmod 777 "$OUT"
TARGET="${TARGET%/}"

auth=()
if [[ -n "${DAST_TOKEN_URL:-}" && -n "${DAST_CLIENT_ID:-}" ]]; then
  token=$(curl -ksf -X POST "$DAST_TOKEN_URL" -d grant_type=client_credentials \
      -d client_id="$DAST_CLIENT_ID" -d client_secret="$DAST_CLIENT_SECRET" -d scope="${DAST_SCOPE:-}" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])') || { echo "::error::Could not obtain DAST token"; exit 1; }
  echo "::add-mask::$token"
  # ZAP adds this header to every request it sends (authenticated scan)
  auth=(-e "ZAP_AUTH_HEADER_VALUE=Bearer $token" -e "ZAP_AUTH_HEADER=Authorization")
fi

hosts=()
for h in $(echo "${DAST_EXTRA_HOSTS:-}" | tr ',' ' '); do hosts+=(--add-host "$h"); done
rules=(); [[ -f .zap/rules.tsv ]] && { cp .zap/rules.tsv "$OUT/rules.tsv"; rules=(-c rules.tsv); }

case "$KIND" in
  web) script=(zap-baseline.py -t "$TARGET") ;;
  api) [[ -n "$OPENAPI" ]] || { echo "::warning::$NAME has no openapi_path – using baseline scan"; script=(zap-baseline.py -t "$TARGET"); }
       [[ -n "$OPENAPI" ]] && script=(zap-api-scan.py -t "$TARGET$OPENAPI" -f openapi) ;;
  *) echo "DAST disabled for $NAME"; exit 0 ;;
esac

echo "Running ${script[0]} against $TARGET"
set +e
docker run --rm --network host "${hosts[@]}" "${auth[@]}" -v "$OUT:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:stable \
  "${script[@]}" -r report.html -J report.json -w report.md -I "${rules[@]}"
rc=$?
set -e
[[ $rc -ge 3 ]] && { echo "::error::ZAP failed to run (exit $rc)"; exit 1; }

high=$(python3 - "$OUT/report.json" <<'PY'
import json, sys
try: r = json.load(open(sys.argv[1]))
except Exception: print(0); sys.exit()
print(sum(1 for s in r.get("site", []) for a in s.get("alerts", []) if a.get("riskcode") == "3"))
PY
)
{ echo "### 🛡️ DAST · $NAME: $high high-risk alert(s)"; [[ -f "$OUT/report.md" ]] && head -60 "$OUT/report.md"; } >> "$GITHUB_STEP_SUMMARY"
if [[ "$high" != "0" && "$FAIL_ON_HIGH" == "true" ]]; then
  echo "::error::DAST found $high High-risk alert(s) – see the dast-$NAME artifact"; exit 1
fi
