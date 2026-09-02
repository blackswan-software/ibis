#!/usr/bin/env python3
"""Pre-commit guard: block commits that touch a node declaring a design invariant.

Why this exists
---------------
A graph records *why* a thing is the way it is. Nothing forces anyone to read
that reason before changing it, so load-bearing decisions get silently reverted
by someone who never knew they were decisions. Documentation does not prevent
this; a blocked commit does.

How it works
------------
A node in .ibis/GRAPH.dot may declare an `invariant="..."` attribute. This guard
maps each staged file to its owning node(s) via that node's `paths=` / `doc=` /
`docN=` attributes. If a staged file belongs to a node that declares an
invariant, the commit is BLOCKED and the invariant text is printed.

Acknowledge — after actually reading it — with:

    IBIS_ACK=1 git commit ...

Nodes without `invariant=` never block. Invariants are opt-in, so this stays
silent for ordinary work and fires exactly where reverting is expensive.

Usage:
    graph_guard.py [--all] [--graph PATH]
      --all    ignore staging; check every file tracked in the graph
"""

import os
import re
import subprocess
import sys
from pathlib import Path

RED, YELLOW, CYAN, BOLD, NC = (
    "\033[0;31m", "\033[1;33m", "\033[0;36m", "\033[1m", "\033[0m"
)
if not sys.stderr.isatty():
    RED = YELLOW = CYAN = BOLD = NC = ""

# Node blocks are `name [ ... ]`. A regex cannot reliably find the closing
# bracket: attribute VALUES contain brackets (shell snippets like ${x[0]}), and
# nodes close in several styles — `]`, `];`, or `port="8010"];` inline with the
# last attribute. Scan with a depth counter that ignores brackets inside quotes.
_NODE_START = re.compile(r"^[ \t]*(\w+)[ \t]*\[", re.M)
_ATTR = re.compile(r'(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', re.S)

_SKIP = {
    "subgraph", "node", "edge", "graph", "digraph", "rankdir", "compound",
    "label", "style", "fillcolor", "color", "fontcolor", "fontname",
    "fontsize", "shape", "margin",
}


def _node_body(text, start):
    """Return (body, end_index) for the node block whose '[' is at `start`."""
    depth, i, in_str = 0, start, False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return text[start + 1:i], i
        i += 1
    return text[start + 1:], len(text)


def parse_nodes(graph_text):
    """[{name, invariant, owns:[paths]}] for every node declaring an invariant."""
    nodes = []
    for m in _NODE_START.finditer(graph_text):
        name = m.group(1)
        if name in _SKIP:
            continue
        body, _ = _node_body(graph_text, m.end() - 1)
        attrs = {}
        for am in _ATTR.finditer(body):
            attrs[am.group(1)] = am.group(2).replace('\\"', '"')
        inv = attrs.get("invariant")
        if not inv:
            continue
        owns = []
        for key, val in attrs.items():
            if key == "paths" or re.fullmatch(r"doc\d*", key):
                owns += [p.strip() for p in val.split(",") if p.strip()]
        nodes.append({"name": name, "invariant": inv, "owns": owns})
    return nodes


def owns_file(owned, path, repo_name=None):
    """True if graph-declared `owned` covers repo-relative `path`.

    A centralized graph — one coordination repo holding the graph for several
    sibling repos — declares paths as "<repo>/dir/file". Inside <repo>, git
    reports the staged path as "dir/file", so a literal compare never matches
    and the guard silently passes. Strip the repo prefix and retry.
    """
    owned = owned.rstrip("/")
    if not owned:
        return False
    if path == owned or path.startswith(owned + "/"):
        return True
    if repo_name and owned.startswith(repo_name + "/"):
        stripped = owned[len(repo_name) + 1:]
        if stripped:
            return path == stripped or path.startswith(stripped + "/")
    return False


def staged_files(repo_root):
    out = subprocess.run(
        ["git", "-C", str(repo_root), "diff", "--cached",
         "--name-only", "--diff-filter=ACMR"],
        capture_output=True, text=True,
    )
    return [f for f in out.stdout.splitlines() if f.strip()]


def main():
    args = sys.argv[1:]
    check_all = "--all" in args

    graph = None
    if "--graph" in args:
        graph = Path(args[args.index("--graph") + 1])

    root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True
    ).stdout.strip()
    if not root:
        return 0
    repo_root = Path(root)
    if graph is None:
        graph = repo_root / ".ibis" / "GRAPH.dot"
    if not graph.exists():
        return 0

    nodes = parse_nodes(graph.read_text(encoding="utf-8", errors="replace"))
    if not nodes:
        return 0

    files = staged_files(repo_root) if not check_all else None

    hits = []
    for n in nodes:
        if check_all:
            touched = [p for p in n["owns"] if (repo_root / p).exists()]
        else:
            touched = [f for f in files
                       for o in n["owns"] if owns_file(o, f, repo_root.name)]
        if touched:
            hits.append((n, sorted(set(touched))))

    if not hits:
        return 0

    if os.environ.get("IBIS_ACK"):
        print(f"{YELLOW}  IBIS_ACK=1 — {len(hits)} invariant(s) acknowledged{NC}",
              file=sys.stderr)
        return 0

    print(f"\n{RED}{BOLD}  BLOCKED — staged files touch a design invariant{NC}",
          file=sys.stderr)
    for n, touched in hits:
        print(f"\n{CYAN}  ── node: {n['name']}{NC}", file=sys.stderr)
        for line in n["invariant"].split("\\n"):
            print(f"     {line}", file=sys.stderr)
        print(f"{YELLOW}     staged:{NC}", file=sys.stderr)
        for f in touched:
            print(f"       - {f}", file=sys.stderr)
    print(f"""
{BOLD}  This decision is load-bearing. Read the invariant above, then either{NC}
  change the approach, or acknowledge that you have read it:

      IBIS_ACK=1 git commit ...
""", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
