# Deployment

## Images

| Image | Built from | Contents |
| --- | --- | --- |
| `hammurapi-core` | `hammurapi-core/Dockerfile`, target `release` | Hammurapi + Pi (`PI_VERSION`) + the `hammurapi-workspace` extension; every mode, required for the agent operator |
| `hammurapi` | `hammurapi-core/Dockerfile`, default target | Static binary on distroless, without Pi (`api`, `worker`, `runner`, `cleaner`, `migrate`) |
| `hammurapi-fakellm` | `hammurapi-core/Dockerfile`, target `fakellm` | Scripted LLM for demos and smoke tests only |
| `hammurapi-web` | `hammurapi-web/Dockerfile` | SPA on unprivileged nginx (port 8080) proxying `/api`, `/admin/api`, `/hooks` to `API_UPSTREAM` |

```sh
docker build --target release --build-arg VERSION=1.2.0 --build-arg PI_VERSION=1.0.0 \
  -t registry.example.com/hammurapi-core:1.2.0 ../hammurapi-core
docker build -t registry.example.com/hammurapi-web:1.2.0 ../hammurapi-web
```

## Docker Compose (single host)

`docker-compose.yml` runs Postgres, Kafka, MinIO, `migrate`, `api`, `worker`, the agent operator
`agent` and `web`; Whisper is in the `voice` profile (it is large and downloads its model on first
start), ClickHouse (a metric source to try Discovery with) in the `metrics` profile, and the fake
GitLab with the scripted LLM `fakellm` in the `demo` profile.
The fake GitLab hosts the spec repository and two service repositories (`demo/booking`,
`demo/pricing`), simulates CI (JUnit results from `Test<ID>_…` tests), deploys and a Prometheus
endpoint, so the whole cycle runs on a laptop.

Code tasks run with `RUNNER_EXECUTOR=local` in Compose: as subprocesses of the worker, in the
`runner-work` volume. That is fine for a demo, not for untrusted code — use Kubernetes Jobs in
production.

```sh
./install/install.sh                          # writes .env, starts everything
docker compose --profile voice up -d          # add speech recognition
docker compose run --rm api cleaner           # one maintenance pass (schedule it with cron)
```

| Port | Service |
| --- | --- |
| 8080 | Web app and API (one origin — this is `PUBLIC_URL`) |
| 8090 | `api` directly (debugging) |
| 9100 / 9101 / 9102 | Service ports of `api` / `worker` / `agent` (`/healthz`, `/readyz`, `/metrics`) |
| 5432, 9092, 9000/9001 | Postgres, Kafka, MinIO API/console |
| 8929, 8099 | Fake GitLab, fakellm (`demo` profile only) |

Put a TLS-terminating reverse proxy in front of port 8080 for anything beyond a laptop and set
`PUBLIC_URL=https://…` (cookies become `Secure`). The proxy must not buffer
`/api/v1/events` (server-sent events) and must allow uploads of at least 60 MB (archive import).

Note: the architecture spec names `bitnami/kafka` and `minio/minio`; neither is published on
Docker Hub any more, so the compose file uses `apache/kafka` (KRaft) and
`cgr.dev/chainguard/minio`.

## Kubernetes (Helm)

The chart in `helm/hammurapi` deploys:

