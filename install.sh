#!/usr/bin/env bash
# DX9HERMES installer — idempotent, env-var driven, no interactive prompts.
#
# Required:
#   TELEGRAM_BOT_TOKEN
#   TELEGRAM_OWNER_ID
# Optional:
#   TELEGRAM_ALLOWED_IDS        comma-separated extra IDs (default: owner only)
#   CLOUDFLARE_API_TOKEN        if set together with CF_ZONE + CF_SUBDOMAIN,
#   CF_ZONE                     the Cloudflare Tunnel path is used instead of
#   CF_SUBDOMAIN                the bare-IP + Caddy path.
#
# Usage:
#   TELEGRAM_BOT_TOKEN=... TELEGRAM_OWNER_ID=... ./install.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

INSTALL_PREFIX="/opt/dx9hermes"
DATA_DIR="/var/lib/9router"
CONF_DIR="/etc/dx9hermes"
ROUTER_ENV="$CONF_DIR/9router.env"
HERMES_ENV="$CONF_DIR/hermes.env"
SVC_USER="dx9hermes"

log()  { printf "${C_GREEN}[dx9hermes]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[dx9hermes]${C_RESET} %s\n" "$*"; }
die()  { printf "${C_RED}[dx9hermes] ERROR:${C_RESET} %s\n" "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "install.sh must run as root (sudo)."
}

check_inputs() {
  : "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required (from @BotFather)}"
  : "${TELEGRAM_OWNER_ID:?TELEGRAM_OWNER_ID is required (from @userinfobot)}"
  TELEGRAM_ALLOWED_IDS="${TELEGRAM_ALLOWED_IDS:-}"
}

retry() {
  # retry <max_tries> <cmd...> — small backoff, survives flaky mirrors/networks
  local max="$1"; shift
  local n=1 delay=3
  until "$@"; do
    if [ "$n" -ge "$max" ]; then
      return 1
    fi
    warn "Command failed (attempt $n/$max): $* — retrying in ${delay}s..."
    sleep "$delay"
    n=$((n+1)); delay=$((delay*2))
  done
}

dl() {
  # curl wrapper with a bounded connect/total timeout. Without this, a host
  # that's slow or silently unreachable (packets dropped rather than
  # actively refused — common for some CDNs on sanctions-affected routes,
  # e.g. from Iran) makes curl hang for many minutes with zero output on
  # EACH retry attempt, which looks exactly like "the install froze/got cut
  # off" even though nothing actually crashed.
  curl -fsSL --connect-timeout 10 --max-time 90 "$@"
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  else echo "unknown"
  fi
}

apt_update_resilient() {
  # A single stale/dead mirror line (e.g. an old security.debian.org
  # snapshot) makes plain `apt-get update` exit non-zero even though every
  # other repo refreshed fine. Retry, then fall back to tolerating partial
  # failures instead of aborting the whole install over one dead repo.
  local log; log="$(mktemp)"
  if apt-get update -y -o Acquire::Retries=3 2>&1 | tee "$log"; then rm -f "$log"; return 0; fi
  if apt_output_looks_eol "$log"; then
    rm -f "$log"
    fix_eol_debian_archive
    return 0
  fi
  rm -f "$log"
  warn "apt-get update had errors (likely a stale/dead repo entry) — continuing with what refreshed OK."
  apt-get update -y -o Acquire::Retries=3 || true
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
  # doesn't have them — repointing them was the actual bug here: it produced
  # a *second*, different 404 (on the Release file) after "fixing" the first.
  [ "$EOL_ARCHIVE_APPLIED" = "1" ] && return 0
  EOL_ARCHIVE_APPLIED=1
  warn "This Debian release looks end-of-life (packages 404 on deb.debian.org / security.debian.org)."
  warn "Repointing the main apt mirror at archive.debian.org, and disabling the security"
  warn "mirror (archive.debian.org has no security archive for an EOL release) — retrying..."
  [ -f /etc/apt/sources.list ] && cp -n /etc/apt/sources.list /etc/apt/sources.list.dx9hermes.bak 2>/dev/null || true
  # Disable security.debian.org lines first (comment them out), BEFORE the
  # deb.debian.org rewrite below, so they don't get swept up into it.
  sed -i -E "s@^([[:space:]]*deb(-src)?[[:space:]]+\S*security\.debian\.org.*)\$@# \1  (disabled by dx9hermes: no archive.debian.org mirror for this EOL release's security suite)@" \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
  sed -i \
    -e 's|https\?://deb\.debian\.org|http://archive.debian.org|g' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
  # Archived Release files are never refreshed, so they read as "expired"
  # to a normal apt — tell it that's expected for this archive mirror.
  echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99dx9hermes-eol-archive
  apt-get update -y -o Acquire::Retries=3
  warn "Note: security updates are unavailable for this EOL release until you upgrade to a"
  warn "supported Debian version (12/13) — the archive.debian.org fallback above only covers"
  warn "the regular package archive, not security patches."
}


