# HTTP API

The SPA uses the same API as any other client. Full contract: the tech specification
(`hammurapi-specs/specs/PLT/HMR/PLT.HMR-0001/tech/spec.md`).

| Prefix | Purpose | Authentication |
| --- | --- | --- |
| `/api/v1/…` | User API | Session cookie + `X-CSRF-Token` on POST/PUT/PATCH/DELETE |
| `/admin/api/v1/…` | Administration | Same, plus a global or area administrator |
| `/hooks/v1/git` | Provider push webhooks | `WEBHOOK_SECRET` |
| `:9100 /healthz /readyz /metrics` | Service | none |

Conventions: JSON; cursor pagination `?cursor=&limit=` with `nextCursor` in the response; features
are addressed by their ID (`FMS.CAR-0005`); `area` is one of `product | design | arch | tech | qa`.

## Endpoints

| Method and path | Purpose |
| --- | --- |
| `GET /api/v1/config` | Provider, limits, languages (no authentication) |
| `GET /api/v1/auth/login`, `GET /api/v1/auth/callback` | OAuth sign-in through the provider |
| `GET /api/v1/auth/me`, `POST /api/v1/auth/logout` | Current user and roles; sign out |
| `GET/PATCH /api/v1/profile`, `GET /api/v1/agent-tones` | Language, theme, my domains, agent name and tone |
| `POST /api/v1/feedback` | Creates an issue in the repository |
| `GET /api/v1/domains` | Dictionary with `approvalRequired` |
| `GET/POST /api/v1/features`, `GET/DELETE /api/v1/features/{id}` | List, create (optionally a fix: `parent`), card, delete (`confirmUniqueId`) |
| `POST /api/v1/features/{id}/handoff` | Merge the PR/MR |
| `POST/DELETE /api/v1/features/{id}/lock` | Take or extend / release the edit lock |
| `POST /api/v1/features/{id}/gates`, `GET/DELETE …/gates/{area}` | Add, read, delete a gate |
| `GET/PUT …/gates/{area}/document` | Markdown and its SHA; save with `baseSha` |
| `GET …/gates/{area}/diff`, `GET …/gates/{area}/history` | Diff since approval; events |
| `POST …/gates/{area}/submit`, `POST …/gates/{area}/approve` | Workflow transitions |
| `GET /api/v1/approvals` | "Awaiting your approval" |
| `POST /api/v1/chat/messages`, `POST /api/v1/chat/voice`, `GET /api/v1/chat/history`, `POST /api/v1/chat/cancel` | Agent chat |
| `GET /api/v1/events` | One SSE stream: `agent.*`, `gate.updated`, `feature.handed_off`, `feature.deleted`, `approvals.changed`, `import.progress` |
| `POST/GET /api/v1/attachments`, `GET /api/v1/attachments/{id}` | Upload, history, download (owner only) |
| `POST /api/v1/imports`, `GET/DELETE /api/v1/imports/{id}`, `POST …/revalidate`, `POST …/confirm` | Import from a zip archive |
| `GET /admin/api/v1/users`, `PUT /admin/api/v1/users/{id}/roles` | Users and roles (global admin) |
| `GET/POST /admin/api/v1/domains`, `PATCH …/domains/{key}`, `PUT …/domains/approval`, `POST/PATCH …/systems` | Dictionary and approval switches (any admin) |
| `GET /admin/api/v1/rules/{area}`, `POST …/rules/{area}/changes`, `GET …/rules/changes[/{id}]`, `POST …/approve`, `POST …/withdraw` | Rules via PR/MR (area admins) |
| `GET/PATCH /admin/api/v1/settings` | Attachment retention (global admin) |

## Errors

```json
{ "error": { "code": "previous_not_approved", "message": "earlier gates must be approved first", "details": { "area": "product" } } }
```

`code` is stable; clients choose the user-facing text by code (the SPA's `locales/*.json` →
`errors.*`). Status codes: `401` no session, `403` missing role or CSRF token, `404` unknown,
`409` state conflict (order of approval, stale `baseSha`, handed-off feature, last gate…), `410`
deleted feature (with `deletedBy` and `deletedAt`), `413`/`415` upload size/type, `422` invalid
input or provider refusal (`provider_refused` with the reason), `423` feature locked by another
user.
