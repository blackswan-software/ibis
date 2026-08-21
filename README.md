# ibis

![ci](https://github.com/HBDunn/blackswan-ibis/actions/workflows/ci.yml/badge.svg)

**Graph-driven coordination for any repo.** Drop ibis into a project and it gives
you a live system map (`GRAPH.dot`) whose nodes are *executable*: each carries a
health `check=`, a `doc=`, and a `test=`. ibis polls the checks, drains a
fire-and-forget message bus into `HANDOFF.md`, and refuses to let a node exist
without a check, a doc, and a test.

No broker. No daemon you have to run. Just files, `systemd --user` (or cron), and
git. That zero-dependency footprint is the point — ibis installs anywhere.

> Honest scope: ibis is a coordination *method*, not a silver bullet. A controlled
> benchmark (n=110, 3 models × 3 architectures) showed a measurable agent-assist
> effect on **one** task × one model+architecture combination only. Use it because
> a live, checkable map of your system is useful — not because of a headline number.

---

## Install

ibis is `bash` + `python3` + `git`. Two steps: put the CLI on your PATH, then
`ibis init` installs the per-repo scheduler using whatever your OS provides.

### macOS / Linux / WSL

```sh
git clone https://github.com/HBDunn/blackswan-ibis ~/.ibis-cli
~/.ibis-cli/install.sh          # symlinks ibis into ~/.local/bin, checks deps
ibis version
```

### Windows

ibis runs under **Git Bash** (install "Git for Windows") or **WSL**. From
PowerShell:

```powershell
git clone https://github.com/HBDunn/blackswan-ibis $env:USERPROFILE\.ibis-cli
& $env:USERPROFILE\.ibis-cli\install.ps1   # writes an ibis.cmd shim → bash, fixes PATH
# then use ibis from Git Bash:
ibis version
```

(WSL users can ignore the PowerShell script and just run `install.sh` inside WSL.)

### Per-repo scheduling — one concept, four backends

`ibis init` detects your platform and installs a **2-min timer** (runs the health
checks) plus an **instant-drain watcher** (delivers `.notify` messages in
sub-second time). No broker, no daemon you manage.

| Platform | Timer | Instant drain | Set up by |
|---|---|---|---|
| **Linux** | `systemd --user` `.timer` | `systemd` `.path` (PathExistsGlob) | `ibis init` |
| **macOS** | `launchd` `StartInterval` | `launchd` `WatchPaths` | `ibis init` |
| **Windows** | Task Scheduler `/sc minute` | PowerShell `FileSystemWatcher` (at-logon task) | `ibis init` |
| **any** | `cron` `*/2` | — (poll is the floor) | `ibis init` fallback |

Re-run or remove the scheduler anytime:

```sh
ibis install-scheduler      # (re)install for the current repo
ibis uninstall-scheduler    # remove it
```

Linux only: `loginctl enable-linger $USER` keeps the units running when you're
logged out. macOS `launchd` and Windows Task Scheduler persist by default.

Requirements: **`bash` ≥ 4** (macOS ships 3.2 — `brew install bash`), `python3`
(or `python`), `git`. Everything else (systemd/launchd/schtasks) is whatever your
OS already ships; `cron` is the universal fallback.

---

## Quickstart

```sh
cd your-repo
ibis init --adopt --name myproj   # --name optional (defaults to dir); names this
                                  # project everywhere (HANDOFF, message tags,
                                  # scheduler units, hub display) so two projects
                                  # don't get confused. Stored in .ibis/config.
ibis status              # run all checks now
ibis doctor              # verify every node has check + doc + test
```

`ibis init` creates:

```
your-repo/
├── .ibis/
│   ├── GRAPH.dot          # the system map (source of truth)
│   ├── .notify/           # fire-and-forget message bus
│   └── docs/<node>.md     # one required doc per node
├── tests/ibis/<node>.sh   # one required test per node
└── HANDOFF.md             # live status + inbox (auto-written)
```

---

## How do new nodes get created?

Three ways — **discovery is automatic, adoption is gated**:

1. **Auto-discovery** (`ibis discover`, run automatically by `ibis init`). ibis
   reads your repo's own structure and proposes candidate nodes:
   - `docker-compose.yml` / `compose.yaml` → one node per service
   - `Dockerfile` with `EXPOSE <port>` → an HTTP liveness node
   - `package.json` with a `start`/`serve`/`dev` script → an app node
   - `.github/workflows/*.yml` → a CI node
   - repo-local `*.service` systemd units → a service node

   Discovery never edits the graph on its own. It only *suggests*.

2. **Adoption** (`ibis init --adopt`, or `ibis add-node <name>`). Accepting a
   candidate — or adding one by hand — runs through one gate: **a node is not
   valid without a `check=`, a `doc=` (a real `.md`), and a `test=` (a real
   script).** ibis scaffolds the doc and test stubs for you so the contract is
   always satisfiable; it never silently skips them.

   ```sh
   ibis add-node payments --check 'curl -fsS localhost:8082/healthz >/dev/null' --poll
   # → writes .ibis/docs/payments.md + tests/ibis/payments.sh, inserts the node
   ```

3. **The gate** (`ibis doctor`). Wire it into CI. It fails the build if any node
   is missing a check, doc, or test; `--strict` also fails on un-written (stub)
   tests. This is what makes "tests required, docs required" real rather than
   aspirational.

So: you don't hand-author DOT. You point ibis at a repo, it proposes the nodes,
and the contract forces each one to come with the docs and tests that make the
map trustworthy.

---

## Coordinator mode — many repos, one HANDOFF

A single repo is the default. To watch several at once, make one of them (or a
dedicated directory) a **hub**: it drains every member repo's `.notify` bus and
runs every member's checks into one aggregate `HANDOFF.md`.

```sh
cd ~/work/coord
ibis hub init
ibis hub add ~/work/api
ibis hub add ~/work/web
ibis hub poll          # one HANDOFF: P0s + inbox across all members, tagged [repo/node]
```

Failures show as `FAIL [api/payments]`, messages as `[web] deploy finished`. A
hub-level bus (`.ibis-hub/.notify/`) carries cross-repo / hub-addressed notes.
`ibis hub poll --drain-only` is the instant path (reuses the last checks). A repo
polled by a hub shouldn't also run its own poll timer — the hub is the poller.

**Drift detection.** `ibis hub currency` fetches every member repo and reports
behind/ahead/diverged/dirty status in `REPO_STATE.md`. Run it on a timer or
before making claims about repo state — it catches the "I thought I was on the
latest" class of bugs before they compound.

## Multiple workers — identity + leases

Several people (or several Claude sessions) can work the same repos without
colliding. Two primitives, still just files:

- **Identity.** Every worker has an id — `IBIS_WORKER` if set (e.g. a Claude
  session id), else `user@host`. `ibis notify` attributes messages with it, so the
  inbox shows `[api] @alice: migration started`, not anonymous noise.
- **Leases.** `ibis claim <node>` writes an *expiring* lease. Another worker who
  tries to claim the same node is refused and told who holds it; the lease
  auto-expires (default 1h, `--ttl`), so a dead session never blocks anyone.

```sh
export IBIS_WORKER=alice
ibis claim payments            # "claimed payments as alice (ttl 3600s)"
ibis who                       # who's working what, with time left
ibis release payments          # or let it expire
ibis hub who                   # leases across every member repo
```

This replaces "commit-as-you-go discipline and hope" with a visible, self-healing
lock — the failure mode (one worker's work invisible to another) that bites every
shared-repo multi-agent setup.

## Keeping the graph in sync with commits

The graph is only useful if it matches reality. The classic failure: you *ship*
the work but forget to *mark it done* in the graph, so the next worker reads a
stale todo and redoes it (or reports it open).

ibis has a structural edge here: **the graph lives in the repo** (`.ibis/GRAPH.dot`),
so closing a node's `todo=` can ride in the *same commit* as the work — unlike a
centralized graph in a separate repo, which can't be updated atomically with the
code. `ibis hook install` installs three hooks:

```sh
ibis hook install                 # installs commit-msg + post-commit + pre-commit (if enabled)
export IBIS_HOOK_STRICT=1         # make warnings block instead of warn
```

**1. commit-msg — graph sync + doc coverage.** If a commit message reads like it
closes work (`fixed`, `done`, `shipped`, `scrub`, `complete`…) while open `todo=`
items exist and `.ibis/GRAPH.dot` isn't staged, the hook reminds you to clear the
todo in the same commit. Other workers read the graph, not your commit history.

**2. post-commit — auto-notify.** After every commit, automatically sends an
`ibis notify` with the commit hash, subject line, and changed files. This means
every commit is visible in the HANDOFF inbox — no manual notification needed.

**3. pre-commit — notify-required gate** (opt-in). Enable with
`require_notify=true` in `.ibis/config`. Blocks commits unless `ibis notify` was
called in the last 15 minutes (configurable: `notify_window=20`). Forces the
discipline of describing what you're about to do before you do it.

**Doc coverage.** The commit-msg hook also enforces that user-visible files are
*graph-tracked*, so a stale string in them is caught by a node's `test=` instead
of by a human. Add a `cover=` line to `.ibis/config` with comma-separated globs:

```
cover=*/install.sh,*/README.md,*/docs/*.json
```

Now a commit that touches a file matching one of those globs while **no** node
references it via `doc=` is flagged — add a node (with `doc=` + `test=`) for it.
This is the portable form of the pattern that closed a multi-round "the stale
string the test should have caught" loop. `ibis doctor` complements it by
validating `test=` refs *resolve* — a `path::Symbol` test whose symbol isn't
defined in that file (a stale pin) fails.

## Auditing — proving docs are true and not stale

`ibis doctor` proves the doc and test *files exist*. `ibis audit` goes further and
proves the docs are **honest**, three ways per node:

1. **Freshness (stamps).** Every doc carries `<!-- ibis-stamp: HASH -->`, a hash of
   its node's contract (`check`/`restart`/`doc`/`test`). `ibis add-node` writes it.
   Change the node in the graph without re-reviewing the doc → the stamp no longer
   matches → audit reports **STALE**. After you update the doc, run `ibis stamp
   <node>` to acknowledge it's current again.
2. **Truth (executable assertions).** A doc can contain fenced `ibis-assert`
   blocks. `ibis audit` *runs* each one and requires exit 0 — so the doc's claims
   are checked, not just asserted in prose:

   ````markdown
   ```ibis-assert
   curl -fsS localhost:8082/healthz | grep -q '"status":"ok"'
   ```
   ````

   If the system drifts from what the doc claims, the assertion fails and so does
   the audit.
3. **Behaviour (test runs).** `ibis audit` executes each node's `tests/ibis/<node>.sh`
   (skip with `--no-run`).

```sh
ibis audit            # stale docs, failed assertions, failing tests → non-zero exit
ibis audit --strict   # also fails on leftover TODO / unstamped docs
ibis stamp web        # mark web's doc reviewed after editing it
```

Exit non-zero on any stale doc, failed assertion, or failing test — so `ibis audit`
is a CI gate for *doc honesty*, complementing `ibis doctor`'s structural gate.

## Validating — proving metadata references are real

`ibis doctor` proves files *exist*. `ibis audit` proves they're *honest*. `ibis
validate` fills the gap between them: do the paths that nodes *reference* actually
resolve to real files on disk?

It checks every node's verifiable attributes:

1. **doc=/doc2=/doc3=** — does the referenced file exist?
2. **paths=** — does every listed path exist?
3. **test=** — does the test file exist? If it uses `::Symbol`, is the symbol defined?
4. **scenarios=** — does every scenario directory exist?
5. **todo=** — is an OPEN/EXECUTING item older than 21 days (stale)?
6. **check=/deploy=/restart=** — do referenced scripts exist? (not run, just resolved)

```sh
ibis validate                     # full validation
ibis validate --node gateway      # single node
ibis validate --json              # JSON report (for CI)
ibis validate --fix               # suggest fixes for stale todos
ibis validate --stale-days 14     # custom staleness threshold
```

Exit non-zero on errors — wire it into CI between `ibis doctor` and `ibis audit`
for the full integrity chain: structure → references → honesty.

## Messaging: polled floor, event-driven ceiling

The `.notify/` bus is fire-and-forget — drop a message, the next drain renders it
into `HANDOFF.md`:

```sh
ibis notify "registry returning 504s"
```

- **Floor:** a 2-min timer (`ibis poll`) runs the health checks and drains the
  bus — systemd `.timer`, launchd `StartInterval`, or cron. With only cron, this
  is the whole story.
- **Ceiling:** a file-watch (systemd `.path`, launchd `WatchPaths`, or a Windows
  `FileSystemWatcher`) triggers `ibis poll --drain-only` the instant a message
  lands — sub-second delivery, no broker. Health checks stay on the timer (the
  checked services emit no events, so there's nothing to push from); only
  *messaging* is event-driven.

A `flock` single-flight lock means the timer poll and the instant drain can never
double-process a message.

---

## Commands

| Command | What it does |
|---|---|
| `ibis init [--adopt] [--no-units]` | scaffold, auto-discover, install timers |
| `ibis discover` | list candidate nodes from repo structure |
| `ibis add-node <name> --check '…' [--poll] [--restart '…']` | add a node (+ doc/test stubs) |
| `ibis poll [--drain-only]` | run checks + drain bus (used by systemd) |
| `ibis status [--all]` | run checks now, report pass/fail |
| `ibis doctor [--strict]` | enforce check+doc+test on every node (CI gate) |
| `ibis audit [--strict] [--no-run]` | prove docs are true (assertions) + fresh (stamps) |
| `ibis validate [--node X] [--json] [--fix]` | prove metadata refs resolve to real files |
| `ibis stamp [<node>\|--all]` | (re)stamp docs after you've reviewed them |
| `ibis notify <message>` | drop a message on the bus (attributed to the worker) |
| `ibis project` | print this project's name (`.ibis/config` or dir name) |
| `ibis whoami` | print this worker's id (`IBIS_WORKER` or `user@host`) |
| `ibis ledger <node> [value]` | record / show a node's measured trend over time |
| `ibis claim <node> [--ttl N]` | lease a node so other workers don't collide |
| `ibis release <node> [--force]` | release your lease |
| `ibis who` | active claims in this repo (expired ones swept) |
| `ibis node <name> [--edges] [--depth N]` | DFS node lookup (never read the graph flat) |
| `ibis render [--open]` | regenerate `graph.html` from `GRAPH.dot` (interactive WASM viewer) |
| `ibis audit-log [--strict]` | run audit + append timestamped result to `.ibis/audit.log` |
| `ibis hub <init\|add\|poll\|who\|currency\|…>` | coordinator: aggregate many repos into one HANDOFF |
| `ibis hub currency` | multi-repo drift detection — writes `REPO_STATE.md` |
| `ibis hook <install\|uninstall>` | git hook: keep `.ibis/GRAPH.dot` in sync with commits |

---

## Use the contract as your CI gate

`ibis doctor --strict` exits non-zero if any node lacks a real check, doc, or
(non-stub) test. Drop this in **your** repo to keep the map honest on every push:

```yaml
# .github/workflows/ibis.yml
name: ibis
on: [push, pull_request]
jobs:
  doctor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          git clone --depth 1 https://github.com/HBDunn/blackswan-ibis ~/.ibis-cli
          ~/.ibis-cli/install.sh && echo "$HOME/.local/bin" >> "$GITHUB_PATH"
      - run: ibis doctor --strict   # structure: every node has check + doc + test
      - run: ibis validate          # references: doc=, paths=, test= point to real files
      - run: ibis audit             # honesty: docs fresh, assertions true, tests pass
```

ibis's own CI (`.github/workflows/ci.yml`) runs the full CLI on Ubuntu, macOS, and
Windows. It hard-asserts init/discover/add-node, the doctor gate, and the
notify→drain path on all three, and validates launchd plists (`plutil -lint`) on
macOS and the FileSystemWatcher script on Windows. It does **not** assert that the
file-watch trigger physically fires — that needs an interactive session, so verify
it once by hand on a real (or VM) macOS/Windows box.

## Using ibis from non-Claude agents (MCP)

ibis is model-agnostic by construction (files + git + shell). `ibis mcp` runs a stdio
MCP server (hand-rolled JSON-RPC, no SDK dependency — python3 only) so any MCP agent
(Cursor, Codex, Gemini, Claude…) consumes the coordination layer natively:

```json
{ "mcpServers": { "ibis": { "command": "ibis", "args": ["mcp"] } } }
```

Tools: read — `ibis_status`, `ibis_open_todos`, `ibis_node`, `ibis_doctor`,
`ibis_audit`, `ibis_validate`, `ibis_who`, `ibis_ledger`; write — `ibis_claim`, `ibis_release`,
`ibis_notify`, `ibis_ledger_record` (the multi-agent-coordination differentiator vs
read-only code-graph servers; `--read-only` hides them). Resources: `ibis://handoff`,
`ibis://graph`, `ibis://node/<id>/doc`, `ibis://ledger/<node>`.

Pairs with code-retrieval MCP servers: **CodeGraph answers "what is this code"; ibis
answers "what's the state of the system + who's doing what."** Design: [docs/mcp.md](docs/mcp.md).

## Visualizing the graph

The graph is Graphviz DOT — render it with any tool that reads `.dot`:

```sh
# Interactive WASM viewer (no graphviz install needed — client-side rendering)
ibis render --open           # regenerates graph.html from GRAPH.dot, opens in browser

# SVG (best for browsers — zoomable, searchable)
dot -Tsvg .ibis/GRAPH.dot -o graph.svg

# PNG (quick preview)
dot -Tpng .ibis/GRAPH.dot -o graph.png

# Interactive (if you have xdot)
xdot .ibis/GRAPH.dot
```

`ibis render` creates a self-contained `graph.html` in your repo root. It uses
`@viz-js/viz` (WASM graphviz) loaded from CDN — the HTML file works offline after
the first load. Features: zoom/pan, node search, click-to-inspect attributes, SVG
export.

For DFS node lookup (agents should use this instead of reading the whole graph):
```sh
ibis node gateway --edges           # show node + incoming/outgoing edges
ibis node gateway --edges --depth 2 # follow edges 2 levels deep
```

For large graphs, filter to a subgraph:
```sh
# Show only a node and its neighbors
grep -E '(mynode|->.*mynode|mynode.*->)' .ibis/GRAPH.dot
```

Online renderers like [dreampuf.github.io/GraphvizOnline](https://dreampuf.github.io/GraphvizOnline)
work for quick sharing — paste the DOT source.

---

## Templates

ibis ships templates for the methodology docs that make the coordination
framework work. Copy and customize them for your project:

```sh
ls ~/.ibis-cli/templates/
```

| Template | Purpose |
|---|---|
| `CLAUDE.md.tmpl` | AI agent rules — session start order, DFS traversal, notify discipline |
| `SESSION.md.tmpl` | Session handoff — what you worked on, what's unfinished |
| `RECOVERY.md.tmpl` | Incident case files — symptom, root cause, fix, prevention |
| `PRIORITIES.md.tmpl` | Priority queue — P0-P3 with auto-population from health checks |
| `NO_GO_LIST.md.tmpl` | Decision exclusions — things explicitly not in the plan |
| `graph.html` | Interactive WASM graph viewer — used by `ibis render` |

Usage:
```sh
cp ~/.ibis-cli/templates/CLAUDE.md.tmpl CLAUDE.md
# Edit PROJECT_NAME and customize for your project
```

See [docs/ai-agents.md](docs/ai-agents.md) for the full agent configuration guide.

---

## Documentation

| Doc | What it covers |
|---|---|
| [docs/nodes.md](docs/nodes.md) | Node contract, discovery, adoption, auditing, multi-check, todo lifecycle |
| [docs/mcp.md](docs/mcp.md) | MCP server design — tools, resources, read-only mode |
| [docs/workflow.md](docs/workflow.md) | Full lifecycle: design → graph → implement → test → measure → close |
| [docs/ai-agents.md](docs/ai-agents.md) | Configuring Claude/Cursor/Codex to use ibis — CLAUDE.md, settings, MCP |
| [docs/metrics.md](docs/metrics.md) | Metrics methodology — what to measure, thresholds, ledger integration |

## License

MIT. See [LICENSE](LICENSE).
