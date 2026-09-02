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

# A member's project name — its .ibis/config name=, else the dir name. So the
# aggregate HANDOFF tags messages/failures by project (api, web) not by an
# ambiguous dir basename, and federated refs can use <name>:<node>.
_member_name() {
  local cfg="$1/.ibis/config"
  if [[ -f "$cfg" ]] && grep -q '^name=' "$cfg"; then
    grep '^name=' "$cfg" | head -1 | cut -d= -f2-
  else
    basename "$1"
  fi
}

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
    currency)  _hub_currency "$@";;
    *) die "ibis hub <init|add|remove|list|poll|status|who|notify|currency>";;
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
    name="$(_member_name "$member")"
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
    name="$(_member_name "$member")"
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

# ibis hub currency — multi-repo drift detection.
# Fetches each member, reports behind/ahead/diverged/dirty.
# Writes REPO_STATE.md in the hub root.
_hub_currency() {
  require_hub

  # Try to pick up SSH agent for cron environments
  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    local sock="/run/user/$(id -u)/keyring/ssh"
    [[ -S "$sock" ]] && export SSH_AUTH_SOCK="$sock"
  fi

  local output="$HUB_ROOT/REPO_STATE.md"
  local tmp; tmp="$(mktemp "${output}.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN

  local ts_now; ts_now="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
  {
    echo "# Repo currency state"
    echo ""
    echo "Last check: \`$ts_now\`  (ibis hub currency)"
    echo ""
    echo "---"
    echo ""
  } > "$tmp"

  local any_drift=0 member name

  while IFS= read -r member; do
    [[ -z "$member" ]] && continue
    name="$(_member_name "$member")"

    if [[ ! -d "$member/.git" ]]; then
      printf '## %s\n  not a git repo at `%s`\n\n' "$name" "$member" >> "$tmp"
      any_drift=1
      continue
    fi

    local branch
    branch="$(git -C "$member" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

    if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
      printf '## %s\n  detached HEAD\n\n' "$name" >> "$tmp"
      any_drift=1
      continue
    fi

    local fetch_out fetch_rc
    fetch_out="$(timeout 30 git -C "$member" fetch --all --quiet 2>&1)"
    fetch_rc=$?

    local upstream
    upstream="$(git -C "$member" rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null || echo "")"
    if [[ -z "$upstream" ]]; then
      printf '## %s\n  branch `%s` has no upstream\n\n' "$name" "$branch" >> "$tmp"
      any_drift=1
      continue
    fi

    if [[ $fetch_rc -ne 0 ]]; then
      printf '## %s\n  fetch failed (rc=%d): %s\n\n' "$name" "$fetch_rc" "$fetch_out" >> "$tmp"
      any_drift=1
      continue
    fi

    local behind ahead dirty
    behind="$(git -C "$member" rev-list --count "HEAD..${upstream}" 2>/dev/null || echo "?")"
    ahead="$(git -C "$member" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo "?")"
    dirty="$(git -C "$member" status --porcelain 2>/dev/null | wc -l | awk '{print $1}')"

    printf '## %s  (`%s` <- `%s`)\n' "$name" "$branch" "$upstream" >> "$tmp"

    if [[ "$behind" == "0" && "$ahead" == "0" ]]; then
      printf '  up to date\n' >> "$tmp"
    elif [[ "$behind" != "0" && "$ahead" == "0" ]]; then
      printf '  **%s commits behind %s** — run `git pull --ff-only`\n' "$behind" "$upstream" >> "$tmp"
      git -C "$member" log "HEAD..${upstream}" --oneline 2>/dev/null | head -5 | sed 's/^/    /' >> "$tmp"
      any_drift=1
    elif [[ "$behind" == "0" && "$ahead" != "0" ]]; then
      printf '  %s commits AHEAD of %s — push when ready\n' "$ahead" "$upstream" >> "$tmp"
    else
      printf '  DIVERGED: %s ahead / %s behind %s\n' "$ahead" "$behind" "$upstream" >> "$tmp"
      any_drift=1
    fi

    if [[ "$dirty" != "0" ]]; then
      printf '  working tree has %s uncommitted change(s)\n' "$dirty" >> "$tmp"
    fi
    echo >> "$tmp"
  done < <(_members)

  if [[ "$any_drift" == "0" ]]; then
    { echo "---"; echo ""; echo "**All member repos current.**"; } >> "$tmp"
    ok "all member repos current"
  else
    { echo "---"; echo ""; echo "**Drift detected.** Pull behind repos before making claims about their state."; } >> "$tmp"
    warn "drift detected — see $output"
  fi

  mv "$tmp" "$output"
  trap - RETURN
}
