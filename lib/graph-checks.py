#!/usr/bin/env python3
"""Extract node attributes from a repo's .ibis/GRAPH.dot.

Portable version of the BlackSwan hub extractor. Reads the GRAPH.dot path from
$IBIS_GRAPH (set by bin/ibis) or the first CLI arg.

Modes:
  (default)   TSV of poll="fast" checks: name<TAB>command<TAB>doc<TAB>label
  --all       every node that has a check=
  --contract  TSV of EVERY node: name<TAB>has_check<TAB>doc<TAB>test
              (used by `ibis doctor` to enforce check+doc+test per node)
"""
import os
import re
import sys
from pathlib import Path


def graph_path() -> Path:
    for a in sys.argv[1:]:
        if not a.startswith("-"):
            return Path(a)
    env = os.environ.get("IBIS_GRAPH")
    if env:
        return Path(env)
    return Path(".ibis/GRAPH.dot")


def extract_nodes(dot_text: str) -> list[dict]:
    """Extract `name [ ... ]` node definitions, respecting quoted attr values
    that may themselves contain [ and ] (e.g. bash `[[ ]]` inside a check=)."""
    nodes = []
    KEYWORDS = {"subgraph", "node", "edge", "graph", "digraph", "rankdir",
                "compound", "label", "style", "fillcolor", "color", "fontcolor",
                "fontname", "fontsize", "shape", "margin"}
    for m in re.finditer(r'(\w+)\s*\[', dot_text):
        name = m.group(1)
        if name in KEYWORDS:
            continue
        i, in_quote = m.end(), False
        while i < len(dot_text):
            c = dot_text[i]
            if c == '\\' and in_quote:
                i += 2
                continue
            if c == '"':
                in_quote = not in_quote
            elif c == ']' and not in_quote:
                break
            i += 1
        if i >= len(dot_text):
            continue
        attrs = {}
        for am in re.finditer(r'(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', dot_text[m.end():i], re.DOTALL):
            val = am.group(2).replace('\\\\', '\\').replace('\\"', '"')
            attrs[am.group(1)] = val
        nodes.append({"node": name, **attrs})
    return nodes


def main():
    path = graph_path()
    if not path.exists():
        sys.stderr.write(f"graph-checks: no graph at {path}\n")
        sys.exit(1)
    nodes = extract_nodes(path.read_text())

    if "--contract" in sys.argv:
        for n in nodes:
            has_check = "yes" if "check" in n else "no"
            print(f'{n["node"]}\t{has_check}\t{n.get("doc","")}\t{n.get("test","")}')
        return

    show_all = "--all" in sys.argv
    for n in nodes:
        if "check" not in n:
            continue
        if not show_all and n.get("poll") != "fast":
            continue
        label = n.get("label", "").split("\\n")[0]
        doc = n.get("doc", "") or "-"
        print(f'{n.get("check_name", n["node"])}\t{n["check"]}\t{doc}\t{label}')
        for i in range(2, 10):
            key = f"check{i}"
            if key not in n:
                break
            nm = n.get(f"{key}_name", f'{n["node"]}/{i}')
            print(f'{nm}\t{n[key]}\t{doc}\t{label}')


if __name__ == "__main__":
    main()
