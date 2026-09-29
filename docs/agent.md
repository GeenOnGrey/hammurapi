# The agent

Every user has a personal agent in a chat available on every screen, and the same agent does the
background work of the cycle: Discovery of issues, generation of the tech and QA gates, checks of
CI results, and code in the service repositories. Hammurapi does not ship an LLM: it connects to an
agent that speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP).

## How Hammurapi runs the agent

- `api` (chat), `worker` (Discovery, gate generation, checks) and runner tasks (code) start the
  agent as a **subprocess** (`ACP_AGENT_COMMAND` + `ACP_AGENT_ARGS`) and talk JSON-RPC over its
  stdin/stdout. The agent must therefore live in the **instance image** used by all three.
- A pool of at most `ACP_MAX_PROCESSES` processes per pod; one process serves many sessions.
- **One ACP session per user.** Idle sessions close after `ACP_SESSION_IDLE_TIMEOUT`; a crashed
  process is restarted and the next message opens a new session.
- If a user moves to another `api` pod, the session is restored with `session/load` when the agent
  supports it, otherwise the last chat messages seed the new session.
- In the chat and the worker Hammurapi does **not** declare filesystem or terminal capabilities:
  the agent reaches Hammurapi only through MCP tools. In a runner task it does — the agent reads,
  writes and runs commands, but only inside the task's workspace (a checkout of one service
  repository, in a Job without cluster credentials). Web research is up to the agent itself.
- If the agent cannot start, the chat shows an error; the rest of Hammurapi keeps working and
  `/readyz` stays green. Agent health is exported as metrics (`hammurapi_agent_processes_up`,
  `hammurapi_agent_sessions_active`).

## Tools (MCP)

Hammurapi gives each session an MCP server (`<INTERNAL_URL>/mcp` for the chat,
`<INTERNAL_URL>/internal/v1/mcp` for runner tasks, the worker's own loopback server for background
sessions, or the stdio bridge `hammurapi mcp-proxy` for agents without HTTP MCP support) with a
grant that decides which tools the session sees:

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

## Building the instance image

`Dockerfile.instance` layers an agent on top of the Hammurapi image:

```sh
# Claude Code through its ACP adapter (Node.js base image)
docker build -f Dockerfile.instance --target claude \
  --build-context hammurapi=docker-image://registry.example.com/hammurapi:1.0.0 \
  -t registry.example.com/hammurapi-instance:1.0.0 .
```

```env
ACP_AGENT_COMMAND=claude-agent-acp
ACP_AGENT_ENV=ANTHROPIC_API_KEY=sk-ant-...
```

Any other ACP agent works the same way: install it in the image, point `ACP_AGENT_COMMAND` at it
and pass its credentials through `ACP_AGENT_ENV`. A distroless base cannot run agents that need a
runtime (Node.js, Python) — use a runtime image as the base and copy `/usr/local/bin/hammurapi`
into it, as the `claude` target does.

## The fake agent

`/usr/local/bin/hammurapi-fakeagent` is included in the Hammurapi image for smoke tests. It answers
deterministically and uses no LLM: in the chat it echoes messages, `edit <area>: <markdown>` calls
`edit_spec`, `tools` lists the MCP tools, `crash` exits. Background prompts start with a
`[hammurapi:task=…]` header, and the fake agent follows a script for each: it saves a Discovery,
submits generated tech and QA gates, writes code with `Test<ID>_…` tests in a runner task and
reports check results. Never use it for real work.
