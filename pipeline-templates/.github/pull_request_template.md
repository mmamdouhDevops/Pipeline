## What & why
<!-- one paragraph; link the work item -->

## Type
- [ ] feature  - [ ] fix / hotfix  - [ ] release  - [ ] chore / docs

## Checklist
- [ ] Branch follows Git Flow (`feature/*`, `hotfix/*` → `develop`; `release/*`, `hotfix/*` → `main`)
- [ ] Tests added/updated, CI green (SAST: SonarQube, Checkmarx One, Snyk)
- [ ] Database: migration/scripts are additive – or label `destructive-migration` added with a rollback note
- [ ] API: no breaking OpenAPI change – or label `breaking-change` added and consumers informed
- [ ] New config/secrets documented (`APP_SETTINGS__*`, `APP_ENV__*` …)

## Deployment notes
<!-- migrations, feature flags, manual steps, rollback plan -->
