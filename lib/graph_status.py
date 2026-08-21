#!/usr/bin/env python3
"""graph_status.py — rich status organized by GRAPH.dot clusters and nodes.

Three tiers of checks:
  poll="fast"   — lightweight health checks (poller runs every 2 min)
  check=        — on-demand validation (run after a fix)
  check= on ops — slow scripts (weekly-qc, etc.)

Usage:
  python3 graph_status.py             # fast checks only
  python3 graph_status.py --all       # all checks including slow
  python3 graph_status.py --cluster X # checks for a specific cluster
  python3 graph_status.py --node X    # single node check
  python3 graph_status.py --dry-run   # show what would run, don't execute
  python3 graph_status.py --json      # output JSON instead of color text
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

GRAPH = Path(os.environ.get("IBIS_GRAPH", ".ibis/GRAPH.dot"))

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
DIM = "\033[2m"
BOLD = "\033[1m"
NC = "\033[0m"


def parse_graph(dot_text: str):
    clusters = {}
    current_cluster = None
    cluster_labels = {}

    lines = dot_text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()

        m = re.match(r'subgraph\s+(cluster_\w+)\s*\{', line)
        if m:
            current_cluster = m.group(1)
            clusters[current_cluster] = []
            i += 1
            continue

        if current_cluster and line.startswith('label='):
            m = re.match(r'label="([^"]*)"', line)
            if m:
                cluster_labels[current_cluster] = m.group(1).split("\\n")[0]
            i += 1
            continue

        if line == '}' and current_cluster:
            current_cluster = None
            i += 1
            continue

        m = re.match(r'(\w+)\s*\[', line)
        if m and m.group(1) not in ('subgraph', 'node', 'edge', 'graph', 'digraph',
                                      'label', 'style', 'rankdir', 'compound'):
            node_name = m.group(1)
            block = line
            while '];' not in block and i < len(lines) - 1:
                i += 1
                block += "\n" + lines[i].strip()

            attrs = {"_name": node_name}
            for am in re.finditer(r'(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', block, re.DOTALL):
                val = am.group(2).replace('\\"', '"')
                attrs[am.group(1)] = val

            if current_cluster:
                clusters.setdefault(current_cluster, []).append(attrs)
            else:
                clusters.setdefault("_toplevel", []).append(attrs)

        i += 1

    return clusters, cluster_labels


def run_check(cmd, timeout=30):
    start = time.time()
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, timeout=timeout)
        elapsed = time.time() - start
        return result.returncode == 0, elapsed
    except subprocess.TimeoutExpired:
        return False, time.time() - start


def print_node_status(node, run, dry_run):
    name = node["_name"]
    label = node.get("label", "").split("\\n")[0]
    check = node.get("check")
    check_name = node.get("check_name", name)
    poll = node.get("poll", "")
    doc = node.get("doc", "")
    todo = node.get("todo", "")
    tier = "fast" if poll == "fast" else "slow"

    passes = fails = 0
    results = []

    if not check:
        print(f"  {DIM}○ {name}{NC}  {DIM}{label}{NC}")
        return 0, 0, results

    if dry_run:
        trunc = f"{check[:80]}..." if len(check) > 80 else check
        print(f"  ◇ {check_name} [{tier}]  {DIM}{trunc}{NC}")
        return 0, 0, results

    if not run:
        print(f"  ◇ {check_name} [{tier}]  {DIM}(skipped — use --all){NC}")
        return 0, 0, results

    passed, elapsed = run_check(check)
    ms = int(elapsed * 1000)

    if passed:
        print(f"  {GREEN}✔{NC} {check_name}  {DIM}{ms}ms{NC}")
        passes = 1
    else:
        print(f"  {RED}✘{NC} {check_name}  {DIM}{ms}ms{NC}")
        if doc and doc != "-":
            print(f"    {YELLOW}doc:{NC} {doc}")
        if todo:
            print(f"    {YELLOW}todo:{NC} {todo}")
        fails = 1
    results.append({"name": check_name, "passed": passed, "ms": ms})

    check2 = node.get("check2")
    if check2 and run:
        check2_name = node.get("check2_name", f"{name}/2")
        passed2, elapsed2 = run_check(check2)
        ms2 = int(elapsed2 * 1000)
        if passed2:
            print(f"  {GREEN}✔{NC} {check2_name}  {DIM}{ms2}ms{NC}")
            passes += 1
        else:
            print(f"  {RED}✘{NC} {check2_name}  {DIM}{ms2}ms{NC}")
            fails += 1
        results.append({"name": check2_name, "passed": passed2, "ms": ms2})

    check3 = node.get("check3")
    if check3 and run:
        check3_name = node.get("check3_name", f"{name}/3")
        passed3, elapsed3 = run_check(check3)
        ms3 = int(elapsed3 * 1000)
        if passed3:
            print(f"  {GREEN}✔{NC} {check3_name}  {DIM}{ms3}ms{NC}")
            passes += 1
        else:
            print(f"  {RED}✘{NC} {check3_name}  {DIM}{ms3}ms{NC}")
            fails += 1
        results.append({"name": check3_name, "passed": passed3, "ms": ms3})

    return passes, fails, results


def main():
    args = sys.argv[1:]
    show_all = "--all" in args
    dry_run = "--dry-run" in args
    as_json = "--json" in args
    filter_cluster = None
    filter_node = None

    for i, a in enumerate(args):
        if a == "--cluster" and i + 1 < len(args):
            filter_cluster = args[i + 1].lower()
        if a == "--node" and i + 1 < len(args):
            filter_node = args[i + 1].lower()

    if not GRAPH.exists():
        print(f"No graph at {GRAPH}", file=sys.stderr)
        sys.exit(1)

    dot_text = GRAPH.read_text()
    clusters, cluster_labels = parse_graph(dot_text)

    all_clusters = sorted(clusters.keys())
    toplevel = [k for k in all_clusters if k == "_toplevel"]
    named = [k for k in all_clusters if k != "_toplevel"]
    order = named + toplevel

    total_pass = total_fail = 0
    json_out = []

    if not as_json:
        print(f"{BOLD}═══ IBIS STATUS ═══{NC}  {time.strftime('%Y-%m-%d %H:%M')}")
        print(f"{DIM}Source: {GRAPH} → {sum(len(v) for v in clusters.values())} nodes{NC}")
        if dry_run:
            print(f"{YELLOW}DRY RUN — showing checks, not executing{NC}")
        print()

    for cluster_key in order:
        if cluster_key not in clusters:
            continue

        if filter_cluster:
            short = cluster_key.replace("cluster_", "")
            if filter_cluster not in (short, cluster_key):
                continue

        nodes = clusters[cluster_key]
        label = cluster_labels.get(cluster_key, cluster_key.replace("cluster_", ""))

        has_checks = any(n.get("check") for n in nodes)
        if not has_checks and not show_all:
            continue

        if not as_json:
            print(f"{CYAN}── {label} ──{NC}")

        for node in nodes:
            name = node["_name"]
            if filter_node and filter_node != name.lower():
                continue

            poll = node.get("poll", "")
            run = (poll == "fast") or show_all

            p, f, results = print_node_status(node, run, dry_run)
            total_pass += p
            total_fail += f

            if as_json and results:
                for r in results:
                    r["cluster"] = label
                    json_out.append(r)

        if not as_json:
            print()

    if as_json:
        print(json.dumps({"checks": json_out, "pass": total_pass, "fail": total_fail}))
    elif not dry_run:
        total = total_pass + total_fail
        if total > 0:
            color = GREEN if total_fail == 0 else RED
            line = f"{BOLD}Summary:{NC} {color}{total_pass}/{total} checks passed{NC}"
            if total_fail > 0:
                line += f"  {RED}{total_fail} failed{NC}"
            print(line)


if __name__ == "__main__":
    main()
