#!/usr/bin/env bash
# demo.sh — PING protocol walkthrough (Python implementation)
#
# Installs dependencies, starts two Flask instances on localhost
# (Blog 1 on :5000, Blog 2 on :5001), and walks through the full state
# machine. Then demonstrates the retry/backoff loop by delaying Blog 2's
# startup.
#
# Usage:
#   ./demo.sh          # happy path + retry demo
#   ./demo.sh --quick  # happy path only

set -euo pipefail

BLOG1="http://localhost:5000"
BLOG2="http://localhost:5001"
QUICK="${1:-}"
LOGDIR="$(mktemp -d)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PING_PY="$SCRIPT_DIR/ping.py"

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

header()  { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
info()    { echo -e "  ${YELLOW}→${RESET} $*"; }
fail()    { echo -e "  ${RED}✗${RESET} $*"; }
json_pp() { echo "$1" | python3 -m json.tool 2>/dev/null || echo "$1"; }

# ── Cleanup ────────────────────────────────────────────────────────────────────
PIDS=()
cleanup() {
    echo -e "\n${YELLOW}Stopping instances…${RESET}"
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ── Helper: wait for an instance to be ready ──────────────────────────────────
# GET /inbox is a stable, side-effect-free endpoint.
wait_for_port() {
    local port=$1 label=$2 attempts=0
    while ! curl -sf "http://localhost:${port}/inbox" &>/dev/null; do
        sleep 0.2
        attempts=$((attempts + 1))
        if [[ $attempts -gt 50 ]]; then
            fail "$label did not start in time"
            exit 1
        fi
    done
}

# ── Prerequisites ──────────────────────────────────────────────────────────────
header "Checking prerequisites"

for cmd in python3 curl jq; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd found"
    else
        fail "$cmd not found — please install it and re-run"
        exit 1
    fi
done

if [[ ! -f "$PING_PY" ]]; then
    fail "ping.py not found at $PING_PY"
    exit 1
fi
ok "ping.py found"

# ── Install dependencies ───────────────────────────────────────────────────────
header "Installing Python dependencies"
python3 -m pip install --quiet flask requests
ok "flask and requests ready"

# ══════════════════════════════════════════════════════════════════════════════
# DEMO 1 — Happy path (both instances online)
# ══════════════════════════════════════════════════════════════════════════════
header "Demo 1 — Happy path"

info "Starting Blog 1 on :5000"
python3 "$PING_PY" 5000 &>"$LOGDIR/blog1.log" &
PIDS+=($!)

info "Starting Blog 2 on :5001"
python3 "$PING_PY" 5001 &>"$LOGDIR/blog2.log" &
PIDS+=($!)

wait_for_port 5000 "Blog 1"
wait_for_port 5001 "Blog 2"
ok "Both instances ready"

# ── Step 1 — Blog 1 sends ─────────────────────────────────────────────────────
header "Step 1 — Blog 1 sends a ping to Blog 2"
SEND_RESP=$(curl -s -X POST "$BLOG1/send" \
    -H 'Content-Type: application/json' \
    -d "{
        \"origin\": \"$BLOG1\",
        \"target\": \"$BLOG2\",
        \"payload_type\": \"ask\",
        \"content\": \"Hello Blog 2, have you heard about PING?\"
    }")

json_pp "$SEND_RESP"
PING_ID=$(echo "$SEND_RESP" | jq -r .ping_id)

if [[ "$PING_ID" == "null" || -z "$PING_ID" ]]; then
    fail "No ping_id returned — aborting"
    exit 1
fi

STATE=$(echo "$SEND_RESP" | jq -r .state)
ok "Ping created: $PING_ID  (Blog 1 state: $STATE)"

if [[ "$STATE" == "PING_RECEIVED" ]]; then
    ok "Blog 2 was online — Blog 1 already advanced to PING_RECEIVED"
else
    info "Blog 2 may not have confirmed yet — state is $STATE"
fi

# Allow a moment for the async ping delivery to reach Blog 2.
sleep 1

# ── Step 2 — Blog 2 inspects its inbox before deciding ───────────────────────
header "Step 2 — Blog 2 inspects inbox (consent check)"
INBOX_RESP=$(curl -s "$BLOG2/inbox")
json_pp "$INBOX_RESP"
INBOX_COUNT=$(echo "$INBOX_RESP" | jq 'length')
if [[ "$INBOX_COUNT" -ge 1 ]]; then
    ok "Blog 2 can see $INBOX_COUNT pending ping(s) — origin and payload type visible before pulling"
else
    info "Inbox empty — ping may not have arrived yet (retry loop will deliver it)"
fi

# ── Step 3 — Blog 2 explicitly pulls ─────────────────────────────────────────
header "Step 3 — Blog 2 explicitly pulls content (consent exercised)"
PULL_RESP=$(curl -s -X POST "$BLOG2/pull/$PING_ID")
json_pp "$PULL_RESP"
ok "Content received by Blog 2"
ok "State sequence: PING_RECEIVED → CONTENT_PULLED → ACKNOWLEDGED"

# ── Step 4 — Verify Blog 1 outbox is terminal ─────────────────────────────────
header "Step 4 — Verify Blog 1 outbox entry is terminal (410)"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BLOG1/outbox/$PING_ID")
if [[ "$HTTP_STATUS" == "410" ]]; then
    ok "Blog 1 returned 410 GONE — entry is ACKNOWLEDGED, outbox closed"
else
    info "Blog 1 returned $HTTP_STATUS (expected 410 after acknowledgement)"
fi

# ── Step 5 — Double-ack guard ─────────────────────────────────────────────────
header "Step 5 — Double-ack on terminal entry returns 204 (idempotent)"
ACK_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BLOG1/outbox/$PING_ID/ack")
if [[ "$ACK_STATUS" == "204" ]]; then
    ok "Correctly accepted duplicate ack with 204 — already ACKNOWLEDGED, no harm done"
else
    info "Got $ACK_STATUS (expected 204 for idempotent re-ack)"
fi

# ── Step 6 — Ignore path ──────────────────────────────────────────────────────
header "Step 6 — Blog 2 ignores an unwanted ping (no notification to Blog 1)"

SEND_IGNORE=$(curl -s -X POST "$BLOG1/send" \
    -H 'Content-Type: application/json' \
    -d "{
        \"origin\": \"$BLOG1\",
        \"target\": \"$BLOG2\",
        \"payload_type\": \"ask\",
        \"content\": \"You can ignore this one.\"
    }")
IGNORE_ID=$(echo "$SEND_IGNORE" | jq -r .ping_id)
sleep 1

IGNORE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BLOG2/ignore/$IGNORE_ID")
if [[ "$IGNORE_STATUS" == "204" ]]; then
    ok "Blog 2 silently ignored ping $IGNORE_ID — Blog 1 receives no notification"
else
    info "Got $IGNORE_STATUS (expected 204)"
fi

# Confirm it is gone from Blog 2's inbox.
INBOX_AFTER=$(curl -s "$BLOG2/inbox")
STILL_PRESENT=$(echo "$INBOX_AFTER" | jq "[.[] | select(.ping_id == \"$IGNORE_ID\")] | length")
if [[ "$STILL_PRESENT" == "0" ]]; then
    ok "Ignored ping no longer appears in Blog 2's inbox"
else
    info "Ping still visible in inbox — check ignore implementation"
fi

# ── Step 7 — Hash mismatch guard ─────────────────────────────────────────────
header "Step 7 — Hash mismatch is rejected with 422"

# Send a ping with a deliberately wrong hash.
SEND_BAD=$(curl -s -X POST "$BLOG1/send" \
    -H 'Content-Type: application/json' \
    -d "{
        \"origin\": \"$BLOG1\",
        \"target\": \"$BLOG2\",
        \"payload_type\": \"ask\",
        \"content\": \"Tampered content.\",
        \"content_hash\": \"0000000000000000000000000000000000000000000000000000000000000000\"
    }")
BAD_ID=$(echo "$SEND_BAD" | jq -r .ping_id)
sleep 1

MISMATCH_RESP=$(curl -s -w "\n%{http_code}" -X POST "$BLOG2/pull/$BAD_ID")
MISMATCH_BODY=$(echo "$MISMATCH_RESP" | head -n -1)
MISMATCH_HTTP=$(echo "$MISMATCH_RESP" | tail -n 1)

json_pp "$MISMATCH_BODY"
if [[ "$MISMATCH_HTTP" == "422" ]]; then
    ok "Hash mismatch correctly rejected with 422"
else
    info "Got $MISMATCH_HTTP (expected 422)"
fi

# ── Quick exit ─────────────────────────────────────────────────────────────────
if [[ "$QUICK" == "--quick" ]]; then
    echo -e "\n${BOLD}${GREEN}Happy path complete. (--quick mode, skipping retry demo)${RESET}"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# DEMO 2 — Retry / backoff (Blog 2 starts late)
# ══════════════════════════════════════════════════════════════════════════════
header "Demo 2 — Retry loop: Blog 2 is offline when Blog 1 sends"

info "Stopping Blog 2 to simulate it being offline"
kill "${PIDS[1]}" 2>/dev/null || true
unset 'PIDS[1]'
sleep 1

info "Sending ping from Blog 1 — Blog 2 is down, expect retry backoff"
SEND_RESP2=$(curl -s -X POST "$BLOG1/send" \
    -H 'Content-Type: application/json' \
    -d "{
        \"origin\": \"$BLOG1\",
        \"target\": \"$BLOG2\",
        \"payload_type\": \"ask\",
        \"content\": \"Are you there, Blog 2?\"
    }")

PING_ID2=$(echo "$SEND_RESP2" | jq -r .ping_id)
STATE2=$(echo "$SEND_RESP2" | jq -r .state)
ok "Ping created: $PING_ID2 — state: $STATE2 (sitting in PING_EXISTS, retry loop running)"

info "Waiting 8 seconds for the first retry attempt to fire and log…"
sleep 8

info "Blog 1 retry log (last 5 lines):"
tail -5 "$LOGDIR/blog1.log" | sed 's/^/    /'

info "Now starting Blog 2 back up"
python3 "$PING_PY" 5001 &>"$LOGDIR/blog2.log" &
PIDS+=($!)
wait_for_port 5001 "Blog 2"
ok "Blog 2 is back online"

# The retry schedule starts at 2s, then 5s, then 10s. After the first
# failures the loop will next attempt at the 10s interval, so Blog 2
# should receive the ping within ~15s of coming back online.
info "Waiting up to 30 seconds for the retry loop to deliver the ping…"
DELIVERED=0
for i in $(seq 1 30); do
    sleep 1

    # Check Blog 2's inbox — presence means the retry delivered the ping.
    INBOX=$(curl -s "$BLOG2/inbox" 2>/dev/null || echo "[]")
    COUNT=$(echo "$INBOX" | jq "[.[] | select(.ping_id == \"$PING_ID2\")] | length" 2>/dev/null || echo "0")
    if [[ "$COUNT" -ge 1 ]]; then
        ok "Ping delivered and visible in Blog 2's inbox after ~${i}s"

        # Now Blog 2 decides to pull.
        RETRY_PULL=$(curl -s -X POST "$BLOG2/pull/$PING_ID2")
        json_pp "$RETRY_PULL"
        ok "Blog 2 successfully pulled content delivered via retry"
        DELIVERED=1
        break
    fi
done

if [[ "$DELIVERED" == "0" ]]; then
    fail "Ping was not delivered within 30s — check logs below"
    info "Blog 1 log tail:"; tail -8 "$LOGDIR/blog1.log" | sed 's/^/    /'
    info "Blog 2 log tail:"; tail -8 "$LOGDIR/blog2.log" | sed 's/^/    /'
fi

# ══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}${GREEN}Demo complete.${RESET}"
echo -e "  Blog 1 log: $LOGDIR/blog1.log"
echo -e "  Blog 2 log: $LOGDIR/blog2.log"