apt_output_looks_eol() {
  grep -Eqi '404[[:space:]]+Not Found.*(deb|security)\.debian\.org|Failed to fetch.*(deb|security)\.debian\.org' "$1"
}

apt_output_looks_version_conflict() {
  # A different, non-404 EOL-box failure mode: a package already installed
  # on this box (usually baked into the base image, e.g. libc6) is NEWER
  # than what archive.debian.org's frozen snapshot has, while some -dev/meta
  # package in that same snapshot hard-pins an exact version of it
  # ("Depends: libc6 (= X)"). apt resolves this fine on its own (there's no
  # missing package), it just refuses to silently downgrade an
  # already-installed package to satisfy the exact match.
  grep -Eqi 'you have held broken packages|Depends:.*\(= [^)]*\) but [^ ]+ is to be installed' "$1"
}

apt_install_resilient() {
  # apt-get install "$@", auto-recovering from two distinct known EOL-box
  # failure modes:
  #   1) EOL 404s                      -> fix_eol_debian_archive, then retry
  #   2) exact-version pin conflicts   -> --allow-downgrades
  # BUG FIX: the final fallback used to omit --allow-downgrades, so a
  # version-pin conflict that (for any reason — different apt output
  # ordering, a locale/grep quirk, etc.) wasn't caught by the
  # apt_output_looks_version_conflict check above still hit an
  # --allow-downgrades-less retry and failed identically, aborting the
  # whole install under `set -e`. The final retry below now always includes
  # --allow-downgrades, regardless of which branch got here, so this class
  # of failure can't repeat itself on the last attempt.
  local log; log="$(mktemp)"
  if apt-get install -y "$@" 2>&1 | tee "$log"; then rm -f "$log"; return 0; fi

  if apt_output_looks_eol "$log"; then
    rm -f "$log"
    fix_eol_debian_archive
    log="$(mktemp)"
    if apt-get install -y "$@" 2>&1 | tee "$log"; then rm -f "$log"; return 0; fi
  fi

  if apt_output_looks_version_conflict "$log"; then
    warn "Archived package versions conflict with newer packages already on this box —"
    warn "retrying with --fix-missing --allow-downgrades (safe here: only touches this EOL"
    warn "release's apt packages — 9Router/Hermes/Node install via npm/their own installer,"
    warn "unaffected)."
  else
    warn "Some packages failed to install cleanly, retrying with --fix-missing --allow-downgrades..."
  fi
  rm -f "$log"
  apt-get install -y --fix-missing --allow-downgrades "$@"
}

install_deps() {
  log "Checking OS packages..."
  PKG_MGR="$(detect_pkg_manager)"
  case "$PKG_MGR" in
    apt)
      apt_update_resilient
      apt_install_resilient git curl ca-certificates python3 jq openssl
      # build-essential/python3-pip/python3-venv are not actually required by
      # anything else in this installer (9Router/Hermes/Node all install via
      # npm or their own installer scripts, not gcc/make/pip/venv). On EOL
      # Debian boxes these three sometimes hard-pin an exact libc6/python3.9/
      # python3-pkg-resources version that conflicts with what's already on
      # the box (see apt_output_looks_version_conflict above) — that failure
      # was previously fatal under `set -e` even though nothing downstream
      # needs these packages. Best-effort them instead of aborting the whole
      # install over a dependency nothing here uses.
      apt_install_resilient build-essential python3-pip python3-venv \
        || warn "build-essential/pip/venv failed to install cleanly (likely EOL-repo version conflict) — continuing, these aren't required by DX9HERMES."
      ;;
    dnf|yum)
      "$PKG_MGR" install -y git curl ca-certificates gcc gcc-c++ make python3 python3-pip jq openssl
      ;;
    zypper)
      zypper --non-interactive refresh
      zypper --non-interactive install git curl ca-certificates gcc gcc-c++ make python3 python3-pip jq openssl
      ;;
    apk)
      apk update
      apk add --no-cache git curl ca-certificates build-base python3 py3-pip jq openssl
      ;;
    pacman)
      pacman -Sy --noconfirm git curl ca-certificates base-devel python python-pip jq openssl
      ;;
    *)
      die "No supported package manager found (looked for apt-get, dnf, yum, zypper, apk, pacman)."
      ;;
  esac

  command -v git >/dev/null 2>&1  || die "git is still missing after package install — check the errors above."
  command -v curl >/dev/null 2>&1 || die "curl is still missing after package install — check the errors above."
  command -v openssl >/dev/null 2>&1 || die "openssl is still missing after package install — check the errors above."

  install_nodejs
  command -v node >/dev/null 2>&1 || die "node is still missing after install_nodejs — check the errors above."
  command -v npm  >/dev/null 2>&1 || die "npm is still missing after install_nodejs — check the errors above."
  log "Node $(node --version), npm $(npm --version) confirmed."
}

