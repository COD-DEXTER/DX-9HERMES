#!/usr/bin/env bash
# DX9HERMES — Configure Hermes's model/provider from 9Router's *live* /v1/models
# (menu option 7 "Change Model", and called once from install.sh after 9Router
# is up). Deliberately does NOT hardcode a model ID: free-provider IDs on
# 9Router (e.g. the OpenCode/MiMo no-auth route) have changed shape between
# 9Router releases and can be rate-limited/blocked upstream without notice,
# so a hardcoded guess is exactly the kind of thing that silently breaks.
# Safe to re-run any time — idempotent, never touches 9Router's own config.
set -euo pipefail

CONF_DIR="/etc/dx9hermes"
ROUTER_ENV="$CONF_DIR/9router.env"
HERMES_ENV="$CONF_DIR/hermes.env"
SVC_USER="dx9hermes"

C_GREEN='\033[1;32m'; C_RED='\033[1;31m'; C_YELLOW='\033[1;33m'; C_RESET='\033[0m'
log()  { printf "${C_GREEN}[model]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[model]${C_RESET} %s\n" "$*"; }
err()  { printf "${C_RED}[model]${C_RESET} %s\n" "$*" >&2; }

[ -f "$ROUTER_ENV" ] || { err "$ROUTER_ENV not found — run install.sh first."; exit 1; }
# shellcheck disable=SC1090
source "$ROUTER_ENV"
PORT="${PORT:-20128}"
BASE_URL="http://127.0.0.1:${PORT}/v1"
REQUIRE_API_KEY="${REQUIRE_API_KEY:-false}"

AUTH_HEADER=()
if [ "$REQUIRE_API_KEY" = "true" ] && [ -f "$HERMES_ENV" ]; then
  ROUTER_KEY_FOR_HERMES="$(grep '^OPENAI_API_KEY=' "$HERMES_ENV" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "${ROUTER_KEY_FOR_HERMES:-}" ] && AUTH_HEADER=(-H "Authorization: Bearer ${ROUTER_KEY_FOR_HERMES}")
fi

wait_for_router() {
  log "Waiting for 9Router to answer on ${BASE_URL} ..."
  # BUG-FIX: on first boot 9Router fetches its full model catalog (~4600
  # models / 23 providers, several hundred KB) before it's genuinely useful,
  # and depending on network conditions that alone has been observed taking
  # over a minute (confirmed via journalctl: the port opens within ~1s of
  # start, but "[modelCatalog] ... loaded" doesn't log until ~60s+ later on
  # this install's network). The old fixed 20-iteration/~40s budget gave up
  # mid-fetch on a perfectly healthy install. Poll against a wall-clock
  # deadline instead, with real room (3 minutes) and a heartbeat every ~20s
  # so a slow-but-working install doesn't look silently stuck.
  local deadline last_heartbeat now code
  deadline=$(( $(date +%s) + 180 ))
  last_heartbeat=$(date +%s)
  while :; do
    code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "${AUTH_HEADER[@]}" "${BASE_URL}/models" 2>/dev/null || echo 000)"
    # 200 = answering with a body; 401 = REQUIRE_API_KEY=true and our key is
    # wrong/missing, but the server IS up — either way, stop waiting.
    case "$code" in
      200|401) return 0 ;;
    esac
    now=$(date +%s)
    [ "$now" -ge "$deadline" ] && return 1
    if [ $(( now - last_heartbeat )) -ge 20 ]; then
      log "...still waiting ($(( deadline - now ))s left — first boot fetches 9Router's full model catalog, can take a minute or two)"
      last_heartbeat=$now
    fi
    sleep 2
  done
}

if ! wait_for_router; then
  warn "9Router isn't answering on ${BASE_URL} yet (checked for ~3 minutes)."
  warn "This is normal right after a fresh install if the service is still starting."
  warn "Re-run this any time from the menu (option 7 — Change Model) once it's up:"
  warn "  dx9hermes"
  exit 0
fi

RAW_MODELS="$(curl -fsS -m 8 "${AUTH_HEADER[@]}" "${BASE_URL}/models" 2>/dev/null || true)"

MODEL_IDS=""
if [ -n "$RAW_MODELS" ] && command -v jq >/dev/null 2>&1; then
  MODEL_IDS="$(echo "$RAW_MODELS" | jq -r '.data[]?.id // empty' 2>/dev/null || true)"
