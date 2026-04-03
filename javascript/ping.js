/* PING — Minimal reference implementation in JavaScript.
 *
 * Fixes vs draft 0.1:
 *  - Outbox now stays open until ACKNOWLEDGED (not CONTENT_PULLED).
 *  - Sender advances to PING_RECEIVED when Blog 2 confirms receipt.
 *  - advance() helper is used throughout instead of manual string assignment.
 *  - Retry loop with exponential backoff on the initial ping.
 *  - Blocking: receiver maintains a blocklist; blocked pings are silently
 *    dropped (sender cannot distinguish blocked from offline).
 *  - Tiered endpoints: /ping/public (open) and /ping/user (token-gated).
 *  - GET /inbox lets the receiver list pending pings.
 *
 * Out of scope for this draft (spec §Non-Goals / future drafts):
 *  - Anonymous proxy tier (requires external infrastructure).
 *  - Private tier / E2EE.
 *  - Message masks.
 *  - P2P / DHT content transfer.
 */

const express = require("express");
const crypto = require("crypto");
const app = express();
app.use(express.json());

// CORS — required for the browser-based demo (ping-demo.html)
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET,POST,DELETE');
  res.header('Access-Control-Allow-Headers', 'Content-Type,Authorization');
  if (req.method === 'OPTIONS') return res.sendStatus(200);
  next();
});

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

const State = Object.freeze({
  PING_EXISTS:    "PING_EXISTS",
  PING_RECEIVED:  "PING_RECEIVED",
  CONTENT_PULLED: "CONTENT_PULLED",
  ACKNOWLEDGED:   "ACKNOWLEDGED",
});

const TRANSITIONS = {
  [State.PING_EXISTS]:    State.PING_RECEIVED,
  [State.PING_RECEIVED]:  State.CONTENT_PULLED,
  [State.CONTENT_PULLED]: State.ACKNOWLEDGED,
};

function advance(state) {
  const next = TRANSITIONS[state];
  if (!next) throw new Error(`${state} is a terminal state`);
  return next;
}

// ---------------------------------------------------------------------------
// Storage (in-memory — replace with durable store for production)
// ---------------------------------------------------------------------------

const outbox   = new Map(); // sender side:   pingId → entry
const inbox    = new Map(); // receiver side: pingId → entry
const blocklist = new Set(); // blocked origins (domain or IP string)

// ---------------------------------------------------------------------------
// Retry / backoff
// ---------------------------------------------------------------------------

// Intervals in ms: 5 s, 30 s, 2 min, 10 min, 1 h
const RETRY_INTERVALS_MS = [5_000, 30_000, 120_000, 600_000, 3_600_000];

// Fires in the background; advances outbox entry to PING_RECEIVED on success.
async function attemptPingWithRetry(pingId, target, payload) {
  for (let attempt = 0; attempt <= RETRY_INTERVALS_MS.length; attempt++) {
    const entry = outbox.get(pingId);
    // Bail if entry was removed or already advanced past PING_EXISTS externally.
    if (!entry || entry.state !== State.PING_EXISTS) return;

    try {
      const resp = await fetch(`${target}/ping/public`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(10_000),
      });
      if (resp.ok) {
        entry.state = advance(entry.state); // PING_EXISTS → PING_RECEIVED
        return;
      }
    } catch (_) {
      // Blog 2 is offline or unreachable; try again after backoff.
    }

    const wait = RETRY_INTERVALS_MS[attempt];
    if (wait === undefined) break; // exhausted retry schedule
    await new Promise((r) => setTimeout(r, wait));
  }
  // State remains PING_EXISTS after all retries; caller may inspect and decide.
}

// ---------------------------------------------------------------------------
// Sender endpoints
// ---------------------------------------------------------------------------

// POST /send — Blog 1 creates a new ping and begins the retry loop.
app.post("/send", (req, res) => {
  const { origin, target, payload_type = "ask", content = "", content_hash } = req.body;
  if (!origin || !target) {
    return res.status(400).json({ error: "origin and target are required" });
  }

  const pingId = crypto.randomUUID();
  outbox.set(pingId, {
    state: State.PING_EXISTS,
    origin,
    target,
    payload_type,
    content,
    content_hash,
  });

  // Kick off the retry loop without blocking the response.
  const payload = { ping_id: pingId, origin, payload_type, content_hash };
  attemptPingWithRetry(pingId, target, payload).catch(() => {});

  res.status(201).json({ ping_id: pingId, state: State.PING_EXISTS });
});

// GET /outbox/:pingId — Blog 2 pulls content from here.
// Content MUST remain available until ACKNOWLEDGED (spec §Sender Records).
app.get("/outbox/:pingId", (req, res) => {
  const entry = outbox.get(req.params.pingId);
  if (!entry) return res.status(404).end();

  // Only close the outbox once the receiver has acknowledged receipt.
  if (entry.state === State.ACKNOWLEDGED) return res.status(410).end();

  // Advance to CONTENT_PULLED on first pull (idempotent on subsequent pulls
  // before ACK, so a failed ACK allows the receiver to retry).
  if (entry.state !== State.CONTENT_PULLED) {
    entry.state = State.CONTENT_PULLED;
  }

  res.json({
    ping_id: req.params.pingId,
    payload_type: entry.payload_type,
    content: entry.content,
  });
});

