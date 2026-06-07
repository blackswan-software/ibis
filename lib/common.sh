#!/usr/bin/env bash
# common.sh — shared helpers for the ibis CLI. Sourced by bin/ibis.

# Python interpreter — macOS/Git-Bash may expose only `python`, not `python3`.
PYTHON="$(command -v python3 || command -v python || true)"

# Worker identity — who is this session? Override with IBIS_WORKER (e.g. a Claude
# session id). Used to attribute messages and own leases.
worker_id() {
  if [[ -n "${IBIS_WORKER:-}" ]]; then printf '%s\n' "$IBIS_WORKER"
  else printf '%s@%s\n' "${USER:-$(id -un 2>/dev/null || echo user)}" "$(hostname -s 2>/dev/null || echo host)"; fi
}

# ── Locations ─────────────────────────────────────────────────────────────
# IBIS_HOME = where ibis is installed (set by bin/ibis).
# REPO_ROOT = the git repo (or cwd) ibis is operating on.
# IBIS_DIR  = the per-repo state dir, REPO_ROOT/.ibis
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

set_paths() {
  REPO_ROOT="$(repo_root)"
  IBIS_DIR="$REPO_ROOT/.ibis"
  GRAPH="$IBIS_DIR/GRAPH.dot"
  NOTIFY_DIR="$IBIS_DIR/.notify"
  DOCS_DIR="$IBIS_DIR/docs"
  TESTS_DIR="$REPO_ROOT/tests/ibis"
  HANDOFF="$REPO_ROOT/HANDOFF.md"
}

# ── Output ────────────────────────────────────────────────────────────────
ts()   { date '+%Y-%m-%d %H:%M'; }
info() { printf '\033[36m●\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_init() {
  [[ -f "$GRAPH" ]] || die "no .ibis/GRAPH.dot in $REPO_ROOT — run 'ibis init' first"
}

# Render a template, substituting {{VAR}} placeholders from the environment.
# Usage: render templates/foo.tmpl > dest   (with VARs exported)
render() {
  local tmpl="$1"
  [[ -f "$tmpl" ]] || die "missing template: $tmpl"
  local line; local out
  out="$(cat "$tmpl")"
  # Substitute every {{NAME}} with ${NAME}
  while [[ "$out" =~ \{\{([A-Z_][A-Z0-9_]*)\}\} ]]; do
    local key="${BASH_REMATCH[1]}"
    local val="${!key:-}"
    out="${out//\{\{$key\}\}/$val}"
  done
  printf '%s\n' "$out"
}

# slug: lowercase, strip non-alnum to dashes (for node names / filenames)
slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }

# camel node id from a slug (graphviz-friendly: no dashes)
# camelCase a slug into a graphviz-safe id (no GNU-sed \U — BSD-safe via awk)
nodeid() {
  slug "$1" | awk -F- '{ s=$1; for (i=2;i<=NF;i++) s=s toupper(substr($i,1,1)) substr($i,2); print s }'
}

# Project identity. An explicit name in .ibis/config wins; else the repo dir name.
# Used to namespace everything a human sees (HANDOFF title, message tags, scheduler
# unit names, hub member display, federated <name>:<node> refs) so a consumer with
# two ibis projects can tell them apart. Needs set_paths first (uses IBIS_DIR).
project_name() {
  local cfg="${IBIS_DIR:-}/config"
  if [[ -n "${IBIS_DIR:-}" && -f "$cfg" ]] && grep -q '^name=' "$cfg"; then
    grep '^name=' "$cfg" | head -1 | cut -d= -f2-
  else
    basename "${REPO_ROOT:-$PWD}"
  fi
}
project_id() { nodeid "$(project_name)"; }

# Read a key from .ibis/config (e.g. cover=*/install.sh,*/README.md). Empty if unset.
config_get() {
  local k="$1" cfg="${IBIS_DIR:-}/config"
  [[ -n "${IBIS_DIR:-}" && -f "$cfg" ]] || return 0
  grep "^$k=" "$cfg" 2>/dev/null | head -1 | cut -d= -f2-
}