fi

CANDIDATE="${HERMES_MODEL_OVERRIDE:-}"
if [ -z "$CANDIDATE" ] && [ -n "$MODEL_IDS" ]; then
  # Prefer a model whose id looks like a free/no-cost route (this project's
  # whole point), otherwise just take whatever is first — either way this is
  # a model 9Router itself just reported as live, never a guessed string.
  CANDIDATE="$(echo "$MODEL_IDS" | grep -i 'free' | head -1 || true)"
  [ -n "$CANDIDATE" ] || CANDIDATE="$(echo "$MODEL_IDS" | head -1)"
fi

if [ -z "$MODEL_IDS" ]; then
  warn "9Router is up but /v1/models returned no models yet."
  warn "This is expected on a brand-new install: even the no-auth free"
  warn "providers (e.g. OpenCode Free / MiMo) need a one-time 'Connect' click"
  warn "in the dashboard before they show up here — 9Router doesn't auto-enable"
  warn "any provider on its own."
  warn ""
  warn "1) Open the 9Router dashboard (see 'dx9hermes' → option 1's output, or"
  warn "   the URL sent to you on Telegram after install)."
  warn "2) Providers → Connect a free one (OpenCode Free / MiMo, or any other"
  warn "   no-auth option currently offered — these change over time, so pick"
  warn "   whatever's actually listed rather than trusting an old guide)."
  warn "3) Re-run this from the menu: dx9hermes → option 7 (Change Model)."
fi

HERMES_BIN_OK=0
if runuser -u "$SVC_USER" -- bash -lc 'command -v hermes' >/dev/null 2>&1; then
  HERMES_BIN_OK=1
elif [ -f "$CONF_DIR/hermes_bin_path" ] && runuser -u "$SVC_USER" -- test -x "$(cat "$CONF_DIR/hermes_bin_path")" 2>/dev/null; then
  HERMES_BIN_OK=1
else
  err "hermes isn't on ${SVC_USER}'s PATH (checked via a login shell, and via"
  err "$CONF_DIR/hermes_bin_path if present)."
  err "install.sh now installs Hermes AS ${SVC_USER} (fixed — it used to run"
  err "as root, which put the binary under /root where ${SVC_USER} can't see"
  err "it). If you're hitting this, re-run install.sh (menu option 1) so"
  err "install_hermes() re-installs it for the right user. Skipping for now."
fi

# Record what was verified BEFORE this run, so a failed candidate below never
# clobbers a previously-working model's status.
PREV_MODEL=""
[ -f "$CONF_DIR/current_model" ] && PREV_MODEL="$(cat "$CONF_DIR/current_model")"
PREV_HERMES_VERIFIED=0
[ -f "$CONF_DIR/model_e2e_verified" ] && PREV_HERMES_VERIFIED=1