install_nodejs() {
  # BUG-FIX (recurring "npm: command not found" on EOL Debian): every
  # distro's package manager was previously asked to install Node/npm
  # itself (NodeSource repo + apt, or dnf/zypper/apk/pacman's own nodejs
  # package). On an EOL Debian box this repeatedly broke in different ways —
  # the NodeSource repo add silently not taking, then the distro's own
  # nodejs package not bundling npm, then even the apt 'npm' package itself
  # hitting an unrelated exact-version conflict (libssl-dev vs an
  # already-installed newer libssl1.1) that --allow-downgrades couldn't
  # resolve. None of that is fixable by patching one more apt edge case.
  #
  # Node.js already ships an official static binary tarball with npm
  # bundled and zero distro package dependencies — exactly the same
  # approach this installer already uses for Caddy and cloudflared. Use
  # that here too, unconditionally, so Node/npm no longer depend on any
  # package manager's state at all.
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "Node.js and npm already present ($(node --version 2>/dev/null), npm $(npm --version 2>/dev/null)), skipping."
    return 0
  fi

  local node_arch
  case "$(uname -m)" in
    x86_64|amd64) node_arch="x64" ;;
    aarch64|arm64) node_arch="arm64" ;;
    armv7l) node_arch="armv7l" ;;
    *) die "Unsupported CPU architecture for Node.js: $(uname -m)" ;;
  esac

  log "Installing Node.js LTS from the official static binary (arch: ${node_arch})..."
  local shasums tarball dist_base
  if [ -n "${DX9_NODE_DIST_BASE:-}" ]; then
    dist_base="$DX9_NODE_DIST_BASE"
    shasums="$(retry 3 dl "${dist_base}/latest-v20.x/SHASUMS256.txt")" \
      || die "Could not reach DX9_NODE_DIST_BASE ($dist_base) to determine the latest Node 20.x LTS build."
  else
    dist_base="https://nodejs.org/dist"
    shasums="$(retry 2 dl "${dist_base}/latest-v20.x/SHASUMS256.txt" 2>/dev/null)" || shasums=""
    if [ -z "$shasums" ]; then
      warn "nodejs.org unreachable (timed out) — falling back to the npmmirror.com mirror."
      dist_base="https://cdn.npmmirror.com/binaries/node"
      shasums="$(retry 3 dl "${dist_base}/latest-v20.x/SHASUMS256.txt")" \
        || die "Could not reach nodejs.org or npmmirror.com to determine the latest Node 20.x LTS build. Check this server's outbound network/DNS, or set DX9_NODE_DIST_BASE to a reachable mirror with the same nodejs.org dist layout."
    fi
  fi
  tarball="$(echo "$shasums" | grep -o "node-v20[0-9.]*-linux-${node_arch}\.tar\.xz" | head -1 || true)"
  [ -n "$tarball" ] || die "Could not find a linux-${node_arch} build in the Node 20.x LTS listing."
  local url="${dist_base}/latest-v20.x/${tarball}"
  local expected_sha
  expected_sha="$(printf '%s\n' "$shasums" | awk -v f="$tarball" '$2==f{print $1; exit}')"
  [ -n "$expected_sha" ] || die "Could not find a SHA256 entry for ${tarball} in the fetched SHASUMS256.txt — refusing to install an unverifiable binary."

  retry 3 dl "$url" -o /tmp/node.tar.xz
  # HARDENING: the tarball was previously installed straight off the wire
  # with no integrity check, even though SHASUMS256.txt (already fetched
  # above, just to learn the filename) is exactly what's needed to verify
  # it. A corrupted download or a compromised mirror (this function already
  # falls back to a third-party mirror, and honors a user-supplied
  # DX9_NODE_DIST_BASE) would otherwise install and run silently. openssl is
  # already a guaranteed dependency by this point in install_deps, so use it
  # rather than assuming sha256sum/shasum exist on every distro.
  local actual_sha
  actual_sha="$(openssl dgst -sha256 -r /tmp/node.tar.xz 2>/dev/null | awk '{print $1}')"
  if [ "$actual_sha" != "$expected_sha" ]; then
    rm -f /tmp/node.tar.xz
    die "Downloaded Node.js tarball checksum mismatch for ${tarball}
(expected ${expected_sha}, got ${actual_sha:-<could not hash>}) — possible
corrupted download or compromised mirror. Refusing to install an unverified
binary. Re-run to retry, or check DX9_NODE_DIST_BASE if you set one."
  fi
  local extracted_dir
  extracted_dir="$(tar -tJf /tmp/node.tar.xz 2>/dev/null | head -1 | cut -d/ -f1 || true)"
  [ -n "$extracted_dir" ] || die "Downloaded Node.js tarball at /tmp/node.tar.xz looks empty or corrupt (couldn't list its contents) — re-run to retry the download."
  mkdir -p /usr/local/lib/nodejs
  rm -rf "/usr/local/lib/nodejs/${extracted_dir}"
  tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs
  rm -f /tmp/node.tar.xz

  # Symlink into /usr/local/bin (already on PATH everywhere, including
  # systemd's default PATH) instead of relying on any shell profile.
  ln -sf "/usr/local/lib/nodejs/${extracted_dir}/bin/node" /usr/local/bin/node
  ln -sf "/usr/local/lib/nodejs/${extracted_dir}/bin/npm" /usr/local/bin/npm
  ln -sf "/usr/local/lib/nodejs/${extracted_dir}/bin/npx" /usr/local/bin/npx
}

