#!/usr/bin/env bash
# cmd_hook.sh — keep the in-repo graph in sync with commits.
#
# ibis's graph lives IN the repo (.ibis/GRAPH.dot), so a commit that closes a
# node's todo= CAN — and should — update the graph in the SAME commit. (A
# centralized graph, like a separate coordination repo, can't do this: the work
# and the annotation are in different repos, so shipped work silently leaves the
# graph stale and other workers read it as still-open.)
#
# This installs a `commit-msg` hook that fires when a commit uses completion
# language but doesn't stage .ibis/GRAPH.dot while open todo= items exist.
# Default: warn. IBIS_HOOK_STRICT=1: block.

COMPLETION_RE='\b(done|closed?|closes|fix(ed|es)?|resolv(e|ed|es)|ship(ped)?|complete[ds]?|scrub(bed|s)?|finish(ed)?|mark(ed)? done)\b'

ibis_hook() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    install)   _hook_install;;
    uninstall) _hook_uninstall;;
    check)     _hook_check "$@";;
    *) echo "usage: ibis hook <install|uninstall>"; return 0;;
  esac
}

_hook_path() {
  set_paths
  local gd; gd="$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null)" || die "not a git repo"
  mkdir -p "$gd/hooks"
  printf '%s/hooks/commit-msg\n' "$gd"
}

_hook_install() {
  set_paths; require_init
  local hook; hook="$(_hook_path)"
  if [[ -f "$hook" ]] && ! grep -q 'hook check' "$hook"; then
    warn "existing commit-msg hook found — appending ibis check"
    printf '\n"%s" hook check "$1" || exit $?\n' "$IBIS_HOME/bin/ibis" >> "$hook"
  else
    { echo "#!/usr/bin/env bash"
      echo "# installed by: ibis hook install"
      echo "exec \"$IBIS_HOME/bin/ibis\" hook check \"\$1\""; } > "$hook"
  fi
  chmod +x "$hook"
  ok "installed commit-msg hook → $hook"
  echo "    block instead of warn:  export IBIS_HOOK_STRICT=1"
}

_hook_uninstall() {
  local hook; hook="$(_hook_path)"
  if [[ -f "$hook" ]] && grep -q 'hook check' "$hook"; then
    rm -f "$hook"; ok "removed $hook"
  else
    warn "no ibis commit-msg hook installed"
  fi
}

# _hook_check <commit-msg-file> — run by git. exit 0 = allow, 1 = block (strict).
# Two independent checks: graph-sync (closed a todo? stage the graph) and
# doc-coverage (touched a cover= file? a node must track it via doc=).
_hook_check() {
  set_paths
  [[ -f "$GRAPH" ]] || return 0
  local msgfile="${1:-}" msg="" staged
  [[ -f "$msgfile" ]] && msg="$(grep -v '^#' "$msgfile" 2>/dev/null || true)"
  staged="$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null || true)"
  local rc=0
  _hook_graph_sync   || rc=1
  _hook_doc_coverage || rc=1
  return $rc
}

# Closed work but didn't stage .ibis/GRAPH.dot while open todos exist → drift.
_hook_graph_sync() {
  echo "$staged" | grep -q '\.ibis/GRAPH\.dot$' && return 0
  grep -q 'todo="' "$GRAPH" 2>/dev/null || return 0           # no open todos
  echo "$msg" | grep -qiE "$COMPLETION_RE" || return 0        # not completion language
  cat >&2 <<EOF

⚠ ibis GRAPH-SYNC: this commit reads like it closes work, but it doesn't stage
  .ibis/GRAPH.dot — and the graph still has open todo= items. Other workers read
  the graph, not your commit. Clear the todo you finished in THIS commit:
    \$EDITOR .ibis/GRAPH.dot && git add .ibis/GRAPH.dot
  See open todos:  grep -n 'todo="' .ibis/GRAPH.dot
EOF
  [[ -n "${IBIS_HOOK_STRICT:-}" ]] && { echo "  IBIS_HOOK_STRICT=1 → blocking." >&2; return 1; }
  return 0
}

# Files matching .ibis/config cover= globs must be referenced by a node's doc=,
# so a stale string in them is caught by that node's test= instead of by a human.
# (The portable form of the hub's pre-commit-graph-doc-check.)
_hook_doc_coverage() {
  local cover; cover="$(config_get cover)"
  [[ -z "$cover" ]] && return 0
  local docs; docs="$(grep -oE 'doc[0-9]*="[^"]+"' "$GRAPH" | sed 's/^doc[0-9]*="//;s/"$//' | sort -u)"
  local missing=() f d pat matched ok
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    matched=0; local IFS=','; local pats=($cover); unset IFS
    for pat in "${pats[@]}"; do
      pat="$(echo "$pat" | xargs)"; [[ -z "$pat" ]] && continue
      case "$f" in $pat) matched=1; break;; esac
    done
    [[ $matched -eq 0 ]] && continue
    ok=0
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      [[ "$f" == "$d" ]] && { ok=1; break; }
      [[ "$d" == */ && "$f" == "$d"* ]] && { ok=1; break; }
      [[ -d "$REPO_ROOT/$d" && "$f" == "$d/"* ]] && { ok=1; break; }
    done <<<"$docs"
    [[ $ok -eq 0 ]] && missing+=("$f")
  done <<<"$staged"
  [[ ${#missing[@]} -eq 0 ]] && return 0
  { echo ""
    echo "⚠ ibis DOC-COVERAGE: these touched files match cover= but no graph node"
    echo "  references them (doc=) — untracked, so no test= pin guards them:"
    printf '    - %s\n' "${missing[@]}"
    echo "  Add a node with doc= (and test=) for each."
  } >&2
  [[ -n "${IBIS_HOOK_STRICT:-}" ]] && { echo "  IBIS_HOOK_STRICT=1 → blocking." >&2; return 1; }
  return 0
}
