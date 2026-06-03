#!/usr/bin/env bash
# cmd_init.sh — the ibis start wizard. Scaffolds the graph + bus + docs/tests
# layout into the current repo, auto-discovers candidate nodes, and (on Linux)
# installs the systemd timer + instant-drain path watcher.
#
# Usage: ibis init [--adopt] [--no-units] [--force]
#   --adopt     add every discovered candidate as a node (with doc+test stubs)
#   --no-units  skip systemd install (print the manual cron fallback instead)
#   --force     overwrite an existing .ibis/GRAPH.dot

ibis_init() {
  set_paths
  local adopt=0 units=1 force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --adopt) adopt=1; shift;;
      --no-units) units=0; shift;;
      --force) force=1; shift;;
      *) die "unknown flag: $1";;
    esac
  done

  if [[ -f "$GRAPH" && $force -eq 0 ]]; then
    die "already initialised ($GRAPH exists) — use --force to overwrite"
  fi

  info "initialising ibis in $REPO_ROOT"
  mkdir -p "$IBIS_DIR" "$NOTIFY_DIR/archive" "$DOCS_DIR" "$TESTS_DIR"
  : > "$NOTIFY_DIR/.gitkeep"

  local REPO_NAME REPO_ID
  REPO_NAME="$(basename "$REPO_ROOT")"
  REPO_ID="$(nodeid "$REPO_NAME")"; [[ -z "$REPO_ID" ]] && REPO_ID="repo"

  REPO_NAME="$REPO_NAME" REPO_ID="$REPO_ID" \
    render "$IBIS_HOME/templates/GRAPH.dot.tmpl" > "$GRAPH"
  ok "graph  .ibis/GRAPH.dot  (root node: $REPO_ID)"

  # Root node's required doc + test
  if [[ ! -f "$DOCS_DIR/$REPO_ID.md" ]]; then
    NODE_NAME="$REPO_NAME" NODE_ID="$REPO_ID" NODE_CHECK="true  # root node has no check" \
      render "$IBIS_HOME/templates/node-doc.md.tmpl" > "$DOCS_DIR/$REPO_ID.md"
  fi
  if [[ ! -f "$TESTS_DIR/$REPO_ID.sh" ]]; then
    NODE_NAME="$REPO_NAME" NODE_ID="$REPO_ID" \
      render "$IBIS_HOME/templates/node-test.sh.tmpl" > "$TESTS_DIR/$REPO_ID.sh"
    chmod +x "$TESTS_DIR/$REPO_ID.sh"
  fi

  # HANDOFF + gitignore for runtime state
  if [[ ! -f "$HANDOFF" ]]; then
    {
      echo "# HANDOFF — $REPO_NAME"
      echo "_Auto-updated by ibis poll. Edit only the Pending section._"
      echo ""
      echo "## Pending"
      echo ""
      echo "_Manual notes survive across polls._"
    } > "$HANDOFF"
  fi
  if ! grep -qs '^\.ibis/\.notify/' "$REPO_ROOT/.gitignore" 2>/dev/null; then
    {
      echo ""
      echo "# ibis runtime state (not source of truth)"
      echo ".ibis/.notify/"
      echo ".ibis/.poll.log"
      echo ".ibis/.poll.lock"
      echo ".ibis/.notified-failures"
      echo ".ibis/.current-failures"
      echo "HANDOFF.md"
    } >> "$REPO_ROOT/.gitignore"
  fi

  # ── Auto-discovery ────────────────────────────────────────────────────────
  echo ""
  info "discovering candidate nodes…"
  local cands=() line
  while IFS= read -r line; do cands+=("$line"); done < <(ibis_discover 3>&1 1>/dev/null)

  if [[ ${#cands[@]} -eq 0 ]]; then
    warn "no services auto-discovered — add nodes with: ibis add-node <name> --check '<cmd>'"
  else
    local kind id name check
    for line in "${cands[@]}"; do
      IFS=$'\t' read -r kind id name check <<<"$line"
      if [[ $adopt -eq 1 ]]; then
        # A '#'-only suggested check can't be a real assertion — make it fail
        # loudly so `ibis doctor`/poll flag it until you set a real one.
        [[ "$check" == \#* ]] && check="false  $check"
        ibis_add_node "$name" --check "$check" --poll || warn "skip $id"
      else
        printf '  \033[36m%-12s\033[0m %-20s %s\n' "$kind" "$id" "$check"
      fi
    done
    [[ $adopt -eq 0 ]] && info "re-run with --adopt to add these as nodes, or add selectively with 'ibis add-node'"
  fi

  # ── systemd units ─────────────────────────────────────────────────────────
  echo ""
  if [[ $units -eq 1 ]]; then
    _ibis_install_units "$REPO_NAME" "$REPO_ID"
  else
    _ibis_print_cron
  fi

  echo ""
  ok "ibis ready. Next:"
  echo "    ibis status     # run all checks now"
  echo "    ibis doctor     # verify every node has check + doc + test"
  echo "    ibis add-node <name> --check '<cmd>' --poll"
}

_ibis_install_units() {
  local REPO_NAME="$1" UNIT_ID="$2"
  if ! command -v systemctl &>/dev/null || ! systemctl --user show-environment &>/dev/null; then
    warn "systemd --user not available — falling back to cron"
    _ibis_print_cron
    return
  fi
  local ud="$HOME/.config/systemd/user"; mkdir -p "$ud"
  local IBIS_BIN; IBIS_BIN="$IBIS_HOME/bin/ibis"
  export REPO_NAME UNIT_ID IBIS_BIN REPO_ROOT

  render "$IBIS_HOME/templates/ibis-poll.service.tmpl"  > "$ud/ibis-poll-$UNIT_ID.service"
  render "$IBIS_HOME/templates/ibis-poll.timer.tmpl"    > "$ud/ibis-poll-$UNIT_ID.timer"
  render "$IBIS_HOME/templates/ibis-drain.service.tmpl" > "$ud/ibis-drain-$UNIT_ID.service"
  render "$IBIS_HOME/templates/ibis-drain.path.tmpl"    > "$ud/ibis-drain-$UNIT_ID.path"

  systemctl --user daemon-reload
  systemctl --user enable --now "ibis-poll-$UNIT_ID.timer" >/dev/null 2>&1
  systemctl --user enable --now "ibis-drain-$UNIT_ID.path"  >/dev/null 2>&1
  ok "systemd  ibis-poll-$UNIT_ID.timer (2-min checks) + ibis-drain-$UNIT_ID.path (instant drain)"
  echo "    linger keeps these running when logged out:  loginctl enable-linger \$USER"
}

_ibis_print_cron() {
  warn "manual scheduling — add to crontab (no systemd):"
  echo "    */2 * * * * cd $REPO_ROOT && $IBIS_HOME/bin/ibis poll >> .ibis/.poll.log 2>&1"
  echo "  Instant drain needs inotify; without systemd, the 2-min cron is the floor."
}
