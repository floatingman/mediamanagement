# Cognee MCP Runbook — wiring agents to the shared memory

Cognee (k8s ns `cognee`) exposes an MCP server for agents at:

```
https://mcp.thenewmans.casa/mcp
```

- **Auth**: HTTP basic — `agent` / `COGNEE_MCP_PASSWORD` (repo `.env`; regenerating k8s side: `k8s/scripts/gen-env.sh`)
- **Transport**: stateful StreamableHTTP — the `initialize` call returns an `Mcp-Session-Id` response header that must be replayed on subsequent calls (standard MCP clients do this automatically; raw curl does not)
- **Tools**: `remember` (ingest + graph build), `recall` (query), `forget`, `search_tools`, `call_tool`
- **LLM backend**: deepseek-v4.1-flash via cline-gateway on the media VM (see CLAUDE.md cognee row for history/fallbacks); embeddings local Ollama
- **Tool args (1.6.2 quirks, verified)**: `remember` takes `data` (text), not `content`; `recall`'s `datasets` is a comma-separated STRING, not a list; `remember` without `dataset_name` auto-creates one named after the MCP clientInfo name

Any internet-reachable host can connect; the wildcard cert is valid and the endpoint is open at the edge with basic auth as the only gate. Treat the credential accordingly.

---

## 1. Pre-flight (run on the target server)

```bash
# Unauthenticated reachability — expect 401
curl -sS -o /dev/null -w '%{http_code}\n' https://mcp.thenewmans.casa/mcp

# Authenticated initialize — expect a JSON-RPC result over SSE
curl -sS -u "agent:PASSWORD" -X POST https://mcp.thenewmans.casa/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}'
```

If you need `tools/list` over raw curl, capture the `Mcp-Session-Id` header from
the initialize response and send it back — otherwise the server answers
`"Missing session ID"`.

## 2. Client wiring (verified patterns)

### pi / omp (oh-my-pi)

`~/.pi/agent/mcp.json` and `~/.omp/agent/mcp.json` respectively (mode 600):

```json
{
  "mcpServers": {
    "cognee": {
      "url": "https://mcp.thenewmans.casa/mcp",
      "headers": { "Authorization": "Basic <base64 agent:PASSWORD>" },
      "lifecycle": "lazy"
    }
  }
}
```

New sessions only; check status in the omp TUI with `/mcp`.

### hermes (bigheartedlabs)

`~/.hermes/config.yaml` under `mcp_servers:` (same shape as its `n8n_native` entry):

```yaml
mcp_servers:
  cognee:
    url: "https://mcp.thenewmans.casa/mcp"
    headers:
      Authorization: "Basic <base64 agent:PASSWORD>"
    timeout: 120
    connect_timeout: 60
```

Hermes reloads MCP config on its `mcp_reload_confirm` path; restart the gateway if it doesn't offer.

### Claude Code [UNVERIFIED HERE]

```bash
claude mcp add --transport http cognee https://mcp.thenewmans.casa/mcp \
  --header "Authorization: Basic <base64>"
```

### Codex [UNVERIFIED HERE]

`~/.codex/config.toml`:

```toml
[mcp_servers.cognee]
url = "https://mcp.thenewmans.casa/mcp"
http_headers = { "Authorization" = "Basic <base64>" }
```

### No-MCP clients: REST instead

`https://cognee-api.thenewmans.casa` serves the same memory over JWT REST
(`/docs` for reference). Login is **form-encoded**:

```bash
TOK=$(curl -s -X POST https://cognee-api.thenewmans.casa/api/v1/auth/login \
  --data-urlencode "username=default_user@example.com" \
  --data-urlencode "password=<COGNEE_DEFAULT_USER_PASSWORD>" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
curl -H "Authorization: Bearer $TOK" .../api/v1/search ...

## Dataset routing convention (per-repo brains + shared global)

Datasets are cognee's partition unit: each gets its own graph, entities can't
collide across them, and `recall` accepts a comma-separated list. Convention:

| Dataset | Contents | Who writes |
|---|---|---|
| `global` | Cross-cutting infra knowledge, incident history, homelab facts, learned lessons | any agent, for non-repo-specific knowledge |
| `repo:<name>` | One git repo's architecture, docs, conventions (e.g. `repo:mediamanagement` = its CLAUDE.md) | agents working in that repo |

- `remember` MUST pass `dataset_name` explicitly (default otherwise creates a
  per-client `<clientname>_memory` dataset — fragmentation, not scoping).
- `recall` with `datasets: "repo:<name>,global"` is the default scope inside a
  repo; omit `datasets` for a broad cross-brain search when the source is unknown.
- `forget(dataset: "repo:<name>")` purges a repo's brain when it's archived or
  rewritten.
- New repo = nothing infra-side to add: the dataset is created lazily by the
  first `remember`/`add`. Onboarding = ingest its README/CLAUDE.md/docs into
  `repo:<name>` and re-call cognify, then agents follow the routing above.
- **Work-repo caution**: ingestion extraction runs through the configured LLM
  backend (currently ClinePass/deepseek — a third-party cloud). Do not route
  employer-confidential code/docs through it unless that's permitted; a
  separate work-only cognee instance with a local Ollama backend is the
  isolation option if needed.

## 3. Post-wire verification
Ask the agent to recall a known fact (memory already contains TROUBLESHOOTING.md):

> Call mcp_cognee_recall with query "Where does Sabnzbd download usenet to?" — expect "the Synology NAS".

Tool names surface as `mcp__cognee_<tool>` in pi/omp.

## 4. Gotchas

- **Password rotation** touches every client: `.env` → `k8s/scripts/gen-env.sh` →
  `kubectl apply -k k8s/cognee` (traefik Secret) → `~/.pi/agent/mcp.json` →
  `~/.omp/agent/mcp.json` → `~/.hermes/config.yaml` on bigheartedlabs → any
  other server wired per this runbook. All copies hold the same base64 header.
- **421 Misdirected Host** from the MCP container means `MCP_ALLOWED_HOSTS`
  doesn't cover the Host header used — only `mcp.thenewmans.casa` is allowed
  (env in `k8s/cognee/cognee.yaml`); extend it if you front the service differently.
- **401** = basic auth failed (rotation drift or typo). **405/400 on GET /mcp** = you reached the server fine; MCP is POST-only.
- `remember` is slow by design (extraction + graph build run inline). Don't wire it into hot paths that need sub-second acks.
- Multi-agent writes share one memory pool (that's the point). For isolation, ask for a dedicated basic-auth user + dataset partition instead of a second deployment.
- **The mcp container runs a LOCAL image** (`cognee/cognee-mcp:1.6.2-fixed`,
  `imagePullPolicy: IfNotPresent`): upstream mcp images pin PyPI cognee 1.5.4
  even on the v1.6.2 tag, whose migrations can't read the 1.6.2 DB — every MCP
  write fails with "Relational DB Migrations failed" until upstream bumps the
  lock. Any node rebuilt from scratch needs a re-import before the pod can
  schedule there: `cat ~/mcp-fixed-cognee-mcp-1.6.2.tar.gz | ssh <node> 'gunzip | sudo ctr -n k8s.io images import -'`.
  When upstream ships mcp images with cognee 1.6.2+, swap the tag back and
  delete the tar.
