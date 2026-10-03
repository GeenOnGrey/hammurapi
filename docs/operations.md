# Operations

## Health checks

Service port `:9100` of `api`, `worker` and `agent` (no authentication, keep it off the public ingress):

| Path | Meaning |
| --- | --- |
| `/healthz` | Liveness: the process is up |
| `/readyz` | Readiness: Postgres and Kafka reachable (`agent`: the Pi binary is present). The agent operator, the LLM and the git provider do **not** affect readiness of `api` and `worker` — an agent failure shows up as an error in the chat and a stopped run, not as a pod failure |
| `/metrics` | Prometheus metrics |

## Metrics

| Metric | What to watch |
| --- | --- |
| `hammurapi_http_requests_total{route,method,status}`, `hammurapi_http_request_duration_seconds` | Error rate and latency per route |
| `hammurapi_git_api_errors_total{provider,op}` | Provider failures (rate limits, expired tokens, outages) |
| `hammurapi_git_provider_up` | 1 when the last provider call succeeded |
| `hammurapi_webhook_events_total{result}` | `accepted`, `processed`, `unauthorized` (wrong secret), `error` |
| `hammurapi_kafka_consumer_lag{topic}` | Worker falling behind |
| `hammurapi_agent_sessions_active{kind}`, `hammurapi_agent_process_starts_total{reason}` | Pi sessions of the operator (chat, task); restarts after crashes |
| `hammurapi_llm_requests_total`, `hammurapi_llm_errors_total{class,connection}` | LLM runs and their errors: balance, authorization, rate limits, outages |
| `hammurapi_llm_tokens_total{direction}`, `hammurapi_llm_cost_usd_total{connection,model}` | Token use and cost (also in Admin → Agent → Usage) |
| `hammurapi_gate_transitions_total{area,to}` | Gate throughput, resets to draft |
| `hammurapi_workflow_runs{kind,state}` | Active runs of Discovery, gate generation, codegen, validation, release, rollback |
| `hammurapi_workflow_blocked_total{kind,reason}` | Runs that exhausted their attempts — each one waits for a human on the General page |
| `hammurapi_workflow_transition_duration_seconds{kind,step}` | Slow steps |
| `hammurapi_runner_tasks{type,status}`, `hammurapi_runner_task_duration_seconds`, `hammurapi_runner_tokens_total{type}` | Agent tasks, their duration and LLM token use |
| `hammurapi_deploy_runs_total{environment,status}`, `hammurapi_release_rollbacks_total` | Deploys and rollbacks |

## Logs and traces

Logs are JSON on stdout with `trace_id`, `span_id`, `request_id`, `user_id` and `mode`. Traces go to
`OTEL_EXPORTER_OTLP_ENDPOINT` (OTLP/HTTP): spans for HTTP requests, provider calls, the agent operator, Whisper,
Kafka produce/consume and SQL.

## Maintenance (cleaner)

`hammurapi cleaner` (CronJob, daily by default) removes:

- chat attachments older than the retention set in **Administration → Settings** (object and row);
- expired sessions and edit locks;
- import jobs not confirmed within 24 hours, with their archives;
- branches of deleted features whose deletion failed at the provider (retried with the deleting
  user's token).

## Backups

- **Postgres** holds statuses, history, roles, chat and settings — back it up.
- **The git repository** holds all document content and rules — it is backed up by your provider.
- **S3** holds chat attachments (temporary by design) and import archives (deleted after import).

Hammurapi can be restored from a Postgres backup plus the repository; statuses are not stored in
git.

## Security notes

- Provider tokens are encrypted with AES-GCM (`TOKEN_ENCRYPTION_KEY`). Rotating the key signs
  everyone out of the provider (they sign in again).
- Session cookie: `HttpOnly`, `SameSite=Lax`, `Secure` over HTTPS. Every state-changing request
  needs the CSRF double-submit header `X-CSRF-Token`.
- Webhooks without a valid secret are rejected with 401 and never reach Kafka.
- Attachments and archive files are checked by content, not extension. Archives are read in memory
  with limits on size, unpacked size and file count; `..`, absolute paths and symlinks are rejected.
- The internal API (`:8081`: MCP and runner tasks) is never routed through the ingress. MCP grants
  are per session and revoked when it closes; task tokens (`hmt_…`, stored as SHA-256) are valid
  only while their task runs, and the git token a task receives is limited to its repository.
- Runner Jobs run without a service account token, as a non-root user with a read-only root
  filesystem, a deadline and a NetworkPolicy. The worker's service account may only manage Jobs in
  the runner namespace.
- CI results, deploy and feature-flag webhooks need an HMAC signature with a timestamp at most five
  minutes old; secrets are shown once and rotated with two active at a time.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "The document changed, reload the page" on every approval | Webhooks do not arrive: check the provider's delivery log, `WEBHOOK_SECRET`, and `hammurapi_webhook_events_total` |
| Edits do not reset statuses | Same as above, or the worker is down / lagging |
| "Git provider session expired, sign in again" | The refresh token was revoked or `TOKEN_ENCRYPTION_KEY` changed |
| Chat says the agent is not configured | No LLM connection or default model: Admin → Agent (or `BOOTSTRAP_DEEPSEEK_API_KEY` on a fresh instance) |
| Chat shows "The balance of the connection … ran out" / "is not authorized" | Top up the provider balance or replace the key in Admin → Agent → LLM connections; "In focus" of global administrators shows the problem |
| Chat says the agent is unavailable | The `agent` operator is down or `AGENT_SERVICE_TOKEN` differs between `api`/`worker` and `agent`; see the operator's logs |
| Analysis or gate generation stops with an LLM error | The reason is on the issue or feature (class and connection); fix the connection and press "Retry" |
| Analysis or gate generation stays "the agent is working" | The operator is at `AGENT_MAX_SESSIONS` (`agent_busy`, retried), or `DISCOVERY_TIMEOUT` is too short; see the run's last error on the issue |
| A code task fails at once | Jobs cannot be created (RBAC, namespace, `RUNNER_IMAGE`), the runner cannot reach `INTERNAL_URL` or `AGENT_RUNNER_URL`, or the operator cannot reach the task's workspace port (NetworkPolicy) |
| Validation waits for CI forever | The CI step does not post to `/hooks/v1/ci-results`, the signature is wrong (401 in the CI log), or test names do not contain the QA test case IDs |
| A release is blocked on merge | Branch protection, required checks or merge conflicts — the reason is on the release; fix it and retry, or roll back |
| A release waits for a deploy | The deploy job does not call `/hooks/v1/deploy` with the `runId`; mark the deploy by hand on the release |
| Voice input says recognition is unavailable | `WHISPER_URL` not set or the Whisper service is not running |
