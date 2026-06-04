#!/usr/bin/env bash
# cmd_hub.sh — coordinator mode. One hub aggregates many ibis repos: it drains
# every member's .notify bus and runs every member's checks into ONE HANDOFF.
# Generalizes the pattern the BlackSwan hub hand-rolled (a poll loop over a
# hardcoded list of repos) into a config-driven command.
#
# A hub lives in any directory:
#   <hubdir>/.ibis-hub/members   newline list of absolute member repo paths
#   <hubdir>/.ibis-hub/.notify/  hub-level bus (cross-repo / hub-addressed msgs)
#   <hubdir>/HANDOFF.md          aggregate P0 + inbox across all members
#
# A repo polled by a hub should NOT also run its own poll timer, or messages
# split between the two HANDOFFs. The hub is the poller.

set_hub_paths() {
  HUB_ROOT="$PWD"
  local d="$PWD"
  while [[ "$d" != "/" ]]; do
    [[ -d "$d/.ibis-hub" ]] && { HUB_ROOT="$d"; break; }
    d="$(dirname "$d")"
  done
  HUB_DIR="$HUB_ROOT/.ibis-hub"
  MEMBERS="$HUB_DIR/members"
  HUB_NOTIFY="$HUB_DIR/.notify"
  HUB_HANDOFF="$HUB_ROOT/HANDOFF.md"
}

require_hub() { [[ -f "$MEMBERS" ]] || die "no .ibis-hub here — run 'ibis hub init' first"; }
_members()    { [[ -f "$MEMBERS" ]] && grep -vE '^[[:space:]]*(#|$)' "$MEMBERS" 2>/dev/null; return 0; }

ibis_hub() {
  set_hub_paths
  local sub="${1:-status}"; shift || true
  case "$sub" in
    init)      _hub_init "$@";;
    add)       _hub_add "$@";;
    remove|rm) _hub_remove "$@";;
    list|ls)   _hub_list;;
    poll)      _hub_poll "$@";;
    status)    _hub_status;;
    who)       _hub_who;;
    notify)    _hub_notify "$@";;
    *) die "ibis hub <init|add|remove|list|poll|status|who|notify>";;
  esac
}

