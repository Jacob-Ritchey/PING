#!/usr/bin/env bash
# demo.sh — PING protocol walkthrough
#
# Starts two instances of the binary on localhost (Blog 1 on :5000, Blog 2 on
# :5001) and walks through the full state machine, then demonstrates the retry
# loop by delaying Blog 2's startup.
#
# Usage:
#   ./demo.sh          # happy path + retry demo
#   ./demo.sh --quick  # happy path only

set -euo pipefail

BLOG1="http://localhost:5000"
BLOG2="http://localhost:5001"
BIN="./target/debug/ping"
QUICK="${1:-}"

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

# ── Prerequisites ──────────────────────────────────────────────────────────────
header "Checking prerequisites"

for cmd in cargo curl jq; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd found"
    else
        fail "$cmd not found — please install it and re-run"
        exit 1
    fi
done

# ── Build ──────────────────────────────────────────────────────────────────────
header "Building binary"
cargo build 2>&1 | tail -3
ok "Build complete"

# ── Helper: wait for a port to be ready ───────────────────────────────────────
wait_for_port() {
    local port=$1 label=$2 attempts=0
    while ! curl -s "http://localhost:${port}/ping" -X POST \
            -H 'Content-Type: application/json' -d '{}' &>/dev/null; do
        sleep 0.2
        attempts=$((attempts + 1))
        if [[ $attempts -gt 25 ]]; then
            fail "$label did not start in time"
            exit 1
        fi
    done
}

# ── Helper: pretty-print state from both sides ────────────────────────────────
check_states() {
    local ping_id=$1
    # Blog 1 outbox state is returned when we attempt to serve content; instead
    # we inspect indirectly through /send response stored in PING_ID context.
    # For demo purposes the retry loop logs to stderr, so we just note the ID.
    info "Ping ID: $ping_id"
}

# ══════════════════════════════════════════════════════════════════════════════
# DEMO 1 — Happy path (both instances online)
# ══════════════════════════════════════════════════════════════════════════════
header "Demo 1 — Happy path"

info "Starting Blog 1 on :5000"
PING_DEMO_MODE=1 $BIN 5000 2>/tmp/blog1.log &
PIDS+=($!)

info "Starting Blog 2 on :5001"
PING_DEMO_MODE=1 $BIN 5001 2>/tmp/blog2.log &
PIDS+=($!)

wait_for_port 5000 "Blog 1"
wait_for_port 5001 "Blog 2"
ok "Both instances ready"

# Step 1 — Blog 1 sends a ping
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

ok "Ping created: $PING_ID"
ok "State on Blog 1: PING_EXISTS → PING_RECEIVED (Blog 2 was online)"

# Step 2 — Blog 2 pulls the content
header "Step 2 — Blog 2 pulls the content from Blog 1"
PULL_RESP=$(curl -s -X POST "$BLOG2/pull/$PING_ID")
json_pp "$PULL_RESP"
ok "Content received by Blog 2"
ok "State sequence complete: CONTENT_PULLED → ACKNOWLEDGED"

# Step 3 — Verify Blog 1 content is now gone (ACKNOWLEDGED)
header "Step 3 — Verify Blog 1 outbox entry is terminal"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BLOG1/outbox/$PING_ID")
if [[ "$HTTP_STATUS" == "410" ]]; then
    ok "Blog 1 returned 410 GONE — entry is ACKNOWLEDGED, content may be archived"
else
    info "Blog 1 returned $HTTP_STATUS (expected 410 after acknowledgement)"
fi

# Step 4 — Double-ack guard
header "Step 4 — Double-ack returns 409 CONFLICT"
ACK_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BLOG1/outbox/$PING_ID/ack")
if [[ "$ACK_STATUS" == "409" ]]; then
    ok "Correctly rejected duplicate ack with 409 CONFLICT"
else
    info "Got $ACK_STATUS (expected 409)"
fi

# ── Stop Blog 2 before retry demo ─────────────────────────────────────────────
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

# Temporarily lower the first backoff interval by editing the env isn't possible
# without recompiling, so instead we'll watch Blog 1's retry log. The first
# retry fires within 10 seconds (the poll interval) since next_retry_at is None.
info "Sending ping from Blog 1 — Blog 2 is down, expect immediate failure"
SEND_RESP2=$(curl -s -X POST "$BLOG1/send" \
    -H 'Content-Type: application/json' \
    -d "{
        \"origin\": \"$BLOG1\",
        \"target\": \"$BLOG2\",
        \"payload_type\": \"ask\",
        \"content\": \"Are you there, Blog 2?\"
    }")

PING_ID2=$(echo "$SEND_RESP2" | jq -r .ping_id)
ok "Ping created: $PING_ID2 — sitting in PING_EXISTS"

info "Waiting 12 seconds to let the retry loop attempt and log a failure…"
sleep 12

info "Blog 1 retry log (last 5 lines):"
tail -5 /tmp/blog1.log | sed 's/^/    /'

info "Now starting Blog 2 back up"
PING_DEMO_MODE=1 $BIN 5001 2>/tmp/blog2.log &
PIDS+=($!)
wait_for_port 5001 "Blog 2"
ok "Blog 2 is back online"

# In demo mode the backoff after attempt 1 is 5s, so the next retry loop tick
# (every 10s) will pick it up within ~15 seconds of Blog 2 coming online.
info "Waiting up to 30 seconds for the retry loop to deliver the ping…"
DELIVERED=0
for i in $(seq 1 30); do
    sleep 1
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$BLOG2/pull/$PING_ID2" 2>/dev/null || echo "000")
    if [[ "$STATUS" == "200" ]]; then
        ok "Blog 2 received and pulled content after retry (~${i}s after coming back online)"
        DELIVERED=1
        break
    fi
done

if [[ "$DELIVERED" == "0" ]]; then
    fail "Ping was not delivered within 30s — check logs below"
    info "Blog 1 log tail:"; tail -8 /tmp/blog1.log | sed 's/^/    /'
    info "Blog 2 log tail:"; tail -8 /tmp/blog2.log | sed 's/^/    /'
fi

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}${GREEN}Demo complete.${RESET}"
echo -e "  Blog 1 log: /tmp/blog1.log"
echo -e "  Blog 2 log: /tmp/blog2.log"
