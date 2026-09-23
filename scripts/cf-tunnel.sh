#!/usr/bin/env bash
# DX9HERMES — Cloudflare Tunnel setup (menu option 5 / install.sh Cloudflare path)
#
# Usage:
#   cf-tunnel.sh create --token <CF_API_TOKEN> --zone <zone> --subdomain <sub>
#
# Requires a Cloudflare API token scoped to:
#   Account -> Cloudflare Tunnel -> Edit
#   Zone    -> DNS               -> Edit
#   Zone    -> Zone               -> Read
set -euo pipefail

CONF_DIR="/etc/dx9hermes"
CF_DIR="/etc/cloudflared"
API="https://api.cloudflare.com/client/v4"
# Local port where Caddy fronts 9Router with the secret-path layer
# described in README.md's security section, before cloudflared's
# ingress hands traffic to it. Not 443/80 and not 20128, so it never
# collides with the bare-IP Caddy instance or with 9Router itself, and both
# access modes can coexist on the box if the operator switches back and
# forth.
CF_LOCAL_PORT=8098

mkdir -p "$CONF_DIR"

ACTION="${1:-}"; shift || true
TOKEN=""; ZONE=""; SUB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --subdomain) SUB="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ "$ACTION" = "create" ] || { echo "Only 'create' is supported."; exit 1; }
: "${TOKEN:?--token required}"; : "${ZONE:?--zone required}"; : "${SUB:?--subdomain required}"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed (should have been installed by install_deps)." >&2; exit 1; }

# Resolve the cloudflared binary wherever install.sh actually put it, instead
# of hardcoding /usr/bin (BUG-002: install.sh downloads the static binary to
# /usr/local/bin, so a hardcoded /usr/bin path made the systemd unit fail
# with 203/EXEC on any host that doesn't already have cloudflared from apt).
CLOUDFLARED_BIN="$(command -v cloudflared || true)"
[ -n "$CLOUDFLARED_BIN" ] || { echo "cloudflared binary not found on PATH." >&2; exit 1; }

api() { curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

# Returns amd64/arm64/armv7 the way most project release pages name them.
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "arm" ;;
    *) return 1 ;;
  esac
}

# NOTE: 9Router (127.0.0.1:20128) has a known RCE (default password +
# Host-header spoof + unsafe command execution on MCP plugin registration —
# see README.md). This local Caddy layer used to also hide the dashboard
# behind a random secret path/cookie gate; per operator request that extra
# obscurity layer was dropped (see install.sh's setup_caddy() BUG-FIX note
# for why it was fragile — 9Router's own root-relative redirects kept
# breaking it — and the operator confirmed it isn't needed here). This still
# keeps cloudflared's ingress pointed at a local Caddy proxy rather than at
# 9Router directly, purely so the Cloudflare Tunnel path and the bare-IP
# path share one code path; the actual login boundary is 9Router's own
# dashboard password either way.
ensure_caddy() {
  command -v caddy >/dev/null 2>&1 && return 0
  local arch
  arch="$(detect_arch)" || { echo "Unsupported CPU architecture: $(uname -m)" >&2; exit 1; }
  echo "Downloading Caddy static binary (linux/$arch)..."
  curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${arch}" -o /usr/local/bin/caddy
  chmod +x /usr/local/bin/caddy
  command -v caddy >/dev/null 2>&1 || { echo "Caddy download failed — check network/output above." >&2; exit 1; }
}

setup_local_caddy_front() {
  ensure_caddy
  mkdir -p /etc/caddy /var/lib/caddy
  if ! id caddy >/dev/null 2>&1; then
    useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
  fi
  chown -R caddy:caddy /var/lib/caddy

  if [ ! -f /etc/systemd/system/caddy-cftunnel.service ]; then
    cat > /etc/systemd/system/caddy-cftunnel.service <<EOF
[Unit]
Description=Caddy reverse proxy fronting 9Router for the Cloudflare Tunnel (DX9HERMES)
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile.cftunnel
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile.cftunnel --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  # Per operator request: no secret path, no cookie gate — just a plain
  # reverse proxy to 9Router. Matches the simplified bare-IP Caddyfile in
  # install.sh's setup_caddy() (see its comment for the full history of why
  # the secret-path/cookie-gate approach was dropped: it broke on 9Router's
  # own root-relative redirects/assets, and the operator doesn't need the
  # extra obscurity layer anyway).
  cat > /etc/caddy/Caddyfile.cftunnel <<EOF
:${CF_LOCAL_PORT} {
  reverse_proxy 127.0.0.1:20128 {
    header_up Host 127.0.0.1:20128
  }
}
EOF

  systemctl enable --now caddy-cftunnel
  systemctl reload caddy-cftunnel || systemctl restart caddy-cftunnel

  rm -f "$CONF_DIR/dashboard_path" "$CONF_DIR/dashboard_basicauth"
}

