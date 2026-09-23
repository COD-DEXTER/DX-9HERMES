#!/usr/bin/env bash
# DX9HERMES — Check For Update (menu option 15)
#
# Snapshots the current 9Router version + config before touching anything.
# If the post-update health check fails, automatically rolls back the
# npm package version and restores the config snapshot, then reports
# failure instead of leaving the stack half-updated.
set -euo pipefail
set -o errtrace  # required so the ERR trap below also fires for failures inside called functions (do_update), not just top-level commands

CONF_DIR="/etc/dx9hermes"
DATA_DIR="/var/lib/9router"
BACKUP_ROOT="/var/backups/dx9hermes"
TS="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_DIR="$BACKUP_ROOT/pre-update-$TS"

C_GREEN='\033[1;32m'; C_RED='\033[1;31m'; C_YELLOW='\033[1;33m'; C_RESET='\033[0m'
log()  { printf "${C_GREEN}[update]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[update]${C_RESET} %s\n" "$*"; }
err()  { printf "${C_RED}[update]${C_RESET} %s\n" "$*" >&2; }

snapshot() {
  log "Snapshotting current state to $SNAPSHOT_DIR ..."
  mkdir -p "$SNAPSHOT_DIR"
  cp -a "$CONF_DIR" "$SNAPSHOT_DIR/etc-dx9hermes"
  # Snapshot the whole data dir (not just config/) so a rollback also undoes
  # any DB/state migration the new version may have performed. Excludes any
  # oversized model-cache subfolder if present, to keep snapshots cheap.
  mkdir -p "$SNAPSHOT_DIR/9router-data"
  cp -a "$DATA_DIR/." "$SNAPSHOT_DIR/9router-data/" 2>/dev/null || true
  cp -a /etc/systemd/system/9router.service "$SNAPSHOT_DIR/9router.service"
  npm ls -g 9router --depth=0 --json > "$SNAPSHOT_DIR/9router-version.json" 2>/dev/null || true
}

current_version() {
  npm ls -g 9router --depth=0 --json 2>/dev/null \
    | grep -o '"version": *"[^"]*"' | head -1 | cut -d'"' -f4
}

do_update() {
  log "Current 9Router version: $(current_version || echo unknown)"
  # shellcheck disable=SC1090
  [ -f "$CONF_DIR/9router.env" ] && source "$CONF_DIR/9router.env"
  local target="9router@latest"
  if [ -n "${ROUTER_VERSION_PIN:-}" ]; then
    log "Updating 9Router to the pinned version ${ROUTER_VERSION_PIN} (from 9router.env)..."
    target="9router@${ROUTER_VERSION_PIN}"
  else
    warn "No ROUTER_VERSION_PIN set — updating to whatever 'latest' resolves to on npm right now."
    log "Updating 9Router to latest..."
  fi
  npm install -g "$target"
  log "New 9Router version: $(current_version || echo unknown)"
  systemctl restart 9router
}

health_check() {
  log "Running post-update health check..."
  local ok=0
  for i in $(seq 1 10); do
    if curl -fsS -m 3 http://127.0.0.1:20128/v1/models >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep 2
  done
  [ "$ok" -eq 1 ]
}

rollback() {
  # Never let a failure inside rollback itself re-trigger the ERR trap below
  # (that would recurse); from here on we handle errors manually.
  trap - ERR
  set +e
  err "Rolling back to the pre-update snapshot ($SNAPSHOT_DIR) ..."
  local prev_version
  prev_version=$(grep -o '"version": *"[^"]*"' "$SNAPSHOT_DIR/9router-version.json" 2>/dev/null | head -1 | cut -d'"' -f4)
  if [ -n "${prev_version:-}" ]; then
    npm install -g "9router@${prev_version}" || warn "Could not reinstall exact previous version $prev_version"
  fi
  rm -rf "$CONF_DIR"
  cp -a "$SNAPSHOT_DIR/etc-dx9hermes" "$CONF_DIR"
  if [ -d "$SNAPSHOT_DIR/9router-data" ]; then
    rm -rf "${DATA_DIR:?}"/*
    cp -a "$SNAPSHOT_DIR/9router-data/." "$DATA_DIR/"
  fi
  cp -a "$SNAPSHOT_DIR/9router.service" /etc/systemd/system/9router.service
  systemctl daemon-reload
  systemctl restart 9router
  err "Rollback complete. 9Router restored to its previous working state."
  set -e
}

main() {
  snapshot
  # BUG-001 fix: previously only a failed health_check triggered rollback.
  # Because the script runs under `set -e`, a failure *inside* do_update
  # (npm install, systemctl restart, ...) used to kill the script outright
  # before health_check — and therefore rollback — ever ran. This ERR trap
  # makes any failure during the update step itself also roll back.
  trap 'err "Update step failed unexpectedly."; rollback; exit 1' ERR
  do_update
  trap - ERR
  if health_check; then
    log "Update succeeded and 9Router is responding normally."
    # keep the last 5 snapshots, prune older ones
    ls -1dt "$BACKUP_ROOT"/pre-update-* 2>/dev/null | tail -n +6 | xargs -r rm -rf
  else
    rollback
    exit 1
  fi
}

main "$@"