# Returns amd64/arm64/armv7 the way most project release pages name them.
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "arm" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

create_user() {
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    log "Creating service user '$SVC_USER'..."
    useradd --system --create-home --shell /usr/sbin/nologin "$SVC_USER"
  fi
}

install_9router() {
  if command -v 9router >/dev/null 2>&1; then
    log "9Router already installed, skipping."
  else
    # BUG-012 mitigation: `npm install -g 9router` (no version) always pulls
    # whatever is newest on npm, at root, on every fresh install — a classic
    # supply-chain exposure. Set ROUTER_VERSION_PIN to pin a known-good release;
    # unset keeps today's latest-always behavior.
    if [ -n "${ROUTER_VERSION_PIN:-}" ]; then
      log "Installing 9Router (npm global, pinned to ${ROUTER_VERSION_PIN})..."
      retry 3 npm install -g "9router@${ROUTER_VERSION_PIN}"
    else
      warn "ROUTER_VERSION_PIN not set — installing latest 9Router from npm (unpinned)."
      log "Installing 9Router (npm global)..."
      retry 3 npm install -g 9router
    fi
  fi
  mkdir -p "$DATA_DIR"
  chown "$SVC_USER":"$SVC_USER" "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  check_9router_version_safe
}

check_9router_version_safe() {
  # 9Router has a real, CVE-documented, chained RCE (default password +
  # Host-header spoof past the local-only gate + unvalidated args to
  # child_process.spawn() on MCP plugin registration): CVE-2026-46339
  # (unauthenticated, 0.4.30-0.4.36 / GHSA-fhh6-4qxv-rpqj), CVE-2026-63732
  # (default-password chain, 0.4.59 / GHSA-4922-8r65-fq26), CVE-2026-62312
  # (authenticated, pre-0.5.2 / GHSA-63p9-g54h-prrp). All three are fixed as
  # of 0.5.2. Binding to 127.0.0.1 (done above/below) blocks the network
  # path for an *outside* attacker, but not from anything else running on
  # this same box — so this is a real check, not just belt-and-suspenders.
  local ver
  ver="$(9router --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [ -z "$ver" ]; then
    warn "Could not determine 9Router's version ('9router --version' gave no"
    warn "parseable output) — skipping the known-CVE version check. Verify"
    warn "manually that you're not on an old version affected by"
    warn "CVE-2026-46339 / CVE-2026-63732 / CVE-2026-62312 (all fixed in 0.5.2+)."
    return 0
  fi
  local major minor patch
  IFS='.' read -r major minor patch <<< "$ver"
  if [ "$major" -gt 0 ] 2>/dev/null \
     || { [ "$major" -eq 0 ] && [ "$minor" -gt 5 ]; } \
     || { [ "$major" -eq 0 ] && [ "$minor" -eq 5 ] && [ "$patch" -ge 2 ]; }; then
    log "9Router $ver — past the known RCE-chain fix version (0.5.2), good."
  else
    die "9Router $ver has a known, publicly-documented, chainable RCE (default
password + Host-header bypass of the local-only gate + unvalidated MCP
plugin args -> child_process.spawn(): CVE-2026-46339, CVE-2026-63732,
CVE-2026-62312). Fixed in 9Router 0.5.2+. Refusing to continue with $ver.
Unset ROUTER_VERSION_PIN (to get latest) or set it to 0.5.2 or newer, then
re-run."
  fi
}

