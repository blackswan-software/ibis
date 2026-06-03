#!/usr/bin/env bash
# install.sh — put the ibis CLI on your PATH (macOS / Linux / WSL / Git Bash).
# Per-repo scheduling is installed later by `ibis init` (systemd/launchd/cron).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${IBIS_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$DEST"
ln -sf "$SRC/bin/ibis" "$DEST/ibis"
chmod +x "$SRC/bin/ibis" "$SRC/lib/graph-checks.py"
echo "✓ linked $DEST/ibis -> $SRC/bin/ibis"

missing=0
for dep in bash git; do
  command -v "$dep" >/dev/null 2>&1 || { echo "✗ missing dependency: $dep"; missing=1; }
done
command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 \
  || { echo "✗ missing dependency: python3 (or python)"; missing=1; }
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "✗ bash ${BASH_VERSION} is too old — ibis needs bash >= 4. macOS: brew install bash"
  missing=1
fi
[[ $missing -eq 0 ]] && echo "✓ deps present (bash $(echo "$BASH_VERSION" | cut -d. -f1-2), python, git)"

case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "→ add to your shell rc:  export PATH=\"$DEST:\$PATH\"" ;;
esac

echo ""
echo "Next:  cd your-repo && ibis init --adopt"
