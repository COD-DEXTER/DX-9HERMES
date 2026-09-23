#!/usr/bin/env bash
# DX9HERMES — menu option 6: Manage Bot Access
set -euo pipefail
ENV_FILE="/etc/dx9hermes/hermes.env"
C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_RESET='\033[0m'

# shellcheck disable=SC1090
source "$ENV_FILE"
OWNER="$TELEGRAM_OWNER_ID"
IFS=',' read -ra IDS <<< "$TELEGRAM_ALLOWED_USERS"

print_list() {
  echo "Current allowed Telegram IDs:"
  for id in "${IDS[@]}"; do
    if [ "$id" = "$OWNER" ]; then
      printf "  %s ${C_YELLOW}(owner)${C_RESET}\n" "$id"
    else
      echo "  $id"
    fi
  done
}

save_list() {
  local joined; joined=$(IFS=,; echo "${IDS[*]}")
  sed -i "s/^TELEGRAM_ALLOWED_USERS=.*/TELEGRAM_ALLOWED_USERS=${joined}/" "$ENV_FILE"
  systemctl restart hermes-gateway
  echo "Updated. Hermes gateway restarted — takes effect within seconds."
}

add_id() {
  read -rp "New Telegram ID to allow (ask them to message @userinfobot): " new_id
  [ -n "$new_id" ] || { echo "No ID entered."; return; }
  IDS+=("$new_id")
  save_list
}

remove_id() {
  local non_owner=()
  for id in "${IDS[@]}"; do [ "$id" != "$OWNER" ] && non_owner+=("$id"); done
  if [ ${#non_owner[@]} -eq 0 ]; then
    echo "No removable (non-owner) IDs."
    return
  fi
  echo "Select an ID to remove:"
  select id in "${non_owner[@]}" "Back"; do
    [ "$id" = "Back" ] || [ -z "$id" ] && return
    IDS=()
    for existing in "${non_owner[@]}" "$OWNER"; do
      [ "$existing" != "$id" ] && IDS+=("$existing")
    done
    save_list
    break
  done
}

main() {
  print_list
  echo
  select choice in "Add a user ID" "Remove a user ID" "Back"; do
    case "$choice" in
      "Add a user ID") add_id; break ;;
      "Remove a user ID") remove_id; break ;;
      *) break ;;
    esac
  done
}
main "$@"
