#!/usr/bin/env bash
# cmd_node.sh — DFS node lookup from .ibis/GRAPH.dot.
#
# Agents MUST use this instead of reading GRAPH.dot flat.
# A full graph read wastes 30-50% of context window on irrelevant nodes.
#
#   ibis node <name>               show node definition + edges
#   ibis node <name> --context     everything an agent needs before acting
#   ibis node <name> --depth N     follow edges N levels deep (default 1)

ibis_node() {
  require_init
  local node="" context=false depth=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --edges) shift ;;  # edges are now always shown
      --context) context=true; shift ;;
      --depth) depth="$2"; shift 2 ;;
      -*) die "unknown flag: $1" ;;
      *)  node="$1"; shift ;;
    esac
  done
  [[ -z "$node" ]] && die "usage: ibis node <name> [--context] [--depth N]"

  if ! grep -q "${node}\s*\[" "$GRAPH"; then
    die "node '$node' not found in $GRAPH"
  fi

  echo "=== Node: ${node} ==="
  sed -n "/^\s*${node}\s*\[/,/\];/p" "$GRAPH"

  echo ""
  echo "=== Outgoing edges ==="
  grep -n "${node}\s*->" "$GRAPH" || echo "(none)"

  echo ""
  echo "=== Incoming edges ==="
  grep -n -- "->.*${node}" "$GRAPH" || echo "(none)"

  if [[ "$depth" -gt 1 ]]; then
    echo ""
    echo "=== Neighbors (depth $depth) ==="
    _node_dfs "$node" "$depth"
  fi

  if $context; then
    _node_context "$node"
  fi
}

_node_context() {
  local node="$1"

  # Extract doc= attribute from the node definition
  local doc
  doc="$(sed -n "/^\s*${node}\s*\[/,/\];/p" "$GRAPH" \
       | grep -oE 'doc="[^"]*"' | head -1 | sed 's/doc="//;s/"//')"

  # --- Doc summary ---
  if [[ -n "$doc" && -f "$REPO_ROOT/$doc" ]]; then
    echo ""
    echo "=== Doc: ${doc} (first 30 lines) ==="
    head -30 "$REPO_ROOT/$doc"
    local total; total="$(wc -l < "$REPO_ROOT/$doc")"
    [[ "$total" -gt 30 ]] && echo "... ($total lines total)"
  fi

  # --- RECOVERY.md entries mentioning this node ---
  local recovery="$REPO_ROOT/RECOVERY.md"
  if [[ -f "$recovery" ]]; then
    local hits
    hits="$(grep -c -i "$node" "$recovery" 2>/dev/null || true)"
    if [[ "$hits" -gt 0 ]]; then
      echo ""
      echo "=== RECOVERY.md ($hits mentions) ==="
      grep -B1 -A3 -i "$node" "$recovery" | head -20
    fi
  fi

  # --- PRIORITIES.md entries mentioning this node ---
  local priorities="$REPO_ROOT/PRIORITIES.md"
  if [[ -f "$priorities" ]]; then
    local hits
    hits="$(grep -c -i "$node" "$priorities" 2>/dev/null || true)"
    if [[ "$hits" -gt 0 ]]; then
      echo ""
      echo "=== PRIORITIES.md ($hits mentions) ==="
      grep -B1 -A2 -i "$node" "$priorities" | head -15
    fi
  fi

  # --- HANDOFF.md entries mentioning this node ---
  if [[ -f "$HANDOFF" ]]; then
    local hits
    hits="$(grep -c -i "$node" "$HANDOFF" 2>/dev/null || true)"
    if [[ "$hits" -gt 0 ]]; then
      echo ""
      echo "=== HANDOFF.md ($hits mentions) ==="
      grep -B1 -A2 -i "$node" "$HANDOFF" | head -15
    fi
  fi

  # --- Last 5 ledger measurements ---
  local ledger_file="$IBIS_DIR/ledger/${node}.tsv"
  if [[ -f "$ledger_file" ]]; then
    echo ""
    echo "=== Ledger (last 5) ==="
    tail -5 "$ledger_file"
  fi

  # --- Active leases on this node ---
  local lease_file="$IBIS_DIR/leases/${node}.lease"
  if [[ -f "$lease_file" ]]; then
    echo ""
    echo "=== Active lease ==="
    cat "$lease_file"
  fi
}

_node_dfs() {
  local start="$1" max_depth="$2"
  local -A visited=()
  local queue=("$start:0")

  while [[ ${#queue[@]} -gt 0 ]]; do
    local item="${queue[0]}"
    queue=("${queue[@]:1}")
    local cur="${item%%:*}" d="${item##*:}"
    [[ -n "${visited[$cur]+x}" ]] && continue
    visited["$cur"]=1
    [[ "$d" -ge "$max_depth" ]] && continue

    local neighbor nd=$(( d + 1 ))
    while IFS= read -r neighbor; do
      [[ -z "$neighbor" ]] && continue
      neighbor="$(echo "$neighbor" | sed -E 's/.*->\s*(\w+).*/\1/')"
      [[ -n "${visited[$neighbor]+x}" ]] && continue
      printf '  %*s→ %s\n' $((d*2)) '' "$neighbor"
      queue+=("$neighbor:$nd")
    done < <(grep "${cur}\s*->" "$GRAPH" 2>/dev/null)
  done
}