// POST /outbox/:pingId/ack — Blog 2 signals it has successfully pulled content.
// Idempotent: re-acknowledging an already-acknowledged entry is a no-op.
app.post("/outbox/:pingId/ack", (req, res) => {
  const entry = outbox.get(req.params.pingId);
  if (!entry) return res.status(404).end();

  if (entry.state !== State.ACKNOWLEDGED) {
    entry.state = State.ACKNOWLEDGED;
  }

  res.status(204).end();
});

// ---------------------------------------------------------------------------
// Receiver — helpers
// ---------------------------------------------------------------------------

// Registers a received ping in the inbox, or silently drops if origin is blocked.
// Silence is the canonical response to an unwanted ping (spec §Blocking and Consent):
// the sender cannot distinguish blocked from offline.
function receivePing(ping_id, origin, payload_type, content_hash, res) {
  if (blocklist.has(origin)) {
    // Return 204 so the sender cannot detect the block via an error code.
    return res.status(204).end();
  }

  inbox.set(ping_id, {
    state: State.PING_RECEIVED,
    origin,
    payload_type,
    content_hash,
  });

  res.status(204).end();
}

// ---------------------------------------------------------------------------
// Receiver — ping endpoints (access tiers)
// ---------------------------------------------------------------------------

// Public tier — open to any sender.
app.post("/ping/public", (req, res) => {
  const { ping_id, origin, payload_type, content_hash } = req.body;
  receivePing(ping_id, origin, payload_type, content_hash, res);
});

// User tier — requires a valid bearer token.
// Replace VALID_TOKENS with real credential storage.
const VALID_TOKENS = new Set(["change-me-secret-token"]);

app.post("/ping/user", (req, res) => {
  const auth = req.headers["authorization"] ?? "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  if (!VALID_TOKENS.has(token)) return res.status(401).end();

  const { ping_id, origin, payload_type, content_hash } = req.body;
  receivePing(ping_id, origin, payload_type, content_hash, res);
});

// ---------------------------------------------------------------------------
// Receiver — pull and inbox management
// ---------------------------------------------------------------------------

// POST /pull/:pingId — Blog 2 initiates a content pull from Blog 1's outbox.
app.post("/pull/:pingId", async (req, res) => {
  const entry = inbox.get(req.params.pingId);
  if (!entry) return res.status(404).end();
  if (entry.state === State.ACKNOWLEDGED) return res.status(410).end();

  // Fetch content from sender.
  let resp;
  try {
    resp = await fetch(`${entry.origin}/outbox/${req.params.pingId}`, {
      signal: AbortSignal.timeout(15_000),
    });
  } catch (err) {
    return res.status(502).json({ error: "could not reach sender" });
  }

  if (!resp.ok) {
    return res.status(502).json({ error: "pull failed", upstream: resp.status });
  }

  const content = await resp.json();
  entry.state = advance(entry.state); // PING_RECEIVED → CONTENT_PULLED
  entry.content = content.content;

  // Acknowledge to sender. If the ACK fails, state stays at CONTENT_PULLED
  // so the receiver can retry the pull (which re-sends the ACK) without loss.
  try {
    const ack = await fetch(`${entry.origin}/outbox/${req.params.pingId}/ack`, {
      method: "POST",
      signal: AbortSignal.timeout(10_000),
    });
    if (ack.ok) {
      entry.state = advance(entry.state); // CONTENT_PULLED → ACKNOWLEDGED
    }
  } catch (_) {
    // ACK failed; pull succeeded. Caller may re-POST /pull to retry the ACK.
  }

  res.json(content);
});

// GET /inbox — list pings that have not yet been acknowledged.
app.get("/inbox", (_req, res) => {
  const pending = [];
  for (const [pingId, entry] of inbox) {
    if (entry.state !== State.ACKNOWLEDGED) {
      pending.push({
        ping_id: pingId,
        state: entry.state,
        origin: entry.origin,
        payload_type: entry.payload_type,
        content_hash: entry.content_hash,
      });
    }
  }
  res.json(pending);
});

// ---------------------------------------------------------------------------
// Receiver — blocking
// ---------------------------------------------------------------------------

// POST /block — add an origin to the blocklist.
app.post("/block", (req, res) => {
  const { origin } = req.body;
  if (!origin) return res.status(400).json({ error: "origin is required" });
  blocklist.add(origin);
  res.status(204).end();
});

// DELETE /block — remove an origin from the blocklist.
app.delete("/block", (req, res) => {
  const { origin } = req.body;
  if (!origin) return res.status(400).json({ error: "origin is required" });
  blocklist.delete(origin);
  res.status(204).end();
});

// GET /block — inspect the current blocklist (admin/debug use).
app.get("/block", (_req, res) => {
  res.json({ blocked: [...blocklist] });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const port = process.argv[2] ?? 5000;
app.listen(port, () => console.log(`PING listening on :${port}`));
