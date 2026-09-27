# Operations

## Health checks

Service port `:9100` of `api` and `worker` (no authentication, keep it off the public ingress):

| Path | Meaning |
| --- | --- |
| `/healthz` | Liveness: the process is up |
| `/readyz` | Readiness: Postgres and Kafka reachable. The agent and the git provider do **not** affect readiness — an agent failure disables the chat, not the pod |
| `/metrics` | Prometheus metrics |

## Metrics

| Metric | What to watch |
| --- | --- |
| `hammurapi_http_requests_total{route,method,status}`, `hammurapi_http_request_duration_seconds` | Error rate and latency per route |
| `hammurapi_git_api_errors_total{provider,op}` | Provider failures (rate limits, expired tokens, outages) |
| `hammurapi_git_provider_up` | 1 when the last provider call succeeded |
| `hammurapi_webhook_events_total{result}` | `accepted`, `processed`, `unauthorized` (wrong secret), `error` |
| `hammurapi_kafka_consumer_lag{topic}` | Worker falling behind |
| `hammurapi_agent_sessions_active`, `hammurapi_agent_processes_up` | Agent pool |
| `hammurapi_gate_transitions_total{area,to}` | Workflow throughput, resets to draft |

## Logs and traces

Logs are JSON on stdout with `trace_id`, `span_id`, `request_id`, `user_id` and `mode`. Traces go to
`OTEL_EXPORTER_OTLP_ENDPOINT` (OTLP/HTTP): spans for HTTP requests, provider calls, ACP, Whisper,
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
- The MCP endpoint listens on loopback only; tokens are per session and revoked when it closes.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "The document changed, reload the page" on every approval | Webhooks do not arrive: check the provider's delivery log, `WEBHOOK_SECRET`, and `hammurapi_webhook_events_total` |
| Edits do not reset statuses | Same as above, or the worker is down / lagging |
| "Git provider session expired, sign in again" | The refresh token was revoked or `TOKEN_ENCRYPTION_KEY` changed |
| Chat says the agent is not configured | `ACP_AGENT_COMMAND` is empty or not in the `api` image |
| Hand-off fails with the provider's reason | Branch protection, required checks or merge conflicts on the PR/MR |
| Voice input says recognition is unavailable | `WHISPER_URL` not set or the Whisper service is not running |
