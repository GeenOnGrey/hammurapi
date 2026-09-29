# HTTP API

The SPA uses the same API as any other client. Full contracts: the tech specifications
`hammurapi-specs/specs/PLT/HMR/PLT.HMR-0001/tech/spec.md` (specifications and gates) and
`PLT.HMR-0002/tech/spec.md` (the development cycle).

| Prefix | Purpose | Authentication |
| --- | --- | --- |
| `/api/v1/…` | User API | Session cookie + `X-CSRF-Token` on POST/PUT/PATCH/DELETE |
| `/admin/api/v1/…` | Administration | Same, plus a global or area administrator |
| `/hooks/v1/git` | Provider webhooks of the spec, service and catalog repositories | `WEBHOOK_SECRET` |
| `/hooks/v1/ci-results`, `/hooks/v1/deploy`, `/hooks/v1/feature-flags` | CI, deploy and flag systems ([cycle.md](cycle.md)) | HMAC `X-Hammurapi-Signature` + `X-Hammurapi-Timestamp` |
| `:8081 /mcp`, `:8081 /internal/v1/…` | Agents and runner tasks; never exposed through the ingress | Grant or task token (`Bearer hmt_…`) |
| `:9100 /healthz /readyz /metrics` | Service | none |

Conventions: JSON; cursor pagination `?cursor=&limit=` with `nextCursor` in the response; entities
are addressed by their key: issues `ISS.FMS.CAR-0012`, features `FTR.FMS.CAR-0005`, releases
`RLS.FMS.CAR-0003`; `area` is one of `product | design | arch | tech | qa`. A merged or moved issue
answers `308` with the new key.

## Endpoints

