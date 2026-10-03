# Development cycle: setup and integrations

Hammurapi runs a feature from an issue to a confirmed release (HMR.CMN-0002):

```text
Discovery     issue (idea | problem) → Analysis by the agent → accepted
Development   feature → human gates (product, design, arch) → generated gates (tech, qa)
              → codegen: one runner task per service → PRs → CI results → validation → signatures
Delivery      release: merge → deploy → flag → value metric → confirm   (or rollback)
```

Every step is a durable workflow in Postgres (runs, events, outbox): a restart of `api` or
`worker` never loses a step, effects are retried with backoff up to `WORKFLOW_MAX_ATTEMPTS`, after
which the run is **blocked** and shows up on the General page for a human to retry or roll back.

This page lists what an administrator connects. All settings are in **Administration**.

## 1. Bot identity

Everything the agent commits, reviews or merges is done by a bot, never by a user token.

| Provider | Identity | Settings |
| --- | --- | --- |
| GitHub | The GitHub App (installation token) | `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`; install the App on the spec repository **and** every service repository |
| GitLab | A bot user (project or group access token with `api` scope, Developer or Maintainer) | `GITLAB_BOT_TOKEN`; add the bot to the spec and service projects |

`HAMMURAPI_BOT_LOGIN` is the bot's login (`<app-slug>[bot]` on GitHub). Commits of the bot carry
trailers (`Hammurapi-Agent`, `Hammurapi-Initiator`, `Hammurapi-Generated`) and never count as a
human change or review.

## 2. Services and the catalog

Code generation needs to know which repositories implement a domain.

- **Backstage catalog** (Administration → Cycle): repository and glob of `catalog-info.yaml`
  files. Domains, systems and components (`spec.type: service`) are synced daily and on a push to
  that repository; owners (`user:` / `group:` of the git provider) become domain experts and
  service owners. Catalog-managed domains and services are read-only in Hammurapi; entities that
  could not be imported are listed with the reason.
- **Manual services** (Administration → Services): name, repository, domain/system, owner.

Service owners choose the autonomy of the agent in their repository (feature page → Autonomy):
`plan` (the agent writes `HAMMURAPI_PLAN.md`, a person writes the code), `pr` (default: the agent
opens a PR, a human review is required) or `autonomous`. At every level PRs are merged only by a
release.

Register the same `/hooks/v1/git` webhook (secret `WEBHOOK_SECRET`) in **every service
repository**: Hammurapi follows PR state, reviews, review comments and tags there.

## 3. Runner (code tasks)

Each service of a feature is a **task**: a `hammurapi runner` process that checks out the
repository through the provider API, opens an agent session in the operator and serves the
checkout to Pi's file and shell tools (the workspace server, only for the operator), commits as the
bot and opens or updates the PR.

| `RUNNER_EXECUTOR` | Where tasks run | Use |
| --- | --- | --- |
| `k8s` (default) | One Kubernetes Job per task in `RUNNER_NAMESPACE`: no service account token, read-only root filesystem, `activeDeadlineSeconds = RUNNER_TIMEOUT` | Production |
| `local` | Subprocesses of the worker in `RUNNER_WORKDIR` | Docker Compose demo only — tasks share the worker's host |

A task authenticates to the **internal API** (`INTERNAL_ADDR`, port 8081 — never exposed through
the ingress) with a one-time task token: it reads its description, gets a short-lived git token
for its repository only, reports progress and the result, and calls MCP tools limited to its
feature. Limits: `RUNNER_TIMEOUT`, `RUNNER_TOKEN_LIMIT` (agent tokens per task),
`RUNNER_MAX_PARALLEL`, `RUNNER_MAX_PARALLEL_PER_REPO`.

Runner pods need no LLM credentials: the agent runs in the operator, and the task's session gets
the model and key of the code generation scenario from Hammurapi. The chart's NetworkPolicy lets
runner pods accept connections only from the operator (the workspace port) and reach only DNS, the
internal API, the operator and HTTPS outside private ranges (git provider). A self-hosted GitLab in a private network must be added to
`runner.networkPolicy.egress`.

## 4. CI results

Validation needs test results linked to the QA test cases (`QA-…` IDs of the qa gate). Add a step
to the CI of each service repository that uploads JUnit XML:

```http
POST <HOOKS_URL>/hooks/v1/ci-results
X-Hammurapi-Signature: sha256=<hex HMAC-SHA256 of the body with CI_RESULTS_SECRET>
X-Hammurapi-Timestamp: <unix seconds, at most 5 minutes old>
Content-Type: application/json

{ "repo": "booking/api", "sha": "<commit>", "branch": "<branch>", "environment": "ci",
  "pipelineUrl": "https://…", "junit": "<base64 JUnit XML>" }
```

`environment` is `ci` for PR pipelines and `stage` for e2e runs after a stage deploy. A test case is
matched when its ID appears in the test name or a `<property>` (case, `-`, `_` and spaces are
ignored; `QA-1` does not match inside `QA-12`), so name tests like `TestQA07_cancel_booking`. A test
case with any failed test is failed. The body is limited to 20 MB; the response is `202`.

GitHub Actions:

