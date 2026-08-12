# Nodes: the contract and how they're generated

A node in `.ibis/GRAPH.dot` is a unit of the system you want to keep healthy and
documented. Every node is held to one contract.

## The contract

| Attribute | Required | Meaning |
|---|---|---|
| `check=` | yes (except root) | shell command; exit 0 = healthy |
| `doc=`   | yes | path to a `.md` that must exist on disk |
| `test=`  | yes | path to a test script that must exist on disk |
| `poll="fast"` | no | run this check on the 2-min timer (else on-demand only) |
| `restart=` | no | remediation command, run by a human/agent after diagnosis |
| `todo=` | no | active work item for this node |

`ibis doctor` enforces the three required attributes and fails (non-zero) on any
violation, so it works as a CI gate. `ibis doctor --strict` additionally fails on
test scripts that are still stubs (contain `STUB`).

The **root node** (the `digraph <name>` identifier) is structural — it represents
the repo itself and is exempt from `check=`, but still needs a doc and test.

## Why check AND test?

They answer different questions:

- `check=` is a **liveness probe** — fast, cheap, run every 2 minutes. "Is it up
  right now?" (`curl`, `docker compose ps`, `systemctl is-active`).
- `test=` is a **behavioral assertion** — run on demand / in CI. "Does it actually
  do the right thing?" A check can be green while behavior is broken; the test is
  where you encode the real contract.

## How nodes get generated

```
repo structure ──ibis discover──▶ candidates ──ibis add-node──▶ node + doc + test
                  (automatic)                   (gated: contract enforced)
```

### 1. Discovery (automatic, read-only)

`ibis discover` scans for, and proposes a node per:

- **compose service** — `services:` keys in `docker-compose.yml` / `compose.yaml`
  → `check="docker compose ps -q <svc> | grep -q ."`
- **Dockerfile `EXPOSE <port>`** → `check="curl -fsS http://localhost:<port>/ >/dev/null"`
- **`package.json`** with a `start`/`serve`/`dev` script → an app node (you set the check)
- **`.github/workflows/*.yml`** → a CI node (`gh run list` conclusion)
- **repo-local `*.service`** → `check="systemctl --user is-active <unit> | grep -qx active"`

Discovery suggests a check but never writes the graph. `ibis init` runs it for you
and, with `--adopt`, feeds each candidate into `add-node`.

### 2. Adoption (gated)

`ibis add-node <name> --check '<cmd>' [--poll] [--restart '<cmd>']`:

1. derives a graphviz-safe node id from the name,
2. refuses duplicates,
3. requires a check (prompts if interactive, else `--check` is mandatory),
4. **creates the doc stub** (`.ibis/docs/<id>.md`) from a template,
5. **creates the test stub** (`tests/ibis/<id>.sh`) from a template,
6. inserts the node block + an edge from the root into `GRAPH.dot`.

Adopted candidates whose discovered check was a placeholder (a bare `# TODO`) are
inserted with a deliberately failing check (`false # TODO …`) so `ibis status` and
`ibis doctor` keep nagging until you write a real one — better a loud red than a
silent green lie.

### 3. The gate (`ibis doctor`)

Run it locally and in CI. A node that someone added by editing `GRAPH.dot`
directly, without a doc or test, fails here. That is what turns "docs and tests
required" from a guideline into an invariant.

## Auditing: proving docs are true and fresh

`ibis doctor` checks the *files exist*. `ibis audit` proves the docs are *honest*:

- **Freshness (stamp).** Each doc ends with `<!-- ibis-stamp: HASH -->`, a `cksum`
  of the node's contract string (`check|restart|doc|test`). `ibis add-node` and
  `ibis init` write it; `ibis audit` recomputes and compares. If the node's
  contract changed but the doc wasn't re-reviewed, the hash differs → **STALE**.
  `ibis stamp <node>` re-stamps after you've updated the doc. This is precise (no
  date-guessing): the doc is provably in sync with the node's actionable attributes
  or it fails.
