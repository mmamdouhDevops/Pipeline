#!/usr/bin/env bash
# Builds the release package for one component. Inputs: COMPONENT_JSON, VERSION.
set -euo pipefail
eval "$(python3 - <<'PY'
import json, os, shlex
c = json.loads(os.environ["COMPONENT_JSON"])
for k, v in c.items():
    if isinstance(v, (list, dict)): v = json.dumps(v)
    elif isinstance(v, bool): v = "true" if v else "false"
    print(f"C_{k.upper()}={shlex.quote(str(v))}")
PY
)"
export PATH="$PATH:$HOME/.dotnet/tools"
ROOT="$GITHUB_WORKSPACE"
STAGE="$RUNNER_TEMP/stage-$C_NAME"
DIST="$ROOT/dist"
rm -rf "$STAGE" && mkdir -p "$STAGE" "$DIST"
cd "$ROOT/$C_PATH"
entry=""

case "$C_PACKAGE" in
  dotnet)
    [[ -n "$C_PUBLISH_PROJECT" ]] || { echo "::error::publish_project is required for $C_NAME"; exit 1; }
    if [[ "$C_ABP_INSTALL_LIBS" == "true" ]]; then
      dotnet tool update -g Volo.Abp.Studio.Cli >/dev/null 2>&1 || dotnet tool install -g Volo.Abp.Studio.Cli
      abp install-libs
    fi
    dotnet publish "$C_PUBLISH_PROJECT" -c Release -o "$STAGE/app" -p:PublishReadyToRun=false
    rm -f "$STAGE"/app/appsettings.secrets.json "$STAGE"/app/appsettings.Development.json
    entry="$(basename "${C_PUBLISH_PROJECT%.csproj}").dll"
    if [[ "$C_OWNS_DATABASE" == "true" && -n "$C_MIGRATOR_PROJECT" ]]; then
      dotnet publish "$C_MIGRATOR_PROJECT" -c Release -o "$STAGE/migrator"
      rm -f "$STAGE"/migrator/appsettings.secrets.json "$STAGE"/migrator/appsettings.Development.json
      echo "$(basename "${C_MIGRATOR_PROJECT%.csproj}").dll" > "$STAGE/migrator/.entry"
    fi
    if [[ "$C_OWNS_DATABASE" == "true" && -n "$C_EF_PROJECT" ]]; then
      dotnet tool update -g dotnet-ef >/dev/null 2>&1 || dotnet tool install -g dotnet-ef
      # list of migration ids -> lets the deploy step skip the migrator when nothing is pending
      dotnet ef migrations list --project "$C_EF_PROJECT" --no-connect --json --prefix-output \
        | sed -n 's/^data:\s*//p' > "$STAGE/migrations.json" || true
      python3 -c "import json;json.load(open('$STAGE/migrations.json'))" 2>/dev/null || \
        dotnet ef migrations list --project "$C_EF_PROJECT" --no-connect --json > "$STAGE/migrations.json"
      dotnet ef migrations script --idempotent --project "$C_EF_PROJECT" -o "$STAGE/migrations.sql"
    fi
    [[ -n "$C_OPENAPI_FILE" && -f "$C_OPENAPI_FILE" ]] && cp "$C_OPENAPI_FILE" "$STAGE/openapi.json"
    ;;
  static)
    npm ci || npm ci --legacy-peer-deps
    if [[ -n "$C_BUILD_COMMAND" ]]; then eval "$C_BUILD_COMMAND"; else npx ng build --configuration production; fi
    out="${C_ANGULAR_DIST:-}"
    [[ -z "$out" ]] && out="$(dirname "$(find dist -name index.html -not -path '*/server/*' | head -1)")"
    [[ -f "$out/index.html" ]] || { echo "::error::No index.html found in build output ($out)"; exit 1; }
    mkdir -p "$STAGE/app" && cp -a "$out/." "$STAGE/app/"
    entry="index.html"
    ;;
  python)
    mkdir -p "$STAGE/app" "$STAGE/wheels"
    git archive HEAD | tar -x -C "$STAGE/app"
    pip wheel -q -r "$C_REQUIREMENTS" -w "$STAGE/wheels"
    entry="$C_APP_MODULE"
    ;;
  sql)
    mkdir -p "$STAGE/sql" && cp -a "$C_SQL_DIR/." "$STAGE/sql/"
    entry="sql"
    ;;
  *) echo "::error::unknown package type $C_PACKAGE"; exit 1 ;;
esac

python3 - "$STAGE/package.json" <<PY
import json, os, sys, datetime
c = json.loads(os.environ["COMPONENT_JSON"])
json.dump({
  "name": c["name"], "type": c["type"], "version": os.environ["VERSION"], "entry": "$entry",
  "commit": os.environ.get("GITHUB_SHA"), "ref": os.environ.get("GITHUB_REF_NAME"),
  "run": f'{os.environ.get("GITHUB_SERVER_URL")}/{os.environ.get("GITHUB_REPOSITORY")}/actions/runs/{os.environ.get("GITHUB_RUN_ID")}',
  "built_at": datetime.datetime.utcnow().isoformat() + "Z",
}, open(sys.argv[1], "w"), indent=2)
PY

FILE="$DIST/$C_NAME-$VERSION.tar.gz"
tar -czf "$FILE" -C "$STAGE" .
(cd "$DIST" && sha256sum "$(basename "$FILE")" > "$(basename "$FILE").sha256")
echo "staging_dir=$STAGE" >> "$GITHUB_OUTPUT"
echo "file=$FILE" >> "$GITHUB_OUTPUT"
echo "### 📦 $C_NAME $VERSION – $(du -h "$FILE" | cut -f1)" >> "$GITHUB_STEP_SUMMARY"