```yaml
- name: Upload test results to Hammurapi
  if: always()
  env:
    SECRET: ${{ secrets.HAMMURAPI_CI_SECRET }}
    URL: ${{ vars.HAMMURAPI_URL }}/hooks/v1/ci-results
  run: |
    body=$(jq -n --arg repo "$GITHUB_REPOSITORY" --arg sha "${{ github.event.pull_request.head.sha || github.sha }}" \
      --arg branch "$GITHUB_HEAD_REF" --arg url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
      --arg junit "$(base64 -w0 report.xml)" \
      '{repo:$repo, sha:$sha, branch:$branch, environment:"ci", pipelineUrl:$url, junit:$junit}')
    ts=$(date +%s)
    sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.* //')
    curl -fsS -X POST "$URL" -H 'Content-Type: application/json' \
      -H "X-Hammurapi-Signature: sha256=$sig" -H "X-Hammurapi-Timestamp: $ts" --data "$body"
```

GitLab CI: the same script with `$CI_PROJECT_PATH`, `$CI_COMMIT_SHA`, `$CI_COMMIT_REF_NAME` and
`$CI_PIPELINE_URL`.

`CI_RESULTS_SECRET` accepts two comma-separated values, so a new secret can be rolled out to CI
before the old one is removed.

## 5. Deploy

Administration → Deploy, per environment (`stage`, `production`); a service may override it
(Administration → Services → deploy override).

| Type | Hammurapi starts | Status comes back |
| --- | --- | --- |
| `github-actions` | `workflow_dispatch` of `workflow` on `ref` with the rendered inputs, as the bot | Deploy webhook |
| `gitlab-ci` | A pipeline on `ref` with the rendered variables, as the bot | Deploy webhook |
| `webhook` | A signed `POST` to `url` with `runId`, `service`, `repo`, `ref`, `environment`, `feature`, `release`, `callbackUrl`, `params` | Deploy webhook |

Parameter values are templates with `{service}`, `{repo}`, `{ref}`, `{environment}`, `{feature}`,
`{release}`, `{callback_url}`, `{run_id}`. They are sent as plain JSON strings (no shell or URL
concatenation) with control characters removed. **Test** performs a dry run and shows the rendered
request without sending it.

The deploy job reports back:

```http
POST <HOOKS_URL>/hooks/v1/deploy
X-Hammurapi-Signature: sha256=<hex HMAC of the body with the environment's secret>
X-Hammurapi-Timestamp: <unix seconds>

{ "runId": "<run_id>", "service": "booking-api", "environment": "production",
  "ref": "<sha or tag>", "status": "started | success | failure", "runUrl": "https://…" }
```

An unknown `runId` gets `404`; the first final status wins. When no deploy is configured, or a
deploy job cannot call back, an owner marks the deploy by hand on the release (deploy mark).
Secrets are shown once on creation and rotation; two are active at a time.

When **stage** is enabled (Administration → Cycle), validation waits for a stage deploy of every
service and for `environment: "stage"` CI results before signatures.

## 6. Feature flags

A feature may have a flag key (feature page). After the production deploy the release waits for
the flag to be switched on:

```http
POST <HOOKS_URL>/hooks/v1/feature-flags
X-Hammurapi-Signature: sha256=<hex HMAC of the body>
X-Hammurapi-Timestamp: <unix seconds>

{ "flag": "onboarding-v2", "state": "on", "environment": "production",
  "changedAt": "2026-09-14T10:00:00Z", "actor": "anna.k" }
```

Enable the webhook and rotate its secret in Administration → Cycle. Without a flag system, a
product expert marks the flag state by hand on the release.

## 7. Metric sources

The Analysis of an issue defines its value metric (source, query, target, window); the release page
shows it and the confirmation compares it with the target. Sources are read-only
(Administration → Metric sources):

| Type | Queries | Protection |
| --- | --- | --- |
| ClickHouse | `SELECT` only, `{at}` is replaced by the evaluation time | `readonly=1`, `max_execution_time`, `max_result_rows` |
| Prometheus / VictoriaMetrics | Instant and range queries (PromQL) | Range limited to `maxRangeDays` |

**Test** runs a query (dry run) and returns the value or the source's error. Credentials are stored
encrypted or referenced as `env:VARIABLE`. The agent uses the same check (`test_metric_query`) while
writing the Analysis.

## 8. Release and rollback

A signed validation creates a release (`RLS.…`): merge PRs in the service order of the tech
spec (the spec PR last), wait for the tags, deploy, switch the flag, show the metric and wait
for confirmation by a product expert. A failed step blocks the release with the reason and offers
**retry** or **rollback**. A rollback reverts the merged PRs (restoring files from the merge
parent), deploys again, switches the flag off, closes open PRs, returns the issues to Discovery
with a link to the release and starts a new Analysis.

## Deviations from the specification

- The CI results, deploy and feature-flag webhooks are processed synchronously by `api` (written
  to Postgres, which wakes the workflow run), not through Kafka. The outcome and the retries are
  the same; Kafka still carries git provider events.
- R30 (metric window evaluation) and R35 (automatic Problem issue on a failed metric) are planned
  for the next release.