| Method and path | Purpose |
| --- | --- |
| `GET /api/v1/config` | Provider, limits, languages (no authentication) |
| `GET /api/v1/auth/login`, `GET /api/v1/auth/callback` | OAuth sign-in through the provider |
| `GET /api/v1/auth/me`, `POST /api/v1/auth/logout` | Current user and roles (global/area admin, product/technical expert of domains, service owner); sign out |
| `GET/PATCH /api/v1/profile`, `GET /api/v1/agent-tones` | Language, theme, my domains, agent name and tone |
| `POST /api/v1/feedback` | Creates an issue in the repository |
| `GET /api/v1/focus`, `GET /api/v1/overview` | General page: what waits for me; board of research, development and delivery |
| `GET/POST /api/v1/issues`, `GET /api/v1/issues/{key}` | Issues (idea or problem): list with filters, create, card |
| `POST /api/v1/issues/{key}/accept\|reject\|reopen\|discover\|merge\|move` | Accept (creates or joins a feature), reject, reopen, rerun Discovery, merge into another issue, move to another domain |
| `GET /api/v1/issues/{key}/discovery[/history]` | Discovery document (value, metric, context, similar items) and its versions |
| `GET /api/v1/features`, `GET/PATCH/DELETE /api/v1/features/{id}` | List, card (phase, issues, services, release, permissions), flag key, delete (`confirmKey`) |
| `GET /api/v1/features/{id}/requirements` | Requirements with IDs and the coverage matrix |
| `POST/DELETE /api/v1/features/{id}/lock` | Take or extend / release the edit lock |
| `POST /api/v1/features/{id}/gates`, `GET/DELETE …/gates/{area}` | Add, read, delete a gate |
| `GET/PUT …/gates/{area}/document` | Markdown and its SHA; save with `baseSha` (generated gates are read-only) |
| `GET …/gates/{area}/diff`, `GET …/gates/{area}/history` | Diff since approval; events |
| `POST …/gates/{area}/submit\|approve\|regenerate` | Workflow transitions; regenerate tech/qa |
| `GET /api/v1/approvals` | "Awaiting your approval" |
| `POST /api/v1/features/{key}/codegen`, `GET …/implementation`, `POST …/codegen/tasks/{taskId}/retry` | Start code generation; tasks, PRs and coverage by service; retry a task |
| `GET …/validation`, `POST …/validation/sign\|return`, `POST …/stage/deploys/{service}/mark` | Test results and signatures; sign (the last signature creates a release) or return to development; manual stage deploy mark |
| `GET /api/v1/services`, `PUT /api/v1/services/{service}/autonomy` | Services; agent autonomy (owners) |
| `GET /api/v1/releases`, `GET /api/v1/releases/{key}`, `GET …/metric` | Releases, the step lane, the value metric |
| `PUT …/plan`, `POST …/merge\|retry\|confirm\|rollback` | Order of services, start, retry a blocked step, confirm, roll back |
| `POST …/deploys/{service}/mark\|retry`, `POST …/flag/mark` | Manual deploy and flag marks, deploy retry |
| `POST /api/v1/chat/messages`, `POST /api/v1/chat/voice`, `GET /api/v1/chat/history`, `POST /api/v1/chat/cancel` | Agent chat; `context` = the open issue, feature or release |
| `GET /api/v1/events` | One SSE stream: `agent.*`, `issue.updated`, `discovery.progress`, `feature.updated`, `gate.updated`, `task.progress`, `validation.updated`, `release.updated`, `release.blocked`, `focus.changed`, `feature.deleted`, `approvals.changed`, `import.progress` |
| `POST/GET /api/v1/attachments`, `GET /api/v1/attachments/{id}` | Upload, history, download (owner only) |
| `POST /api/v1/imports`, `GET/DELETE /api/v1/imports/{id}`, `POST …/revalidate`, `POST …/confirm` | Import from a zip archive |
| `GET /admin/api/v1/users`, `PUT /admin/api/v1/users/{id}/roles` | Users and roles (global admin) |
| `GET/POST /admin/api/v1/domains`, `PATCH …/domains/{key}`, `PUT …/domains/{key}/experts`, `PUT …/domains/approval`, `POST/PATCH …/systems` | Domains, systems and experts (manual ones; catalog-managed ones answer `409 catalog_managed`) |
| `GET /admin/api/v1/services`, `POST/PATCH/DELETE …/services/{service}`, `PUT …/services/{service}/deploy-override` | Manual services, per-service deploy |
| `GET/PUT /admin/api/v1/catalog`, `POST …/catalog/sync`, `GET …/catalog/errors` | Backstage catalog |
| `GET/PUT /admin/api/v1/deploy/{env}`, `POST …/deploy/{env}/secret/rotate`, `POST …/deploy/{env}/test` | Deploy per environment; dry run |
| `GET/POST /admin/api/v1/metric-sources`, `PATCH/DELETE …/{name}`, `POST …/{name}/test` | Metric sources; dry run of a query |
| `GET /admin/api/v1/rules/{area}`, `POST …/rules/{area}/changes`, `GET …/rules/changes[/{id}]`, `POST …/approve`, `POST …/withdraw` | Rules via PR/MR (area admins) |
| `GET/PATCH /admin/api/v1/settings`, `POST …/settings/feature-flags/secret/rotate` | Attachment retention, feature-flag webhook, stage, runner executor |

## Errors

```json
{ "error": { "code": "previous_not_approved", "message": "earlier gates must be approved first", "details": { "area": "product" } } }
```

`code` is stable; clients choose the user-facing text by code (the SPA's `locales/*.json` →
`errors.*`). Status codes: `401` no session, `403` missing role or CSRF token, `404` unknown,
`409` state conflict (order of approval, stale `baseSha`, `requirements_without_id`,
`codegen_in_progress`, `feature_read_only`, `catalog_managed`, last gate…), `410` deleted feature (with `deletedBy` and `deletedAt`), `413`/`415` upload size/type, `422` invalid
input or provider refusal (`provider_refused` with the reason), `423` feature locked by another
user.
