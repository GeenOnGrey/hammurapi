# Configuration

Every setting of a Hammurapi instance is an environment variable. Secrets come from a Kubernetes
Secret (Helm) or from `.env` (Docker Compose). Empty values mean "use the default".

`api`, `worker` and `cleaner` read the same variables; `migrate` only needs `DATABASE_URL`; a runner
task gets its settings from the worker (`HAMMURAPI_TASK_TOKEN`, `HAMMURAPI_INTERNAL_URL`, `ACP_*`).

## URLs and listeners

| Variable | Purpose | Default |
| --- | --- | --- |
| `PUBLIC_URL` | URL people open. Used for the OAuth callback (`<PUBLIC_URL>/api/v1/auth/callback`); `https://` turns on `Secure` cookies | `http://localhost:8080` |
| `HTTP_ADDR` | User API, admin API and webhooks | `:8080` |
| `SERVICE_ADDR` | `/healthz`, `/readyz`, `/metrics` (no authentication — keep it internal) | `:9100` |
| `INTERNAL_ADDR` | Internal API: `/mcp` for chat agents, `/internal/v1/…` for runner tasks (task token). Reachable from runners, never through the ingress. `MCP_ADDR` is the old name | `:8081` |
| `INTERNAL_URL` | URL of the internal API as seen from runners | `http://localhost:<INTERNAL_ADDR port>` |
| `WORKER_MCP_ADDR` | MCP endpoint of the worker's one-off agent sessions (Discovery, gate generation, checks); loopback only | `127.0.0.1:8083` |
| `HOOKS_URL` | Base URL of `/hooks/v1/*` given to deploy systems as the callback | `PUBLIC_URL` |

## Git provider

One provider and one repository per instance.

| Variable | Purpose | Default |
| --- | --- | --- |
| `GIT_PROVIDER` | `github` or `gitlab` | — (required) |
| `GIT_BASE_URL` | Provider URL as seen from the server (self-hosted GitLab, GitHub Enterprise) | `https://github.com` / `https://gitlab.com` |
| `GIT_OAUTH_URL` | Provider URL as seen from browsers, if different (split DNS, demo) | `GIT_BASE_URL` |
| `GIT_REPO` | Specifications repository, `owner/name` | — (required) |
| `GIT_DEFAULT_BRANCH` | Main branch that features are merged into | `main` |
| `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` | GitHub App identity | — |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | GitHub App OAuth credentials (user-to-server tokens) | — (required for GitHub) |
| `GITLAB_CLIENT_ID`, `GITLAB_CLIENT_SECRET` | GitLab OAuth application | — (required for GitLab) |
| `WEBHOOK_SECRET` | Shared with the webhooks of the spec, service and catalog repositories. GitLab sends it as `X-Gitlab-Token`; GitHub signs with it (`X-Hub-Signature-256`) | — (required for `api`) |
| `GITLAB_BOT_TOKEN` | GitLab: token of the bot account that commits, merges and triggers pipelines (GitHub uses the App) | — |
| `HAMMURAPI_BOT_LOGIN` | Login of the bot (`<app-slug>[bot]` on GitHub); its commits and reviews are not counted as human | — |

See [git-providers.md](git-providers.md) and [cycle.md](cycle.md).

## Development cycle

| Variable | Purpose | Default |
| --- | --- | --- |
| `CI_RESULTS_SECRET` | HMAC secret of `/hooks/v1/ci-results`; two comma-separated values while rotating | — (CI results are refused) |
| `RUNNER_EXECUTOR` | `k8s` (a Job per code task) or `local` (subprocesses of the worker, demo only) | `k8s` |
| `RUNNER_NAMESPACE` | Namespace of runner Jobs | `hammurapi-runners` |
| `RUNNER_IMAGE` | Image of runner Jobs (the instance image, with the agent) | — (required for `k8s`) |
| `RUNNER_AGENT_SECRET` | Secret in the runner namespace with the agent credentials, passed as `envFrom` | — |
| `RUNNER_CPU`, `RUNNER_MEMORY` | Limits of a runner Job | `2`, `4Gi` |
| `RUNNER_WORKDIR` | Working directories of `local` tasks | `/var/lib/hammurapi/runs` |
| `RUNNER_TIMEOUT` | Maximum duration of a task (Job `activeDeadlineSeconds`) | `2h` |
| `RUNNER_TOKEN_LIMIT` | Agent tokens per task; the task fails when exceeded | `3000000` |
| `RUNNER_MAX_PARALLEL` | Tasks running at once per instance | `10` |
| `RUNNER_MAX_PARALLEL_PER_REPO` | Tasks running at once per repository | `1` |
| `WORKFLOW_MAX_ATTEMPTS` | Attempts of an effect (deploy, merge, agent call…) before the run is blocked | `8` |
| `WORKFLOW_LEASE` | How long a worker holds a run before another may take it | `2m` |
| `DISCOVERY_TIMEOUT` | Maximum duration of one Discovery session | `20m` |

