# The agent

Every user has a personal agent in a chat available on every screen. Hammurapi does not ship an
LLM: it connects to an agent that speaks the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP).

## How Hammurapi runs the agent

- `api` starts the agent as a **subprocess** (`ACP_AGENT_COMMAND` + `ACP_AGENT_ARGS`) and talks
  JSON-RPC over its stdin/stdout. The agent must therefore live in the **same container** as `api`.
- A pool of at most `ACP_MAX_PROCESSES` processes per pod; one process serves many sessions.
- **One ACP session per user.** Idle sessions close after `ACP_SESSION_IDLE_TIMEOUT`; a crashed
  process is restarted and the next message opens a new session.
- If a user moves to another `api` pod, the session is restored with `session/load` when the agent
  supports it, otherwise the last chat messages seed the new session.
- Hammurapi does **not** declare filesystem or terminal capabilities: the agent reaches Hammurapi
  only through MCP tools. Web research is up to the agent itself.
- If the agent cannot start, the chat shows an error; the rest of Hammurapi keeps working and
  `/readyz` stays green. Agent health is exported as metrics (`hammurapi_agent_processes_up`,
  `hammurapi_agent_sessions_active`).

## Tools (MCP)

Hammurapi gives each session an MCP server (`http://127.0.0.1:8081/mcp`, or the stdio bridge
`hammurapi mcp-proxy` for agents without HTTP MCP support) with a token scoped to the user:

| Tool | General questions | Specification |
| --- | --- | --- |
| `list_features`, `search_specs` | yes | yes |
| `read_spec(uniqueId, area)` | yes | yes |
| `read_rules(area, template\|fix)` | yes | yes |
| `edit_spec(area, content)` | no | only areas where the user is an editor, only gates that are not approved |

`edit_spec` commits with the user's token like a manual edit, with the trailer
`Hammurapi-Agent: true`, so history shows "Agent on behalf of <name>". There is no delete tool —
irreversible actions are for people only.

Switching the chat mode or the open feature updates the token's rights immediately. At the start
of a session and whenever the context changes, Hammurapi sends a context block: the agent's name
and tone, the mode, the feature and the open area. The tone changes only how the agent talks,
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
deterministically and uses no LLM: it echoes messages, `edit <area>: <markdown>` calls `edit_spec`,
`tools` lists the MCP tools, `crash` exits. Never use it for real work.