- **Truth (assertions).** Fenced ` ```ibis-assert ` blocks in the doc are extracted
  and run under `bash -e`; every block must exit 0. This is how a doc *proves* its
  claims rather than just stating them. Example:

  ````markdown
  ```ibis-assert
  test -f /etc/myservice/config.yml
  curl -fsS localhost:9000/version | grep -q '2\.'
  ```
  ````
- **Behaviour (test).** `ibis audit` runs `tests/ibis/<node>.sh` (skip with
  `--no-run` for a docs-only audit).

Severity: a stale stamp, a failed assertion, or a failing test is a **failure**
(non-zero exit). Leftover `TODO` text and missing stamps/assert-blocks are **notes**
under plain `audit`, and become failures under `audit --strict`.

Why the stamp covers the *contract* and not the doc prose: editing prose shouldn't
trip the audit, but changing what the node *does* (its check or remediation) must
force a doc re-review. The stamp captures exactly that boundary.

## Recovery loops: proof that persists across context resets

Some nodes track a metric you drive up over *many* sessions — sandbox ok-rate, test
coverage, perf, error count. These have a notorious failure mode: each session
re-derives the root cause (burning its whole context budget), runs out before it can
measure, declares a false "shipped, looks good," and the next session starts over.
Work *resets* instead of *compounding*. (BlackSwan lived this: 6 weeks to 0.62% on a
training corpus.)

ibis's node primitives compose into the fix — make the proof durable and the
work-unit atomic:

| Need | ibis primitive |
|---|---|
| Capture root cause **once** (don't re-derive) | the node's **doc** = a case file |
| "Done" = a **measurement**, not a probe | the node's **`check=`** = the metric; `ibis-assert` runs it |
| Prove the doc is still true + fresh | `ibis audit` (assertions + stamp) |
| The measured **trend** (compounding proof) | `ibis ledger <node> <value>` |
| Proof rides with the commit | `ibis hook` (graph-sync commit-msg gate) |
| One unit per commit (fits one context window) | discipline: one node × one fix × one measurement |

The rule that ties it together: **never mark a recovery node "done" off a probe or a
healthy process — only off a measured value recorded in its ledger.** The next
session reads the case file + ledger (cheap) instead of re-deriving (expensive), so
the loop closes and the trend climbs. This is exactly the framework the BlackSwan hub
hard-codes for ecosystem ok-rate (case file + `measure-ok-rate.sh` + `ECO_RATE_LEDGER`
+ a pre-commit gate); `ibis ledger` + the doc/audit/hook primitives are its portable
form.

## Multiple checks per node

A node with one health dimension gets `check=`. Nodes with several independent
health signals use numbered attributes:

```dot
apiGateway [
  check="curl -fsS localhost:8080/healthz",
  check2="curl -fsS localhost:8080/metrics | grep -q up",
  check3="test $(curl -s localhost:8080/queue/depth) -lt 1000",
  doc=".ibis/docs/api-gateway.md",
  test="tests/ibis/api-gateway.sh"
];
```

`ibis status` and `ibis poll` run all `check`, `check2`, `check3`, ... attributes.
Each is reported independently — a node can be "liveness OK, metrics DOWN, queue OK".
This prevents "green on the probe, broken on the data" failures where a single
health check masks a real problem.

Use multi-check when:
- The node has distinct failure modes (liveness vs correctness vs capacity)
- A single check would mask partial failures
- Different checks have different remediation paths

## Todo lifecycle

The `todo=` attribute tracks active work on a node. It follows a simple
state machine:

```
  (empty)  →  OPEN  →  EXECUTING  →  DONE / FIXED
                ↑          |
                └──────────┘  (blocked → re-open)
```

### States

| State | Meaning | Example |
|---|---|---|
| `todo="OPEN: migrate to v2 schema"` | Work identified, not started | Backlog item |
| `todo="EXECUTING: @alice migrating schema"` | Claimed, in progress | Active work |
| `todo="DONE (2026-08-12): v2 schema shipped"` | Completed with date | Closed |
| `todo="FIXED (2026-08-12): rate limiter tuned"` | Bug/incident resolved | Closed |

### Rules

- **OPEN → EXECUTING**: claim the node first (`ibis claim <node>`)
- **EXECUTING → DONE/FIXED**: record a measurement (`ibis ledger`), update the
  doc, and clear the todo in the same commit as the fix
- The commit-msg hook (`ibis hook`) catches commits that use completion language
  without staging `GRAPH.dot` — preventing stale todos that other workers read
  as still-open
- `ibis validate --stale-days 21` flags OPEN/EXECUTING todos older than 21 days

### Archiving

When a todo reaches DONE/FIXED, you can either:
- Remove the `todo=` attribute entirely (clean graph)
- Leave it as `todo="DONE ..."` for audit trail (ibis ignores DONE in staleness checks)

Move the completed item to the `## Completed` section of PRIORITIES.md with date
and commit hash.

## Editing by hand

You can always edit `GRAPH.dot` directly — it's the source of truth and meant to be
read and diffed. Just run `ibis doctor` afterward; if you added a node, create its
doc and test (or re-run `ibis add-node` which scaffolds them).
