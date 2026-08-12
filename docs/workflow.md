# ibis Workflow — From Design to Done

The full lifecycle of work in an ibis-managed project. Each phase has a
corresponding ibis primitive.

## The lifecycle

```
Design  →  Graph Node  →  Implement  →  Test  →  Measure  →  Close
  ↓           ↓              ↓           ↓         ↓          ↓
doc.md    GRAPH.dot      code + CI    test=     ledger     todo=DONE
```

### 1. Design

Write a doc describing what you're building and why. This becomes the node's
`doc=` attribute — the canonical reference for anyone (human or AI) who needs
to understand the component.

Keep the doc honest. Use `ibis-assert` blocks for claims that can be
machine-verified:

````markdown
```ibis-assert
curl -fsS localhost:8080/healthz | grep -q ok
```
````

### 2. Add the graph node

```bash
ibis add-node payment-gateway \
  --check 'curl -fsS localhost:8080/healthz' \
  --poll
```

This creates:
- The node in `.ibis/GRAPH.dot` with `check=`, `doc=`, `test=`
- A doc stub at `.ibis/docs/payment-gateway.md`
- A test stub at `tests/ibis/payment-gateway.sh`

### 3. Implement

Build the thing. As you work:
- `ibis notify "implementing payment gateway retry logic"` before each change
- Commit after each logical change (don't batch)
- Update the doc if the design changes

### 4. Test

Fill in the test stub. The test should verify the node's behavior, not just
that it exists. Symbol-pinned refs (`test=tests/foo.py::TestPayment`) catch
stale test references — if the class moves, `ibis doctor` flags it.

Run the full gate:
```bash
ibis doctor --strict    # every node has check + doc + test
ibis validate           # doc=, paths=, test= resolve to real files
ibis audit              # docs are fresh and assertions pass
```

### 5. Measure

Record a baseline and track progress:
```bash
ibis ledger payment-gateway 99.2 "uptime after retry fix"
```

The ledger is append-only, git-tracked, and survives context resets. See
[docs/metrics.md](metrics.md) for the methodology.

### 6. Close

When done:
- Update the node's `todo=` attribute: `DONE (2026-08-12): retry logic shipped`
- Move the PRIORITIES.md entry to Completed
- Record a final measurement
- Commit the graph update and the code in the same commit

## Recovery workflow

When something breaks, the lifecycle reverses:

1. Health check fires → P0 in HANDOFF.md
2. Read RECOVERY.md — has this been seen before?
3. Read the node's `doc=` — what does the doc say about failures?
4. Fix → measure → record in the case file → commit
5. Add to RECOVERY.md if this is a new pattern

## Session handoff

At the end of each session, write `SESSION.md`:
- What you were working on
- What's unfinished
- What you learned that isn't obvious from the code

The next session reads HANDOFF.md (auto-generated) + SESSION.md (your notes)
and picks up where you left off without re-deriving context.

## Solo dev vs. team

For a solo developer, ibis tracks YOUR state across sessions. The graph, the
HANDOFF, the leases — they prevent your Thursday self from colliding with your
Tuesday self's uncommitted work.

For a team (multiple humans or AI agents), ibis adds:
- **Leases** (`ibis claim`/`release`) — prevent two workers from editing the
  same node
- **Attributed messages** — `@alice: fixed the gateway` vs `@bob: still debugging`
- **PRIORITIES.md** — shared, ordered work queue
- **Hub mode** — aggregate multiple repos into one HANDOFF

The same primitives, different scale.
