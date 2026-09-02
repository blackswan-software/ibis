# ibis

![ci](https://github.com/HBDunn/blackswan-ibis/actions/workflows/ci.yml/badge.svg)
![license](https://img.shields.io/badge/license-MIT-blue)
![deps](https://img.shields.io/badge/deps-bash%20%2B%20python3%20%2B%20git-lightgrey)

**Graph-driven coordination for AI-assisted repos.** A shared map, a message
bus, and git hooks that enforce discipline — so multiple AI sessions can work
the same repo without colliding, losing context, or shipping unproven work.

No broker. No daemon. Just files, git, and a system timer.

---

## The problem

You added AI agents. You didn't add a coordination layer. Four things follow:

- **Amnesia.** A session has no memory. Without a handoff, the next one
  re-derives what the last one figured out — burning its context window on
  archaeology instead of progress.
- **False victories.** An agent reports "fixed" because a probe passed. A
  passing probe is not a measurement. "Fixed" becomes a guess nobody can verify.
- **State collisions.** Session A edits `auth.py`. Session B edits `auth.py`.
  Neither knows the other exists.
- **Context bloat.** An agent that reads your whole repo to find what matters
  wastes most of its window and still misses things.

ibis fixes these with a graph whose nodes are executable, a file-based bus, and
hooks that make skipping steps a blocked commit rather than a bad habit.

Full argument and industry evidence: **[docs/why.md](docs/why.md)**.

---

## How it works

```
Human: ibis init          ← one time, per repo
                ↓
    ┌───────────────────────────────┐
    │  Scheduler (every 2 min)      │
    │  • runs health checks         │
    │  • drains message bus         │
    │  • writes HANDOFF.md          │
    └───────────────────────────────┘
                ↓
    ┌───────────────────────────────┐
    │  AI agent reads HANDOFF.md    │
    │  • ibis node X --context      │  ← one command: graph + doc + recovery
    │  • does the work              │     + priorities + ledger + leases
    │  • ibis notify + commit       │
    │  • ibis ledger (prove it)     │
    └───────────────────────────────┘
                ↓
    ┌───────────────────────────────┐
    │  Git hooks (tracked in-repo)  │
    │  • invariant guard: block a   │
    │    commit that reverts a      │
    │    recorded design decision   │
    │  • pre-commit: was notify     │
    │    called? block if not       │
    │  • post-commit: auto-notify   │
    └───────────────────────────────┘
```

**The human reviews diffs and approves commits.** Everything else is automated.

---

## Install

```sh
git clone https://github.com/HBDunn/blackswan-ibis ~/.ibis-cli
~/.ibis-cli/install.sh
```

Windows: Git Bash or WSL. PowerShell users — `install.ps1` writes an `ibis.cmd`
shim. Requirements: `bash` ≥ 4 (macOS: `brew install bash`), `python3`, `git`.

## Setup — one command

```sh
cd your-repo
ibis init --adopt
```

Discovers nodes from your repo structure, writes `.ibis/GRAPH.dot` with health
checks and doc/test stubs, installs tracked git hooks, installs a 2-min
scheduler, and starts writing `HANDOFF.md`. After init the repo is live.

Then, from an agent session:

```sh
ibis node gateway --context     # everything about a node, in one call
ibis notify "raised the pool size to 20"
ibis ledger gateway 200 "response time ms after fix"
```

Full walkthrough: **[docs/getting-started.md](docs/getting-started.md)**.

---

## Honest scope

ibis is a coordination *method*, not a silver bullet. A controlled benchmark
(n=110, 3 models × 3 architectures) showed a measurable agent-assist effect on
**one** task × one model+architecture combination only. Use it because a live,
checkable map of your system is useful — not because of a headline number.

---

## What you get

| | |
|---|---|
| **Executable graph** | Every node carries `check=`, `doc=`, `test=`. `ibis doctor` refuses nodes missing any of the three. |
| **Design invariants** | A node can declare `invariant=`. Commits touching it are blocked until acknowledged — decisions stop getting silently reverted. |
| **Message bus** | `.notify/` drop dirs, sub-second drain into `HANDOFF.md`. No broker. |
| **Leases** | `ibis claim` / `release`, auto-expiring. A crashed session never blocks anyone. |
| **Ledger** | Append-only measurements with timestamps and commit hashes. "Fixed" means measured. |
| **Audit** | Fenced `ibis-assert` blocks in docs are executed. Docs that drift from reality fail. |
| **Hub mode** | One HANDOFF across many repos. |
| **MCP server** | Model-agnostic — Cursor, Codex, Gemini, Claude. 12 tools, `--read-only` available. |

---

## CI gates

```yaml
- run: ibis doctor --strict   # structure: every node has check + doc + test
- run: ibis validate          # references: doc=, paths=, test= resolve
- run: ibis audit             # honesty: docs fresh, assertions true, tests pass
```

---

## Documentation

| Doc | What it covers |
|---|---|
| [docs/why.md](docs/why.md) | The problem, the evidence, guardrailing agents |
| [docs/getting-started.md](docs/getting-started.md) | Install, init, graph, hooks, CI — step by step |
| [docs/nodes.md](docs/nodes.md) | Node contract, `invariant=`, discovery, auditing |
| [docs/workflow.md](docs/workflow.md) | Full SDLC lifecycle with ibis |
| [docs/ai-agents.md](docs/ai-agents.md) | Configuring Claude / Cursor / Codex |
| [docs/mcp.md](docs/mcp.md) | MCP server design |
| [docs/metrics.md](docs/metrics.md) | What to measure, ledger integration |

Command reference: `ibis help`, or `ibis <command> --help`.

---

## Support

Questions, bugs, and feature requests:
[issues](https://github.com/HBDunn/blackswan-ibis/issues).

Teams adopting ibis at scale can also get hands-on training and workshops —
see [blackswan-software.com](https://blackswan-software.com) for details.

## License

MIT. See [LICENSE](LICENSE).