| Resource | Purpose |
| --- | --- |
| `Deployment` api | Core image, probes on `:9100`; internal API on `:8081` (runner tasks, MCP of the chat) |
| `Deployment` worker | Kafka consumers, workflow engine, agent scenarios through the operator, MCP of task sessions on `:8083`, runner Jobs |
| `Deployment` agent | The agent operator: a Pi process per session on `:8090`; gets only `AGENT_SERVICE_TOKEN` from the Secret; `NetworkPolicy`: only api, worker and runner pods may call it |
| `Namespace`, `ServiceAccount`, `Role`, `RoleBinding` | Runner namespace (`runner.namespace`, Pod Security `restricted`); the worker may create, read and delete Jobs there only |
| `NetworkPolicy` | Runner pods: ingress only from the agent operator to the workspace port (`runner.workspacePort`); egress to DNS, the internal API, the operator and `runner.networkPolicy.egress` |
| `Deployment` web | SPA (optional, `web.enabled`) |
| `CronJob` cleaner | Daily maintenance, `cleaner.schedule` |
| `Job` migrate | `helm.sh/hook: pre-install,pre-upgrade` — migrations before the rollout |
| `Service` ×3, `Ingress` | `/api`, `/admin/api`, `/hooks` → api; `/` → web (the internal port 8081 is not routed) |
| `ConfigMap`, `Secret` | Configuration; or reference an existing Secret |
| `ServiceMonitor` | Optional Prometheus Operator scraping |

Postgres, Kafka, S3 and Whisper are not part of the chart — use managed services or their own
charts.

```sh
kubectl create secret generic hammurapi-secrets \
  --from-literal=DATABASE_URL='postgres://…' \
  --from-literal=TOKEN_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
  --from-literal=WEBHOOK_SECRET="$(openssl rand -hex 24)" \
  --from-literal=GITLAB_CLIENT_ID=… --from-literal=GITLAB_CLIENT_SECRET=… \
  --from-literal=S3_ACCESS_KEY=… --from-literal=S3_SECRET_KEY=… \
  --from-literal=AGENT_SERVICE_TOKEN="$(openssl rand -hex 32)" \
  --from-literal=BOOTSTRAP_DEEPSEEK_API_KEY=… \
  --from-literal=GITLAB_BOT_TOKEN=…   --from-literal=CI_RESULTS_SECRET="$(openssl rand -hex 24)"

helm upgrade --install hammurapi ./helm/hammurapi \
  --set image.repository=registry.example.com/hammurapi-core \
  --set coreImage.repository=registry.example.com/hammurapi \
  --set web.image.repository=registry.example.com/hammurapi-web \
  --set ingress.host=hammurapi.example.com \
  --set config.PUBLIC_URL=https://hammurapi.example.com \
  --set config.GIT_REPO=product/specs
```

`image` is the core release image (with Pi) used by `api`, `worker`, `agent` and runner Jobs
(`runner.image` overrides it for Jobs); `coreImage` overrides the image for `cleaner` and
`migrate`. LLM connections, models, skills and MCP servers of the agent are set in
**Administration → Agent**; `BOOTSTRAP_DEEPSEEK_API_KEY` creates the first connection. When the runner namespace is created beforehand, set
`runner.createNamespace=false`.

### Sticky sessions

A user's SSE stream (the streamed chat answer) lives in one `api` pod. `ingress.stickySessions: true` (default)
adds cookie affinity annotations for ingress-nginx; with another ingress controller, configure the
equivalent. Without affinity the answer may stream to another pod's connection and appear only after a reload.

### Scaling

- `api`: stateless; scale horizontally. Agent sessions live in the operator.
- `agent`: one replica; size its memory for `agent.maxSessions` Pi processes (about 100–150 MB
  each). Idle sessions close after `AGENT_IDLE_TIMEOUT`; chats restore from S3 snapshots.
- `worker`: one consumer group; Kafka partitions (6 per topic by default) bound the parallelism,
  and events of one feature are always processed in order. Workflow runs are leased with
  `SELECT … FOR UPDATE SKIP LOCKED`, so several workers share them safely.
- Runner Jobs: `RUNNER_MAX_PARALLEL` per instance, `RUNNER_MAX_PARALLEL_PER_REPO` per repository;
  size the runner namespace quota for `RUNNER_CPU` × `RUNNER_MEMORY` × parallel tasks.
- Kafka topics `hammurapi.git` and `hammurapi.imports` are created on start if missing.

### Validating the chart

```sh
helm lint helm/hammurapi
helm template demo helm/hammurapi | kubeconform -summary -ignore-missing-schemas
```
