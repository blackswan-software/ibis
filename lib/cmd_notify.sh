#!/usr/bin/env bash
# cmd_notify.sh — drop a message on this repo's .notify bus. With the drain
# .path unit installed it lands in HANDOFF within a second; otherwise at the
# next 2-min poll. Fire-and-forget.

ibis_notify() {
  require_init
  local msg="$*"
  [[ -z "$msg" ]] && die "usage: ibis notify <message>"
  mkdir -p "$NOTIFY_DIR"
  # BSD date has no %N; $$/$RANDOM keep names unique within a second.
  local f="$NOTIFY_DIR/$(date +%s)-$$-$RANDOM-msg.pending"
  printf '%s\n' "$msg" > "$f"
  ok "queued: $msg"
}
