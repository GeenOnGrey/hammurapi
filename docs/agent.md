# The agent

Every user has a personal agent in a chat available on every screen, and the same agent does the
background work of the cycle: Analysis of issues, generation of the tech and QA gates, checks of
CI results, and code in the service repositories. The agent is [Pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
(`@earendil-works/pi-coding-agent`) run by Hammurapi's **agent operator**; Hammurapi does not ship
an LLM — the administrator connects one (DeepSeek in the first release) in **Admin → Agent**.

## How Hammurapi runs the agent

- The operator is the `agent` mode of the core image (release target, Pi and the
  `hammurapi-workspace` extension inside; the Pi version is `PI_VERSION` in
  `hammurapi-core/deploy/versions.env`). It listens on `:8090` and runs **one `pi --mode rpc`
  process per session**: one chat session per user and one per agent task.
- `api` (chat), `worker` (Analysis, gate generation, checks) and runner tasks (code) open sessions
  over HTTP with `AGENT_SERVICE_TOKEN`; a runner task gets a token of its own session only. Each
  request carries the model, the LLM key, the MCP servers and the skills of its scenario: the
  operator keeps no configuration and no keys of its own, and Pi gets a clean environment with
  them only.
- Limits: `AGENT_MAX_SESSIONS` processes in total, `AGENT_MAX_TASK_SESSIONS` of them for tasks;
  beyond that a request gets `503 agent_busy` and is retried. Idle sessions close after
  `AGENT_IDLE_TIMEOUT`: the chat saves the Pi session file to S3 first and restores it with the
  next message (or seeds a new session with the recent history).
- In the chat and the worker Pi has **no file or shell tools**: it reaches Hammurapi only through
  MCP tools. In a runner task Pi's `read`, `write`, `edit`, `bash`, `ls`, `find` and `grep` are
  routed by the `hammurapi-workspace` extension to the **workspace server** of the task
  (`:8095` in the runner pod): only inside the task's checkout, with a clean environment, in a Job
  without cluster credentials. Only the operator may connect to that port.
- LLM errors are classified — insufficient balance, authorization, rate limit, unavailable, bad
  request, context overflow, crash — and shown to people in plain words: a card with "Retry" in
  the chat, the reason of a stopped Analysis or generation, the connection status in Admin and a
  problem in "In focus" for global administrators. Rate limits and outages are retried by Pi;
  a context overflow is compacted and retried once.
- Metrics: `hammurapi_agent_sessions_active`, `hammurapi_agent_process_starts_total`,
  `hammurapi_llm_requests_total`, `hammurapi_llm_errors_total`, `hammurapi_llm_tokens_total`,
  `hammurapi_llm_cost_usd_total`.

## Configuring the agent (Admin → Agent)

Global administrators only:

- **LLM connections** — type (DeepSeek), name, API key (stored encrypted; only the last four
  characters are shown), models. "Check" sends a tiny request to every model. Saving is allowed
  after a failed check.
- **Models by scenario** — the default connection, model and reasoning level, and overrides for
  chat, issue analysis, gate generation, conformance check, code generation, review updates and
  rollback revert.
- **Skills** — Pi skills (`SKILL.md` with optional files) stored in the rules repository under
  `agent/skills/`; adding, changing and deleting go through a pull request, the skill works after
  the merge. A skill can be bound to scenarios; its scripts run only in code generation tasks.
- **MCP servers** — extra HTTP MCP servers with headers (stored encrypted), visibility (always
  visible or found on search) and scenarios. The built-in `hammurapi` server is always there.
- **Usage** — cost, tokens, cache share and runs by scenario, connection and model; the change log.

`BOOTSTRAP_DEEPSEEK_API_KEY` creates the first connection and the default model once, when there
are no connections, so a fresh instance works without a visit to Admin.

## Tools (MCP)

Hammurapi gives each session its MCP server with a grant that decides which tools the session
sees: `<INTERNAL_URL>/mcp` for the chat and runner tasks, the worker's own server
(`WORKER_MCP_URL`, `:8083`) for background scenarios.

In every scenario the agent also reads the specification of the default branch through read-only
tools over the same index as the **Specification** section (FTR.HMR.CMN-0005): `spec_tree` (domains,
systems, features), `spec_search` (full text and ID prefix, 20 per page), `spec_read` (a document
or one section; long documents come with the table of contents and the sections left out),
`spec_requirements` (R1… with acceptance criteria) and `spec_references` (where a feature or a
requirement is mentioned).

| Tool | Chat | Discovery | Gate generation | Check | Runner task |
| --- | --- | --- | --- | --- | --- |
| `list_issues`, `read_issue`, `list_features`, `search_specs` | yes | yes | yes | yes | no |
| `read_spec`, `read_rules`, `list_services` | yes | yes | yes | yes | its feature |
| `read_service_file` | no | yes | yes | yes | no (it has the checkout) |
| `test_metric_query` | with an open context | yes | no | no | no |
| `edit_spec` | human gates the user may edit, not approved, not generated | no | no | no | no |
| `edit_discovery`, `regenerate_gate` | with an open issue / feature, within the user's roles | no | no | no | no |
| `save_discovery` | no | its issue | no | no | no |
| `submit_gate` | no | no | its gate | no | no |
| `report_discrepancy` | no | no | no | its feature | no |
| `report_progress` | no | no | no | no | its task |

Edits made for a user commit with the user's token and the trailer `Hammurapi-Agent`, so history
shows "Agent on behalf of <name>"; background work commits as the bot with `Hammurapi-Initiator`.
There is no delete tool — irreversible actions are for people only.

The chat sends the open issue, feature or release as its context; the grant follows it. At the
start of a session and whenever the context changes, Hammurapi sends a context block: the agent's
name and tone, the context and the user's roles in it. The tone changes only how the agent talks,
never the content of drafts.

## fakellm (development only)

`fakellm` (target `fakellm` of the core Dockerfile, the `demo` compose profile) is a scripted
OpenAI-compatible endpoint: the real Pi talks to it like to DeepSeek. Background prompts start with
a `[hammurapi:task=…]` header, and it answers each with scripted tool calls — it saves an
Analysis, submits generated tech and QA gates, writes code with `Test<ID>_…` tests through Pi's
`write` tool in a runner task and reports check results; the chat echoes. Model ids `e401`,
`e402`, `e429`, `e503` imitate provider errors. Point the first connection at it with
`BOOTSTRAP_DEEPSEEK_BASE_URL=http://fakellm:8099`. Never use it for real work.
