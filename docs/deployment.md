# Deployment

## Images

| Image | Built from | Contents |
| --- | --- | --- |
| `hammurapi` | `hammurapi-core/Dockerfile` | Static binary on distroless (`api`, `worker`, `cleaner`, `migrate`) plus the fake agent |
| `hammurapi-instance` | `hammurapi/Dockerfile.instance` | `hammurapi` + your ACP agent; used by `api` only |
| `hammurapi-web` | `hammurapi-web/Dockerfile` | SPA on unprivileged nginx (port 8080) proxying `/api`, `/admin/api`, `/hooks` to `API_UPSTREAM` |

```sh
docker build -t registry.example.com/hammurapi:1.0.0 --build-arg VERSION=1.0.0 ../hammurapi-core
docker build -t registry.example.com/hammurapi-web:1.0.0 ../hammurapi-web
docker build -f Dockerfile.instance --target claude \
  --build-context hammurapi=docker-image://registry.example.com/hammurapi:1.0.0 \
  -t registry.example.com/hammurapi-instance:1.0.0 .
```

## Docker Compose (single host)

`docker-compose.yml` runs Postgres, Kafka, MinIO, `migrate`, `api`, `worker` and `web`; Whisper is
in the `voice` profile (it is large and downloads its model on first start), the fake GitLab in the
`demo` profile.

```sh
./install/install.sh                          # writes .env, starts everything
docker compose --profile voice up -d          # add speech recognition
docker compose run --rm api cleaner           # one maintenance pass (schedule it with cron)
```

| Port | Service |
| --- | --- |
| 8080 | Web app and API (one origin — this is `PUBLIC_URL`) |
| 8090 | `api` directly (debugging) |
| 9100 / 9101 | Service ports of `api` / `worker` (`/healthz`, `/readyz`, `/metrics`) |
| 5432, 9092, 9000/9001 | Postgres, Kafka, MinIO API/console |
| 8929 | Fake GitLab (`demo` profile only) |

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
| `Deployment` api | Instance image (Hammurapi + agent), probes on `:9100` |
| `Deployment` worker | Kafka consumers |
| `Deployment` web | SPA (optional, `web.enabled`) |
| `CronJob` cleaner | Daily maintenance, `cleaner.schedule` |
| `Job` migrate | `helm.sh/hook: pre-install,pre-upgrade` — migrations before the rollout |
| `Service` ×3, `Ingress` | `/api`, `/admin/api`, `/hooks` → api; `/` → web |
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
  --from-literal=ACP_AGENT_ENV='ANTHROPIC_API_KEY=…'

helm upgrade --install hammurapi ./helm/hammurapi \
  --set image.repository=registry.example.com/hammurapi-instance \
  --set coreImage.repository=registry.example.com/hammurapi \
  --set web.image.repository=registry.example.com/hammurapi-web \
  --set ingress.host=hammurapi.example.com \
  --set config.PUBLIC_URL=https://hammurapi.example.com \
  --set config.GIT_REPO=product/specs
```

`image` is the instance image (with the agent) used by `api`; `coreImage` overrides the image for
`worker`, `cleaner` and `migrate`, which do not need the agent.

### Sticky sessions

A user's ACP session and SSE stream live in one `api` pod. `ingress.stickySessions: true` (default)
adds cookie affinity annotations for ingress-nginx; with another ingress controller, configure the
equivalent. Without affinity everything still works, but agent sessions are re-created more often.

### Scaling

- `api`: stateless apart from agent sessions; scale horizontally. Size memory for
  `ACP_MAX_PROCESSES` agent processes per pod.
- `worker`: one consumer group; Kafka partitions (6 per topic by default) bound the parallelism,
  and events of one feature are always processed in order.
- Kafka topics `hammurapi.git.push` and `hammurapi.imports` are created on start if missing.

### Validating the chart

```sh
helm lint helm/hammurapi
helm template demo helm/hammurapi | kubeconform -summary -ignore-missing-schemas
```
