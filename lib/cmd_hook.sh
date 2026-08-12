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
    install)      _hook_install;;
    uninstall)    _hook_uninstall;;
    check)        _hook_check "$@";;
    post-commit)  _hook_post_commit;;
    pre-commit)   _hook_pre_commit;;
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

  # post-commit hook: auto-notify with commit hash + subject + changed files
  local gd; gd="$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null)" || die "not a git repo"
  local pc="$gd/hooks/post-commit"
  if [[ -f "$pc" ]] && ! grep -q 'hook post-commit' "$pc"; then
    warn "existing post-commit hook found — appending ibis auto-notify"
    printf '\n"%s" hook post-commit\n' "$IBIS_HOME/bin/ibis" >> "$pc"
  else
    { echo "#!/usr/bin/env bash"
      echo "# installed by: ibis hook install"
      echo "\"$IBIS_HOME/bin/ibis\" hook post-commit"; } > "$pc"
  fi
  chmod +x "$pc"
  ok "installed post-commit hook → $pc"

  # pre-commit hook (notify-required gate): only if require_notify=true in config
  local rn; rn="$(config_get require_notify)"
  if [[ "$rn" == "true" ]]; then
    local pre="$gd/hooks/pre-commit"
    if [[ -f "$pre" ]] && ! grep -q 'hook pre-commit' "$pre"; then
      warn "existing pre-commit hook found — appending ibis notify check"
      printf '\n"%s" hook pre-commit || exit $?\n' "$IBIS_HOME/bin/ibis" >> "$pre"
    else
      { echo "#!/usr/bin/env bash"
        echo "# installed by: ibis hook install"
        echo "exec \"$IBIS_HOME/bin/ibis\" hook pre-commit"; } > "$pre"
    fi
    chmod +x "$pre"
    ok "installed pre-commit hook → $pre (require_notify=true)"
  fi
}

_hook_uninstall() {
  local gd; gd="$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null)" || die "not a git repo"
  local hook; hook="$(_hook_path)"
  if [[ -f "$hook" ]] && grep -q 'hook check' "$hook"; then
    rm -f "$hook"; ok "removed $hook"
  else
    warn "no ibis commit-msg hook installed"
  fi
  local pc="$gd/hooks/post-commit"
  if [[ -f "$pc" ]] && grep -q 'hook post-commit' "$pc"; then
    rm -f "$pc"; ok "removed $pc"
  else
    warn "no ibis post-commit hook installed"
  fi
  local pre="$gd/hooks/pre-commit"
  if [[ -f "$pre" ]] && grep -q 'hook pre-commit' "$pre"; then
    rm -f "$pre"; ok "removed $pre"
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

# _hook_post_commit — auto-notify with commit hash + subject + changed files.
# Runs after every commit via the post-commit hook.
_hook_post_commit() {
  set_paths
  [[ -d "$IBIS_DIR" ]] || return 0
  local hash subject files proj
  hash="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)" || return 0
  subject="$(git -C "$REPO_ROOT" log -1 --format='%s' 2>/dev/null)" || return 0
  files="$(git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | head -5)"
  proj="$(config_get name 2>/dev/null)"
  [[ -z "$proj" ]] && proj="$(basename "$REPO_ROOT")"
  local flist=""
  [[ -n "$files" ]] && flist=" | $(echo "$files" | tr '\n' ' ')"
  ibis_notify "[$proj] $hash $subject$flist" 2>/dev/null || true
}

# _hook_pre_commit — notify-required gate.
# Blocks commit if no ibis notify was recorded in the last N minutes.
# Enable: require_notify=true in .ibis/config
# Configure window: notify_window=15 in .ibis/config (default 15 min)
_hook_pre_commit() {
  set_paths
  [[ -d "$IBIS_DIR" ]] || return 0
  local rn; rn="$(config_get require_notify)"
  [[ "$rn" == "true" ]] || return 0
  local window; window="$(config_get notify_window)"
  [[ -z "$window" ]] && window=15
  local cutoff notify_dir="$IBIS_DIR/.notify"
  cutoff=$(( $(date +%s) - window * 60 ))
  local found=0
  if [[ -d "$notify_dir" ]]; then
    local f
    for f in "$notify_dir"/*.pending "$notify_dir"/*.drained; do
      [[ -e "$f" ]] || continue
      local mtime
      if stat --version &>/dev/null; then
        mtime=$(stat -c '%Y' "$f" 2>/dev/null) || continue
      else
        mtime=$(stat -f '%m' "$f" 2>/dev/null) || continue
      fi
      if [[ "$mtime" -ge "$cutoff" ]]; then
        found=1; break
      fi
    done
  fi
  if [[ $found -eq 0 ]]; then
    cat >&2 <<EOF

⚠ ibis NOTIFY-REQUIRED: no ibis notify in the last ${window} minutes.
  Before committing, describe what you're about to do:
    ibis notify "what you changed"
  Then retry the commit.
  (Disable: set require_notify=false in .ibis/config)
EOF
    return 1
  fi
  return 0
}
