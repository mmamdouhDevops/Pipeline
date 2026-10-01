#!/usr/bin/env python3
"""Builds the component matrix for the CI/CD templates. See docs/PIPELINE-YML.md for the schema."""
import fnmatch, json, os, re, subprocess, sys
import yaml

env = os.environ.get
config_path = env("PLAN_CONFIG", "pipeline.yml")
mode = env("PLAN_MODE", "ci")
types_dir = env("PLAN_TYPES_DIR")
only = [c.strip() for c in env("PLAN_ONLY", "").split(",") if c.strip()]
out_file = env("GITHUB_OUTPUT")


def fail(msg):
    print(f"::error title=plan::{msg}")
    sys.exit(1)


def out(key, value):
    if not isinstance(value, str):
        value = json.dumps(value, separators=(",", ":"))
    with open(out_file, "a") as f:
        f.write(f"{key}={value}\n")


if not os.path.exists(config_path):
    fail(f"{config_path} not found in the repository root")
cfg = yaml.safe_load(open(config_path)) or {}
components = cfg.get("components") or []
if not components:
    fail("pipeline.yml has no 'components'")
defaults = cfg.get("defaults") or {}

slug = lambda s: re.sub(r"[^A-Z0-9]+", "_", s.upper()).strip("_")
types = {}
for f in os.listdir(types_dir):
    if f.endswith(".yml"):
        t = yaml.safe_load(open(os.path.join(types_dir, f)))
        types[t["type"]] = t

matrix = []
for raw in components:
    c = {**defaults, **raw}
    if "name" not in c or "type" not in c:
        fail(f"every component needs 'name' and 'type': {raw}")
    t = types.get(c["type"])
    if not t:
        fail(f"unknown type '{c['type']}' for component '{c['name']}'. Known: {', '.join(sorted(types))}")
    name = c["name"]
    owns_db = bool(c.get("owns_database", False)) or c["type"] == "database"
    item = {
        # identity
        "name": name,
        "slug": slug(name),
        "type": c["type"],
        "path": c.get("path", "."),
        # build
        "solution": c.get("solution", ""),
        "publish_project": c.get("publish_project", ""),
        "migrator_project": c.get("migrator_project", ""),
        "ef_project": c.get("ef_project", ""),
        "test_projects": c.get("test_projects", "**/*Tests.csproj"),
        "angular_dist": c.get("angular_dist", ""),
        "requirements": c.get("requirements", "requirements.txt"),
        "app_module": c.get("app_module", "app.main:app"),
        "sql_dir": c.get("sql_dir", "sql/migrations"),
        "abp_install_libs": bool(c.get("abp_install_libs", False)),
        "openapi_file": c.get("openapi_file", ""),
        "build_command": c.get("build_command", ""),
        "test_command": c.get("test_command", ""),
        "dotnet_version": str(c.get("dotnet_version", "10.0.x")),
        "node_version": str(c.get("node_version", "24")),
        "python_version": str(c.get("python_version", "3.12")),
        "sonar_project_key": c.get("sonar_project_key", f"{env('PLAN_REPO','repo')}-{name}"),
        # database
        "owns_database": owns_db,
        "db_name_var": c.get("db_name_var", f"DB_NAME__{slug(name)}"),
        "backup": c.get("backup", "always" if owns_db else "never"),
        "always_run_migrator": bool(c.get("always_run_migrator", False)),
        # runtime / deploy
        "server_role": c.get("server_role", t.get("default_role", "api")),
        "service_name": c.get("service_name", name),
        "deploy_path": c.get("deploy_path", f"/var/www/{name}"),
        "port": int(c.get("port", 5000)),
        "health_path": c.get("health_path", "/health"),
        "openapi_path": c.get("openapi_path", ""),
        "public_url_var": c.get("public_url_var", f"URL__{slug(name)}"),
        "server_name_var": c.get("server_name_var", f"SERVER_NAME__{slug(name)}"),
        "keep_releases": int(c.get("keep_releases", 5)),
        # type definition (flattened)
        "toolchain": t.get("toolchain", []),
        "ci_build": t["ci"]["build"],
        "ci_sonar": t["ci"]["sonar"],
        "ci_snyk": t["ci"]["snyk"],
        "ci_checks": t["ci"].get("checks", []),
        "ci_contract": bool(t["ci"].get("contract", False)) and bool(c.get("openapi_file")),
        "package": t["package"],
        "runner_tasks": t["cd"].get("runner_tasks", []),
        "host_tasks": t["cd"].get("host_tasks", []),
        "post_tasks": t["cd"].get("post_tasks", []),
        "dast": c.get("dast", t.get("dast", "none")),
    }
    if not item["owns_database"]:
        item["runner_tasks"] = [x for x in item["runner_tasks"] if not x.startswith("db-")]
        item["ci_checks"] = [x for x in item["ci_checks"] if x != "ef-migrations"]
    matrix.append(item)

