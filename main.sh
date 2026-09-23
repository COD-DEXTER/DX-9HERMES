#!/usr/bin/env bash
# DX9HERMES — one-line bootstrap
#
#   bash <(curl -Ls https://raw.githubusercontent.com/COD-DEXTER/DX-9HERMES/main/main.sh)
#
# Works two ways:
#   1) Non-interactive, exactly like before:
#        TELEGRAM_BOT_TOKEN=... TELEGRAM_OWNER_ID=... \
#        bash <(curl -Ls .../main.sh)
#   2) Fully interactive: run it with no env vars and it will ask the four
#      questions itself (BotFather token, owner ID, optional extra IDs,
#      optional Cloudflare domain) before handing off to install.sh.
#
# NOTE: this must be run with `bash <(curl ...)` (process substitution),
# not `curl | bash` — with a pipe, stdin is consumed by the download and
# interactive prompts below would silently fail. `bash <(...)` leaves your
# terminal's stdin free, so prompts work normally.
set -euo pipefail

REPO_URL="${DX9_REPO_URL:-https://github.com/COD-DEXTER/DX-9HERMES.git}"
REPO_BRANCH="${DX9_REPO_BRANCH:-main}"
CLONE_DIR="/opt/dx9hermes-src"

C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_RESET='\033[0m'
log()  { printf "${C_GREEN}[bootstrap]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[bootstrap]${C_RESET} %s\n" "$*"; }
die()  { printf "${C_RED}[bootstrap] ERROR:${C_RESET} %s\n" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root, e.g.: sudo bash <(curl -Ls .../main.sh)"

if [ ! -t 0 ]; then
  die "stdin is not a terminal — run this with 'bash <(curl -Ls ...)', not 'curl ... | bash'."
fi

retry() {
  # retry <max_tries> <cmd...> — small backoff, survives flaky mirrors/networks
  local max="$1"; shift
  local n=1 delay=3
  until "$@"; do
    if [ "$n" -ge "$max" ]; then return 1; fi
    warn "Command failed (attempt $n/$max) — retrying in ${delay}s..."
    sleep "$delay"
    n=$((n+1)); delay=$((delay*2))
  done
}

apt_output_looks_eol() {
  grep -Eqi '404[[:space:]]+Not Found.*(deb|security)\.debian\.org|Failed to fetch.*(deb|security)\.debian\.org' "$1"
}

EOL_ARCHIVE_APPLIED=0
fix_eol_debian_archive() {
  # A Debian release past its LTS end-of-life date is pulled off
  # deb.debian.org entirely (this is what a 404 for a package that clearly
  # exists in the Release listing means). The fix Debian itself documents:
  # repoint the main archive at archive.debian.org, which keeps every EOL
  # release's main/updates/backports pockets mirrored permanently.
  #
  # security.debian.org is a DIFFERENT, separate archive that is NOT part of
  # that permanent mirror — archive.debian.org does not carry a
  # debian-security tree for an EOL release at all (confirmed: even the
  # security Release file itself 404s there, not just individual packages).
  # So security lines get disabled outright, not repointed to a mirror that
  # doesn't have them.
  [ "$EOL_ARCHIVE_APPLIED" = "1" ] && return 0
  EOL_ARCHIVE_APPLIED=1
  warn "This Debian release looks end-of-life (packages 404 on deb.debian.org / security.debian.org)."
  warn "Repointing the main apt mirror at archive.debian.org, and disabling the security"
  warn "mirror (archive.debian.org has no security archive for an EOL release) — retrying..."
  [ -f /etc/apt/sources.list ] && cp -n /etc/apt/sources.list /etc/apt/sources.list.dx9hermes.bak 2>/dev/null || true
  sed -i -E "s@^([[:space:]]*deb(-src)?[[:space:]]+\S*security\.debian\.org.*)\$@# \1  (disabled by dx9hermes: no archive.debian.org mirror for this EOL release's security suite)@" \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
  sed -i \
    -e 's|https\?://deb\.debian\.org|http://archive.debian.org|g' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
  echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99dx9hermes-eol-archive
  apt-get update -y -o Acquire::Retries=3
  warn "Note: security updates are unavailable for this EOL release until you upgrade to a"
  warn "supported Debian version (12/13) — the archive.debian.org fallback above only covers"
  warn "the regular package archive, not security patches."
}

ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  log "Installing git..."
  if command -v apt-get >/dev/null 2>&1; then
    local log; log="$(mktemp)"
    if ! apt-get update -y -o Acquire::Retries=3 2>&1 | tee "$log"; then
      if apt_output_looks_eol "$log"; then fix_eol_debian_archive; fi
    fi
    rm -f "$log"
    log="$(mktemp)"
    if ! apt-get install -y git 2>&1 | tee "$log"; then
      if apt_output_looks_eol "$log"; then
        fix_eol_debian_archive
        apt-get install -y git
      else
        apt-get install -y --fix-missing git
      fi
    fi
    rm -f "$log"
  elif command -v dnf >/dev/null 2>&1; then dnf install -y git
  elif command -v yum >/dev/null 2>&1; then yum install -y git
  elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install git
  elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache git
  elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm git
  else
    die "No supported package manager found to install git (looked for apt-get, dnf, yum, zypper, apk, pacman)."
  fi
  command -v git >/dev/null 2>&1 || die "git install failed — check the errors above."
}

fetch_repo() {
  ensure_git
  if [ -d "$CLONE_DIR/.git" ]; then
    log "Existing checkout found, updating..."
    retry 3 git -C "$CLONE_DIR" fetch --depth 1 origin "$REPO_BRANCH"
    git -C "$CLONE_DIR" reset --hard "origin/$REPO_BRANCH"
  else
    log "Cloning DX9HERMES..."
    rm -rf "$CLONE_DIR"
    retry 3 git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR"
  fi
}

ask_if_missing() {
  # Only prompts for whatever wasn't already passed as an env var, so a
  # fully non-interactive call still works exactly as before.
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo
    echo "Telegram bot token (from @BotFather):"
    read -rp "> " TELEGRAM_BOT_TOKEN
  fi
  if [ -z "${TELEGRAM_OWNER_ID:-}" ]; then
    echo "Your numeric Telegram ID (from @userinfobot):"
    read -rp "> " TELEGRAM_OWNER_ID
  fi
  if [ -z "${TELEGRAM_ALLOWED_IDS+x}" ]; then
    echo "Extra allowed Telegram IDs, comma-separated (leave empty for owner-only):"
    read -rp "> " TELEGRAM_ALLOWED_IDS
  fi
  if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    echo "Do you have a Cloudflare-managed domain to use? [y/N]"
    read -rp "> " use_cf
    if [[ "${use_cf:-}" =~ ^[Yy]$ ]]; then
      read -rp "Cloudflare API token: " CLOUDFLARE_API_TOKEN
      read -rp "Zone (e.g. example.com): " CF_ZONE
      read -rp "Subdomain (e.g. 9router): " CF_SUBDOMAIN
    fi
  fi

  export TELEGRAM_BOT_TOKEN TELEGRAM_OWNER_ID TELEGRAM_ALLOWED_IDS
  export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
  export CF_ZONE="${CF_ZONE:-}"
  export CF_SUBDOMAIN="${CF_SUBDOMAIN:-}"

  [ -n "$TELEGRAM_BOT_TOKEN" ] || die "A Telegram bot token is required."
  [ -n "$TELEGRAM_OWNER_ID" ] || die "Your Telegram owner ID is required."
}

main() {
  fetch_repo
  ask_if_missing
  log "Handing off to install.sh ..."
  bash "$CLONE_DIR/install.sh"
}

main "$@"
