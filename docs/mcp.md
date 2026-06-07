# ibis MCP server — spec

**Status: spec (not yet implemented).** Goal: expose ibis's coordination layer over
the Model Context Protocol so *any* MCP-speaking agent — Cursor, Codex, Gemini,
OpenCode, Claude — consumes ibis natively (structured tools + resources) instead of
shelling out and parsing text.

## Why

ibis is already model-agnostic (files + git + shell). But non-shell agent harnesses
integrate via MCP, not by running `ibis` in a terminal. An MCP server makes ibis a
first-class citizen in those stacks and pairs cleanly with code-retrieval MCP servers
(CodeGraph, Claude Context): **CodeGraph answers "what is this code"; ibis answers
"what's the state of the system + who's doing what."** Retrieval + coordination, both
over the same protocol.

Differentiator vs code-graph MCP servers: those are read-only retrieval. ibis exposes
**write** coordination too — an agent can *claim* work (a lease), *notify*, and record
a *measurement*. That's multi-agent coordination over MCP, which retrieval servers
don't do.

Scope: this is the **public-ibis** feature. The BlackSwan hub stays centralized + shell
(`poll.sh`/`GRAPH.dot`); it does **not** get an MCP server.

## Transport & launch

- `ibis mcp` starts a **stdio** MCP server (JSON-RPC 2.0 over stdin/stdout — the
  standard local transport). No network port.
- Operates on the repo for the cwd (or `ibis mcp --repo <path>`), resolving `.ibis/`
  exactly like the CLI. Multi-repo: `ibis mcp --hub` serves an `ibis hub` aggregate
  (qualified `project:node` refs).
- Agent config (example, Claude Code / Cursor `mcpServers`):
  ```json
  { "mcpServers": { "ibis": { "command": "ibis", "args": ["mcp"] } } }
  ```

## Tools (the agent calls these)

Read:
| tool | args | returns | wraps |
|---|---|---|---|
| `ibis_status` | `{all?:bool}` | per-node pass/fail | `ibis status` |
| `ibis_open_todos` | `{}` | nodes with open `todo=` | grep `todo="` |
| `ibis_node` | `{node}` | label/check/doc/test/restart/todo + doc body | graph + doc file |
| `ibis_neighbors` | `{node}` | upstream/downstream edges (cross-repo in `--hub`) | graph edges |
| `ibis_doctor` | `{strict?:bool}` | contract violations | `ibis doctor` |
| `ibis_audit` | `{strict?:bool}` | stale/false-claim findings | `ibis audit` |
| `ibis_who` | `{}` | active leases (worker, node, ttl left) | `ibis who` |
| `ibis_ledger` | `{node}` | measured trend | `ibis ledger <node>` |

Write (the coordination differentiator — gated, explicit):
| tool | args | effect |
|---|---|---|
| `ibis_claim` | `{node, ttl?}` | take a lease; **refuses** if held by another live worker (returns holder) |
| `ibis_release` | `{node}` | release own lease |
| `ibis_notify` | `{message}` | drop attributed message on the bus |
| `ibis_ledger_record` | `{node, value, note?}` | append a measured value |

Worker identity = `IBIS_WORKER` (the agent sets it, e.g. its session id) → leases +
messages are attributed. Writes are always explicit tool calls; the server never
mutates on a read.

## Resources (read-only context the agent can attach)

- `ibis://handoff` — current HANDOFF.md
- `ibis://graph` — GRAPH.dot (topology)
- `ibis://node/<id>/doc` — a node's doc/case file
- `ibis://ledger/<node>` — a node's measured trend

Resources let an agent *pin* live coordination state into its context without a tool
round-trip — the inverse of CodeGraph pinning code structure.

## Security / scoping

- Read tools and resources expose only `.ibis/` artifacts (graph, docs, HANDOFF,
  ledger) — never `.env`/secrets; the server refuses paths outside the repo's `.ibis/`
  and tracked docs.
- Writes are limited to bus/lease/ledger files. No tool runs arbitrary shell; checks
  run only the graph's own `check=` (same trust boundary as `ibis poll`).
- `--read-only` flag disables all write tools for untrusted agents.

## Implementation sketch (when built)

- `lib/mcp_server.py` using the official MCP Python SDK; `ibis mcp` execs it via
  `$PYTHON`. Each tool shells to the existing `ibis` subcommand (or reads `.ibis/`
  directly) and returns structured JSON — so the MCP server is a thin adapter over the
  CLI, not a reimplementation.
- Keep the bash CLI authoritative; the MCP server is one more consumer of the same
  `.ibis/` substrate (like poll.sh and the hooks).
- Pairs with a code-retrieval MCP server in the same agent: CodeGraph for code, ibis
  for coordination.

## Out of scope (for v1)

- Network/SSE transport (stdio only).
- Auth beyond `--read-only` (local-agent trust model).
- Hub federation tools beyond aggregate read (`--hub` read first; write-through later).