setup_local_caddy_front

ACCOUNT_ID="$(api "$API/accounts" | jq -r '.result[0].id // empty')"
ZONE_ID="$(api "$API/zones?name=${ZONE}" | jq -r '.result[0].id // empty')"
[ -n "$ACCOUNT_ID" ] && [ -n "$ZONE_ID" ] || { echo "Could not resolve account/zone from token." >&2; exit 1; }

TUNNEL_NAME="dx9hermes-$(hostname -s)"
mkdir -p "$CF_DIR"

# BUG-011: reuse/replace a previous tunnel of the same name instead of
# letting orphaned tunnels pile up in the Cloudflare account on every re-run.
EXISTING_ID="$(api "$API/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false" \
  | jq -r '.result[0].id // empty')"
if [ -n "$EXISTING_ID" ]; then
  echo "Found existing tunnel '${TUNNEL_NAME}' (${EXISTING_ID}) — deleting it before creating a fresh one."
  api -X DELETE "$API/accounts/${ACCOUNT_ID}/cfd_tunnel/${EXISTING_ID}" >/dev/null || true
fi

TUNNEL_JSON="$(api -X POST "$API/accounts/${ACCOUNT_ID}/cfd_tunnel" \
  --data "{\"name\":\"${TUNNEL_NAME}\",\"config_src\":\"cloudflare\"}")"
TUNNEL_ID="$(echo "$TUNNEL_JSON" | jq -r '.result.id // empty')"
[ -n "$TUNNEL_ID" ] || { echo "Tunnel creation failed: $TUNNEL_JSON" >&2; exit 1; }

# BUG-003 fix: write the *complete* credentials file the API gave us,
# TunnelSecret included — the previous version extracted this object but
# never used it, so cloudflared always failed to authenticate the tunnel.
TUNNEL_SECRET="$(echo "$TUNNEL_JSON" | jq -r '.result.credentials_file.TunnelSecret // empty')"
[ -n "$TUNNEL_SECRET" ] || { echo "API response did not include a TunnelSecret: $TUNNEL_JSON" >&2; exit 1; }

cat > "$CF_DIR/${TUNNEL_ID}.json" <<EOF
{"AccountTag":"${ACCOUNT_ID}","TunnelID":"${TUNNEL_ID}","TunnelName":"${TUNNEL_NAME}","TunnelSecret":"${TUNNEL_SECRET}"}
EOF
chmod 600 "$CF_DIR/${TUNNEL_ID}.json"

cat > "$CF_DIR/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CF_DIR}/${TUNNEL_ID}.json
ingress:
  - hostname: ${SUB}.${ZONE}
    service: http://127.0.0.1:${CF_LOCAL_PORT}
  - service: http_status:404
EOF

api -X PUT "$API/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  --data "{\"config\":{\"ingress\":[{\"hostname\":\"${SUB}.${ZONE}\",\"service\":\"http://127.0.0.1:${CF_LOCAL_PORT}\"},{\"service\":\"http_status:404\"}]}}" \
  >/dev/null

api -X POST "$API/zones/${ZONE_ID}/dns_records" \
  --data "{\"type\":\"CNAME\",\"name\":\"${SUB}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" \
  >/dev/null

cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel (DX9HERMES)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --config ${CF_DIR}/config.yml run ${TUNNEL_ID}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared

echo "${SUB}.${ZONE}" > "$CONF_DIR/dashboard_domain"
echo "Cloudflare Tunnel set up: https://${SUB}.${ZONE}/"
echo "Log in with 9Router's own dashboard password (sent via Telegram after install)."
