// PING — Minimal reference implementation in Rust.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc};
use tokio::{sync::RwLock, time::{Duration, Instant}};
use uuid::Uuid;

// --- State Machine ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum PingState {
    PingExists,
    PingReceived,
    ContentPulled,
    Acknowledged,
}

impl PingState {
    fn advance(&self) -> Result<PingState, &'static str> {
        match self {
            PingState::PingExists    => Ok(PingState::PingReceived),
            PingState::PingReceived  => Ok(PingState::ContentPulled),
            PingState::ContentPulled => Ok(PingState::Acknowledged),
            PingState::Acknowledged  => Err("terminal state"),
        }
    }
}

// --- Types ---

// Exponential backoff intervals for PING_EXISTS retries.
// Delays (in seconds): 30, 60, 120, 240, 480, then capped at 900 (15 min).
// Set PING_DEMO_MODE=1 to use accelerated intervals (3, 5, 8, …, capped at 10s)
// so the retry loop is observable without long waits.
const BACKOFF_SECONDS:      &[u64] = &[30, 60, 120, 240, 480];
const BACKOFF_CAP_SECONDS:   u64   = 900;
const DEMO_BACKOFF_SECONDS: &[u64] = &[3, 5, 8];
const DEMO_BACKOFF_CAP:      u64   = 10;

