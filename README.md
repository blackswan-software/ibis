# ibis

![ci](https://github.com/HBDunn/blackswan-ibis/actions/workflows/ci.yml/badge.svg)

**Graph-driven coordination for AI-assisted repos.** Humans run `ibis init`.
After that, AI agents and git hooks do the rest. ibis gives every agent a
shared map, a message bus, and discipline hooks — so multiple AI sessions
can work the same repo without colliding, losing context, or shipping broken
work.

No broker. No daemon. Just files, git, and a system timer. ibis installs
anywhere bash, python3, and git run.

---

## How it works

```
Human: ibis init          ← one time, per repo
                ↓
    ┌───────────────────────────────┐
    │  Scheduler (every 2 min)     │
    │  • runs health checks        │
    │  • drains message bus         │
    │  • writes HANDOFF.md         │
    └───────────────────────────────┘
                ↓
    ┌───────────────────────────────┐
    │  AI agent reads HANDOFF.md   │
    │  • ibis node X --context     │  ← one command: graph + doc + recovery
    │  • does the work             │     + priorities + ledger + leases
    │  • ibis notify + commit      │
    │  • ibis ledger (prove it)    │
    └───────────────────────────────┘
                ↓
    ┌───────────────────────────────┐
    │  Git hooks (automatic)       │
    │  • pre-commit: was notify    │
    │    called? block if not      │
    │  • post-commit: auto-notify  │
    │    with hash + changed files │
    │  • doc-drift: fix without    │
    │    doc update? warn          │
    └───────────────────────────────┘
```

**The human reviews diffs and approves commits.** Everything else is automated.

---

## Install

```sh
git clone https://github.com/HBDunn/blackswan-ibis ~/.ibis-cli
~/.ibis-cli/install.sh
```

Windows: runs under Git Bash or WSL. PowerShell users: `install.ps1` writes
an `ibis.cmd` shim.

Requirements: `bash` ≥ 4 (macOS: `brew install bash`), `python3`, `git`.

---

## Setup (one command)

```sh
cd your-repo
ibis init --adopt
```

This does everything:
- Discovers nodes from your repo structure (Dockerfiles, compose files, CI workflows)
- Creates `.ibis/GRAPH.dot` with health checks, docs, and test stubs
- Installs git hooks (notify enforcement, doc-drift detection, auto-logging)
- Installs a 2-min scheduler (systemd/launchd/Task Scheduler/cron)
- Starts writing `HANDOFF.md` automatically

After init, the repo is live. Health checks run every 2 minutes. The message
bus drains in sub-second time. `HANDOFF.md` updates itself.

---

## What the AI agent does (via CLAUDE.md rules)

The `CLAUDE.md` template (`ibis init` generates it) tells the agent:

### Before touching any node

```sh
ibis node gateway --context
```

One command returns everything the agent needs (~50-100 lines):
- Node definition (check=, restart=, doc=, test= attributes)
- Incoming and outgoing edges (what depends on this)
- Doc summary (first 30 lines of the doc= file)
- RECOVERY.md entries mentioning this node
- PRIORITIES.md entries mentioning this node
- HANDOFF.md entries (what's broken, what's in the inbox)
- Last 5 ledger measurements
- Active leases (is someone else working on this?)

This replaces reading 4-5 separate files. Fewer tokens, no steps to skip.

### Before committing

```sh
ibis notify "fixed the gateway timeout — increased pool size to 20"
```

The pre-commit hook blocks the commit if notify wasn't called. The agent
must describe what it did before it can commit. After commit, the
post-commit hook auto-logs the commit hash and changed files to the bus.

### After fixing something

```sh
ibis ledger gateway 200 "response time ms after pool fix"
```

A measurement, not a claim. The ledger is append-only with timestamps
and commit hashes. `ibis audit` catches docs that went stale.

### When editing shared files

```sh
ibis claim gateway --ttl 1800     # lease it for 30 min
# ... do the work ...
ibis release gateway
```

Another session trying to claim the same node is refused and told who
holds it. Leases auto-expire — a crashed session never blocks anyone.

---

## What the hooks enforce

| Hook | When | What it does |
|---|---|---|
| pre-commit | Every commit | Blocks if `ibis notify` wasn't called recently |
| pre-commit | Every commit | Warns if fix-language commit has no doc update staged |
| post-commit | Every commit | Auto-notifies with commit hash + subject + changed files |
| commit-msg | Every commit | Warns if open `todo=` items exist and graph isn't staged |

Install with `ibis init` (automatic) or `ibis hook install` (manual).

---

## What the scheduler does

`ibis init` detects your platform and installs:

| Platform | Timer (health checks) | Instant drain (messages) |
|---|---|---|
| Linux | systemd `.timer` (2 min) | systemd `.path` (sub-second) |
| macOS | launchd `StartInterval` | launchd `WatchPaths` |
| Windows | Task Scheduler | PowerShell `FileSystemWatcher` |
| any | cron `*/2` | — (poll is the floor) |

Re-run: `ibis install-scheduler`. Remove: `ibis uninstall-scheduler`.

---

## CI gates

Wire ibis into your pipeline — these are the three integrity gates:

```yaml
# .github/workflows/ibis.yml
- run: ibis doctor --strict   # structure: every node has check + doc + test
- run: ibis validate          # references: doc=, paths=, test= resolve to real files
- run: ibis audit             # honesty: docs fresh, assertions true, tests pass
```

---

## Multi-repo coordination (hub)

Watch several repos from one place:

```sh
ibis hub init
ibis hub add ~/work/api
ibis hub add ~/work/web
ibis hub poll        # one HANDOFF across all repos
ibis hub currency    # which repos are behind/ahead/diverged
```

Failures show as `FAIL [api/payments]`. Messages show as `[web] deploy finished`.

---

## MCP server (any AI agent)

ibis is model-agnostic. `ibis mcp` runs a stdio MCP server so any MCP
client (Cursor, Codex, Gemini, Claude) uses the coordination layer:

```json
{ "mcpServers": { "ibis": { "command": "ibis", "args": ["mcp"] } } }
```

12 tools (8 read, 4 write). `--read-only` hides write tools for monitoring
agents. Design: [docs/mcp.md](docs/mcp.md).

---

## Graph visualization

```sh
ibis render --open    # interactive WASM viewer in browser (no graphviz needed)
ibis node X --context # DFS lookup (agents use this, never read the graph flat)
```

---

## Auditing and proof

ibis proves docs are **honest**, not just present:

1. **Freshness** — stamp hash tracks the node's contract. Change the node
   without updating the doc → audit reports STALE.
2. **Truth** — fenced `ibis-assert` blocks in docs are executed. If the
   system drifts from what the doc claims, audit fails.
3. **Behaviour** — node tests run during audit.

```sh
ibis audit --strict   # CI gate for doc honesty
ibis stamp gateway    # acknowledge doc is current after review
```

---

## All commands

Setup:
- `ibis init [--adopt]` — scaffold, discover, hooks, scheduler
- `ibis add-node <name> --check '…'` — add a node manually

For AI agents (CLAUDE.md rules):
- `ibis node <name> --context` — everything before acting
- `ibis notify <message>` — describe what you're about to do
- `ibis claim/release <node>` — lease management
- `ibis ledger <node> [value] [note]` — measurements
- `ibis status [--all]` — health checks

Automatic (hooks + scheduler + CI):
- `ibis poll` — checks + bus drain (scheduler)
- `ibis doctor [--strict]` — structure gate (CI)
- `ibis audit [--strict]` — honesty gate (CI)
- `ibis validate [--node X]` — reference gate (CI)
- `ibis hook install/uninstall` — git hooks
- `ibis stamp [<node>]` — re-stamp docs after review

Coordinator:
- `ibis hub init/add/poll/who/currency` — multi-repo
- `ibis mcp [--read-only]` — MCP server
- `ibis render [--open]` — graph visualization

---

## Templates

```sh
ls ~/.ibis-cli/templates/
```

| Template | Purpose |
|---|---|
| `CLAUDE.md.tmpl` | AI agent rules — the real "user manual" |
| `SESSION.md.tmpl` | Session handoff — what you worked on |
| `RECOVERY.md.tmpl` | Incident case files |
| `PRIORITIES.md.tmpl` | Priority queue (P0-P3) |
| `graph.html` | Interactive WASM graph viewer |

---

## Documentation

| Doc | What it covers |
|---|---|
| [docs/nodes.md](docs/nodes.md) | Node contract, discovery, auditing |
| [docs/mcp.md](docs/mcp.md) | MCP server design |
| [docs/workflow.md](docs/workflow.md) | Full SDLC lifecycle with ibis |
| [docs/ai-agents.md](docs/ai-agents.md) | Configuring Claude/Cursor/Codex |
| [docs/metrics.md](docs/metrics.md) | What to measure, ledger integration |

## License

MIT. See [LICENSE](LICENSE).