install_hermes() {
  # BUG FIX (critical): this used to run the Hermes installer as root
  # (`bash /tmp/hermes-install.sh`). Hermes Agent's own installer puts the
  # binary and config under the *installing* user's home directory
  # (~/.local/bin/hermes, ~/.hermes/...). Run as root that means /root/...,
  # which hermes-gateway.service (User=dx9hermes) can never read — the
  # service would fail every single time with a permission/PATH error.
  # Run the installer AS the service user instead, so everything lands
  # under $SVC_USER's own home from the start.
  if runuser -u "$SVC_USER" -- bash -lc 'command -v hermes' >/dev/null 2>&1; then
    log "Hermes Agent already installed for $SVC_USER, skipping."
  else
    # BUG-012 mitigation: same supply-chain concern as above — this pulls
    # and runs a remote script. Set HERMES_INSTALL_REF to a specific commit
    # hash (preferred) or tag to pin it; unset keeps the previous
    # always-main behavior.
    local ref="${HERMES_INSTALL_REF:-main}"
    if [ -z "${HERMES_INSTALL_REF:-}" ]; then
      warn "HERMES_INSTALL_REF not set — installing Hermes Agent from the 'main' branch (unpinned)."
    fi
    log "Installing Hermes Agent (official installer, ref: ${ref}) as $SVC_USER..."
    retry 3 dl "https://raw.githubusercontent.com/NousResearch/hermes-agent/${ref}/scripts/install.sh" -o /tmp/hermes-install.sh
    chmod 644 /tmp/hermes-install.sh
    runuser -u "$SVC_USER" -- bash /tmp/hermes-install.sh
  fi

  # Resolve the installed binary from the SERVICE USER's own login-shell
  # PATH (a login shell so it picks up whatever the installer appended to
  # ~/.bashrc / ~/.profile), with a couple of documented fallback locations,
  # and persist it so install_hermes_unit doesn't have to re-derive it later
  # under a possibly-different PATH.
  HERMES_BIN="$(runuser -u "$SVC_USER" -- bash -lc 'command -v hermes' 2>/dev/null || true)"
  if [ -z "$HERMES_BIN" ]; then
    local svc_home; svc_home="$(getent passwd "$SVC_USER" | cut -d: -f6)"
    local candidate
    for candidate in "$svc_home/.local/bin/hermes" "$svc_home/.hermes/bin/hermes" "$svc_home/bin/hermes"; do
      if runuser -u "$SVC_USER" -- test -x "$candidate" 2>/dev/null; then HERMES_BIN="$candidate"; break; fi
    done
  fi
  [ -n "$HERMES_BIN" ] || die "Hermes Agent installer ran but its binary can't be found for $SVC_USER
(checked a login-shell PATH plus ~/.local/bin, ~/.hermes/bin, ~/bin under
$(getent passwd "$SVC_USER" | cut -d: -f6)). Check the installer output
above for where it actually placed the binary and adjust install_hermes()."
  mkdir -p "$CONF_DIR"
  echo "$HERMES_BIN" > "$CONF_DIR/hermes_bin_path"
  log "Hermes binary confirmed for $SVC_USER at: $HERMES_BIN"
}

gen_secret() { openssl rand -hex 32; }

write_router_env() {
  mkdir -p "$CONF_DIR"
  if [ -f "$ROUTER_ENV" ]; then
    log "9Router config already exists at $ROUTER_ENV, leaving secrets untouched."
    # shellcheck disable=SC1090
    source "$ROUTER_ENV"
  else
    log "Generating 9Router secrets..."
    JWT_SECRET="$(gen_secret)"
    API_KEY_SECRET="$(gen_secret)"
    # BUG-FIX: the upstream project's own default is INITIAL_PASSWORD=123456
    # (not stronger than what we had before). Generate a real random one
    # instead of shipping any fixed default — notify_owner() below sends the
    # actual value to the Telegram owner so it's still usable, just not a
    # value every DX9HERMES install (or 9Router itself) shares.
    INITIAL_PASSWORD="$(openssl rand -hex 6)"
    cat > "$ROUTER_ENV" <<EOF
JWT_SECRET=$JWT_SECRET
API_KEY_SECRET=$API_KEY_SECRET
DATA_DIR=$DATA_DIR
PORT=20128
HOSTNAME=127.0.0.1
INITIAL_PASSWORD=$INITIAL_PASSWORD
# 9Router's own default here is 'false' (confirmed against its documented
# env vars) — meaning /v1/* accepts unauthenticated requests by default,
# which is fine ONLY because 9Router is bound to 127.0.0.1 above and never
# reachable except through Hermes on this same box, or through Caddy/
# Cloudflare Tunnel's own auth layer in front of the *dashboard*. Setting
# this to 'true' instead adds a second, independent layer of protection for
# the /v1 API itself (defense in depth if the bind-address assumption above
# is ever wrong) — but there is no confirmed CLI/API in this installer to
# mint a matching key non-interactively, so turning it on requires manually
# creating a key in the dashboard and putting it in both this file and
# $HERMES_ENV's OPENAI_API_KEY. Left off by default to match 9Router's own
# out-of-the-box behavior and avoid silently breaking the Hermes connection.
REQUIRE_API_KEY=false
ROUTER_VERSION_PIN=${ROUTER_VERSION_PIN:-}
EOF
    chmod 600 "$ROUTER_ENV"
    chown "$SVC_USER":"$SVC_USER" "$ROUTER_ENV"
  fi
}

