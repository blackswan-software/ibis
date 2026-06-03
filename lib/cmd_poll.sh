#!/usr/bin/env bash
# cmd_poll.sh — the ibis runtime poller. Mirrors the BlackSwan hub poll.sh:
# full poll (timer) runs health checks; --drain-only (path-triggered) just drains
# the .notify bus and re-renders HANDOFF, reusing the last poll's failures.

ibis_poll() {
  require_init

  local DRAIN_ONLY=0
  [[ "${1:-}" == "--drain-only" ]] && DRAIN_ONLY=1

  mkdir -p "$NOTIFY_DIR/archive"

  # Single-flight lock so the timer poll and the path-triggered drain can't
  # double-process the same .pending message.
  local LOCKFILE="$IBIS_DIR/.poll.lock"
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    echo "[$(ts)] ibis poll: lock held, skipping"
    return 0
  fi

  # ── Drain the .notify bus (both modes) ────────────────────────────────────
  local new_msgs=() f msg
  for f in "$NOTIFY_DIR"/*.pending; do
    [[ -f "$f" ]] || continue
    msg=$(cat "$f")
    new_msgs+=("$(ts)  $msg")
    mv "$f" "$NOTIFY_DIR/archive/$(date +%s)-$RANDOM-$(basename "$f")"
  done

  # ── Health checks (full poll only) ────────────────────────────────────────
  local failures=() new_failures=()
  local CURRENT="$IBIS_DIR/.current-failures"

  if [[ $DRAIN_ONLY -eq 0 ]]; then
    local NOTIFIED="$IBIS_DIR/.notified-failures"
    local COOLDOWN=3600 NOW; NOW=$(date +%s)
    declare -A prev=() curr=()
    [[ -f "$NOTIFIED" ]] && while IFS=' ' read -r ep nm; do
      [[ -n "$nm" ]] && prev["$nm"]="$ep"
    done < "$NOTIFIED"

    local name cmd doc label
    while IFS=$'\t' read -r name cmd doc label; do
      [[ -z "$name" ]] && continue
      if ! eval "$cmd" 2>/dev/null; then
        [[ "$doc" == "-" ]] && doc=""
        failures+=("$(ts) FAIL [$name]${doc:+ — see $doc}")
        curr["$name"]=1
        [[ -z "${prev[$name]:-}" ]] && new_failures+=("$name")
      fi
    done < <(IBIS_GRAPH="$GRAPH" "$PYTHON" "$IBIS_HOME/lib/graph-checks.py")

    # Rebuild anti-flap sentinel (epoch name per line)
    {
      for nm in "${!prev[@]}"; do
        [[ -z "$nm" ]] && continue
        local ep="${prev[$nm]}"
        if [[ -n "${curr[$nm]:-}" ]]; then echo "$ep $nm"
        elif (( NOW - ep < COOLDOWN )); then echo "$ep $nm"; fi
      done
      for nm in "${new_failures[@]}"; do [[ -n "$nm" ]] && echo "$NOW $nm"; done
    } > "$NOTIFIED.tmp" && mv "$NOTIFIED.tmp" "$NOTIFIED"

    if [[ ${#failures[@]} -gt 0 ]]; then printf '%s\n' "${failures[@]}" > "$CURRENT"
    else : > "$CURRENT"; fi
  else
    # Drain-only: reuse last full poll's failures for the P0 section.
    [[ -f "$CURRENT" ]] && while IFS= read -r line; do
      [[ -n "$line" ]] && failures+=("$line")
    done < "$CURRENT"
  fi

  # ── Render HANDOFF (preserve manual Pending section) ──────────────────────
  local pending_block=""
  [[ -f "$HANDOFF" ]] && pending_block=$(sed -n '/^## Pending/,$p' "$HANDOFF")
  {
    echo "# HANDOFF — $(basename "$REPO_ROOT")"
    echo "_Auto-updated by ibis poll. Edit only the Pending section._"
    echo ""
    if [[ ${#failures[@]} -gt 0 ]]; then
      echo "## P0 — Failing Health Checks"
      for x in "${failures[@]}"; do echo "- $x"; done
      echo ""
    fi
    if [[ ${#new_msgs[@]} -gt 0 ]]; then
      echo "## Inbox — $(ts)"
      for m in "${new_msgs[@]}"; do echo "- $m"; done
      echo ""
    fi
    if [[ -n "$pending_block" ]]; then echo "$pending_block"
    else
      echo "## Pending"
      echo ""
      echo "_Manual notes survive across polls. Todos live on graph nodes (\`todo=\`)._"
    fi
  } > "$HANDOFF.tmp" && mv "$HANDOFF.tmp" "$HANDOFF"

  # ── Desktop notification on NEW failures (best-effort) ────────────────────
  if [[ ${#new_failures[@]} -gt 0 ]] && command -v notify-send &>/dev/null; then
    notify-send "ibis: $(basename "$REPO_ROOT")" "NEW FAIL: ${new_failures[0]}" --urgency=normal 2>/dev/null || true
  fi

  echo "[$(ts)] ibis poll: ${#failures[@]} failures, ${#new_msgs[@]} messages$([[ $DRAIN_ONLY -eq 1 ]] && echo ' (drain-only)')"
}
