#!/usr/bin/env bash
# cmd_doctor.sh — enforce the ibis node contract. This is the gate you wire into
# CI: every node MUST have a check, a doc (.md that exists), and a test (that
# exists). --strict also fails on stub tests (tests that still echo "STUB").
#
# Exit 0 = all nodes compliant; non-zero = violations (fail the build).

# _doctor_install — does ibis actually RUN here, or is it just checked in?
#
# The activation of ibis is machine-local: git hooks live in a directory git
# does not track, and the scheduler lives in the user's init system. A clone
# therefore arrives with the graph, the docs and the CLI — and nothing running
# them. HANDOFF quietly stops updating, no health check fires, no failure
# escalates, and NOTHING reports the gap. Every doc still claims it is active.
#
# Observed 2026-09-02 on a machine where git hooks had never been installed in
# any repo, the poll timer had never existed, and a GPU scheduler had sat
# installed-but-disabled for days. Each was invisible because absence is silent.
#
# So: doctor checks its own installation, not just the graph's contents. These
# are warnings rather than hard failures — a CI runner legitimately has no
# scheduler — but they are loud, and they name the command that fixes them.
_doctor_install() {
  local warn=0
  printf '\033[1m── ibis installation ──\033[0m\n'

  # 1. Git hooks, and whether they survive a clone.
  local hp; hp="$(git -C "$REPO_ROOT" config core.hooksPath 2>/dev/null || true)"
  if [[ -z "$hp" ]]; then
    warn "git hooks not active (core.hooksPath unset) — run: ibis hook install"; warn=1
  elif [[ ! -x "$REPO_ROOT/$hp/pre-commit" ]]; then
    warn "core.hooksPath=$hp but no executable pre-commit — run: ibis hook install"; warn=1
  elif ! git -C "$REPO_ROOT" ls-files --error-unmatch "$hp/pre-commit" >/dev/null 2>&1; then
    warn "hooks at $hp are UNTRACKED — they vanish on the next clone."
    echo "      fix: git add $hp && git commit -m 'ibis: track git hooks'"; warn=1
  else
    ok "git hooks active and tracked ($hp)"
  fi

  # 2. Scheduler — the thing that keeps HANDOFF true.
  local sched="none"
  if command -v systemctl >/dev/null 2>&1 && \
     systemctl --user list-timers --all 2>/dev/null | grep -q "ibis-poll"; then
    sched="systemd"
  elif command -v launchctl >/dev/null 2>&1 && launchctl list 2>/dev/null | grep -q "ibis"; then
    sched="launchd"
  elif crontab -l 2>/dev/null | grep -q "ibis poll"; then
    sched="cron"
  fi
  if [[ "$sched" == "none" ]]; then
    warn "no scheduler installed — health checks are NOT running."
    echo "      fix: ibis install-scheduler"; warn=1
  else
    ok "scheduler installed ($sched)"
  fi

  # 3. HANDOFF freshness — the observable symptom of 1 and 2 being wrong.
  local hf="$REPO_ROOT/HANDOFF.md"
  if [[ -f "$hf" ]]; then
    local age=$(( ( $(date +%s) - $(stat -c %Y "$hf" 2>/dev/null || stat -f %m "$hf") ) / 60 ))
    if (( age > 15 )); then
      warn "HANDOFF.md is ${age} min stale — nothing has polled recently."
      echo "      Anything reading it is acting on old state."; warn=1
    else
      ok "HANDOFF.md fresh (${age} min)"
    fi
  fi

  return $warn
}

ibis_doctor() {
  require_init
  local strict=0; [[ "${1:-}" == "--strict" ]] && strict=1
  _doctor_install || true
  echo ""
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
