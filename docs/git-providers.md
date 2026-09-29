# Git providers

Hammurapi works with **one** provider per instance: one specifications repository, any number of
service repositories and, optionally, a Backstage catalog repository. All access goes through the
provider API. What people do uses the signed-in user's own token, so their commits, PRs/MRs and
issues are attributed to them; what the agent does (generated gates, code, merges and reverts of
a release, pipelines) uses the **bot** — the GitHub App or a GitLab bot account.

## The specifications repository

1. Create a repository (e.g. `product/specs`) with a default branch (`main`).
2. Copy [`rules/`](../rules) from this repository into it and commit. Hammurapi creates each new
   gate document from `rules/<area>/template.md`, and each fix document from `fix-template.md`.
   A missing template falls back to an empty document with a title.
3. Hammurapi writes specifications to `specs/<domain>/<system>/<feature key>/<area>/spec.md` and
   Discovery to `specs/<domain>/<system>/<feature key>/discovery.md`.

Branch protection on the default branch is fine. A **release** merges the feature's PR/MR (last,
after the services) as the bot; if the provider refuses (required checks, conflicts, protection),
the release is blocked with the provider's reason until someone retries or rolls back.

## Service repositories

Every repository of a service (from the catalog or Administration → Services) needs:

- the bot with write access (Developer/Maintainer on GitLab; the App installed on GitHub), allowed
  to push branches, open PRs, merge them and start pipelines or workflows;
- the same webhook as the specifications repository (below), so PR state, reviews, review comments
  and tags reach Hammurapi;
- a CI step that uploads JUnit results ([cycle.md](cycle.md#4-ci-results)).

Hammurapi never merges into a service repository outside a release, whatever the autonomy level.

## GitLab (gitlab.com or self-hosted)

1. **User Settings → Applications** (or a group/instance application): create an application.
   - Redirect URI: `<PUBLIC_URL>/api/v1/auth/callback`
   - Confidential: yes
   - Scopes: `api`, `read_user`
2. Set `GIT_PROVIDER=gitlab`, `GIT_BASE_URL` (self-hosted: your GitLab URL), `GITLAB_CLIENT_ID`,
   `GITLAB_CLIENT_SECRET`, `GIT_REPO=<group>/<project>`.
3. **Bot**: a user (e.g. `hammurapi-bot`) or a group access token with scope `api` and role
   Developer (Maintainer where it must merge into protected branches) on the specifications and
   service projects. Set `GITLAB_BOT_TOKEN` and `HAMMURAPI_BOT_LOGIN`.
4. **Settings → Webhooks** of the specifications project and every service project (a group
   webhook covers them all):
   - URL: `<PUBLIC_URL>/hooks/v1/git`
   - Secret token: `WEBHOOK_SECRET`
   - Triggers: **Push events** (all branches), **Tag push events**, **Merge request events**,
     **Comments**
5. Users need at least Developer access to the project to push to feature branches; merging into a
   protected default branch needs the corresponding permission.

GitLab tokens expire after two hours; Hammurapi refreshes them automatically with the refresh
token while the user is active. If refreshing fails, the user is asked to sign in again.

## GitHub (github.com or GitHub Enterprise)

1. **Settings → Developer settings → GitHub Apps → New GitHub App**:
   - Callback URL: `<PUBLIC_URL>/api/v1/auth/callback`
   - Expire user authorization tokens: on (recommended)
   - Webhook: off (the repository webhook below is used instead)
   - Repository permissions: **Contents** read & write, **Pull requests** read & write,
     **Issues** read & write, **Actions** read & write (deploy through `workflow_dispatch`),
     **Metadata** read
2. Install the App on the specifications repository and every service repository. The App is
   also the bot: set `HAMMURAPI_BOT_LOGIN=<app-slug>[bot]`.
3. Set `GIT_PROVIDER=github`, `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_CLIENT_ID`,
   `GITHUB_CLIENT_SECRET`, `GIT_REPO=<owner>/<repo>`. GitHub Enterprise: `GIT_BASE_URL=https://<host>`
   (the API is used at `<host>/api/v3`).
4. **Settings → Webhooks** of the repository:
   - Payload URL: `<PUBLIC_URL>/hooks/v1/git`
   - Content type: `application/json`
   - Secret: `WEBHOOK_SECRET`
   - Events: **Pushes**, **Pull requests**, **Pull request reviews**, **Pull request review
     comments**, **Issue comments** (tags arrive as pushes)
   - Add the same webhook to every service repository (or once for the organization).

## Why the webhook matters

Hammurapi never polls git. Every event arrives as a webhook and goes through Kafka (topic
`hammurapi.git`) to the `worker`:

- a push to a feature branch of the specifications repository becomes an `edited` event; the gate
  returns to draft if it was awaiting approval or approved — also for edits made directly in git.
  Commits Hammurapi made itself (feature creation, import, deletion, generated gates) are
  recognised and skipped;
- pushes, PRs, reviews and comments in service repositories update the tasks and PRs of a feature;
  a review comment on an agent's PR goes back to the agent;
- tags wake up releases waiting for a service version;
- a push to the catalog repository starts a catalog sync.

Without a working webhook, edits never reach the projection and approvals are refused with
"the document changed, reload the page". Check the provider's webhook delivery log and the
`hammurapi_webhook_events_total{result}` metric.

## Deleting directly in git

Removing a gate's `spec.md` in git marks that gate deleted in Hammurapi (the last gate of a feature
is kept, with a warning in the log). Deleting a whole feature is only possible in Hammurapi.