if [ "$HERMES_BIN_OK" -eq 1 ]; then
  # BUG FIX: `runuser -u X -- hermes ...` (no login shell) does NOT source
  # ~/.bashrc/~/.profile, so it only works if hermes happens to already be
  # on runuser's bare PATH — not guaranteed for a ~/.local/bin install. Use
  # a login shell (bash -lc) like the detection above, so this actually runs
  # the same binary HERMES_BIN_OK just confirmed exists.
  hermes_run() { runuser -u "$SVC_USER" -- bash -lc "hermes $*"; }
  log "Pointing Hermes at 9Router (${BASE_URL})..."
  hermes_run config set model.provider custom
  hermes_run config set model.base_url "$(printf '%q' "$BASE_URL")"

  # Sync ~/.hermes/.env BEFORE any test call below, so a real `hermes chat`
  # attempt already has whatever credential Hermes' custom-provider path
  # reads (per Hermes' own docs: "API keys are saved to .env" — this mirrors
  # the exact OPENAI_API_KEY convention Hermes' own custom-provider examples
  # use, not a guess). 9Router has REQUIRE_API_KEY=false by default, so this
  # is a non-empty placeholder, not a real secret, unless that's been flipped.
  SVC_HOME="$(getent passwd "$SVC_USER" | cut -d: -f6)"
  if [ -n "$SVC_HOME" ]; then
    HERMES_DOTENV="$SVC_HOME/.hermes/.env"
    mkdir -p "$SVC_HOME/.hermes"
    touch "$HERMES_DOTENV"
    router_key_val="local-no-auth"
    [ "$REQUIRE_API_KEY" = "true" ] && router_key_val="${ROUTER_KEY_FOR_HERMES:-REPLACE_ME}"
    grep -q '^OPENAI_BASE_URL=' "$HERMES_DOTENV" 2>/dev/null \
      && sed -i "s#^OPENAI_BASE_URL=.*#OPENAI_BASE_URL=${BASE_URL}#" "$HERMES_DOTENV" \
      || echo "OPENAI_BASE_URL=${BASE_URL}" >> "$HERMES_DOTENV"
    grep -q '^OPENAI_API_KEY=' "$HERMES_DOTENV" 2>/dev/null \
      && sed -i "s#^OPENAI_API_KEY=.*#OPENAI_API_KEY=${router_key_val}#" "$HERMES_DOTENV" \
      || echo "OPENAI_API_KEY=${router_key_val}" >> "$HERMES_DOTENV"
    chown -R "$SVC_USER":"$SVC_USER" "$SVC_HOME/.hermes"
    chmod 600 "$HERMES_DOTENV"
  fi

  if [ -n "$CANDIDATE" ]; then
    # BUG FIX (critical, per second audit): the previous version committed
    # model.default to $CANDIDATE FIRST, then curl'd 9Router's
    # /chat/completions directly to "verify" it. That only proves 9Router +
    # the model work — it never sends a single request through Hermes's own
    # runtime (its provider wiring, base_url handling, API-key routing,
    # compatibility mode), so a config mistake or a Hermes-side bug in that
    # path could pass "verification" while every real Telegram message
    # still fails. It also meant a candidate that failed the check was left
    # sitting in model.default as Hermes's active model anyway.
    #
    # Fix, using only documented Hermes behavior (hermes-agent.nousresearch.com
    # /docs/reference/cli-commands — "Configuration Precedence": CLI
    # arguments override config.yaml; `hermes chat -q "..."` is a genuine
    # non-interactive single-query mode, exit 0 = turn completed): run
    #   hermes chat --model <candidate> -q "<prompt>"
    # This sends one real turn through Hermes itself, using the candidate as
    # a PER-INVOCATION override, without ever writing it to model.default.
    # Only if that call actually succeeds do we commit model.default to it —
    # so a failing candidate can never become Hermes's live default.
    log "Testing candidate model through Hermes itself (not just 9Router directly): ${CANDIDATE}"
    set +e
    # HARDENING: printf %q shell-escapes $CANDIDATE properly before it's
    # embedded in the bash -lc string below — the previous version wrapped
    # it in manual single-quotes ('${CANDIDATE}'), which breaks (and could
    # let a crafted model id inject shell syntax) if a model id ever
    # contained a single quote itself. 9Router model ids don't today, but
    # this removes the assumption entirely rather than relying on it.
    CANDIDATE_Q="$(printf '%q' "$CANDIDATE")"
    E2E_RAW="$(runuser -u "$SVC_USER" -- bash -lc "timeout 30 hermes chat --model ${CANDIDATE_Q} -q 'Reply with the single word: ok'" 2>&1)"
    E2E_EXIT=$?
    set -e
    E2E_STRIPPED="$(printf '%s' "$E2E_RAW" | tr -d '[:space:]')"

    if [ "$E2E_EXIT" -eq 0 ] && [ -n "$E2E_STRIPPED" ]; then
      log "Real 'hermes chat --model ${CANDIDATE}' call succeeded (exit 0, non-empty reply)."
      hermes_run config set model.default "$(printf '%q' "$CANDIDATE")"
      echo "$CANDIDATE" > "$CONF_DIR/current_model"
      : > "$CONF_DIR/model_e2e_verified"
      rm -f "$CONF_DIR/router_model_e2e_verified"
      log "E2E verified through Hermes: Hermes -> ${BASE_URL} -> 9Router -> ${CANDIDATE} -> got a real reply."
    else
      warn "Candidate model ${CANDIDATE} is listed by 9Router's /v1/models, but a real"
      warn "'hermes chat --model ${CANDIDATE}' call did NOT complete successfully"
      warn "(exit code: ${E2E_EXIT}). Output: ${E2E_RAW:-<empty/timeout>}"
      if [ -n "$PREV_MODEL" ] && [ "$PREV_HERMES_VERIFIED" -eq 1 ]; then
        warn "Hermes's active model is UNCHANGED — still the previously-verified"
        warn "${PREV_MODEL}, since ${CANDIDATE} never passed this test."
      else
        warn "NOT changing Hermes's model.default — a candidate that fails this"
        warn "test is never written as the active model, so Hermes is left"
        warn "exactly as it was before this run (no working model set yet)."
      fi
      warn "Open the 9Router dashboard, check the provider's actual status/"
      warn "logs, then re-run this (menu option 7)."
      # Deliberately no writes to current_model / model_e2e_verified here.
    fi
  else
    warn "No model set yet — model.provider/model.base_url are configured,"
    warn "model.default is left alone until a model shows up in /v1/models."
  fi

  if systemctl is-active --quiet hermes-gateway 2>/dev/null; then
    log "Restarting hermes-gateway so it picks up the new config..."
    systemctl restart hermes-gateway
  fi
