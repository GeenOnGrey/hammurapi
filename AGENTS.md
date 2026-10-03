# AGENTS.md — hammurapi

Guide for coding agents and developers working in this repository.

## Workspace

Hammurapi is five repositories checked out side by side: `hammurapi-core` (Go backend),
`hammurapi-web` (SPA), `hammurapi` (this one: public docs, demo stack, self-hosted chart, installer,
the reusable deploy workflow), `hammurapi-infra` (private stand and charts) and `hammurapi-specs`
(the specifications).

- Features are specified in `hammurapi-specs/specs/HMR/<GROUP>/FTR.HMR.<GROUP>-NNNN/`. Refer to them
  as `FTR.HMR.CMN-0004`, `FTR.HMR.INFRA-0002` (old `PLT.HMR-…`, `PLT.INFRA-…`, bare `HMR.CMN-…` are
  obsolete). Deviations are written into the spec.
- Do not commit, tag or push unless asked.

## Contents

```text
docs/                    user and operator docs (English): configuration, agent, cycle, deployment, …
docker-compose.yml       local stack; builds ../hammurapi-core and ../hammurapi-web
helm/hammurapi/          self-hosted chart (not the stand: the stand uses hammurapi-infra charts)
install/                 installer (install.sh, install.ps1)
rules/                   default rules of a specification repository (seed of the demo) — keep it
scripts/e2e-smoke.sh     end-to-end smoke test of the whole cycle on the demo stack
.github/workflows/deploy-component.yml   reusable deploy workflow used by core and web releases
```

Every product change that adds a setting, a service or behaviour visible to operators updates
`docs/` (configuration.md lists every environment variable).

## Demo stack and the smoke test

```sh
install/install.sh --demo                        # writes .env (secrets, AGENT_SERVICE_TOKEN, demo values) and starts
docker compose --profile demo up -d --build      # later starts; + fakegitlab and fakellm
scripts/e2e-smoke.sh                             # ~110 checks, needs a fresh stack
docker compose --profile demo down -v            # before a rerun: the script creates data
```

- Wait until `http://localhost:8080/api/v1/config` answers before running the script (otherwise
  curl exits with 52).
- The real agent runs: Pi in the `agent` service talks to `fakellm`
  (`BOOTSTRAP_DEEPSEEK_BASE_URL=http://fakellm:8099`).
- Helpers: `call <user> <method> <path> [json]`, `field <user> <method> <path> <python expr over d>`,
  `expect <status> <description>`, `wait_for <description> <command…>` (90 s). `json` strips CR:
  Python on Windows prints CRLF.
- `fakegitlab` has `/fake/*` endpoints for the script (deploy target, Prometheus, `/fake/push` —
  a commit straight to a branch with a push webhook).

## Reusable deploy workflow

`deploy-component.yml` is called by `hammurapi-core` and `hammurapi-web` releases through
`DEPLOY_WORKFLOW_REF` (a tag of this repository). Rules:

- Configuration and secrets reach the stand as one JSON on the stdin of SSH, built by `jq` from
  `$ENV` — never in arguments or files.
- The runner has jq 1.7: in object literals wrap computed values in parentheses
  (`secrets: ({…} + (if … end))`). `checks.yml` compiles the payload; keep that check passing.
- After a change: tag this repository, then bump `DEPLOY_WORKFLOW_REF` in core and web
  (`deploy/sync-ref.sh`). The infra unit tests run the config step of this workflow from `main`.
- The workflow, compose file and chart are YAML: edit them by hand; do not run generic formatters.

`actionlint` (`checks.yml`) must pass; use pinned action SHAs.
