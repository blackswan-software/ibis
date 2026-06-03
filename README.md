# ibis

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

```sh
git clone https://github.com/blackswan-software/ibis ~/.ibis-cli
ln -s ~/.ibis-cli/bin/ibis ~/.local/bin/ibis   # anywhere on $PATH
ibis version
```

Requirements: `bash`, `python3`, `git`. Optional: `systemd --user` (instant
delivery + timers) or `cron` (2-min polling).

---

## Quickstart

```sh
cd your-repo
ibis init --adopt        # scaffold + auto-discover services + install timers
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

## Messaging: polled floor, event-driven ceiling

The `.notify/` bus is fire-and-forget — drop a message, the next drain renders it
into `HANDOFF.md`:

```sh
ibis notify "registry returning 504s"
```

- **Floor:** a 2-min `systemd` timer (`ibis poll`) runs the health checks and
  drains the bus. With only cron available, this is the whole story.
- **Ceiling:** a `systemd` `.path` unit watches `.notify/*.pending` and triggers
  `ibis poll --drain-only` the instant a message lands — sub-second delivery, no
  broker. Health checks stay on the timer (the checked services emit no events,
  so there's nothing to push from); only *messaging* is event-driven.

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
| `ibis notify <message>` | drop a message on the bus |

---

## License

MIT. See [LICENSE](LICENSE).
