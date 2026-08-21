# AI Team Coordination — Why It Matters

_The evidence and context behind the workshop. Read this first._

This document covers:
- Why developers are now managers of AI workers
- What goes wrong without coordination (real costs)
- What production deployments are teaching the industry
- How to guardrail LLMs against hallucinations, destruction, and false claims

The hands-on content is in two companion documents:
- **[Part A: Installing and Setting Up ibis](presentation-setup.md)** — free, open
- **[Part B: Multi-Team AI Development Workshop](presentation-enterprise.md)** — enterprise training

---

## The shift

Six months ago, you wrote code. Today, you write instructions for something
that writes code. The job title didn't change. The job did.

Every developer using Claude Code, Cursor, Codex, or Gemini has quietly become
a **manager of AI workers**. The skills that matter now aren't syntax and
algorithms — they're **delegation, coordination, and review**.

---

## You are the manager

Think about what a good engineering manager does:

- Breaks work into tasks that can be done independently
- Assigns tasks to the right people
- Sets up guardrails so mistakes are caught early
- Reviews output before it ships
- Keeps the team from stepping on each other's work
- Maintains context across meetings and handoffs

Now think about what you do with an AI coding agent:

- Break work into prompts that can be completed in one session
- Route the right context to the right session
- Set up rules (CLAUDE.md, settings) so the agent doesn't go rogue
- Review diffs before committing
- Keep multiple sessions from editing the same files
- Carry context between sessions that have no memory

**Same job. Different team.**

## PRs are team communication

A pull request isn't a code delivery mechanism. It's a **message from one team
member to another**: "Here's what I did, here's why, here's what to look for."

When your AI agent creates a PR, that PR is addressed to *you*. You are the
reviewer. The quality of the PR description, the commit messages, the test
coverage — these are things you, the manager, should demand from your worker.

When you create a PR from your agent's work, that PR is addressed to your
*human* team. The description should explain the intent, not the implementation.

## The solo dev trap

A solo developer can get away with keeping everything in their head. The moment
you add a second worker — human or AI — you need infrastructure:

| Solo dev | Team (you + AI agents) |
|---|---|
| Context lives in your head | Context must be written down |
| "I'll remember" works | Sessions have no memory |
| No handoffs needed | Every session starts cold |
| No conflicts possible | Two sessions can edit the same file |
| "It works on my machine" is fine | Prove it works with a measurement |

Most developers added AI agents without adding the coordination layer.
They're managing a team with solo-dev tools.

---

## What goes wrong without coordination

### Amnesia

Your AI session has no memory. Without a handoff mechanism, the next session
re-derives everything the last one figured out — burning its entire context
window on archaeology instead of progress.

**Cost**: 60-80% of session tokens wasted on rediscovery.

### False victories

An AI agent will tell you "fixed!" based on a probe that passes. But passing
a health check isn't the same as measuring the actual metric. Without durable
measurements, "fixed" is a guess that the next session can't verify.

**Cost**: Work that loops — fix, declare done, discover it's not done, re-fix.

### State collisions

Two sessions working on the same project don't know about each other. Session
A edits `auth.py`. Session B edits `auth.py`. One overwrites the other.

**Cost**: Lost work, subtle bugs from merged-by-accident changes.

### Context bloat

An AI session that reads your entire codebase to find what's relevant wastes
tokens and misses things. A 2,000-line system map fills 30-50% of the context
window.

**Cost**: $3K+ in wasted spend from a single flat-read pattern (real number
from a real project).

---

## What the industry is learning the hard way

### "Locally correct, globally incoherent"

ZS Associates built a 4-agent pipeline for pharmaceutical analytics: signal
detection, source localization, driver attribution, synthesis, plus an
orchestrator. Each agent was individually correct. The integrated system
failed catastrophically.

When detecting an 18% prescription drop caused by payer coverage changes, the
system recommended deploying additional sales representatives. Every agent was
right. The system was wrong.

They killed the pipeline and rebuilt around three principles:

1. **Separate deterministic work from LLM reasoning.** Statistical signal
   detection should never involve a language model. That's a threshold
   calculation. Do it in code.

2. **Consolidate all judgment into one agent.** Distributed reasoning creates
   context-loss cascades at every handoff. One reasoning agent with sub-agents
   for execution — never for judgment.

3. **Knowledge graph as control plane, not lookup layer.** The graph **bounds
   what the agent can investigate** — every edge is a hypothesis the agent can
   test. Without this boundary, agents invent non-existent causal relationships.

   > "The knowledge graph is not just something the agent looks up for data.
   > It is a control plane for the agent."

