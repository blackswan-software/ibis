#!/usr/bin/env bash
# cmd_claim.sh — work leases. Lets multiple workers (people / Claude sessions)
# coordinate without colliding: claim a node before working it. The claim is
# visible to everyone and EXPIRES, so a dead session never blocks others — the
# safety primitive that "discipline + hope" isn't.
#
# Files: .ibis/claims/<slug>.lease = worker<TAB>epoch<TAB>ttl<TAB>node

_claims_dir() { printf '%s\n' "$IBIS_DIR/claims"; }
_lease_file() { printf '%s/%s.lease\n' "$(_claims_dir)" "$(slug "$1")"; }

# Echo "worker<TAB>epoch<TAB>ttl<TAB>node" if the file holds an ACTIVE (non-expired)
# lease; return non-zero otherwise.
_lease_read() {
  local f="$1"; [[ -f "$f" ]] || return 1
  local w e t n now; IFS=$'\t' read -r w e t n < "$f"
  [[ -n "$e" && -n "$t" ]] || return 1
  now=$(date +%s)
  (( now < e + t )) || return 1
  printf '%s\t%s\t%s\t%s\n' "$w" "$e" "$t" "$n"
}

ibis_claim() {
  require_init
  local node="" ttl=3600
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ttl) ttl="$2"; shift 2;;
      -*) die "unknown flag: $1";;
      *) node="$1"; shift;;
    esac
  done
  [[ -z "$node" ]] && die "usage: ibis claim <node> [--ttl seconds]"
  mkdir -p "$(_claims_dir)"
  local me f cur; me="$(worker_id)"; f="$(_lease_file "$node")"
  if cur="$(_lease_read "$f")"; then
    local w e t n; IFS=$'\t' read -r w e t n <<<"$cur"
    if [[ "$w" != "$me" ]]; then
      err "$node is claimed by $w ($(( e + t - $(date +%s) ))s left) — coordinate or wait"
      return 1
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$me" "$(date +%s)" "$ttl" "$node" > "$f"
  ok "claimed $node as $me (ttl ${ttl}s)"
}

ibis_release() {
  require_init
  local node="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --force) force=1; shift;; *) node="$1"; shift;; esac
  done
  [[ -z "$node" ]] && die "usage: ibis release <node> [--force]"
  local f; f="$(_lease_file "$node")"
  [[ -f "$f" ]] || { warn "no lease on $node"; return 0; }
  local me w; me="$(worker_id)"; IFS=$'\t' read -r w _ _ _ < "$f"
  if [[ "$w" != "$me" && $force -eq 0 ]]; then
    err "$node is held by $w, not you — use --force to override"; return 1
  fi
  rm -f "$f"; ok "released $node"
}

# ibis who — active claims in this repo (expired leases are swept).
ibis_who() {
  require_init
  local d; d="$(_claims_dir)"
  [[ -d "$d" ]] || { echo "no active claims"; return 0; }
  local f any=0 now; now=$(date +%s)
  for f in "$d"/*.lease; do
    [[ -f "$f" ]] || continue
    local cur
    if cur="$(_lease_read "$f")"; then
      local w e t n; IFS=$'\t' read -r w e t n <<<"$cur"
      printf '  \033[36m%-24s\033[0m %-20s %ss left\n' "$w" "$n" "$(( e + t - now ))"
      any=1
    else
      rm -f "$f"
    fi
  done
  [[ $any -eq 0 ]] && echo "  no active claims"
  return 0
}
