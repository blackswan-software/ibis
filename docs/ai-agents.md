# Configuring AI Agents for ibis

How to set up Claude Code, Cursor, Codex, or any AI coding agent to use ibis
as its coordination layer.

## The problem ibis solves for agents

AI agents have no persistent memory between sessions. Each session starts
fresh, re-derives context from scratch, and has no idea what the last session
did. This causes:

- **Repeated work** — re-discovering root causes that were already documented
- **State collisions** — two agents editing the same file
- **False victories** — declaring "fixed" without measuring
- **Context bloat** — reading the entire graph/codebase to find what matters

ibis solves each one:
- **HANDOFF.md** carries state between sessions (what's broken, what changed)
- **Leases** prevent collisions (`ibis claim`/`release`)
- **Ledger** persists measurements that survive context resets
- **DFS traversal** reads only the relevant graph nodes

## Setting up CLAUDE.md

Copy the template:
```bash
cp ~/.ibis-cli/templates/CLAUDE.md.tmpl CLAUDE.md
```

Edit it for your project. The key sections:

1. **Session start order** — HANDOFF first, then graph DFS, then SESSION.md
2. **DFS traversal rules** — never read the whole graph
3. **Notify discipline** — notify before every action
4. **Never-do list** — project-specific anti-patterns
5. **Anti-patterns from past sessions** — add entries as they occur

## Setting up .claude/settings.json

For Claude Code specifically, configure permission allowlists and hooks:

```json
{
  "permissions": {
    "allow": [
      "Bash(ibis *)",
      "Bash(grep * .ibis/GRAPH.dot)",
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git push *)"
    ]
  }
}
```

This lets the agent run ibis commands without prompting for permission on
each one.

## Worker identity

Set `IBIS_WORKER` so messages and leases are attributed:

```bash
export IBIS_WORKER="claude-session-$(date +%s)"
```

Or in `.claude/settings.json`:
```json
{
  "env": {
    "IBIS_WORKER": "claude-main"
  }
}
```

## The agent's read order

Every session should start:

1. **Read HANDOFF.md** — auto-generated health + inbox
2. **Read SESSION.md** — what the last session was working on
3. **DFS the graph** for the relevant node(s)
4. **Read the node's doc=** — the canonical reference
5. **Check PRIORITIES.md** — what to work on next
6. **Check RECOVERY.md** — has this failure been seen before?

## Multi-agent coordination

When multiple agents work on the same project:

```bash
# Agent A takes the database node
IBIS_WORKER=agent-a ibis claim database --ttl 3600

# Agent B tries — gets refused
IBIS_WORKER=agent-b ibis claim database
# Error: database held by agent-a (expires in 58m)

# Agent B works on something else
IBIS_WORKER=agent-b ibis claim frontend --ttl 3600

# When done
IBIS_WORKER=agent-a ibis release database
```

## MCP integration

For non-Claude agents (Cursor, Codex, Gemini), add ibis as an MCP server:

```json
{ "mcpServers": { "ibis": { "command": "ibis", "args": ["mcp"] } } }
```

This exposes all ibis tools (status, claim, release, notify, validate, etc.)
as native MCP tools the agent can call directly.

## The hook chain

Install the git hooks to enforce discipline:

```bash
ibis hook install
```

This installs a `commit-msg` hook that:
1. **Graph-sync check** — warns when closing work without updating GRAPH.dot
2. **Doc-coverage check** — warns when touching covered files not tracked by a
   node's `doc=`

Configure in `.ibis/config`:
```
cover=*.md,install.sh,README*
```
