#!/usr/bin/env python3
"""graph_validate.py — prove GRAPH.dot metadata is true against the filesystem.

Validates every node's verifiable attributes:
  1. doc=/doc2=/doc3= — file must exist
  2. paths= — every comma-separated path must exist
  3. test= — test file (and optional ::class/method) must exist
  4. scenarios= — every space-separated dir must exist
  5. todo= — flag OPEN/EXECUTING items older than N days as stale
  6. check= — smoke-test that referenced scripts/files exist (NOT run)
  7. deploy=/restart= — referenced scripts must be syntactically reachable

Sits between `ibis doctor` (structural: every node HAS a check/doc/test) and
`ibis audit` (content: docs are TRUE and FRESH). This validates that metadata
references resolve to real files — the graph describes what actually exists.

Outputs JSON report + human-readable summary.
Exit 0 = clean, 1 = problems found, 2 = usage error.

Usage (via ibis CLI):
  ibis validate                     # full validation
  ibis validate --node gateway      # single node
  ibis validate --json              # JSON output only
  ibis validate --fix               # output sed commands for stale todos
  ibis validate --stale-days 14     # flag OPEN todos older than 14d (default: 21)

Env:
  IBIS_GRAPH       path to GRAPH.dot (default: .ibis/GRAPH.dot)
  IBIS_REPO_ROOT   repo root (default: git root or cwd)
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path


def _repo_root():
    env = os.environ.get("IBIS_REPO_ROOT")
    if env:
        return Path(env)
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        return Path(out)
    except Exception:
        return Path.cwd()


def _graph_path():
    env = os.environ.get("IBIS_GRAPH")
    if env:
        return Path(env)
    return _repo_root() / ".ibis" / "GRAPH.dot"


ROOT = _repo_root()
GRAPH = _graph_path()

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
DIM = "\033[2m"
BOLD = "\033[1m"
NC = "\033[0m"


def resolve_path(p: str) -> Path:
    """Resolve a path relative to the repo root."""
    p = p.strip()
    if p.startswith("~/"):
        return Path(os.path.expanduser(p))
    if p.startswith("/"):
        return Path(p)
    candidate = ROOT / p
    if candidate.exists():
        return candidate
    # Try subdirectories one level deep (covers multi-repo layouts)
    for child in ROOT.iterdir():
        if child.is_dir() and not child.name.startswith('.'):
            sub = child / p
            if sub.exists():
                return sub
    return candidate


def extract_nodes(dot_text: str) -> list:
    """Extract every node with its attributes, handling quoted brackets."""
    nodes = []
    skip = {'subgraph', 'node', 'edge', 'graph', 'digraph', 'rankdir',
            'compound', 'label', 'style', 'fillcolor', 'color', 'fontcolor',
            'fontname', 'fontsize', 'shape', 'margin'}

    for m in re.finditer(r'(\w+)\s*\[', dot_text):
        name = m.group(1)
        if name in skip:
            continue
        start = m.end()
        i = start
        in_quote = False
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
        attrs_raw = dot_text[start:i]
        attrs = {"_name": name, "_line": dot_text[:m.start()].count('\n') + 1}
        for am in re.finditer(r'(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', attrs_raw, re.DOTALL):
            val = am.group(2).replace('\\\\', '\\').replace('\\"', '"')
            attrs[am.group(1)] = val
        nodes.append(attrs)
    return nodes


def check_file_exists(path_str: str) -> tuple:
    """Check if a path resolves to an existing file/dir. Returns (exists, resolved)."""
    clean = re.split(r'[:§]', path_str)[0].strip()
    clean = re.sub(r'\s*\(.*?\)\s*$', '', clean).strip()
    if not clean:
        return True, path_str
    resolved = resolve_path(clean)
    return resolved.exists(), str(resolved)


def validate_doc_attrs(node: dict) -> list:
    """Validate doc=, doc2=, doc3= attributes."""
    findings = []
    for key in ('doc', 'doc2', 'doc3'):
        val = node.get(key)
        if not val:
            continue
        if val.endswith('/'):
            exists, resolved = check_file_exists(val)
            if not exists:
                findings.append({
                    "node": node["_name"], "line": node["_line"],
                    "attr": key, "value": val, "resolved": resolved,
                    "type": "missing_doc", "severity": "error",
                    "msg": f"{key}= directory does not exist: {val}"
                })
        else:
            for part in val.split(' + '):
                part = part.strip()
                if not part:
                    continue
                exists, resolved = check_file_exists(part)
                if not exists:
                    findings.append({
                        "node": node["_name"], "line": node["_line"],
                        "attr": key, "value": part, "resolved": resolved,
                        "type": "missing_doc", "severity": "error",
                        "msg": f"{key}= file does not exist: {part}"
                    })
    return findings


def validate_paths_attr(node: dict) -> list:
    """Validate paths= attribute (comma or space separated file/dir paths)."""
    findings = []
    val = node.get("paths")
    if not val:
        return findings
    if ',' in val:
        parts = val.split(',')
    else:
        parts = val.split()
    for p in parts:
        p = p.strip()
        if not p:
            continue
        exists, resolved = check_file_exists(p)
        if not exists:
            findings.append({
                "node": node["_name"], "line": node["_line"],
                "attr": "paths", "value": p, "resolved": resolved,
                "type": "missing_path", "severity": "error",
                "msg": f"paths= entry does not exist: {p}"
            })
    return findings


def validate_test_attr(node: dict) -> list:
    """Validate test= attribute. Handles comma-separated paths and ::Class::method."""
    findings = []
    val = node.get("test")
    if not val:
        return findings
    entries = [e.strip() for e in val.split(",") if e.strip()]
    for entry in entries:
        file_part = entry.split("::")[0]
        exists, resolved = check_file_exists(file_part)
        if not exists:
            findings.append({
                "node": node["_name"], "line": node["_line"],
                "attr": "test", "value": entry, "resolved": resolved,
                "type": "missing_test", "severity": "error",
                "msg": f"test= file does not exist: {file_part}"
            })
        elif "::" in entry:
            resolved_path = resolve_path(file_part)
            try:
                content = resolved_path.read_text()
                parts = entry.split("::")
                for symbol in parts[1:]:
                    if symbol not in content:
                        findings.append({
                            "node": node["_name"], "line": node["_line"],
                            "attr": "test", "value": entry, "resolved": str(resolved_path),
                            "type": "missing_test_symbol", "severity": "error",
                            "msg": f"test= symbol '{symbol}' not found in {file_part}"
                        })
            except (OSError, UnicodeDecodeError):
                pass
    return findings


def validate_scenarios_attr(node: dict) -> list:
    """Validate scenarios= attribute (space or comma separated directory paths)."""
    findings = []
    val = node.get("scenarios")
    if not val:
        return findings
    parts = re.split(r'[,\s]+', val)
    for p in parts:
        p = p.strip()
        if not p:
            continue
        exists, resolved = check_file_exists(p)
        if not exists:
            findings.append({
                "node": node["_name"], "line": node["_line"],
                "attr": "scenarios", "value": p, "resolved": resolved,
                "type": "missing_scenario", "severity": "error",
                "msg": f"scenarios= dir does not exist: {p}"
            })
    return findings


def validate_todo_attr(node: dict, stale_days: int) -> list:
    """Flag todo= items that are OPEN or EXECUTING and older than stale_days."""
    findings = []
    val = node.get("todo")
    if not val:
        return findings

    status_match = re.match(r'(OPEN|EXECUTING|DONE|FIXED|PLANNING)\s', val)
    if not status_match:
        return findings

    status = status_match.group(1)
    if status in ('DONE', 'FIXED'):
        return findings

    date_match = re.search(r'(\d{4}-\d{2}-\d{2})', val)
    if not date_match:
        if status in ('OPEN', 'EXECUTING'):
            findings.append({
                "node": node["_name"], "line": node["_line"],
                "attr": "todo", "value": val[:120],
                "type": "undated_todo", "severity": "warn",
                "msg": f"todo= is {status} with no date — cannot determine staleness"
            })
        return findings

    try:
        todo_date = datetime.strptime(date_match.group(1), "%Y-%m-%d")
        age_days = (datetime.now() - todo_date).days
        if age_days > stale_days:
            findings.append({
                "node": node["_name"], "line": node["_line"],
                "attr": "todo", "value": val[:120],
                "type": "stale_todo", "severity": "warn",
                "age_days": age_days,
                "msg": f"todo= {status} for {age_days} days (threshold: {stale_days}d): {val[:80]}..."
            })
    except ValueError:
        pass
    return findings


def validate_command_refs(node: dict) -> list:
    """Light check: if check=/deploy=/restart= references a local script, does it exist?"""
    findings = []
    for key in ('check', 'deploy', 'restart'):
        val = node.get(key)
        if not val:
            continue
        if val.strip().startswith("ssh "):
            continue
        for m in re.finditer(r'(?:bash\s+|python3?\s+|sh\s+)([~\w./-]+\.\w+)', val):
            script = m.group(1)
            if script.startswith("/tmp/"):
                continue
            exists, resolved = check_file_exists(script)
            if not exists:
                findings.append({
                    "node": node["_name"], "line": node["_line"],
                    "attr": key, "value": script, "resolved": resolved,
                    "type": "missing_script", "severity": "warn",
                    "msg": f"{key}= references script that doesn't exist: {script}"
                })
    return findings


def main():
    args = sys.argv[1:]
    json_mode = "--json" in args
    fix_mode = "--fix" in args
    stale_days = 21
    filter_node = None

    for i, a in enumerate(args):
        if a == "--stale-days" and i + 1 < len(args):
            stale_days = int(args[i + 1])
        if a == "--node" and i + 1 < len(args):
            filter_node = args[i + 1]

    if not GRAPH.exists():
        print(f"ERROR: {GRAPH} not found", file=sys.stderr)
        sys.exit(2)

    dot_text = GRAPH.read_text()
    raw_nodes = extract_nodes(dot_text)
    seen = set()
    nodes = []
    for n in raw_nodes:
        if n["_name"] not in seen:
            seen.add(n["_name"])
            nodes.append(n)

    if filter_node:
        nodes = [n for n in nodes if n["_name"] == filter_node]
        if not nodes:
            print(f"ERROR: node '{filter_node}' not found in GRAPH.dot", file=sys.stderr)
            sys.exit(2)

    all_findings = []
    node_count = 0
    clean_count = 0

    for node in nodes:
        node_findings = []
        node_findings.extend(validate_doc_attrs(node))
        node_findings.extend(validate_paths_attr(node))
        node_findings.extend(validate_test_attr(node))
        node_findings.extend(validate_scenarios_attr(node))
        node_findings.extend(validate_todo_attr(node, stale_days))
        node_findings.extend(validate_command_refs(node))

        all_findings.extend(node_findings)
        node_count += 1
        if not node_findings:
            clean_count += 1

    errors = [f for f in all_findings if f["severity"] == "error"]
    warns = [f for f in all_findings if f["severity"] == "warn"]

    if json_mode:
        report = {
            "nodes_checked": node_count,
            "nodes_clean": clean_count,
            "errors": len(errors),
            "warnings": len(warns),
            "findings": all_findings,
        }
        print(json.dumps(report, indent=2))
        sys.exit(1 if errors else 0)

    print(f"{BOLD}=== GRAPH.dot Metadata Validation ==={NC}")
    print(f"{DIM}Checked {node_count} nodes, stale threshold: {stale_days} days{NC}")
    print()

    if errors:
        print(f"{RED}{BOLD}ERRORS ({len(errors)}):{NC}")
        for f in errors:
            print(f"  {RED}x{NC} [{f['node']}:{f['line']}] {f['msg']}")
        print()

    if warns:
        print(f"{YELLOW}{BOLD}WARNINGS ({len(warns)}):{NC}")
        for f in warns:
            print(f"  {YELLOW}~{NC} [{f['node']}:{f['line']}] {f['msg']}")
        print()

    if fix_mode and warns:
        stale_todos = [f for f in warns if f["type"] == "stale_todo"]
        if stale_todos:
            print(f"{CYAN}Suggested fixes for stale todos:{NC}")
            for f in stale_todos:
                print(f"  # {f['node']} -- {f['age_days']} days old")
                print(f"  # Review and either: complete (DONE), close (FIXED), or refresh the date")
                print(f"  grep -n '{f['node']}.*todo=' .ibis/GRAPH.dot")
                print()

    print(f"{BOLD}Summary:{NC} ", end="")
    if not errors and not warns:
        print(f"{GREEN}all {node_count} nodes clean{NC}")
    else:
        parts = []
        if errors:
            parts.append(f"{RED}{len(errors)} errors{NC}")
        if warns:
            parts.append(f"{YELLOW}{len(warns)} warnings{NC}")
        print(f"{clean_count}/{node_count} clean, " + ", ".join(parts))

    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
