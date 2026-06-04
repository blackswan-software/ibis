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
_hook_check() {
  set_paths
  [[ -f "$GRAPH" ]] || return 0
  local msgfile="${1:-}" msg="" staged
  [[ -f "$msgfile" ]] && msg="$(grep -v '^#' "$msgfile" 2>/dev/null || true)"
  staged="$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null || true)"

  echo "$staged" | grep -q '\.ibis/GRAPH\.dot$' && return 0   # graph already updated → fine
  # require the quote so the template's `todo=` comment doesn't false-positive
  grep -q 'todo="' "$GRAPH" 2>/dev/null || return 0           # no open todos → nothing to drift
  echo "$msg" | grep -qiE "$COMPLETION_RE" || return 0        # not completion language → fine

  cat >&2 <<EOF

⚠ ibis GRAPH-SYNC: this commit reads like it closes work, but it doesn't stage
  .ibis/GRAPH.dot — and the graph still has open todo= items. Other workers (and
  sessions) read the graph, not your commit. If you closed a node's todo, clear it
  in THIS commit so they aren't left blind:
    \$EDITOR .ibis/GRAPH.dot      # remove/shorten the todo= you finished
    git add .ibis/GRAPH.dot && git commit --amend --no-edit
  See open todos:  grep -n 'todo="' .ibis/GRAPH.dot
EOF
  if [[ -n "${IBIS_HOOK_STRICT:-}" ]]; then
    echo "  IBIS_HOOK_STRICT=1 → blocking. Stage the graph update, or: git commit --no-verify" >&2
    return 1
  fi
  return 0
}
