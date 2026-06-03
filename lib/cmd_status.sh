#!/usr/bin/env bash
# cmd_status.sh — run checks now and report. `ibis status` = fast checks,
# `ibis status --all` = every node with a check=.

ibis_status() {
  require_init
  local mode=""; [[ "${1:-}" == "--all" ]] && mode="--all"
  local name cmd doc label nfail=0 npass=0
  while IFS=$'\t' read -r name cmd doc label; do
    [[ -z "$name" ]] && continue
    if eval "$cmd" >/dev/null 2>&1; then
      ok "$name"; ((npass++))
    else
      err "$name${doc:+  → $doc}"; ((nfail++))
    fi
  done < <(IBIS_GRAPH="$GRAPH" python3 "$IBIS_HOME/lib/graph-checks.py" $mode)
  echo ""
  printf 'ibis status: %d passing, %d failing\n' "$npass" "$nfail"
  [[ $nfail -eq 0 ]]
}
