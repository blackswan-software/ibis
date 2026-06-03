#!/usr/bin/env bash
# cmd_addnode.sh — add a node to the graph. Enforces the ibis node contract:
# every node MUST have a check, a doc (.md), and a test. Missing doc/test are
# created from templates so the contract is satisfiable, never silently skipped.
#
# Usage:
#   ibis add-node <name> --check '<cmd>' [--poll] [--restart '<cmd>'] [--no-edge]
# If --check is omitted and stdin is a TTY, you'll be prompted.

ibis_add_node() {
  require_init
  local name="${1:-}"; shift || true
  [[ -z "$name" ]] && die "usage: ibis add-node <name> --check '<cmd>' [--poll]"

  local check="" poll="" restart="" edge=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)   check="$2"; shift 2;;
      --poll)    poll=1; shift;;
      --restart) restart="$2"; shift 2;;
      --no-edge) edge=0; shift;;
      *) die "unknown flag: $1";;
    esac
  done

  local id; id="$(nodeid "$name")"
  [[ -z "$id" ]] && die "could not derive a node id from '$name'"

  # Duplicate guard
  if grep -qE "^[[:space:]]*${id}[[:space:]]*\[" "$GRAPH"; then
    die "node '$id' already exists in $GRAPH"
  fi

  # Check is required — prompt if interactive, else fail loudly.
  if [[ -z "$check" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Health check command for '$id' (exit 0 = healthy): " check
    fi
    [[ -z "$check" ]] && die "a node needs a check= — pass --check '<cmd>'"
  fi

  local doc_rel=".ibis/docs/$id.md"
  local test_rel="tests/ibis/$id.sh"

  # ── Create the required doc stub ──────────────────────────────────────────
  mkdir -p "$DOCS_DIR"
  if [[ ! -f "$REPO_ROOT/$doc_rel" ]]; then
    NODE_NAME="$name" NODE_ID="$id" NODE_CHECK="$check" \
      render "$IBIS_HOME/templates/node-doc.md.tmpl" > "$REPO_ROOT/$doc_rel"
    ok "doc   $doc_rel"
  fi

  # ── Create the required test stub ─────────────────────────────────────────
  mkdir -p "$TESTS_DIR"
  if [[ ! -f "$REPO_ROOT/$test_rel" ]]; then
    NODE_NAME="$name" NODE_ID="$id" \
      render "$IBIS_HOME/templates/node-test.sh.tmpl" > "$REPO_ROOT/$test_rel"
    chmod +x "$REPO_ROOT/$test_rel"
    ok "test  $test_rel"
  fi

  # ── Insert the node into GRAPH.dot (before the final closing brace) ───────
  # The graph's final line is a lone "}". Drop it, append the node, re-close.
  local check_esc="${check//\"/\\\"}"
  local root; root="$(grep -oE '^digraph[[:space:]]+[A-Za-z0-9_]+' "$GRAPH" | awk '{print $2}')"
  {
    sed '$d' "$GRAPH"   # all but the final lone "}" (BSD-safe; head -n -1 isn't)
    echo "  $id ["
    echo "    label=\"$name\","
    echo "    check=\"$check_esc\","
    [[ -n "$poll" ]]    && echo "    poll=\"fast\","
    [[ -n "$restart" ]] && echo "    restart=\"${restart//\"/\\\"}\","
    echo "    doc=\"$doc_rel\","
    echo "    test=\"$test_rel\""
    echo "  ];"
    [[ -n "$root" && $edge -eq 1 ]] && echo "  $root -> $id;"
    echo "}"
  } > "$GRAPH.tmp" && mv "$GRAPH.tmp" "$GRAPH"

  # Stamp the doc with the node's contract so `ibis audit` can detect drift.
  _write_stamp "$REPO_ROOT/$doc_rel" "$(_compute_stamp "$check" "$restart" "$doc_rel" "$test_rel")"

  ok "node  $id  ($([[ -n "$poll" ]] && echo 'poll=fast' || echo 'on-demand') check)"
  info "edit the doc + test, then: ibis doctor"
}
