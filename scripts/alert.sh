#!/usr/bin/env bash
# Invoked by systemd's OnFailure= for 9router.service / hermes-gateway.service
set -euo pipefail
UNIT="${1:-unknown-service}"
# shellcheck disable=SC1091
source /etc/dx9hermes/hermes.env 2>/dev/null || true

[ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_OWNER_ID:-}" ] || exit 0

curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_OWNER_ID}" \
  --data-urlencode text="⚠️ DX9HERMES: service ${UNIT} failed and was restarted by systemd. Check: journalctl -u ${UNIT} -n 50" \
  >/dev/null || true
