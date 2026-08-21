#!/usr/bin/env bash
# cmd_status.sh — run checks now and report. `ibis status` = fast checks,
# `ibis status --all` = every node with a check=.

ibis_status() {
  require_init
  # Rich mode: cluster output with timing, filters, dry-run, JSON
  local rich=false args=()
  for arg in "$@"; do
    case "$arg" in
      --rich|--cluster|--node|--dry-run|--json) rich=true; args+=("$arg") ;;
      *) args+=("$arg") ;;
    esac
  done
  if $rich; then
    IBIS_GRAPH="$GRAPH" "$PYTHON" "$IBIS_HOME/lib/graph_status.py" "${args[@]}"
    return $?
  fi

  local mode=""; [[ "${1:-}" == "--all" ]] && mode="--all"
  local name cmd doc label nfail=0 npass=0
  while IFS=$'\t' read -r name cmd doc label; do
    [[ -z "$name" ]] && continue
    if eval "$cmd" >/dev/null 2>&1; then
      ok "$name"; ((npass++))
    else
      err "$name${doc:+  → $doc}"; ((nfail++))
    fi
  done < <(IBIS_GRAPH="$GRAPH" "$PYTHON" "$IBIS_HOME/lib/graph-checks.py" $mode)
  echo ""
  printf 'ibis status: %d passing, %d failing\n' "$npass" "$nfail"
  [[ $nfail -eq 0 ]]
}