if only:
    unknown = set(only) - {m["name"] for m in matrix}
    if unknown:
        fail(f"unknown component(s): {', '.join(unknown)}")
    matrix = [m for m in matrix if m["name"] in only]

# ---------------------------------------------------------------- CI: keep changed components only
if mode == "ci" and env("PLAN_BASE"):
    base = env("PLAN_BASE")
    try:
        subprocess.run(["git", "fetch", "--no-tags", "--depth=200", "origin", base], check=True,
                       capture_output=True)
        changed = subprocess.run(["git", "diff", "--name-only", f"origin/{base}...HEAD"], check=True,
                                 capture_output=True, text=True).stdout.split()
    except subprocess.CalledProcessError:
        changed = None  # can't tell -> run everything
    if changed is not None:
        shared = [config_path, ".github/*"]
        global_change = any(any(fnmatch.fnmatch(f, p) or f.startswith(p.rstrip("*")) for p in shared) for f in changed)
        if not global_change:
            def touched(m):
                p = m["path"].strip("./")
                return p == "" or any(f.startswith(p + "/") for f in changed)
            kept = [m for m in matrix if touched(m)]
            print(f"Changed files: {len(changed)}; components affected: {[m['name'] for m in kept]}")
            matrix = kept

# ---------------------------------------------------------------- CD: branch guard + version
version = semver = channel = ""
if mode == "cd":
    ref = env("PLAN_REF_NAME", "")
    m = re.fullmatch(r"(release|hotfix)/v?(\d+\.\d+\.\d+)", ref)
    if not m:
        fail(f"CD only runs from release/X.Y.Z or hotfix/X.Y.Z branches (got '{ref}')")
    channel, semver = m.group(1), m.group(2)
    version = f"{semver}-b{env('PLAN_RUN_NUMBER', '0')}"

# ---------------------------------------------------------------- per-job matrices
# A GitHub matrix can't be filtered at job level, so the plan emits one matrix per job.
job_filters = {
    "build":    lambda m: True,
    "sonar":    lambda m: m["ci_sonar"] != "none",
    "snyk":     lambda m: m["ci_snyk"] != "none",
    "dbcheck":  lambda m: any(x in m["ci_checks"] for x in ("ef-migrations", "sql-lint")),
    "contract": lambda m: m["ci_contract"],
    "dast":     lambda m: m["dast"] != "none",
}
for key, keep in job_filters.items():
    sub = [m for m in matrix if keep(m)]
    out(f"matrix_{key}", {"include": sub})
    out(f"count_{key}", str(len(sub)))

names = [m["name"] for m in matrix]
print(json.dumps(matrix, indent=2))
out("matrix", {"include": matrix})
out("count", str(len(matrix)))
out("names", names)
out("any_dotnet", str(any(m["ci_build"] == "dotnet" for m in matrix)).lower())
out("any_node", str(any("node" in m["toolchain"] for m in matrix)).lower())
out("any_db", str(any(m["owns_database"] for m in matrix)).lower())
out("any_contract", str(any(m["ci_contract"] for m in matrix)).lower())
out("any_dast", str(any(m["dast"] != "none" for m in matrix)).lower())
out("version", version)
out("semver", semver)
out("channel", channel)