### The numbers nobody wants to publish

| Finding | Source |
|---|---|
| **36.9%** of multi-agent failures are coordination breakdowns | MAST study |
| Error amplification: **17x** in unstructured agent networks | MAST study |
| Coordination gains **plateau beyond 4 agents** | Multiple production reports |
| Auto-generated MAS **underperform at 10x the cost** | "Illusion of Multi-Agent Advantage" (arxiv) |
| Multi-agent systems use **~15x as many tokens** as single-agent | Augment Code |
| A single hallucinated value **propagated through 4 downstream systems** | Kumar (control plane protocols) |
| One compromised agent **poisoned 87% of downstream decisions** in 4 hours | Galileo AI |
| At 95% per-step reliability across 20 steps, system **fails 64.2%** | Compound reliability decay |

### What actually works

- One reasoning agent, bounded by a graph of what it's allowed to do
- Deterministic operations (tests, checks, measurements) separated from LLM reasoning
- File-based handoffs that survive context resets
- Human review at judgment boundaries

---

## Guardrailing LLMs — they will hallucinate, delete, and lie

### Layer 1: Access limits — prevent destruction

An AI agent with full shell access can `rm -rf`, force-push, drop tables,
kill processes, and overwrite production configs. It will do these things not
out of malice but because it "thinks" that's the fastest path.

**Rule: never give an agent permission to do something you wouldn't let a
day-one intern do unsupervised.**

```markdown
# In CLAUDE.md — the agent reads this every session

## Never do
- Never kill processes, restart services, or modify system state
- Never run rm -rf, git reset --hard, git push --force, git clean -f
- Never overwrite files without reading them first
- Never drop database tables or run destructive migrations
- Never delete branches, tags, or releases
- Never modify .env, secrets, credentials, or SSH keys
- Never take any destructive action without explicit user approval
```

In `.claude/settings.json`, enforce with permission allowlists:

```json
{
  "permissions": {
    "allow": [
      "Bash(ibis *)", "Bash(grep *)", "Bash(git status)",
      "Bash(git diff *)", "Bash(git log *)",
      "Bash(git add *)", "Bash(git commit *)"
    ],
    "deny": [
      "Bash(rm -rf *)", "Bash(git push --force*)",
      "Bash(git reset --hard*)", "Bash(git clean *)"
    ]
  }
}
```

### Layer 2: Testing — catch hallucinations before they ship

#### Unit tests are necessary but not sufficient

The agent wrote the code AND the test. An agent that hallucinated
`client.send(data, timeout=30)` will also write a test that calls
`client.send(data, timeout=30)`. Both are wrong. Both pass.

#### Mutation testing — proving tests actually catch bugs

Mutation testing introduces small bugs and checks whether the test suite
catches them. Surviving mutants = weak tests.

Tools: `mutmut` (Python), `Stryker` (JS/TS, C#), `PITest` (Java),
`go-mutesting` (Go).

#### End-to-end testing — verifying reality

**An AI agent's unit tests verify the agent's understanding of the code.
E2E tests verify reality.** When the two disagree, reality wins.

#### Integration tests vs mocks

AI agents love mocks — easy to write, always pass the way the agent expects.
That's exactly why they're dangerous. **Test against the real thing in CI.**

### Layer 3: Verification — proving claims are true

| Gate | What it proves | Tool |
|---|---|---|
| Structure | Files exist | `ibis doctor` |
| References | Paths resolve | `ibis validate` |
| Honesty | Assertions pass, docs fresh | `ibis audit` |
| Durability | Trend holds across sessions | `ibis ledger` |

### The guardrail stack

| Layer | What it catches | Tool |
|---|---|---|
| Access limits | Destructive actions | CLAUDE.md rules, settings.json deny list |
| Unit tests | Logic errors | pytest, jest, go test |
| Mutation tests | Weak tests that pass with bugs | mutmut, Stryker, PITest |
| Integration tests | Mock/reality divergence | docker compose + real services |
| E2E tests | System-level failures | curl + real endpoints |
| Doc assertions | Lies in documentation | `ibis audit` (ibis-assert blocks) |
| Measurement trends | False "fixed" claims | `ibis ledger` (append-only) |
| Pre-commit hooks | Stale graph, missing notifications | `ibis hook install` |

No single layer is enough. The stack works because each layer is independent.
