#!/usr/bin/env bash
# cmd_node.sh — DFS node lookup from .ibis/GRAPH.dot.
#
# Agents MUST use this instead of reading GRAPH.dot flat.
# A full graph read wastes 30-50% of context window on irrelevant nodes.
#
#   ibis node <name>             show node definition
#   ibis node <name> --edges     also show incoming/outgoing edges
#   ibis node <name> --depth N   follow edges N levels deep (default 1)

ibis_node() {
  require_init
  local node="" show_edges=false depth=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --edges) show_edges=true; shift ;;
      --depth) depth="$2"; shift 2 ;;
      -*) die "unknown flag: $1" ;;
      *)  node="$1"; shift ;;
    esac
  done
  [[ -z "$node" ]] && die "usage: ibis node <name> [--edges] [--depth N]"

  if ! grep -q "${node}\s*\[" "$GRAPH"; then
    die "node '$node' not found in $GRAPH"
  fi

  echo "=== Node: ${node} ==="
  sed -n "/^\s*${node}\s*\[/,/\];/p" "$GRAPH"

  if $show_edges; then
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
