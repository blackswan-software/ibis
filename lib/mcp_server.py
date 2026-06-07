#!/usr/bin/env python3
"""ibis MCP server — expose the coordination layer over the Model Context Protocol.

Hand-rolled stdio JSON-RPC 2.0 (newline-delimited), no SDK dependency — python3 only,
keeping ibis's zero-install promise. Each tool shells to the existing `ibis` CLI (the
bash layer stays authoritative); this is a thin adapter so any MCP agent (Cursor,
Codex, Gemini, Claude) consumes ibis natively. Spec: docs/mcp.md.

Launched by `ibis mcp` (see bin/ibis). Env:
  IBIS_HOME       install dir (to find bin/ibis)
  IBIS_MCP_REPO   repo root to operate on (cwd if unset)
Flags: --read-only disables write tools.
"""
import json
import os
import re
import subprocess
import sys

IBIS_HOME = os.environ.get("IBIS_HOME", "")
REPO = os.environ.get("IBIS_MCP_REPO") or os.getcwd()
IBIS = os.path.join(IBIS_HOME, "bin", "ibis") if IBIS_HOME else "ibis"
READ_ONLY = "--read-only" in sys.argv[1:]
ANSI = re.compile(r"\033\[[0-9;]*m")
SERVER = {"name": "ibis", "version": "0.1.0"}


def run(args, timeout=60):
    """Run `ibis <args>` in the repo; return cleaned combined output."""
    try:
        p = subprocess.run([IBIS, *args], cwd=REPO, capture_output=True,
                           text=True, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
    except Exception as e:  # noqa: BLE001
        out = f"error running ibis {' '.join(args)}: {e}"
    return ANSI.sub("", out).strip() or "(no output)"


def read_file(rel):
    p = os.path.join(REPO, rel)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


# ── Tools ────────────────────────────────────────────────────────────────────
READ_TOOLS = [
    ("ibis_status", "Run health checks now; pass/fail per node.",
     {"all": {"type": "boolean", "description": "include on-demand (non-fast) checks"}},
     lambda a: run(["status"] + (["--all"] if a.get("all") else []))),
    ("ibis_open_todos", "List nodes that still have an open todo=.", {},
     lambda a: run(["doctor"]) if False else _grep_todos()),
    ("ibis_node", "Show a node's attributes + its doc/case file.",
     {"node": {"type": "string"}}, lambda a: _node(a.get("node", ""))),
    ("ibis_doctor", "Enforce the node contract (check + doc + test).",
     {"strict": {"type": "boolean"}},
     lambda a: run(["doctor"] + (["--strict"] if a.get("strict") else []))),
    ("ibis_audit", "Prove docs are true (assertions) + fresh (stamps).",
     {"strict": {"type": "boolean"}},
     lambda a: run(["audit"] + (["--strict"] if a.get("strict") else []))),
    ("ibis_who", "Active work leases (worker, node, ttl left).", {},
     lambda a: run(["who"])),
    ("ibis_ledger", "Show a node's measured trend.",
     {"node": {"type": "string"}}, lambda a: run(["ledger", a.get("node", "")])),
]
WRITE_TOOLS = [
    ("ibis_claim", "Lease a node so other workers don't collide (refused if held).",
     {"node": {"type": "string"}, "ttl": {"type": "integer"}},
     lambda a: run(["claim", a.get("node", "")] + (["--ttl", str(a["ttl"])] if a.get("ttl") else []))),
    ("ibis_release", "Release your lease on a node.",
     {"node": {"type": "string"}}, lambda a: run(["release", a.get("node", "")])),
    ("ibis_notify", "Drop an attributed message on the bus.",
     {"message": {"type": "string"}}, lambda a: run(["notify", a.get("message", "")])),
    ("ibis_ledger_record", "Append a measured value to a node's ledger.",
     {"node": {"type": "string"}, "value": {"type": "string"}, "note": {"type": "string"}},
     lambda a: run(["ledger", a.get("node", ""), str(a.get("value", "")), a.get("note", "")])),
]


def _grep_todos():
    g = read_file(".ibis/GRAPH.dot")
    if g is None:
        return "no .ibis/GRAPH.dot"
    hits = [l.strip() for l in g.splitlines() if 'todo="' in l]
    return "\n".join(hits) if hits else "no open todos"


def _node(name):
    if not name:
        return "usage: node=<id>"
    g = read_file(".ibis/GRAPH.dot") or ""
    # crude block grab: `<name> [ ... ];`
    m = re.search(r'\b' + re.escape(name) + r'\s*\[(.*?)\];', g, re.DOTALL)
    block = (name + " [" + m.group(1) + "];") if m else f"(node '{name}' not found)"
    doc = re.search(r'doc="([^"]+)"', m.group(1)) if m else None
    docbody = read_file(doc.group(1)) if doc else None
    return block + (("\n\n--- doc ---\n" + docbody) if docbody else "")


def tool_defs():
    tools = list(READ_TOOLS) + ([] if READ_ONLY else list(WRITE_TOOLS))
    out = []
    for name, desc, props, _ in tools:
        out.append({"name": name, "description": desc,
                    "inputSchema": {"type": "object", "properties": props}})
    return out


def dispatch_tool(name, args):
    for n, _d, _p, fn in (READ_TOOLS + WRITE_TOOLS):
        if n == name:
            if READ_ONLY and name in {t[0] for t in WRITE_TOOLS}:
                return "tool disabled (--read-only)", True
            return fn(args or {}), False
    return f"unknown tool: {name}", True


# ── Resources ──────────────────────────────────────────────────────────────
def resource_list():
    res = [
        {"uri": "ibis://handoff", "name": "HANDOFF.md", "mimeType": "text/markdown"},
        {"uri": "ibis://graph", "name": "GRAPH.dot", "mimeType": "text/vnd.graphviz"},
    ]
    return res


def resource_read(uri):
    if uri == "ibis://handoff":
        return read_file("HANDOFF.md")
    if uri == "ibis://graph":
        return read_file(".ibis/GRAPH.dot")
    if uri.startswith("ibis://node/") and uri.endswith("/doc"):
        node = uri[len("ibis://node/"):-len("/doc")]
        return read_file(f".ibis/docs/{node}.md")
    if uri.startswith("ibis://ledger/"):
        node = uri[len("ibis://ledger/"):]
        return read_file(f".ibis/ledger/{node}.tsv")
    return None


# ── JSON-RPC loop ─────────────────────────────────────────────────────────────
def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        method, id_ = req.get("method"), req.get("id")
        params = req.get("params") or {}

        if method == "initialize":
            reply(id_, {
                "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}, "resources": {}},
                "serverInfo": SERVER,
            })
        elif method in ("notifications/initialized", "initialized"):
            continue  # notification, no response
        elif method == "ping":
            reply(id_, {})
        elif method == "tools/list":
            reply(id_, {"tools": tool_defs()})
        elif method == "tools/call":
            text, is_err = dispatch_tool(params.get("name"), params.get("arguments"))
            reply(id_, {"content": [{"type": "text", "text": text}], "isError": is_err})
        elif method == "resources/list":
            reply(id_, {"resources": resource_list()})
        elif method == "resources/read":
            uri = params.get("uri", "")
            body = resource_read(uri)
            if body is None:
                reply(id_, error={"code": -32602, "message": f"no such resource: {uri}"})
            else:
                reply(id_, {"contents": [{"uri": uri, "text": body}]})
        elif id_ is not None:
            reply(id_, error={"code": -32601, "message": f"method not found: {method}"})


if __name__ == "__main__":
    main()
