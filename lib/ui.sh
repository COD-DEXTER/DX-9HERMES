#!/usr/bin/env bash
# DX9HERMES — shared UI helpers (banner, dashed menu box, colors)
# Sourced by install.sh and bin/dx9hermes. Not meant to be run directly.

C_RESET='\033[0m'
C_CYAN='\033[1;36m'
C_MAGENTA='\033[1;35m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[1;34m'
C_WHITE='\033[1;37m'

DX9_VERSION="0.1.0"
DX9_CREATOR="${DX9_CREATOR:-COD-DEXTER}"

dx9_banner() {
  printf "${C_CYAN}"
  cat <<'EOF'
+---------------------------------------------------------------------------------+
| ██████╗ ██╗  ██╗       ╔═════╗  ██╗  ██╗███████╗██████╗ ███╗   ███╗███████╗███████╗ |
| ██╔══██╗╚██╗██╔╝      ╔██████╝  ██║  ██║██╔════╝██╔══██╗████╗ ████║██╔════╝██╔════╝ |
| ██║  ██║ ╚███╔╝       ██╔═══██╗ ███████║█████╗  ██████╔╝██╔████╔██║█████╗  ███████╗ |
| ██║  ██║ ██╔██╗       ╚███████╗ ██╔══██║██╔══╝  ██╔══██╗██║╚██╔╝██║██╔══╝  ╚════██║ |
| ██████╔╝██╔╝ ██╗       ╚════██╗ ██║  ██║███████╗██║  ██║██║ ╚═╝ ██║███████╗███████║ |
| ╚═════╝ ╚═╝  ╚═╝       ██████╔╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝╚══════╝ |
+---------------------------------------------------------------------------------+
EOF
  printf "${C_RESET}"
}

# $1 = service name (systemd unit), prints "CONNECTED"/"NOT CONNECTED" colored
dx9_svc_state() {
  local unit="$1"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    printf "${C_GREEN}CONNECTED${C_RESET}"
  else
    printf "${C_RED}NOT CONNECTED${C_RESET}"
  fi
}

dx9_access_mode() {
  local mode_file="/etc/dx9hermes/access_mode"
  if [ -f "$mode_file" ]; then
    cat "$mode_file"
  else
    echo "Direct IP + Caddy"
  fi
}

dx9_menu() {
  local hermes_state; hermes_state=$(dx9_svc_state "hermes-gateway")
  local router_state; router_state=$(dx9_svc_state "9router")
  local mode; mode=$(dx9_access_mode)

  printf "${C_CYAN}+-----------------------------------------------------------------+${C_RESET}\n"
  printf "${C_CYAN}|${C_RESET} ${C_MAGENTA}Creator: %-20s${C_RESET}${C_CYAN}|${C_RESET} ${C_GREEN}Version: v%-10s${C_RESET}${C_CYAN}|${C_RESET}\n" "$DX9_CREATOR" "$DX9_VERSION"
  printf "${C_CYAN}+-----------------------------------------------------------------+${C_RESET}\n"
  printf " Hermes Gateway Status: %b\n" "$hermes_state"
  printf " 9Router Status:        %b\n" "$router_state"
  printf "\n"
  printf "${C_YELLOW}Choose an option :${C_RESET}\n"
  printf "${C_CYAN}-------------------------------------------------------------------${C_RESET}\n"
  local items=(
    "Install DX9HERMES (Hermes + 9Router)"
    "Show Status"
    "Test Telegram Bot Connection"
    "Remove / Uninstall"
    "Set Domain / Cloudflare Subdomain (switch from IP mode)"
    "Manage Bot Access (Add / Remove Allowed Users)"
    "Change AI Model (Quick switch)"
    "Reconfigure Free Provider (New Combo)"
    "Change 9Router Port / Bind Address"
    "Restart Services"
    "View Logs"
    "Backup / Restore Config"
    "Reset Configuration"
    "Switch Access Mode   [${mode}]"
    "Check For Update"
    "About"
  )
  local i
  for i in "${!items[@]}"; do
    printf " ${C_BLUE}%-2s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "$((i+1))" "${items[$i]}"
  done
  printf " ${C_BLUE}%-2s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "0" "Exit"
  printf "${C_CYAN}-------------------------------------------------------------------${C_RESET}\n"
}