Deploy settings, the feature-flag webhook, the Backstage catalog, stage and metric sources are not
environment variables: administrators set them in the web app (see [cycle.md](cycle.md)).

## Users

| Variable | Purpose | Default |
| --- | --- | --- |
| `BOOTSTRAP_ADMINS` | Provider logins (comma-separated) that become global administrators on their **first** sign-in | — |
| `DEFAULT_LANGUAGE` | Interface language before sign-in when the browser language is not supported, and for new users: `en`, `ru`, `de`, `es`, `zh-CN` | `en` |

## Agent (ACP)

| Variable | Purpose | Default |
| --- | --- | --- |
| `ACP_AGENT_COMMAND` | Path of the agent binary in the instance image (`api`, `worker`, runner) | — (the agent is disabled when empty) |
| `ACP_AGENT_ARGS` | Arguments, space-separated | — |
| `ACP_AGENT_ENV` | Extra environment of the agent, `KEY=VALUE;KEY=VALUE` (e.g. its LLM API key) | — |
| `ACP_MAX_PROCESSES` | Maximum agent processes per `api` pod; sessions share processes beyond that | `4` |
| `ACP_SESSION_IDLE_TIMEOUT` | Idle agent sessions are closed after this Go duration | `30m` |

See [agent.md](agent.md).

## Infrastructure

| Variable | Purpose | Default |
| --- | --- | --- |
| `DATABASE_URL` | Postgres 16 connection string | — (required) |
| `KAFKA_BROKERS` | Comma-separated brokers | — (required for `api`, `worker`) |
| `S3_ENDPOINT` | S3/MinIO host:port | — (required) |
| `S3_BUCKET` | Bucket for attachments and import archives (created if missing) | `hammurapi` |
| `S3_ACCESS_KEY`, `S3_SECRET_KEY` | S3 credentials | — |
| `S3_USE_SSL` | Use HTTPS for S3 | `false` |
| `WHISPER_URL` | [whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice) base URL (model `small`) | — (voice input fails without it) |
| `TOKEN_ENCRYPTION_KEY` | 32 bytes, base64 or hex; encrypts users' provider tokens (AES-GCM). Changing it forces everyone to sign in again | — (required) |

## Limits

| Variable | Purpose | Default |
| --- | --- | --- |
| `UPLOAD_MAX_BYTES` | Chat attachment size limit | `20971520` (20 MB) |
| `UPLOAD_ALLOWED_TYPES` | Comma-separated MIME types, detected from content, not extension | images (JPEG, PNG, GIF, WebP, HEIC), Office (DOC/DOCX/XLS/XLSX/PPT/PPTX), TXT, PDF |
| `IMPORT_MAX_BYTES` | Import archive size | `52428800` (50 MB) |
| `IMPORT_MAX_UNCOMPRESSED_BYTES` | Unpacked size of an archive (zip-bomb protection) | `209715200` (200 MB) |
| `IMPORT_MAX_FILES` | Files in an archive | `500` |
| `IMPORT_ALLOWED_ASSET_TYPES` | Types allowed next to `spec.md` in an archive | PNG, JPEG, GIF, WebP, SVG, PDF, HTML |

The retention period of chat attachments is not an environment variable: a global administrator
sets it in **Administration → Settings** (default 90 days).

## Observability

| Variable | Purpose | Default |
| --- | --- | --- |
| `LOG_LEVEL` | `debug`, `info`, `warn`, `error` (JSON logs on stdout) | `info` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP/HTTP endpoint for traces; the standard `OTEL_*` variables apply | — (no export) |

## Docker Compose only

| Variable | Purpose | Default |
| --- | --- | --- |
| `AGENT_TARGET` | `Dockerfile.instance` target for the `api` image: `fake` or `claude` | `fake` |
