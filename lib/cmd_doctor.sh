#!/usr/bin/env bash
# cmd_doctor.sh — enforce the ibis node contract. This is the gate you wire into
# CI: every node MUST have a check, a doc (.md that exists), and a test (that
# exists). --strict also fails on stub tests (tests that still echo "STUB").
#
# Exit 0 = all nodes compliant; non-zero = violations (fail the build).

ibis_doctor() {
  require_init
  local strict=0; [[ "${1:-}" == "--strict" ]] && strict=1
  local node has_check doc test violations=0 nodes=0
  # The root node (= the digraph name) is structural; it needs a doc + test but
  # not a health check. Service nodes must have all three.
  local root; root="$(grep -oE '^digraph[[:space:]]+[A-Za-z0-9_]+' "$GRAPH" | awk '{print $2}')"

  while IFS=$'\t' read -r node has_check doc test; do
    [[ -z "$node" ]] && continue
    ((nodes++))
    local problems=()

    if [[ "$has_check" != "yes" && "$node" != "$root" ]]; then
      problems+=("no check=")
    fi
    if [[ -z "$doc" ]]; then
      problems+=("no doc=")
    elif [[ ! -f "$REPO_ROOT/$doc" ]]; then
      problems+=("doc missing: $doc")
    fi
    # test= may be a script (tests/ibis/x.sh) or a symbol-pinned ref
    # (path::Class). Split off ::symbol, check the file exists, and — when a
    # symbol is given — that it's actually defined there (catches stale refs
    # like a test= pointing at a class that lives in a different file).
    local test_file="${test%%::*}" test_sym=""
    [[ "$test" == *::* ]] && test_sym="${test##*::}"
    if [[ -z "$test" ]]; then
      problems+=("no test=")
    elif [[ ! -f "$REPO_ROOT/$test_file" ]]; then
      problems+=("test missing: $test_file")
    elif [[ -n "$test_sym" ]] && ! grep -qE "(class|def|func|describe)[[:space:]]+$test_sym\b" "$REPO_ROOT/$test_file" 2>/dev/null; then
      problems+=("test ref unresolved: $test_sym not defined in $test_file")
    elif [[ $strict -eq 1 && -z "$test_sym" ]] && grep -q 'STUB' "$REPO_ROOT/$test_file" 2>/dev/null; then
      problems+=("test is a stub")
    fi

    if [[ ${#problems[@]} -eq 0 ]]; then
      ok "$node"
    else
      err "$node — $(IFS='; '; echo "${problems[*]}")"
      ((violations += ${#problems[@]}))
    fi
  done < <(IBIS_GRAPH="$GRAPH" "$PYTHON" "$IBIS_HOME/lib/graph-checks.py" --contract)

  echo ""
  if [[ $violations -eq 0 ]]; then
    ok "$nodes nodes, contract satisfied (check + doc + test)"
    return 0
  fi
  err "$nodes nodes, $violations contract violation(s)"
  echo "    fix with: edit the doc/test, or 'ibis add-node' which scaffolds both"
  return 1
}
