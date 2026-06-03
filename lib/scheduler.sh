#!/usr/bin/env bash
# scheduler.sh — cross-platform "run ibis poll on a timer + instant-drain on a
# new message" install. One concept, four backends:
#
#   Linux  → systemd --user  (.timer + .path)      instant drain via PathExistsGlob
#   macOS  → launchd          (StartInterval + WatchPaths)  instant drain via WatchPaths
#   Windows→ Task Scheduler   (schtasks /sc minute) + PowerShell FileSystemWatcher
#   any    → cron             (*/2)                 no instant drain (poll is the floor)
#
# All backends call `ibis poll` (timer) and `ibis poll --drain-only` (instant).

detect_platform() {
  case "$(uname -s 2>/dev/null)" in
    Linux*)
      if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        echo systemd
      else echo cron; fi ;;
    Darwin*) echo launchd ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo cron ;;
  esac
}

# install_scheduler <repo_name> <unit_id>
install_scheduler() {
  local REPO_NAME="$1" UNIT_ID="$2"
  local IBIS_BIN="$IBIS_HOME/bin/ibis"
  export REPO_NAME UNIT_ID IBIS_BIN REPO_ROOT NOTIFY_DIR
  local plat; plat="$(detect_platform)"
  info "scheduler backend: $plat"
  case "$plat" in
    systemd) _sched_systemd ;;
    launchd) _sched_launchd ;;
    windows) _sched_windows ;;
    *)       _sched_cron ;;
  esac
}

uninstall_scheduler() {
  local UNIT_ID="$1"
  case "$(detect_platform)" in
    systemd)
      systemctl --user disable --now "ibis-poll-$UNIT_ID.timer" "ibis-drain-$UNIT_ID.path" 2>/dev/null
      rm -f "$HOME/.config/systemd/user/ibis-poll-$UNIT_ID."{service,timer} \
            "$HOME/.config/systemd/user/ibis-drain-$UNIT_ID."{service,path}
      systemctl --user daemon-reload ;;
    launchd)
      local la="$HOME/Library/LaunchAgents"
      launchctl unload "$la/com.blackswan.ibis.poll.$UNIT_ID.plist" 2>/dev/null
      launchctl unload "$la/com.blackswan.ibis.drain.$UNIT_ID.plist" 2>/dev/null
      rm -f "$la/com.blackswan.ibis.poll.$UNIT_ID.plist" "$la/com.blackswan.ibis.drain.$UNIT_ID.plist" ;;
    windows)
      schtasks //Delete //TN "ibis-poll-$UNIT_ID" //F 2>/dev/null
      schtasks //Delete //TN "ibis-drain-$UNIT_ID" //F 2>/dev/null ;;
    *)
      warn "cron: remove the ibis lines from 'crontab -e' by hand" ;;
  esac
  ok "scheduler removed ($UNIT_ID)"
}

# ── Linux / systemd --user ──────────────────────────────────────────────────
_sched_systemd() {
  local ud="$HOME/.config/systemd/user"; mkdir -p "$ud"
  render "$IBIS_HOME/templates/ibis-poll.service.tmpl"  > "$ud/ibis-poll-$UNIT_ID.service"
  render "$IBIS_HOME/templates/ibis-poll.timer.tmpl"    > "$ud/ibis-poll-$UNIT_ID.timer"
  render "$IBIS_HOME/templates/ibis-drain.service.tmpl" > "$ud/ibis-drain-$UNIT_ID.service"
  render "$IBIS_HOME/templates/ibis-drain.path.tmpl"    > "$ud/ibis-drain-$UNIT_ID.path"
  systemctl --user daemon-reload
  systemctl --user enable --now "ibis-poll-$UNIT_ID.timer" >/dev/null 2>&1
  systemctl --user enable --now "ibis-drain-$UNIT_ID.path"  >/dev/null 2>&1
  ok "systemd: ibis-poll-$UNIT_ID.timer (2-min) + ibis-drain-$UNIT_ID.path (instant)"
  echo "    persist across logout:  loginctl enable-linger \$USER"
}

# ── macOS / launchd ─────────────────────────────────────────────────────────
_sched_launchd() {
  local la="$HOME/Library/LaunchAgents"; mkdir -p "$la"
  local poll="$la/com.blackswan.ibis.poll.$UNIT_ID.plist"
  local drain="$la/com.blackswan.ibis.drain.$UNIT_ID.plist"
  render "$IBIS_HOME/templates/launchd-poll.plist.tmpl"  > "$poll"
  render "$IBIS_HOME/templates/launchd-drain.plist.tmpl" > "$drain"
  # Reload (ignore "not loaded" errors on first install)
  launchctl unload "$poll" "$drain" 2>/dev/null || true
  if launchctl load -w "$poll" && launchctl load -w "$drain"; then
    ok "launchd: poll (StartInterval 120s) + drain (WatchPaths .notify) loaded"
  else
    warn "launchd plists written but not loaded — load by hand:"
    echo "    launchctl load -w $poll"
    echo "    launchctl load -w $drain"
  fi
}

# ── Windows / Task Scheduler + PowerShell watcher ────────────────────────────
_sched_windows() {
  # ibis runs under Git Bash / MSYS here. schtasks is on PATH; // escapes the
  # MSYS path-mangling of /flags.
  local watch_ps="$REPO_ROOT/.ibis/ibis-watch.ps1"
  render "$IBIS_HOME/templates/windows-watch.ps1.tmpl" > "$watch_ps"
  local bash_exe; bash_exe="$(command -v bash)"

  if command -v schtasks >/dev/null 2>&1; then
    schtasks //Create //TN "ibis-poll-$UNIT_ID" //F //SC MINUTE //MO 2 \
      //TR "\"$bash_exe\" -lc \"cd '$REPO_ROOT' && ibis poll\"" >/dev/null 2>&1 \
      && ok "schtasks: ibis-poll-$UNIT_ID (every 2 min)" \
      || warn "could not create ibis-poll task — see README Windows section"
    schtasks //Create //TN "ibis-drain-$UNIT_ID" //F //SC ONLOGON \
      //TR "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"$watch_ps\"" >/dev/null 2>&1 \
      && ok "schtasks: ibis-drain-$UNIT_ID (FileSystemWatcher at logon) — starts next logon" \
      || warn "could not create ibis-drain task — start the watcher by hand: powershell -File $watch_ps"
    echo "    start the watcher now:  schtasks //Run //TN ibis-drain-$UNIT_ID"
  else
    warn "schtasks not found — run ibis under Git Bash or WSL. See README Windows section."
    _sched_cron
  fi
}

# ── Universal fallback / cron ─────────────────────────────────────────────────
_sched_cron() {
  warn "no per-user service manager detected — use cron (2-min poll is the floor):"
  echo "    (crontab -l 2>/dev/null; echo \"*/2 * * * * cd $REPO_ROOT && $IBIS_HOME/bin/ibis poll >> .ibis/.poll.log 2>&1\") | crontab -"
  echo "  Instant drain needs a file-watch (systemd/launchd/FSWatcher); cron can't do it."
}