setup_caddy() {
  log "Setting up Caddy (bare-IP HTTPS path)..."
  if ! command -v caddy >/dev/null 2>&1; then
    # Static binary from Caddy's official download API — works the same on
    # any distro/init system, no apt repo or keyring dance required.
    local arch; arch="$(detect_arch)"
    log "Downloading Caddy static binary (linux/$arch)..."
    # NOTE: unlike the Node.js download above, Caddy's own download API
    # (caddyserver.com/api/download) builds the binary on the fly per
    # request and doesn't publish a fixed checksum artifact for it, so
    # there's nothing to verify this against beyond the HTTPS transport
    # itself. Documented limitation, not an oversight.
    retry 3 dl "https://caddyserver.com/api/download?os=linux&arch=${arch}" -o /usr/local/bin/caddy
    chmod +x /usr/local/bin/caddy
    command -v caddy >/dev/null 2>&1 || die "Caddy download failed — check network/output above."
  fi

  mkdir -p /etc/caddy /var/lib/caddy
  if ! id caddy >/dev/null 2>&1; then
    useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
  fi
  chown -R caddy:caddy /var/lib/caddy

  # The apt package used to ship this unit; since we now install a static
  # binary (so this works the same on any distro), we ship our own.
  if [ ! -f /etc/systemd/system/caddy.service ]; then
    cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy web server (DX9HERMES)
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  # BUG-FIX (operator report: visiting /dx9-<hex>/ redirected the browser to
  # /dashboard and 404'd): 9Router has no basePath/subpath config (confirmed
  # against its documented env vars), so its own 307 redirect to /dashboard,
  # and every asset/API call the app makes (/_next/*, /api/*, /v1/*), are
  # always root-relative — no Caddy config can keep a prebuilt Next.js app
  # entirely under an arbitrary prefix without rebuilding it from source. A
  # cookie-gate workaround was tried next (mint a cookie at the secret path,
  # require it everywhere else), but that's still a second moving part that
  # can silently break (cookie matcher, Secure-cookie-over-self-signed-TLS
  # edge cases, etc.) for a threat model the operator has explicitly said
  # doesn't matter to them here. Simplified per operator request: no secret
  # path, no cookie gate — Caddy just reverse-proxies the bare root straight
  # to 9Router, exactly like a normal single-app HTTPS front. The only
  # remaining gate is 9Router's own dashboard login.
  cat > /etc/caddy/Caddyfile <<EOF
:443 {
  # BUG-FIX (ERR_SSL_PROTOCOL_ERROR / TLS "internal error" alert on every
  # handshake): a bare ":443" site address has no hostname for Caddy to
  # mint a certificate for ahead of time. Plain "tls internal" only manages
  # certs for identifiers it can enumerate statically (none here, since we
  # don't know the box's public IP at Caddyfile-generation time) — so on a
  # real client connection Caddy's TLS layer finds "no matching
  # certificates and no custom selection logic" for the SNI it receives
  # and aborts the handshake with a TLS internal_error alert (confirmed:
  # this is Caddy's documented behavior for catch-all ":443" blocks,
  # tracked upstream as caddyserver/caddy#5479 and #5758). "on_demand"
  # tells Caddy to mint (and cache) an internal-CA cert for whatever
  # identifier it's asked for at handshake time instead of requiring one
  # configured in advance — exactly the bare-IP case this script is for.
  tls internal {
    on_demand
  }

  reverse_proxy 127.0.0.1:20128 {
    header_up Host 127.0.0.1:20128
  }
}
EOF
  systemctl enable --now caddy
  systemctl reload caddy || systemctl restart caddy

  rm -f "$CONF_DIR/dashboard_path" "$CONF_DIR/dashboard_basicauth"
  echo "Direct IP + Caddy" > "$CONF_DIR/access_mode"

  PUBLIC_IP="$(dl --connect-timeout 5 --max-time 15 ifconfig.me 2>/dev/null || echo "<server-ip>")"
  DASHBOARD_URL="https://${PUBLIC_IP}/"
}

setup_cloudflare() {
  log "Setting up Cloudflare Tunnel (domain path)..."
  if ! command -v cloudflared >/dev/null 2>&1; then
    # Static binary, same reasoning as Caddy above — avoids apt/dpkg
    # entirely so this works on dnf/zypper/apk/pacman systems too.
    local arch; arch="$(detect_arch)"
    log "Downloading cloudflared static binary (linux/$arch)..."
    # NOTE: same limitation as Caddy above — cloudflare doesn't publish a
    # fixed, reliably-discoverable checksum file alongside this release
    # asset, so this is HTTPS-transport integrity only.
    retry 3 dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
    command -v cloudflared >/dev/null 2>&1 || die "cloudflared download failed — check network/output above."
  fi

  # Tunnel creation via the Cloudflare API is intentionally left as a call
  # into scripts/cf-tunnel.sh so it can be re-run standalone from menu
  # option 5 without repeating the whole installer.
  bash "$SCRIPT_DIR/scripts/cf-tunnel.sh" create \
    --token "$CLOUDFLARE_API_TOKEN" --zone "$CF_ZONE" --subdomain "$CF_SUBDOMAIN"

  echo "Cloudflare Tunnel" > "$CONF_DIR/access_mode"
  # cf-tunnel.sh fronts 9Router with a plain local Caddy reverse proxy (see
  # scripts/cf-tunnel.sh) — no secret path, matching the bare-IP path above.
  DASHBOARD_URL="https://${CF_SUBDOMAIN}.${CF_ZONE}/"
}