else
  # Hermes isn't reachable for this user at all, so its own request path
  # genuinely cannot be exercised. Per audit: report that limitation
  # honestly instead of silently falling back to a curl-only check and
  # still calling it a Hermes verification.
  if [ -n "$CANDIDATE" ]; then
    warn "Cannot verify through Hermes itself (hermes binary not found for ${SVC_USER})."
    warn "Falling back to a direct check against 9Router only — this proves"
    warn "9Router + the model work, NOT that Hermes can reach them."
    E2E_RESPONSE="$(curl -sS -m 25 "${AUTH_HEADER[@]}" -H 'Content-Type: application/json' \
      -X POST "${BASE_URL}/chat/completions" \
      -d "$(jq -n --arg m "$CANDIDATE" '{model:$m, messages:[{role:"user",content:"Reply with the single word: ok"}], max_tokens:5}')" \
      2>/dev/null || true)"
    E2E_OK=0
    if [ -n "$E2E_RESPONSE" ] && command -v jq >/dev/null 2>&1; then
      E2E_TEXT="$(echo "$E2E_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)"
      [ -n "$E2E_TEXT" ] && E2E_OK=1
    fi
    if [ "$E2E_OK" -eq 1 ]; then
      log "9Router model E2E verified: ${BASE_URL}/chat/completions -> ${CANDIDATE} -> got a real reply."
      warn "NOTE: this only proves 9Router + the model work. Hermes's own request"
      warn "path was NOT exercised (hermes binary unavailable for ${SVC_USER}), so"
      warn "this is intentionally NOT reported as a Hermes -> 9Router -> model"
      warn "verification. Fix the hermes install for ${SVC_USER} (menu option 1),"
      warn "then re-run this to get the full Hermes-level check."
      echo "$CANDIDATE" > "$CONF_DIR/current_model"
      : > "$CONF_DIR/router_model_e2e_verified"
      rm -f "$CONF_DIR/model_e2e_verified"
    else
      warn "Model ${CANDIDATE} did NOT return a usable completion directly from 9Router either."
      warn "Raw response: ${E2E_RESPONSE:-<empty/timeout>}"
    fi
  fi
fi

if [ -f "$CONF_DIR/model_e2e_verified" ]; then
  log "Done. Hermes → 9Router (${BASE_URL}) → model: $(cat "$CONF_DIR/current_model" 2>/dev/null || echo "$CANDIDATE") (E2E verified via a real Hermes call)."
elif [ -f "$CONF_DIR/router_model_e2e_verified" ]; then
  log "Done (partial). 9Router → model: $(cat "$CONF_DIR/current_model" 2>/dev/null || echo "$CANDIDATE") is verified directly, but NOT through Hermes itself — see notes above."
elif [ -n "$CANDIDATE" ] && [ -n "$PREV_MODEL" ] && [ "$PREV_HERMES_VERIFIED" -eq 1 ]; then
  log "Done (partial) — candidate ${CANDIDATE} did NOT pass the real E2E test above; Hermes is still on its previously-verified model: ${PREV_MODEL}."
elif [ -n "$CANDIDATE" ]; then
  log "Done (partial) — candidate ${CANDIDATE} did NOT pass the real E2E test above, so it was NOT set as Hermes's model. Fix the provider, then re-run this."
else
  log "Done (partial) — see the notes above for the one manual step left."
fi
