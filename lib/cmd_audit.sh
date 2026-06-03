#!/usr/bin/env bash
# cmd_audit.sh — prove node docs are TRUE and not STALE.
#
# `ibis doctor` proves the doc/test FILES exist. `ibis audit` goes further and
# proves the docs are honest, three ways per node:
#
#   1. FRESHNESS (stamp). Each doc carries `<!-- ibis-stamp: HASH -->`, a hash of
#      the node's contract (check|restart|doc|test). Change the node without
#      re-reviewing the doc → stamp mismatch → STALE. Re-stamp with `ibis stamp`
#      once you've updated the doc.
#   2. TRUTH (assertions). Fenced ```ibis-assert blocks in the doc are EXECUTED;
#      each must exit 0. If a claim no longer holds, audit fails.
#   3. BEHAVIOUR (test run). `audit` runs tests/ibis/<node>.sh (unless --no-run).
#
# Exit 0 = every node true + fresh. Non-zero = problems. Wire into CI.

# Map the "-" empty-field sentinel (from graph-checks --audit) back to "".
# Operates on the loop locals check/restart/doc/test in the caller's scope.
_unsentinel() {
  [[ "$check"   == "-" ]] && check=""
  [[ "$restart" == "-" ]] && restart=""
  [[ "$doc"     == "-" ]] && doc=""
  [[ "$test"    == "-" ]] && test=""
  return 0
}

# stamp = cksum (POSIX, on every platform) of the node's contract string.
_compute_stamp() { printf '%s' "check=$1|restart=$2|doc=$3|test=$4" | cksum | awk '{print $1"-"$2}'; }
_read_stamp()   { grep -oE 'ibis-stamp: [^ ]+' "$1" 2>/dev/null | awk '{print $2}' | head -1; }
_write_stamp() {
  local f="$1" s="$2"
  if grep -q 'ibis-stamp:' "$f" 2>/dev/null; then
    sed "s|<!-- ibis-stamp:.*-->|<!-- ibis-stamp: $s -->|" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    printf '\n<!-- ibis-stamp: %s -->\n' "$s" >> "$f"
  fi
}

# ibis stamp [<node>|--all]  — (re)stamp docs after you've reviewed/updated them.
ibis_stamp() {
  require_init
  local only="${1:-}"
  local node check restart doc test n=0
  while IFS=$'\t' read -r node check restart doc test; do
    [[ -z "$node" ]] && continue
    _unsentinel   # "-" → "" for empty fields
    [[ -n "$only" && "$only" != "--all" && "$only" != "$node" ]] && continue
    [[ -z "$doc" || ! -f "$REPO_ROOT/$doc" ]] && continue
    _write_stamp "$REPO_ROOT/$doc" "$(_compute_stamp "$check" "$restart" "$doc" "$test")"
    ok "stamped $node"; n=$((n+1))
  done < <(IBIS_GRAPH="$GRAPH" "$PYTHON" "$IBIS_HOME/lib/graph-checks.py" --audit)
  [[ $n -eq 0 ]] && warn "nothing stamped${only:+ (no node '$only')}"
  return 0
}

# ibis audit [--strict] [--no-run]
ibis_audit() {
  require_init
  local strict=0 run=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict) strict=1; shift;;
      --no-run) run=0; shift;;
      *) die "unknown flag: $1 (use --strict, --no-run)";;
    esac
  done

  local node check restart doc test
  local nodes=0 fails=0 warns=0
  while IFS=$'\t' read -r node check restart doc test; do
    [[ -z "$node" ]] && continue
    _unsentinel   # "-" → "" for empty fields
    nodes=$((nodes+1))
    local problems=() notes=()
    local df="$REPO_ROOT/$doc"

    if [[ -z "$doc" || ! -f "$df" ]]; then
      problems+=("doc missing")
    else
      # 1. Freshness — stamp vs live contract
      local want have
      want="$(_compute_stamp "$check" "$restart" "$doc" "$test")"
      have="$(_read_stamp "$df")"
      if [[ -z "$have" ]]; then
        notes+=("unstamped — run: ibis stamp $node")
        [[ $strict -eq 1 ]] && problems+=("unstamped")
      elif [[ "$have" != "$want" ]]; then
        problems+=("STALE: node contract changed since doc was reviewed — ibis stamp $node")
      fi

      # 2. Unfilled template text
      if grep -q 'TODO' "$df"; then
        if [[ $strict -eq 1 ]]; then problems+=("doc has unresolved TODO"); else notes+=("doc has TODO"); fi
      fi

      # 3. Executable assertions — prove the doc's claims are still true
      local asserts
      asserts="$(awk '/^```ibis-assert[[:space:]]*$/{f=1;next} /^```/{f=0} f' "$df")"
      if [[ -n "$asserts" ]]; then
        if ! bash -c "set -e; $asserts" >/dev/null 2>&1; then
          problems+=("doc assertion failed — a claim is no longer true")
        fi
      else
        notes+=("no ibis-assert block — doc claims unverified")
      fi
    fi

    # 4. Behavioural test
    if [[ $run -eq 1 && -n "$test" && -f "$REPO_ROOT/$test" ]]; then
      if ! bash "$REPO_ROOT/$test" >/dev/null 2>&1; then
        problems+=("node test failed: $test")
      fi
    fi

    # Report
    if [[ ${#problems[@]} -eq 0 ]]; then
      if [[ ${#notes[@]} -eq 0 ]]; then ok "$node"
      else printf '\033[33m~\033[0m %s — %s\n' "$node" "$(IFS='; '; echo "${notes[*]}")"; fi
    else
      err "$node — $(IFS='; '; echo "${problems[*]}")"
    fi
    fails=$((fails + ${#problems[@]}))
    warns=$((warns + ${#notes[@]}))
  done < <(IBIS_GRAPH="$GRAPH" "$PYTHON" "$IBIS_HOME/lib/graph-checks.py" --audit)

  echo ""
  if [[ $fails -eq 0 ]]; then
    ok "$nodes nodes — docs true + fresh$([[ $warns -gt 0 ]] && echo " ($warns note(s))")"
    return 0
  fi
  err "$nodes nodes — $fails audit failure(s)"
  echo "    stale doc → update it, then: ibis stamp <node>"
  echo "    failed assertion → the doc claims something untrue; fix the doc or the system"
  return 1
}
