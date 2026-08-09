#!/usr/bin/env bash
# cmd_validate.sh — prove GRAPH.dot metadata resolves to real files.
#
# `ibis doctor` checks structural completeness (every node HAS check+doc+test).
# `ibis audit` checks content truth (docs are honest and fresh).
# `ibis validate` checks referential truth: do the paths in doc=, paths=, test=,
# scenarios= actually exist? Are todos stale? Do check=/deploy= scripts resolve?
#
# Wire into CI alongside doctor + audit for full graph integrity.

ibis_validate() {
  require_init
  local args=()
  args+=("$@")
  IBIS_GRAPH="$GRAPH" IBIS_REPO_ROOT="$REPO_ROOT" \
    "$PYTHON" "$IBIS_HOME/lib/graph_validate.py" "${args[@]}"
}
