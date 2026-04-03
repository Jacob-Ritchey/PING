"""PING — Reference implementation in Python.

Aligned with Protocol Specification Draft 0.1.

State machine:
    PING_EXISTS → PING_RECEIVED → CONTENT_PULLED → ACKNOWLEDGED

Key changes from initial demo:
  - advance() is now the sole mechanism for state transitions everywhere.
  - Sender-side outbox state advances to PING_RECEIVED once Blog 2 confirms receipt.
  - Background retry/backoff loop delivers pings to an offline Blog 2.
  - Hash verification: Blog 2 rejects content whose SHA-256 doesn't match the ping.
  - /inbox lets Blog 2 inspect pending pings before deciding whether to pull.
  - /ignore/<ping_id> implements the silent-ignore consent path.
  - /outbox/<ping_id> returns 410 only after ACKNOWLEDGED (not after CONTENT_PULLED).
  - /outbox/<ping_id>/ack is idempotent — safe to call on an already-terminal entry.
  - Locks guard all shared state so the retry thread and Flask threads don't race.
"""

import hashlib
import sys
import threading
import time
from enum import Enum
from uuid import uuid4

from flask import Flask, request, jsonify
import requests as http

app = Flask(__name__)


# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

class State(Enum):
    PING_EXISTS    = "PING_EXISTS"
    PING_RECEIVED  = "PING_RECEIVED"
    CONTENT_PULLED = "CONTENT_PULLED"
    ACKNOWLEDGED   = "ACKNOWLEDGED"

TRANSITIONS = {
    State.PING_EXISTS:    State.PING_RECEIVED,
    State.PING_RECEIVED:  State.CONTENT_PULLED,
    State.CONTENT_PULLED: State.ACKNOWLEDGED,
}

def advance(state: State) -> State:
    """Return the next state, or raise if already terminal."""
    if state not in TRANSITIONS:
        raise ValueError(f"{state.value} is a terminal state")
    return TRANSITIONS[state]


# ---------------------------------------------------------------------------
# In-memory storage
# ---------------------------------------------------------------------------

# Sender side:  ping_id → {state, origin, target, payload_type, content,
#                           content_hash}
outbox: dict = {}
outbox_lock = threading.Lock()

# Receiver side: ping_id → {state, origin, payload_type, content_hash,
#                            content (set after pull)}
inbox: dict = {}
inbox_lock = threading.Lock()

