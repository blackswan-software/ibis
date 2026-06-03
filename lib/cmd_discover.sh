#!/usr/bin/env bash
# cmd_discover.sh — scan the repo for candidate nodes.
#
# This is how nodes get "auto-generated": ibis reads the repo's own structure
# (compose services, Dockerfiles, CI, systemd units) and proposes node stubs.
# Discovery NEVER writes the graph by itself — it emits candidates that you
# accept via `ibis add-node` (or `ibis init --adopt`). Every accepted node still
# gets a required doc + test stub. So: discovery is automatic, adoption is gated.
#
# Emits TSV on fd 3 if open (machine mode), else pretty-prints to stdout:
#   kind <TAB> node_id <TAB> display_name <TAB> suggested_check

_emit() {  # kind id name check
  if { true >&3; } 2>/dev/null; then
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >&3
  else
    printf '  \033[36m%-14s\033[0m %-22s %s\n' "$1" "$2" "${4:-(set a check)}"
  fi
}

ibis_discover() {
  set_paths
  local found=0

  # ── docker compose services ───────────────────────────────────────────────
  local cf
  for cf in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [[ -f "$REPO_ROOT/$cf" ]] || continue
    # top-level "services:" → 2-space-indented "name:" keys
    awk '
      /^services:[[:space:]]*$/ {insec=1; next}
      /^[^[:space:]]/ {insec=0}
      insec && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
        gsub(/[: ]/,"",$1); print $1
      }' "$REPO_ROOT/$cf" | while read -r svc; do
      [[ -z "$svc" ]] && continue
      _emit "compose" "$(nodeid "$svc")" "$svc" "docker compose ps -q $svc | grep -q ."
      found=1
    done
    found=1
  done

  # ── Dockerfile EXPOSE → http liveness ─────────────────────────────────────
  local df port
  while IFS= read -r df; do
    port=$(grep -iE '^EXPOSE ' "$df" | head -1 | grep -oE '[0-9]+' | head -1)
    [[ -z "$port" ]] && continue
    local id; id=$(nodeid "$(basename "$(dirname "$df")")")
    [[ "$id" == "." || -z "$id" ]] && id="app"
    _emit "dockerfile" "$id" "$(basename "$(dirname "$df")")" "curl -fsS http://localhost:$port/ >/dev/null"
    found=1
  done < <(find "$REPO_ROOT" -maxdepth 3 -name Dockerfile -not -path '*/node_modules/*' 2>/dev/null)

  # ── package.json with a start/server script → app node ────────────────────
  if [[ -f "$REPO_ROOT/package.json" ]] && grep -qE '"(start|serve|dev)"[[:space:]]*:' "$REPO_ROOT/package.json"; then
    _emit "node-app" "app" "$(basename "$REPO_ROOT")" "# TODO: curl your health endpoint"
    found=1
  fi

  # ── GitHub Actions workflows → CI node ────────────────────────────────────
  if [[ -d "$REPO_ROOT/.github/workflows" ]] && compgen -G "$REPO_ROOT/.github/workflows/*.y*ml" >/dev/null; then
    _emit "ci" "ci" "GitHub Actions" "gh run list --limit 1 --json conclusion -q '.[0].conclusion' | grep -qx success"
    found=1
  fi

  # ── repo-local systemd units ──────────────────────────────────────────────
  local u
  while IFS= read -r u; do
    local id; id=$(nodeid "$(basename "$u" .service)")
    _emit "systemd" "$id" "$(basename "$u")" "systemctl --user is-active $(basename "$u") | grep -qx active"
    found=1
  done < <(find "$REPO_ROOT" -maxdepth 2 -name '*.service' 2>/dev/null)

  if [[ $found -eq 0 ]] && ! { true >&3; } 2>/dev/null; then
    warn "no candidate services found (no compose/Dockerfile/CI/systemd detected)"
    echo "    Add nodes manually:  ibis add-node <name> --check '<cmd>'"
  fi
}