write_hermes_env() {
  # BUG-FIX: '9router keys create ...' was never a real 9router CLI command —
  # the actual CLI (confirmed against its own --help output) only parses
  # --port/--host/--no-browser/--log/--tray/--skip-update/--version, no
  # subcommands at all. Since REQUIRE_API_KEY=false above (9Router's own
  # default), 9Router doesn't check this value on /v1/* anyway — it only
  # needs to be a non-empty string because some clients (Hermes included)
  # refuse to save a provider with a blank key field. If you flip
  # REQUIRE_API_KEY=true in $ROUTER_ENV, replace this with a real key you
  # create in the 9Router dashboard (Settings → API Keys) and re-run
  # scripts/configure-hermes-model.sh so Hermes picks up the change too.
  local router_key="local-no-auth"

  ALLOWED="$TELEGRAM_OWNER_ID"
  [ -n "$TELEGRAM_ALLOWED_IDS" ] && ALLOWED="${ALLOWED},${TELEGRAM_ALLOWED_IDS}"

  cat > "$HERMES_ENV" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_OWNER_ID=$TELEGRAM_OWNER_ID
TELEGRAM_ALLOWED_USERS=$ALLOWED
OPENAI_BASE_URL=http://127.0.0.1:20128/v1
OPENAI_API_KEY=$router_key
EOF
  chmod 600 "$HERMES_ENV"
  chown "$SVC_USER":"$SVC_USER" "$HERMES_ENV"
}

