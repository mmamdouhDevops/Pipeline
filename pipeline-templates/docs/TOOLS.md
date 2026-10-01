# Security tools setup

All three SAST tools run in parallel as the **first stage** of CI (after plan/policy). Each can be switched
off per repository (`enable_sonar|enable_checkmarx|enable_snyk|enable_gitleaks: false` in `ci.yml`).

## SonarQube Server
1. *Administration › Security › Users › Tokens* → token for a technical user (or *Global Analysis Token*).
2. Create one project per component; key = `sonar_project_key` (default `<repo>-<component>`).
3. Quality gate: the CI waits for it (`sonar.qualitygate.wait=true`) and fails the job when it is red.
4. PR decoration (Developer Edition+): set `sonar_pr_decoration: true` and bind the GitHub repo in SonarQube.
   Community Edition analyses the branch only.
5. Values: `vars.SONAR_HOST_URL`, `secrets.SONAR_TOKEN`.
.NET uses `dotnet-sonarscanner` (begin/build/test with OpenCover coverage/end); Angular/Python use the
SonarQube scan action with `lcov` / `coverage.xml`.

## Checkmarx One
1. *Settings › Identity and Access Management › OAuth Clients* → new client with role `ast-scanner`.
2. Values: `vars.CHECKMARX_BASE_URI` (region URL, e.g. `https://eu.ast.checkmarx.net`), `vars.CHECKMARX_TENANT`,
   `secrets.CHECKMARX_CLIENT_ID`, `secrets.CHECKMARX_CLIENT_SECRET`.
3. Scan types: `sast, sca, iac-security`; thresholds `sast-high=1; sca-high=1; iac-security-high=1`
   fail the job. Project name = repository name, branch = PR head.

## Snyk
1. Service account (*Org settings › Service accounts*) → token.
2. Values: `vars.SNYK_ORG`, `secrets.SNYK_TOKEN`.
3. CI runs `snyk code test`, `snyk test --all-projects` (dependencies) and `snyk iac test`, threshold `high`.
   Exit code 3 (no supported files) is ignored.

## gitleaks
Secret scanning of the PR commits with the latest gitleaks release; findings → job failure + SARIF artifact.
Allow-list false positives in `.gitleaks.toml` in the repository.

## OWASP ZAP (DAST, after the test deployment)
* `ghcr.io/zaproxy/zaproxy:stable` via Docker on the **test runner** (Docker group membership is set by
  `install-runner.sh`).
* `dast: web` → baseline scan of `URL__<SLUG>`; `dast: api` → API scan of `URL__<SLUG>` + `openapi_path`.
* Authenticated scans: an OpenIddict client-credentials client (`DAST_CLIENT_ID/SECRET`, `DAST_TOKEN_URL`,
  `DAST_SCOPE`) – the token is sent as `Authorization: Bearer`.
* Tune rules with `.zap/rules.tsv` in the application repo (`10038	IGNORE	(CSP header)` …).
* High risk findings fail the stage unless `vars.DAST_FAIL_ON_HIGH=false`. The HTML/JSON report is an artifact.

## Contract and migration checks
* **oasdiff** compares the build-time OpenAPI document of the PR with the base branch; breaking changes need
  the `breaking-change` label.
* **EF guard** scans new migrations for `DropTable`, `DropColumn`, `RenameColumn`, `RenameTable`, `AlterColumn`
  narrowing …; needs the `destructive-migration` label.

## Supply-chain hardening (recommended once things work)
* Pin third-party actions to commit SHAs, e.g.
  `uses: actions/checkout@<40-char sha> # v4.2.2`; Dependabot (`.github/dependabot.yml`, ecosystem
  `github-actions`) keeps them updated.
* Keep `ATTEST_BUILDS=true` where available and verify with `gh attestation verify <file> -R <repo>`.
* SBOMs (CycloneDX) are attached to every GitHub Release.
