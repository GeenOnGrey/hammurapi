# Git providers

Hammurapi works with **one** provider and **one** repository per instance. All access goes through
the provider API with the signed-in user's own token, so every commit, PR/MR and issue is
attributed to the person who made it.

## The specifications repository

1. Create a repository (e.g. `product/specs`) with a default branch (`main`).
2. Copy [`rules/`](../rules) from this repository into it and commit. Hammurapi creates each new
   gate document from `rules/<area>/template.md`, and each fix document from `fix-template.md`.
   A missing template falls back to an empty document with a title.
3. Hammurapi writes specifications to `specs/<domain>/<system>/<feature ID>/<area>/spec.md`.

Branch protection on the default branch is fine. **Hand off** merges the feature's PR/MR through
the API; if the provider refuses (required checks, conflicts, protection), the user sees the
provider's reason and the feature stays in progress.

## GitLab (gitlab.com or self-hosted)

1. **User Settings → Applications** (or a group/instance application): create an application.
   - Redirect URI: `<PUBLIC_URL>/api/v1/auth/callback`
   - Confidential: yes
   - Scopes: `api`, `read_user`
2. Set `GIT_PROVIDER=gitlab`, `GIT_BASE_URL` (self-hosted: your GitLab URL), `GITLAB_CLIENT_ID`,
   `GITLAB_CLIENT_SECRET`, `GIT_REPO=<group>/<project>`.
3. **Settings → Webhooks** of the project:
   - URL: `<PUBLIC_URL>/hooks/v1/git`
   - Secret token: `WEBHOOK_SECRET`
   - Trigger: **Push events** (all branches)
4. Users need at least Developer access to the project to push to feature branches; merging into a
   protected default branch needs the corresponding permission.

GitLab tokens expire after two hours; Hammurapi refreshes them automatically with the refresh
token while the user is active. If refreshing fails, the user is asked to sign in again.

## GitHub (github.com or GitHub Enterprise)

1. **Settings → Developer settings → GitHub Apps → New GitHub App**:
   - Callback URL: `<PUBLIC_URL>/api/v1/auth/callback`
   - Expire user authorization tokens: on (recommended)
   - Webhook: off (the repository webhook below is used instead)
   - Repository permissions: **Contents** read & write, **Pull requests** read & write,
     **Issues** read & write, **Metadata** read
2. Install the App on the specifications repository.
3. Set `GIT_PROVIDER=github`, `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_CLIENT_ID`,
   `GITHUB_CLIENT_SECRET`, `GIT_REPO=<owner>/<repo>`. GitHub Enterprise: `GIT_BASE_URL=https://<host>`
   (the API is used at `<host>/api/v3`).
4. **Settings → Webhooks** of the repository:
   - Payload URL: `<PUBLIC_URL>/hooks/v1/git`
   - Content type: `application/json`
   - Secret: `WEBHOOK_SECRET`
   - Events: **Just the push event**

## Why the webhook matters

Hammurapi never polls git. Every push to a `feature/<ID>` branch arrives as a webhook, goes
through Kafka to the `worker`, and becomes an `edited` event; the gate returns to draft if it was
awaiting approval or approved. This also covers edits made directly in git, outside Hammurapi.
Commits Hammurapi made itself (feature creation, import, deletion) are recognised and skipped.

Without a working webhook, edits never reach the projection and approvals are refused with
"the document changed, reload the page". Check the provider's webhook delivery log and the
`hammurapi_webhook_events_total{result}` metric.

## Deleting directly in git

Removing a gate's `spec.md` in git marks that gate deleted in Hammurapi (the last gate of a feature
is kept, with a warning in the log). Deleting a whole feature is only possible in Hammurapi.