fn backoff_delay(retry_count: u32) -> Duration {
    let demo = std::env::var("PING_DEMO_MODE").as_deref() == Ok("1");
    let (table, cap) = if demo {
        (DEMO_BACKOFF_SECONDS, DEMO_BACKOFF_CAP)
    } else {
        (BACKOFF_SECONDS, BACKOFF_CAP_SECONDS)
    };
    Duration::from_secs(table.get(retry_count as usize).copied().unwrap_or(cap))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct OutboxEntry {
    state: PingState,
    origin: String,
    target: String,           // remembered so the retry loop knows where to ping
    payload_type: String,
    content: String,
    content_hash: Option<String>,
    retry_count: u32,
    #[serde(skip)]            // Instant is not serialisable; fine for in-memory use
    next_retry_at: Option<Instant>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct InboxEntry {
    state: PingState,
    origin: String,
    payload_type: String,
    content_hash: Option<String>,
    content: Option<String>,
}

#[derive(Deserialize)]
struct SendRequest {
    origin: String,
    target: String,
    #[serde(default = "default_payload_type")]
    payload_type: String,
    #[serde(default)]
    content: String,
    content_hash: Option<String>,
}

fn default_payload_type() -> String { "ask".into() }

#[derive(Serialize, Deserialize)]
struct PingMessage {
    ping_id: String,
    origin: String,
    payload_type: String,
    content_hash: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct ContentResponse {
    ping_id: String,
    payload_type: String,
    content: String,
}

// --- Storage (in-memory) ---

type Store<T> = Arc<RwLock<HashMap<String, T>>>;

#[derive(Clone)]
struct AppState {
    outbox: Store<OutboxEntry>,
    inbox:  Store<InboxEntry>,
}

// --- Retry Loop ---

// Runs in the background. Every 10 seconds it scans the outbox for entries
// that are still in PING_EXISTS and whose next_retry_at has elapsed, then
// re-sends the ping. State only advances to PING_RECEIVED once the remote
// endpoint responds with success; otherwise the entry stays in PING_EXISTS
// and retry_count / next_retry_at are updated for the next attempt.
async fn retry_loop(state: AppState) {
    let client = reqwest::Client::new();
    let poll_interval = Duration::from_secs(10);

    loop {
        tokio::time::sleep(poll_interval).await;

        // Collect IDs that are due for a retry without holding the lock.
        let due: Vec<(String, OutboxEntry)> = {
            let outbox = state.outbox.read().await;
            outbox.iter()
                .filter(|(_, e)| {
                    e.state == PingState::PingExists
                        && e.next_retry_at.map_or(true, |t| Instant::now() >= t)
                })
                .map(|(id, e)| (id.clone(), e.clone()))
                .collect()
        };

        for (ping_id, entry) in due {
            let msg = PingMessage {
                ping_id: ping_id.clone(),
                origin: entry.origin.clone(),
                payload_type: entry.payload_type.clone(),
                content_hash: entry.content_hash.clone(),
            };

            let result = client
                .post(format!("{}/ping", entry.target))
                .json(&msg)
                .send()
                .await;

            let mut outbox = state.outbox.write().await;
            let Some(e) = outbox.get_mut(&ping_id) else { continue };

            // Only act if still PING_EXISTS — another path may have advanced it.
            if e.state != PingState::PingExists { continue; }

            match result {
                Ok(resp) if resp.status().is_success() => {
                    // Remote confirmed receipt: advance state through the machine.
                    match e.state.advance() {
                        Ok(next) => {
                            eprintln!("[retry] {ping_id}: PING_EXISTS → {next:?} (attempt {})", e.retry_count);
                            e.state = next;
                            e.next_retry_at = None;
                        }
                        Err(reason) => {
                            eprintln!("[retry] {ping_id}: advance failed: {reason}");
                        }
                    }
                }
                _ => {
                    // Remote unreachable or returned an error — schedule next retry.
                    e.retry_count += 1;
                    e.next_retry_at = Some(Instant::now() + backoff_delay(e.retry_count));
                    eprintln!(
                        "[retry] {ping_id}: attempt {} failed, next retry in {:?}",
                        e.retry_count,
                        backoff_delay(e.retry_count)
                    );
                }
            }
        }
    }
}

// --- Sender Endpoints ---

async fn send_ping(
    State(state): State<AppState>,
    Json(body): Json<SendRequest>,
) -> (StatusCode, Json<serde_json::Value>) {
    let ping_id = Uuid::new_v4().to_string();

    // Persist with PING_EXISTS immediately. The retry loop will drive delivery.
    state.outbox.write().await.insert(ping_id.clone(), OutboxEntry {
        state: PingState::PingExists,
        origin: body.origin.clone(),
        target: body.target.clone(),
        payload_type: body.payload_type.clone(),
        content: body.content,
        content_hash: body.content_hash.clone(),
        retry_count: 0,
        next_retry_at: None, // due immediately on the first loop tick
    });

    // Best-effort first attempt; if it fails the retry loop takes over.
    let client = reqwest::Client::new();
    let result = client
        .post(format!("{}/ping", body.target))
        .json(&PingMessage {
            ping_id: ping_id.clone(),
            origin: body.origin,
            payload_type: body.payload_type,
            content_hash: body.content_hash,
        })
        .send()
        .await;

    // If the first attempt succeeded, advance state immediately rather than
    // waiting for the retry loop to notice it.
    if let Ok(resp) = result {
        if resp.status().is_success() {
            let mut outbox = state.outbox.write().await;
            if let Some(entry) = outbox.get_mut(&ping_id) {
                if let Ok(next) = entry.state.advance() {
                    entry.state = next;
                }
            }
        }
    }

    (StatusCode::CREATED, Json(serde_json::json!({
        "ping_id": ping_id,
        "state": "PING_EXISTS"
    })))
}

async fn serve_content(
    State(state): State<AppState>,
    Path(ping_id): Path<String>,
) -> Result<Json<ContentResponse>, StatusCode> {
    let mut outbox = state.outbox.write().await;
    let entry = outbox.get_mut(&ping_id).ok_or(StatusCode::NOT_FOUND)?;

    // Only reject once fully acknowledged. Allowing re-fetch while ContentPulled
    // means a lost ack doesn't strand Blog 2 with no recovery path.
    if entry.state == PingState::Acknowledged {
        return Err(StatusCode::GONE);
    }

    // Advance through advance() rather than assigning directly.
    // If already ContentPulled (re-fetch before ack), leave state as-is.
    if entry.state == PingState::PingReceived || entry.state == PingState::PingExists {
        entry.state = entry.state.advance().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }

    Ok(Json(ContentResponse {
        ping_id,
        payload_type: entry.payload_type.clone(),
        content: entry.content.clone(),
    }))
}

async fn receive_ack(
    State(state): State<AppState>,
    Path(ping_id): Path<String>,
) -> StatusCode {
    let mut outbox = state.outbox.write().await;
    match outbox.get_mut(&ping_id) {
        Some(entry) => {
            match entry.state.advance() {
                Ok(next) => { entry.state = next; StatusCode::NO_CONTENT }
                Err(_)   => StatusCode::CONFLICT, // already terminal
            }
        }
        None => StatusCode::NOT_FOUND,
    }
}

// --- Receiver Endpoints ---

async fn receive_ping(
    State(state): State<AppState>,
    Json(msg): Json<PingMessage>,
) -> StatusCode {
    state.inbox.write().await.insert(msg.ping_id, InboxEntry {
        state: PingState::PingReceived,
        origin: msg.origin,
        payload_type: msg.payload_type,
        content_hash: msg.content_hash,
        content: None,
    });

    StatusCode::NO_CONTENT
}

async fn pull_content(
    State(state): State<AppState>,
    Path(ping_id): Path<String>,
) -> Result<Json<ContentResponse>, StatusCode> {
    let origin = {
        let inbox = state.inbox.read().await;
        let entry = inbox.get(&ping_id).ok_or(StatusCode::NOT_FOUND)?;
        if entry.state == PingState::Acknowledged {
            return Err(StatusCode::GONE);
        }
        entry.origin.clone()
    };

    let client = reqwest::Client::new();

    // Fetch content from sender's outbox.
    let resp = client
        .get(format!("{}/outbox/{}", origin, ping_id))
        .send()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;

    if !resp.status().is_success() {
        return Err(StatusCode::BAD_GATEWAY);
    }
    let content: ContentResponse = resp.json().await.map_err(|_| StatusCode::BAD_GATEWAY)?;

    // Advance inbox state to CONTENT_PULLED via the state machine.
    {
        let mut inbox = state.inbox.write().await;
        if let Some(entry) = inbox.get_mut(&ping_id) {
            if entry.state == PingState::PingReceived {
                entry.state = entry.state.advance()
                    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
            }
            entry.content = Some(content.content.clone());
        }
    }

    // Send acknowledgement to Blog 1. This is no longer fire-and-forget:
    // if it fails, Blog 2 returns an error and can be retried. Blog 1's
    // content remains available at the outbox endpoint until ack succeeds.
    let ack = client
        .post(format!("{}/outbox/{}/ack", origin, ping_id))
        .send()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;

    if !ack.status().is_success() {
        // Blog 1 is reachable but rejected the ack — surface this rather
        // than silently claiming delivery is complete.
        return Err(StatusCode::BAD_GATEWAY);
    }

    // Advance inbox to ACKNOWLEDGED now that Blog 1 has confirmed.
    {
        let mut inbox = state.inbox.write().await;
        if let Some(entry) = inbox.get_mut(&ping_id) {
            if entry.state == PingState::ContentPulled {
                if let Ok(next) = entry.state.advance() {
                    entry.state = next;
                }
            }
        }
    }

    Ok(Json(content))
}

// --- Router ---

#[tokio::main]
async fn main() {
    let state = AppState {
        outbox: Arc::new(RwLock::new(HashMap::new())),
        inbox:  Arc::new(RwLock::new(HashMap::new())),
    };

    // Spawn the background retry loop before starting the HTTP server.
    tokio::spawn(retry_loop(state.clone()));

    let app = Router::new()
        .route("/send",                    post(send_ping))
        .route("/outbox/{ping_id}",        get(serve_content))
        .route("/outbox/{ping_id}/ack",    post(receive_ack))
        .route("/ping",                    post(receive_ping))
        .route("/pull/{ping_id}",          post(pull_content))
        .with_state(state);

    let port = std::env::args().nth(1).unwrap_or_else(|| "5000".into());
    let addr = format!("0.0.0.0:{}", port);
    println!("PING listening on :{}", port);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
