# zulip-mcp

An [MCP](https://modelcontextprotocol.io) server that lets Claude read — and,
only if you opt in, post to — a Zulip organization. It is the "connector" half
of a Claude + Zulip integration: any MCP client (Claude Code, Claude Desktop,
claude.ai custom connectors) can use it.

> Status: prototype. Unit/integration tests run against a mock Zulip server;
> it has not yet been exercised against a live Zulip organization or from
> claude.ai. This directory is a side track and is not part of `PLAN.md`.

## Tools

| Tool | Kind | What it does |
| --- | --- | --- |
| `zulip_whoami` | read | Which account the connector acts as, and whether writes are enabled |
| `zulip_list_channels` | read | Channels the account can see (optional name filter) |
| `zulip_list_topics` | read | Recent topics of a channel |
| `zulip_get_messages` | read | Recent messages of a channel or topic, with paging |
| `zulip_get_direct_messages` | read | A DM conversation with given emails |
| `zulip_search_messages` | read | Full-text search |
| `zulip_send_message` | write | Post to a channel topic |
| `zulip_send_direct_message` | write | Send a DM |
| `zulip_add_reaction` | write | React to a message |

Write tools are **not registered at all** unless `ZULIP_MCP_WRITE=1`.
Reads go through the API and never mark messages as read. Message bodies are
returned prefixed with a notice that they are untrusted data (prompt-injection
mitigation), truncated per message and in total.

## Configuration

Credentials come from the environment or a standard `zuliprc` file; they are
never logged or returned by a tool.

| Variable | Meaning |
| --- | --- |
| `ZULIP_SITE`, `ZULIP_EMAIL`, `ZULIP_API_KEY` | Account credentials (`https://` required, except localhost) |
| `ZULIP_RC` | Path to a `zuliprc` (`[api]` section) instead of the three above |
| `ZULIP_MCP_WRITE` | `1` registers the write tools. Default: read-only |
| `ZULIP_MCP_WRITE_CHANNELS` | Comma-separated channel allowlist for posting; when set, DMs are refused |
| `ZULIP_MCP_TOKEN` | HTTP mode only: bearer token, at least 32 chars (`openssl rand -hex 32`) |
| `ZULIP_MCP_HOST`, `ZULIP_MCP_PORT` | HTTP mode bind address (default `127.0.0.1:8787`) |

Recommendation: give Claude its own Zulip **bot user** (Settings → Bots) rather
than your personal API key, so anything it posts is clearly labelled and you
can revoke it independently.

## Build and test

```bash
cd connectors/zulip-mcp
npm install
npm test        # builds, then runs the node:test suite against a mock Zulip server
```

## Use it locally (no hosting)

stdio, launched by the client:

```bash
# Claude Code
claude mcp add zulip \
  -e ZULIP_SITE=https://yourorg.zulipchat.com \
  -e ZULIP_EMAIL=claude-bot@yourorg.zulipchat.com \
  -e ZULIP_API_KEY=... \
  -- node /absolute/path/to/connectors/zulip-mcp/dist/src/index.js
```

For Claude Desktop add the same `command`/`args`/`env` under `mcpServers` in
`claude_desktop_config.json`.

## Use it as a remote connector

```bash
export ZULIP_MCP_TOKEN=$(openssl rand -hex 32)
npm start -- --http          # http://127.0.0.1:8787/mcp, bearer-protected
claude mcp add --transport http zulip http://127.0.0.1:8787/mcp \
  --header "Authorization: Bearer $ZULIP_MCP_TOKEN"
```

claude.ai connects from Anthropic's cloud, so it needs a public HTTPS URL
(deploy it, or tunnel with Cloudflare Tunnel/ngrok while testing) and a way to
authenticate. This prototype only has a static bearer token, which claude.ai
accepts through the (beta) *Request headers* field of a custom connector. A
proper per-user OAuth front (so each person signs in with their own Zulip
account) is the next step; see the design notes.
