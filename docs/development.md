# Development

Check out the three repositories side by side:

```text
hammurapi/        docs, compose, Helm, installer, rules
hammurapi-core/   Go backend
hammurapi-web/    React SPA
```

Tools: Go 1.27, Node 24, Docker with Compose v2.

## Run the stack

```sh
cd hammurapi
cp .env.example .env              # or: ./install/install.sh --demo
docker compose --profile demo up -d --build
```

The `demo` profile adds **fakegitlab** (`hammurapi-core/cmd/fakegitlab`): an in-memory imitation of
the GitLab endpoints Hammurapi uses — OAuth, branches, files, multi-file commits, merge requests
with a three-way merge, diffs, notes, tags, pipelines, issues, search — for the specification
repository and the service repositories in `FAKE_SERVICE_REPOS` (`demo/booking`, `demo/pricing`).
It sends real push, tag, merge request and note webhooks to `api`, simulates CI (a JUnit report
with the `Test<ID>_…` tests of a branch, signed with `FAKE_CI_SECRET`), answers pipeline triggers
with a deploy callback, and serves a Prometheus endpoint (`/fake/prometheus`) for metric sources.
Its sign-in page lets you choose any login. `FAKE_REFUSE_MERGE=1` makes it refuse merges, to test
provider refusals. Development only.

Code tasks run with `RUNNER_EXECUTOR=local` in compose (subprocesses of the worker).

The default agent in compose is **hammurapi-fakeagent** (`hammurapi-core/cmd/fakeagent`), a scripted
ACP agent. To try a real agent, set `AGENT_TARGET=claude`, `ACP_AGENT_COMMAND=claude-agent-acp` and
`ACP_AGENT_ENV=ANTHROPIC_API_KEY=…` in `.env` and rebuild `api`.

## Backend

```sh
cd hammurapi-core
make build              # bin/hammurapi, bin/hammurapi-fakeagent
make test               # unit tests
make test-integration   # + Postgres via dockertest v4 (needs Docker)
make generate           # mocks via `go tool mockgen`
```

Run the api against the compose infrastructure from your IDE: take `.env`, replace the service
names with `localhost` (`postgres`, `kafka`, `minio`), and start `hammurapi migrate`, then
`hammurapi api` / `hammurapi worker`. Kafka advertises `kafka:9092`, so add `127.0.0.1 kafka` to your
hosts file when running outside compose.

Layout: vertical slices in `internal/features/*` (handlers, service, repository); adapters in
`internal/platform/*`; the shared projection of features and gates in `internal/specdata`, and of
issues, services, tasks and releases in `internal/cycledata`. Cycle steps are state machines on the
workflow engine (`internal/features/workflows`): a slice registers its machine and its effects, the worker
runs them. External dependencies sit behind interfaces with generated mocks.

## Frontend

```sh
cd hammurapi-web
npm ci
npm run dev             # http://localhost:5173, proxies /api and /admin/api to localhost:8080
npm test                # vitest: locales (key parity, ICU), formatting, markdown helpers
npm run build           # typecheck + production build
```

Point the dev server at another api with `HAMMURAPI_API=http://host:port npm run dev`. Sign-in
redirects to the provider and back to `PUBLIC_URL`, so for local UI work either use the compose
stack on port 8080 or set `PUBLIC_URL=http://localhost:5173` for the api.

## Tests

| Level | Where | What |
| --- | --- | --- |
| Unit | `hammurapi-core` `go test ./...` | Services on mockgen mocks: roles per area, sequential approval, stale approval, locks, deletion rules, webhook projection and idempotency; ACP pool against the fake agent over stdio (streaming, crash recovery, process limit, refused fs access); MCP permissions; providers against `httptest`; archive parsing (zip bombs, traversal) |
| Integration | `go test -tags integration ./...` | Every repository query on Postgres 16 in Docker; concurrent numbering; locks; the workflow engine (leases, retries, blocking); the whole cycle from an issue to a release and a rollback with stubbed effects |
| Frontend | `hammurapi-web` `npm test` | All five locales have the same keys and valid ICU; fallback to English; Russian plurals; `Intl` formatting |
| End to end | `hammurapi/scripts/e2e-smoke.sh` | Through the web origin against the demo stack: an issue, Discovery by the fake agent, acceptance, human gates, generated tech/qa, code generation in the runner, CI results, signatures, a release (merge order, deploy marks, confirmation), a second release through a pipeline, and a rollback |

## Translations

Interface strings live in `hammurapi-web/locales/<lang>.json` (ICU MessageFormat). English is the
fallback. Add a key to every file — `npm test` fails when locales diverge. Error texts are keyed by
the API error code under `errors.*`.