install_self() {
  log "Copying DX9HERMES into $INSTALL_PREFIX ..."
  mkdir -p "$INSTALL_PREFIX"
  cp -a "$SCRIPT_DIR/." "$INSTALL_PREFIX/"
  chmod +x "$INSTALL_PREFIX/bin/dx9hermes" "$INSTALL_PREFIX"/scripts/*.sh "$INSTALL_PREFIX/install.sh"
  ln -sf "$INSTALL_PREFIX/bin/dx9hermes" /usr/local/bin/dx9hermes
}

install_9router_unit() {
  log "Installing and starting the 9Router systemd unit..."
  local ninerouter_bin
  ninerouter_bin="$(command -v 9router || true)"
  [ -n "$ninerouter_bin" ] || die "9router binary not found on PATH — cannot generate its systemd unit."
  # `env 9router ...` depends on npm's global bin dir being in systemd's own
  # (usually minimal) PATH, which isn't guaranteed to match the PATH this
  # install script resolved the binary from. Bake in the absolute path
  # instead, same as Caddy/cloudflared already get.
  #
  # BUG-FIX: read the actual PORT/HOSTNAME this install is using from
  # 9router.env (written by write_router_env, always called before this
  # function) instead of duplicating the literal 20128/127.0.0.1 a second
  # time here — keeps the unit file from silently drifting out of sync if
  # 9router.env is ever hand-edited or those defaults change.
  local router_port router_host
  # shellcheck disable=SC1090
  source "$ROUTER_ENV"
  router_port="${PORT:-20128}"
  router_host="${HOSTNAME:-127.0.0.1}"

  # The unit wraps 9router in `script` so it gets a real pty (see the
  # BUG-FIX #3 comment in systemd/9router.service for why) — resolve its
  # real path the same way as 9router itself rather than trusting the
  # /usr/bin/script placeholder, since some distros (e.g. some minimal
  # container base images) ship it under /bin or not at all.
  local script_bin
  script_bin="$(command -v script || true)"
  [ -n "$script_bin" ] || die "'script' (from util-linux/bsdutils) not found on PATH — required to run 9router under systemd. Install your distro's util-linux/bsdutils package and re-run."

  sed \
    -e "s#/usr/bin/script#${script_bin}#" \
    -e "s#/usr/bin/env 9router#${ninerouter_bin}#" \
    -e "s#--host 127\.0\.0\.1#--host ${router_host}#" \
    -e "s#--port 20128#--port ${router_port}#" \
    "$SCRIPT_DIR/systemd/9router.service" > /etc/systemd/system/9router.service
  systemctl daemon-reload
  systemctl enable --now 9router
}

install_hermes_unit() {
  log "Installing and starting the Hermes Gateway systemd unit..."
  # BUG FIX: this used to resolve via root's `command -v hermes`, which (a)
  # could silently find nothing since Hermes is now installed for $SVC_USER,
  # not root, and (b) even if it found something, could resolve to the WRONG
  # binary if one ever existed on root's own PATH. Always use the path
  # install_hermes() already confirmed is executable BY $SVC_USER.
  local hermes_bin=""
  [ -f "$CONF_DIR/hermes_bin_path" ] && hermes_bin="$(cat "$CONF_DIR/hermes_bin_path")"
  if [ -z "$hermes_bin" ] || ! runuser -u "$SVC_USER" -- test -x "$hermes_bin" 2>/dev/null; then
    hermes_bin="$(runuser -u "$SVC_USER" -- bash -lc 'command -v hermes' 2>/dev/null || true)"
  fi
  [ -n "$hermes_bin" ] && runuser -u "$SVC_USER" -- test -x "$hermes_bin" 2>/dev/null \
    || die "hermes binary not found/executable for $SVC_USER — cannot generate its systemd unit. Re-run install_hermes (menu option 1) first."
  sed "s#/usr/bin/env hermes gateway start#${hermes_bin} gateway start#" \
    "$SCRIPT_DIR/systemd/hermes-gateway.service" > /etc/systemd/system/hermes-gateway.service
  systemctl daemon-reload
  systemctl enable --now hermes-gateway
}

notify_owner() {
  local pw_line="Dashboard password: (kept from previous install)"
  if [ -n "${INITIAL_PASSWORD:-}" ]; then
    pw_line="Dashboard password: ${INITIAL_PASSWORD} — change it in 9Router's Settings when convenient."
  fi

  # BUG FIX (critical, per audit): this used to send "✅ setup complete" as
  # soon as configure-hermes-model.sh finished, regardless of whether the
  # selected model actually answered anything — services being "active" is
  # not proof the AI path works. Now it checks the real E2E result that
  # script recorded ($CONF_DIR/model_e2e_verified) and sends an honestly
  # different message when that step didn't pass.
  local header text
  if [ -n "${HERMES_MODEL_CONFIGURED:-}" ] && [ -f "$CONF_DIR/model_e2e_verified" ]; then
    header="✅ DX9HERMES setup complete."
    text="Verified end-to-end through Hermes itself (a real 'hermes chat' call, not just
9Router directly): Hermes -> 127.0.0.1:20128/v1 -> 9Router -> ${HERMES_MODEL_CONFIGURED} -> got a real reply."
  elif [ -n "${HERMES_MODEL_CONFIGURED:-}" ] && [ -f "$CONF_DIR/router_model_e2e_verified" ]; then
    header="⚠️ DX9HERMES installed — 9Router verified, Hermes path NOT independently verified."
    text="9Router itself confirmed a real reply from ${HERMES_MODEL_CONFIGURED} directly, but the
hermes binary wasn't reachable for the dx9hermes user during install, so Hermes's own
request path to it was never exercised. Hermes IS pointed at this model; once 'hermes'
is confirmed working for that user, run: dx9hermes -> option 7, to get a full
Hermes -> 9Router verification instead of just a 9Router-only one."
  elif [ -n "${HERMES_MODEL_CONFIGURED:-}" ]; then
    header="⚠️ DX9HERMES installed, but NOT fully verified."
    text="9Router and Hermes services are up, model is set to ${HERMES_MODEL_CONFIGURED},
but a real test request to it did NOT get a usable reply (see install
output above). Fix the provider in the dashboard, then run:
dx9hermes -> option 7 (Change Model) to re-verify."
  else
    header="⚠️ DX9HERMES installed, but NOT fully verified."
    text="9Router and Hermes services are up, but no working model/provider is
connected yet. Open the dashboard, Providers -> Connect a free one, then
run: dx9hermes -> option 7 (Change Model)."
  fi

  local msg="${header}
Dashboard: ${DASHBOARD_URL:-not configured}
${pw_line}
${text}"
  curl -fsSL --connect-timeout 10 --max-time 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_OWNER_ID}" \
    --data-urlencode text="$msg" >/dev/null || warn "Could not send Telegram confirmation (bot not reachable yet)."
}

main() {
  clear; dx9_banner
  require_root
  check_inputs
  install_deps
  create_user
  install_9router
  install_hermes
  write_router_env
  write_hermes_env
  install_self

  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CF_ZONE:-}" ] && [ -n "${CF_SUBDOMAIN:-}" ]; then
    setup_cloudflare
  else
    setup_caddy
  fi

  # 9Router has to actually be running (not just installed) before we can
  # ask it what models it has and wire Hermes to one — start it on its own
  # first, run discovery, THEN start Hermes Gateway so it comes up already
  # pointed at the right model instead of an empty/default config.
  install_9router_unit
  bash "$INSTALL_PREFIX/scripts/configure-hermes-model.sh" || warn "Model auto-configuration hit an issue (see above) — re-run it later via menu option 7."
  [ -f "$CONF_DIR/current_model" ] && HERMES_MODEL_CONFIGURED="$(cat "$CONF_DIR/current_model")"
  install_hermes_unit

  notify_owner

  if [ -f "$CONF_DIR/model_e2e_verified" ]; then
    log "Done — model E2E-verified through Hermes itself. Run 'dx9hermes' any time to manage the stack."
  elif [ -f "$CONF_DIR/router_model_e2e_verified" ]; then
    warn "Done — 9Router+model verified directly, but NOT yet through Hermes itself (see warnings above)."
    warn "Run 'dx9hermes' -> option 7 (Change Model) again once the hermes binary is reachable for dx9hermes."
  else
    warn "Done, but the AI model is NOT E2E-verified yet (see warnings above)."
    warn "Run 'dx9hermes' -> option 7 (Change Model) once a provider is connected."
  fi
  [ -n "${DASHBOARD_URL:-}" ] && log "Dashboard: $DASHBOARD_URL"
}

main "$@"
