#!/usr/bin/env bash
# cmd_ledger.sh — a durable, append-only measurement trend per node.
#
# The general form of the BlackSwan ECO_RATE_LEDGER: when a node tracks a metric you
# drive up over many sessions (sandbox ok-rate, coverage, perf, error count), the
# trend is the proof. Recording it in a tracked file means work COMPOUNDS across
# context resets instead of each session re-deriving and declaring false victory.
#
#   ibis ledger <node> <value> [note]   append a measured value (dated, with commit)
#   ibis ledger <node>                   show the node's trend
#
# Ledgers live in .ibis/ledger/<node>.tsv and are git-TRACKED (durable proof).

ibis_ledger() {
  require_init
  local node="${1:-}"; [[ -z "$node" ]] && die "usage: ibis ledger <node> [value] [note]"
  shift || true
  local dir="$IBIS_DIR/ledger"; mkdir -p "$dir"
  local f="$dir/$(slug "$node").tsv"

  if [[ $# -eq 0 ]]; then
    [[ -f "$f" ]] || { echo "no ledger for $node yet — ibis ledger $node <value>"; return 0; }
    column -t -s $'\t' "$f" 2>/dev/null || cat "$f"
    return 0
  fi

  local value="$1"; shift || true
  local note="$*"
  [[ -f "$f" ]] || printf '# date\tvalue\tcommit\tnote\n' > "$f"
  local commit; commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo -)"
  printf '%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%d)" "$value" "$commit" "$note" >> "$f"
  ok "ledger $node: $value ($(date +%Y-%m-%d))  — commit it so the trend persists"
}