# ── Drain one .notify dir into a (nameref) array, tagged. No eval → message
#    contents are never executed. ────────────────────────────────────────────
_drain_bus() {            # dir tag arrayname
  local dir="$1" tag="$2"; local -n _out="$3"
  local f msg
  mkdir -p "$dir/archive"
  for f in "$dir"/*.pending; do
    [[ -f "$f" ]] || continue
    msg="$(cat "$f")"
    _out+=("$(ts)  [$tag] $msg")
    mv "$f" "$dir/archive/$(date +%s)-$RANDOM-$(basename "$f")"
  done
}

_render_handoff() {       # handoff_path title failuresArr msgsArr
  local hp="$1" title="$2"; local -n _f="$3" _m="$4"
  local pending=""
  [[ -f "$hp" ]] && pending="$(sed -n '/^## Pending/,$p' "$hp")"
  {
    echo "# HANDOFF — $title"
    echo "_Aggregate of member repos. Auto-updated by ibis hub poll._"
    echo ""
    if [[ ${#_f[@]} -gt 0 ]]; then
      echo "## P0 — Failing Health Checks"; for x in "${_f[@]}"; do echo "- $x"; done; echo ""
    fi
    if [[ ${#_m[@]} -gt 0 ]]; then
      echo "## Inbox — $(ts)"; for x in "${_m[@]}"; do echo "- $x"; done; echo ""
    fi
    if [[ -n "$pending" ]]; then echo "$pending"; else echo "## Pending"; echo ""; fi
  } > "$hp.tmp" && mv "$hp.tmp" "$hp"
}

_hub_init() {
  if [[ -f "$MEMBERS" ]]; then warn "hub already initialised at $HUB_DIR"; return 0; fi
  mkdir -p "$HUB_NOTIFY/archive"
  : > "$MEMBERS"; : > "$HUB_NOTIFY/.gitkeep"
  if [[ ! -f "$HUB_HANDOFF" ]]; then
    { echo "# HANDOFF — $(basename "$HUB_ROOT") (ibis hub)"
      echo "_Aggregate of member repos. Auto-updated by ibis hub poll._"; echo ""
      echo "## Pending"; echo ""; } > "$HUB_HANDOFF"
  fi
  if ! grep -qs '^\.ibis-hub/\.notify/' "$HUB_ROOT/.gitignore" 2>/dev/null; then
    { echo ""; echo "# ibis hub runtime state"; echo ".ibis-hub/.notify/"
      echo ".ibis-hub/.poll.lock"; echo ".ibis-hub/.current-failures"; echo "HANDOFF.md"; } >> "$HUB_ROOT/.gitignore"
  fi
  ok "hub initialised at $HUB_DIR"
  echo "    add repos:  ibis hub add <path-to-ibis-repo>"
}

_hub_add() {
  require_hub
  local p="${1:-}"; [[ -z "$p" ]] && die "usage: ibis hub add <repo-path>"
  local abs; abs="$(cd "$p" 2>/dev/null && pwd)" || die "no such directory: $p"
  [[ -f "$abs/.ibis/GRAPH.dot" ]] || die "$abs is not an ibis repo (run 'ibis init' there first)"
  if _members | grep -qxF "$abs"; then warn "already a member: $abs"; return 0; fi
  printf '%s\n' "$abs" >> "$MEMBERS"
  ok "added member: $abs"
  warn "if that repo runs its own poll timer, disable it so the hub is sole poller:"
  echo "    (cd \"$abs\" && ibis uninstall-scheduler)"
}

_hub_remove() {
  require_hub
  local p="${1:-}"; [[ -z "$p" ]] && die "usage: ibis hub remove <repo-path>"
  local abs; abs="$(cd "$p" 2>/dev/null && pwd || echo "$p")"
  grep -vxF "$abs" "$MEMBERS" > "$MEMBERS.tmp" 2>/dev/null; mv "$MEMBERS.tmp" "$MEMBERS"
  ok "removed member: $abs"
}

_hub_list() {
  require_hub
  local n=0 m
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue; n=$((n+1))
    if [[ -f "$m/.ibis/GRAPH.dot" ]]; then ok "$m"; else err "$m  (missing .ibis/GRAPH.dot)"; fi
  done < <(_members)
  echo ""; echo "$n member(s)"
}

_hub_status() { require_hub; echo "ibis hub: $HUB_ROOT"; _hub_list; }

# ibis hub notify <msg> — drop an attributed message on the hub-level bus.
_hub_notify() {
  require_hub
  local msg="$*"; [[ -z "$msg" ]] && die "usage: ibis hub notify <message>"
  mkdir -p "$HUB_NOTIFY"
  printf '@%s: %s\n' "$(worker_id)" "$msg" > "$HUB_NOTIFY/$(date +%s)-$$-$RANDOM.pending"
  ok "queued (hub): $msg"
}

# ibis hub who — active leases across all members (reuses _lease_read).
_hub_who() {
  require_hub
  local member name f any=0 now; now=$(date +%s)
  while IFS= read -r member; do
    [[ -z "$member" ]] && continue
    name="$(basename "$member")"
    [[ -d "$member/.ibis/claims" ]] || continue
    for f in "$member/.ibis/claims"/*.lease; do
      [[ -f "$f" ]] || continue
      local cur
      if cur="$(_lease_read "$f")"; then
        local w e t n; IFS=$'\t' read -r w e t n <<<"$cur"
        printf '  \033[36m%-22s\033[0m [%s] %-18s %ss left\n' "$w" "$name" "$n" "$(( e + t - now ))"
        any=1
      fi
    done
  done < <(_members)
  [[ $any -eq 0 ]] && echo "  no active claims across members"
  return 0
}

# ibis hub poll [--drain-only] — aggregate drain + checks across members.
_hub_poll() {
  require_hub
  local DRAIN_ONLY=0; [[ "${1:-}" == "--drain-only" ]] && DRAIN_ONLY=1
  mkdir -p "$HUB_NOTIFY/archive"

  exec 9>"$HUB_DIR/.poll.lock"
  flock -n 9 || { echo "[$(ts)] ibis hub poll: lock held, skipping"; return 0; }

  local new_msgs=() failures=()
  local CURRENT="$HUB_DIR/.current-failures"

  _drain_bus "$HUB_NOTIFY" "hub" new_msgs            # hub-level bus

  local member name
  while IFS= read -r member; do
    [[ -z "$member" ]] && continue
    name="$(basename "$member")"
    if [[ -d "$member/.ibis/.notify" ]]; then
      # Take the member's own poll lock so we don't race its timer (if any).
      exec 8>"$member/.ibis/.poll.lock"; flock 8
      _drain_bus "$member/.ibis/.notify" "$name" new_msgs
      exec 8>&-
    fi
    if [[ $DRAIN_ONLY -eq 0 && -f "$member/.ibis/GRAPH.dot" ]]; then
      local cn cmd doc label
      while IFS=$'\t' read -r cn cmd doc label; do
        [[ -z "$cn" ]] && continue
        if ! ( cd "$member" && eval "$cmd" ) >/dev/null 2>&1; then
          [[ "$doc" == "-" ]] && doc=""
          failures+=("$(ts) FAIL [$name/$cn]${doc:+ — see $doc}")
        fi
      done < <(IBIS_GRAPH="$member/.ibis/GRAPH.dot" "$PYTHON" "$IBIS_HOME/lib/graph-checks.py")
    fi
  done < <(_members)

  if [[ $DRAIN_ONLY -eq 1 ]]; then
    [[ -f "$CURRENT" ]] && while IFS= read -r l; do [[ -n "$l" ]] && failures+=("$l"); done < "$CURRENT"
  else
    if [[ ${#failures[@]} -gt 0 ]]; then printf '%s\n' "${failures[@]}" > "$CURRENT"; else : > "$CURRENT"; fi
  fi

  _render_handoff "$HUB_HANDOFF" "$(basename "$HUB_ROOT") (ibis hub)" failures new_msgs
  echo "[$(ts)] ibis hub poll: ${#failures[@]} failures, ${#new_msgs[@]} messages across $(_members | grep -c .) member(s)$([[ $DRAIN_ONLY -eq 1 ]] && echo ' (drain-only)')"
}