# Ping IDs that this instance has explicitly ignored — silently dropped on
# future re-delivery attempts.
ignored: set = set()


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _log(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------------------
# Retry / backoff delivery loop (sender side)
# ---------------------------------------------------------------------------

# Delays in seconds between successive retry attempts.
RETRY_SCHEDULE = [2, 5, 10, 30, 60, 300]


def _retry_worker(ping_id: str) -> None:
    """Background thread: keep attempting ping delivery until Blog 2 confirms."""
    for delay in RETRY_SCHEDULE:
        time.sleep(delay)

        with outbox_lock:
            entry = outbox.get(ping_id)
            if entry is None or entry["state"] != State.PING_EXISTS:
                _log(f"[retry] {ping_id}: already past PING_EXISTS, stopping")
                return

        _log(f"[retry] {ping_id}: attempting delivery to {entry['target']}")
        try:
            resp = http.post(
                f"{entry['target']}/ping",
                json={
                    "ping_id":      ping_id,
                    "origin":       entry["origin"],
                    "payload_type": entry["payload_type"],
                    "content_hash": entry["content_hash"],
                },
                timeout=5,
            )
            if resp.status_code == 204:
                with outbox_lock:
                    entry["state"] = advance(entry["state"])  # → PING_RECEIVED
                _log(f"[retry] {ping_id}: delivered → PING_RECEIVED")
                return
            else:
                _log(f"[retry] {ping_id}: remote returned {resp.status_code}, will retry")
        except http.RequestException as exc:
            _log(f"[retry] {ping_id}: network error ({exc}), will retry")

    _log(f"[retry] {ping_id}: exhausted retry schedule, state remains PING_EXISTS")


# ---------------------------------------------------------------------------
# Sender endpoints
# ---------------------------------------------------------------------------

@app.post("/send")
def send_ping():
    """Blog 1: compose content, record it in the outbox, and notify Blog 2."""
    body = request.json
    ping_id  = str(uuid4())
    origin   = body["origin"]
    target   = body["target"]
    content  = body.get("content", "")

    # If no hash is supplied, compute one so Blog 2 can verify integrity.
    content_hash = body.get("content_hash") or sha256(content)

    with outbox_lock:
        outbox[ping_id] = {
            "state":        State.PING_EXISTS,
            "origin":       origin,
            "target":       target,
            "payload_type": body.get("payload_type", "ask"),
            "content":      content,
            "content_hash": content_hash,
        }

    # Attempt immediate delivery.
    delivered = False
    try:
        resp = http.post(
            f"{target}/ping",
            json={
                "ping_id":      ping_id,
                "origin":       origin,
                "payload_type": outbox[ping_id]["payload_type"],
                "content_hash": content_hash,
            },
            timeout=5,
        )
        if resp.status_code == 204:
            with outbox_lock:
                # Advance sender-side state now that Blog 2 has confirmed receipt.
                outbox[ping_id]["state"] = advance(outbox[ping_id]["state"])  # → PING_RECEIVED
            delivered = True
    except http.RequestException:
        pass

    if not delivered:
        # Blog 2 is offline — start the background retry loop.
        t = threading.Thread(target=_retry_worker, args=(ping_id,), daemon=True)
        t.start()

    state_value = outbox[ping_id]["state"].value
    _log(f"[send] {ping_id}: initial state → {state_value}")
    return jsonify({"ping_id": ping_id, "state": state_value}), 201


@app.get("/outbox/<ping_id>")
def serve_content(ping_id):
    """Blog 2 pulls content from here.

    Returns 410 only after ACKNOWLEDGED (terminal). Re-pulls during
    CONTENT_PULLED are allowed — they handle the case where Blog 2's ack
    request was lost in transit.
    """
    with outbox_lock:
        entry = outbox.get(ping_id)
        if not entry:
            return "", 404

        if entry["state"] == State.ACKNOWLEDGED:
            return "", 410  # terminal — outbox entry is closed

        # Allow serving from PING_RECEIVED or CONTENT_PULLED (idempotent pull).
        entry["state"] = State.CONTENT_PULLED
        return jsonify({
            "ping_id":      ping_id,
            "payload_type": entry["payload_type"],
            "content":      entry["content"],
            "content_hash": entry["content_hash"],
        })


@app.post("/outbox/<ping_id>/ack")
def receive_ack(ping_id):
    """Blog 2 confirms delivery. Idempotent — safe to call on an already-terminal entry."""
    with outbox_lock:
        entry = outbox.get(ping_id)
        if not entry:
            return "", 404
        if entry["state"] != State.ACKNOWLEDGED:
            entry["state"] = advance(entry["state"])  # CONTENT_PULLED → ACKNOWLEDGED
            _log(f"[ack] {ping_id}: → ACKNOWLEDGED")
    return "", 204


# ---------------------------------------------------------------------------
# Receiver endpoints
# ---------------------------------------------------------------------------

@app.post("/ping")
def receive_ping():
    """Accept a ping notification from a remote blog.

    Silently drops pings from origins on the ignored list.
    """
    body    = request.json
    ping_id = body["ping_id"]

    with inbox_lock:
        if ping_id in ignored:
            _log(f"[ping] {ping_id}: in ignored set, dropping silently")
        else:
            inbox[ping_id] = {
                "state":        State.PING_RECEIVED,
                "origin":       body["origin"],
                "payload_type": body["payload_type"],
                "content_hash": body.get("content_hash"),
            }
            _log(f"[ping] {ping_id}: recorded → PING_RECEIVED")

    # Always return 204 — silence reveals nothing to the sender.
    return "", 204


@app.get("/inbox")
def list_inbox():
    """Return all non-terminal inbox entries so Blog 2 can decide what to pull.

    This is the consent inspection point: Blog 2 sees origin and payload type
    before committing to a pull.
    """
    with inbox_lock:
        items = [
            {
                "ping_id":      pid,
                "origin":       e["origin"],
                "payload_type": e["payload_type"],
                "content_hash": e["content_hash"],
                "state":        e["state"].value,
            }
            for pid, e in inbox.items()
            if e["state"] != State.ACKNOWLEDGED
        ]
    return jsonify(items)


@app.post("/pull/<ping_id>")
def pull_content(ping_id):
    """Blog 2 decides to fetch content — this is where consent is exercised.

    Verifies the SHA-256 hash of the received content against the hash
    advertised in the original ping. Returns 422 on mismatch.
    """
    with inbox_lock:
        entry = inbox.get(ping_id)
    if not entry:
        return jsonify({"error": "unknown ping_id"}), 404
    if entry["state"] == State.ACKNOWLEDGED:
        return jsonify({"error": "already acknowledged"}), 409

    # Fetch content from the sender's outbox.
    try:
        resp = http.get(f"{entry['origin']}/outbox/{ping_id}", timeout=10)
    except http.RequestException as exc:
        return jsonify({"error": f"pull failed: {exc}"}), 502

    if resp.status_code != 200:
        return jsonify({"error": f"sender returned {resp.status_code}"}), 502

    payload = resp.json()

    # Hash verification — reject tampered or corrupted content.
    advertised_hash = entry["content_hash"]
    if advertised_hash:
        actual_hash = sha256(payload["content"])
        if actual_hash != advertised_hash:
            _log(f"[pull] {ping_id}: hash mismatch — expected {advertised_hash}, got {actual_hash}")
            return jsonify({
                "error":    "hash mismatch",
                "expected": advertised_hash,
                "actual":   actual_hash,
            }), 422

    with inbox_lock:
        entry["state"]   = advance(entry["state"])  # PING_RECEIVED → CONTENT_PULLED
        entry["content"] = payload["content"]

    # Acknowledge delivery to the sender.
    try:
        ack = http.post(f"{entry['origin']}/outbox/{ping_id}/ack", timeout=5)
        if ack.status_code == 204:
            with inbox_lock:
                entry["state"] = advance(entry["state"])  # CONTENT_PULLED → ACKNOWLEDGED
            _log(f"[pull] {ping_id}: → ACKNOWLEDGED")
    except http.RequestException as exc:
        _log(f"[pull] {ping_id}: ack failed ({exc}), state left at CONTENT_PULLED")

    return jsonify(payload)


@app.post("/ignore/<ping_id>")
def ignore_ping(ping_id):
    """Blog 2 silently ignores a ping.

    Removes it from the inbox and marks the ID so future re-delivery attempts
    are also dropped. Blog 1 receives no notification — silence is the
    canonical response to an unwanted ping.
    """
    with inbox_lock:
        inbox.pop(ping_id, None)
        ignored.add(ping_id)
    _log(f"[ignore] {ping_id}: silently ignored")
    return "", 204


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    # threaded=True so Flask can handle concurrent requests while the retry
    # loop is running in the background.
    app.run(port=port, threaded=True)
