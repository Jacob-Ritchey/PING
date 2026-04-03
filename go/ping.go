// PING — Minimal reference implementation in Go.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// --- State Machine ---

type State string

const (
	PingExists    State = "PING_EXISTS"
	PingReceived  State = "PING_RECEIVED"
	ContentPulled State = "CONTENT_PULLED"
	Acknowledged  State = "ACKNOWLEDGED"
)

var transitions = map[State]State{
	PingExists:   PingReceived,
	PingReceived: ContentPulled,
	ContentPulled: Acknowledged,
}

// advance enforces the state machine. All state transitions must go through
// here — no direct assignment allowed.
func advance(s State) (State, error) {
	next, ok := transitions[s]
	if !ok {
		return s, fmt.Errorf("state %s is terminal, cannot advance", s)
	}
	return next, nil
}

// --- Types ---

type OutboxEntry struct {
	mu          sync.Mutex
	State       State  `json:"state"`
	Origin      string `json:"origin"`
	Target      string `json:"target"`
	PayloadType string `json:"payload_type"`
	Content     string `json:"content"`
	ContentHash string `json:"content_hash,omitempty"`
}

type InboxEntry struct {
	mu          sync.Mutex
	State       State  `json:"state"`
	Origin      string `json:"origin"`
	PayloadType string `json:"payload_type"`
	ContentHash string `json:"content_hash,omitempty"`
	Content     string `json:"content,omitempty"`
}

type PingMessage struct {
	PingID      string `json:"ping_id"`
	Origin      string `json:"origin"`
	PayloadType string `json:"payload_type"`
	ContentHash string `json:"content_hash,omitempty"`
}

// --- Storage (in-memory) ---

var (
	outbox = sync.Map{}
	inbox  = sync.Map{}
)

// --- Helpers ---

func jsonResp(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func lastSegment(path, prefix string) string {
	return strings.TrimPrefix(path, prefix)
}

// hashContent returns the SHA-256 hex digest of the given string.
func hashContent(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

// --- Retry / Backoff ---

// pingWithRetry fires a ping at the target endpoint and retries with
// exponential backoff if the target is unreachable. It gives up after
// maxAttempts. Runs in its own goroutine so the caller is never blocked.
func pingWithRetry(target string, msg PingMessage, pingID string, maxAttempts int) {
	backoff := 5 * time.Second
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		// Abort if the ping has already been acknowledged by some other path.
		if val, ok := outbox.Load(pingID); ok {
			if val.(*OutboxEntry).State == Acknowledged {
				return
			}
		}

		body, _ := json.Marshal(msg)
		resp, err := http.Post(target+"/ping", "application/json", bytes.NewReader(body))
		if err == nil && resp.StatusCode == 204 {
			fmt.Printf("[ping] %s delivered to %s on attempt %d\n", pingID, target, attempt)
			return
		}

		if attempt < maxAttempts {
			fmt.Printf("[ping] %s attempt %d failed, retrying in %s\n", pingID, attempt, backoff)
			time.Sleep(backoff)
			if backoff < 5*time.Minute {
				backoff *= 2
			}
		}
	}
	fmt.Printf("[ping] %s gave up after %d attempts\n", pingID, maxAttempts)
}

// --- Sender Endpoints ---

// POST /send — create a new outbox entry and begin pinging the remote.
func handleSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(405)
		return
	}
	var body struct {
		Origin      string `json:"origin"`
		Target      string `json:"target"`
		PayloadType string `json:"payload_type"`
		Content     string `json:"content"`
		ContentHash string `json:"content_hash"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonResp(w, 400, map[string]string{"error": "invalid JSON"})
		return
	}
	if body.PayloadType == "" {
		body.PayloadType = "ask"
	}

	// Derive hash from content if the caller did not supply one.
	if body.ContentHash == "" && body.Content != "" {
		body.ContentHash = hashContent(body.Content)
	}

	pingID := uuid.NewString()
	outbox.Store(pingID, &OutboxEntry{
		State:       PingExists,
		Origin:      body.Origin,
		Target:      body.Target,
		PayloadType: body.PayloadType,
		Content:     body.Content,
		ContentHash: body.ContentHash,
	})

	msg := PingMessage{
		PingID:      pingID,
		Origin:      body.Origin,
		PayloadType: body.PayloadType,
		ContentHash: body.ContentHash,
	}

	// Retry in the background; never block the sender's response.
	go pingWithRetry(body.Target, msg, pingID, 10)

	jsonResp(w, 201, map[string]string{"ping_id": pingID, "state": string(PingExists)})
}

// GET /outbox/{id} — receiver pulls content from sender's outbox.
// Returns 410 only once the ping is ACKNOWLEDGED, preserving the
// content through the CONTENT_PULLED stage so the receiver can retry
// if their first pull is interrupted.
func handleOutbox(w http.ResponseWriter, r *http.Request) {
	pingID := lastSegment(r.URL.Path, "/outbox/")

	// ACK sub-route: POST /outbox/{id}/ack
	if strings.HasSuffix(pingID, "/ack") {
		if r.Method != http.MethodPost {
			w.WriteHeader(405)
			return
		}
		pingID = strings.TrimSuffix(pingID, "/ack")
		val, ok := outbox.Load(pingID)
		if !ok {
			w.WriteHeader(404)
			return
		}
		entry := val.(*OutboxEntry)
		entry.mu.Lock()
		defer entry.mu.Unlock()

		next, err := advance(entry.State)
		if err != nil {
			// Already acknowledged — idempotent, accept gracefully.
			w.WriteHeader(204)
			return
		}
		if next != Acknowledged {
			// Guard: ACK is only valid after content has been pulled.
			jsonResp(w, 409, map[string]string{"error": "content has not been pulled yet"})
			return
		}
		entry.State = Acknowledged
		w.WriteHeader(204)
		return
	}

	// Content pull: GET /outbox/{id}
	if r.Method != http.MethodGet {
		w.WriteHeader(405)
		return
	}
	val, ok := outbox.Load(pingID)
	if !ok {
		w.WriteHeader(404)
		return
	}
	entry := val.(*OutboxEntry)
	entry.mu.Lock()
	defer entry.mu.Unlock()

	// Only close the door once the receiver has fully acknowledged.
	// CONTENT_PULLED is still serveable so the receiver can re-fetch
	// if their first attempt was interrupted before they could store it.
	if entry.State == Acknowledged {
		w.WriteHeader(410)
		return
	}

	// Advance PING_EXISTS → CONTENT_PULLED if this is the first pull.
	// A re-fetch from CONTENT_PULLED state is allowed and leaves state
	// unchanged.
	if entry.State == PingExists {
		next, err := advance(entry.State) // PING_EXISTS → PING_RECEIVED
		if err != nil {
			jsonResp(w, 500, map[string]string{"error": err.Error()})
			return
		}
		next, err = advance(next) // PING_RECEIVED → CONTENT_PULLED
		if err != nil {
			jsonResp(w, 500, map[string]string{"error": err.Error()})
			return
		}
		entry.State = next
	} else if entry.State == PingReceived {
		next, err := advance(entry.State) // PING_RECEIVED → CONTENT_PULLED
		if err != nil {
			jsonResp(w, 500, map[string]string{"error": err.Error()})
			return
		}
		entry.State = next
	}
	// entry.State == ContentPulled: re-fetch allowed, no transition needed.

	jsonResp(w, 200, map[string]string{
		"ping_id":      pingID,
		"payload_type": entry.PayloadType,
		"content":      entry.Content,
		"content_hash": entry.ContentHash,
	})
}

// --- Receiver Endpoints ---

// POST /ping — receive a lightweight notification from a sender.
// Stores the metadata without content; does not pull anything.
func handlePing(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(405)
		return
	}
	var msg PingMessage
	if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
		w.WriteHeader(400)
		return
	}
	if msg.PingID == "" || msg.Origin == "" {
		w.WriteHeader(400)
		return
	}

	inbox.Store(msg.PingID, &InboxEntry{
		State:       PingReceived,
		Origin:      msg.Origin,
		PayloadType: msg.PayloadType,
		ContentHash: msg.ContentHash,
	})

	w.WriteHeader(204)
}

// GET /inbox — list pending (PING_RECEIVED) notifications so Blog 2 can
// inspect what is waiting before deciding whether to pull.
func handleInbox(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(405)
		return
	}
	type summary struct {
		PingID      string `json:"ping_id"`
		State       State  `json:"state"`
		Origin      string `json:"origin"`
		PayloadType string `json:"payload_type"`
		ContentHash string `json:"content_hash,omitempty"`
	}
	var pending []summary
	inbox.Range(func(k, v any) bool {
		e := v.(*InboxEntry)
		e.mu.Lock()
		defer e.mu.Unlock()
		if e.State == PingReceived {
			pending = append(pending, summary{
				PingID:      k.(string),
				State:       e.State,
				Origin:      e.Origin,
				PayloadType: e.PayloadType,
				ContentHash: e.ContentHash,
			})
		}
		return true
	})
	jsonResp(w, 200, pending)
}

// POST /pull/{id} — explicit consent to fetch content for a given ping.
// Blog 2 calls this only after inspecting the inbox and deciding to pull.
// Verifies the content hash before accepting the payload and ACKs the sender.
func handlePull(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(405)
		return
	}
	pingID := lastSegment(r.URL.Path, "/pull/")

	val, ok := inbox.Load(pingID)
	if !ok {
		w.WriteHeader(404)
		return
	}
	entry := val.(*InboxEntry)
	entry.mu.Lock()
	defer entry.mu.Unlock()

	if entry.State != PingReceived {
		jsonResp(w, 409, map[string]string{
			"error": fmt.Sprintf("ping is in state %s, expected PING_RECEIVED", entry.State),
		})
		return
	}

	// Fetch content from the sender's outbox.
	resp, err := http.Get(entry.Origin + "/outbox/" + pingID)
	if err != nil || resp.StatusCode != 200 {
		jsonResp(w, 502, map[string]string{"error": "pull from sender failed"})
		return
	}
	var payload map[string]string
	json.NewDecoder(resp.Body).Decode(&payload)
	resp.Body.Close()

	// Verify hash if one was carried in the original ping.
	if entry.ContentHash != "" {
		got := hashContent(payload["content"])
		if got != entry.ContentHash {
			jsonResp(w, 422, map[string]string{
				"error":    "content hash mismatch",
				"expected": entry.ContentHash,
				"got":      got,
			})
			return
		}
	}

	// Advance state: PING_RECEIVED → CONTENT_PULLED
	next, err := advance(entry.State)
	if err != nil {
		jsonResp(w, 500, map[string]string{"error": err.Error()})
		return
	}
	entry.State = next
	entry.Content = payload["content"]

	// Send ACK to the sender so they can advance to ACKNOWLEDGED.
	http.Post(entry.Origin+"/outbox/"+pingID+"/ack", "application/json", nil)

	// Advance state: CONTENT_PULLED → ACKNOWLEDGED
	next, err = advance(entry.State)
	if err != nil {
		jsonResp(w, 500, map[string]string{"error": err.Error()})
		return
	}
	entry.State = next

	jsonResp(w, 200, payload)
}

// POST /ignore/{id} — explicit signal that Blog 2 does not want this ping.
// Removes it from the inbox without pulling. No notification is sent to Blog 1.
func handleIgnore(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(405)
		return
	}
	pingID := lastSegment(r.URL.Path, "/ignore/")
	_, ok := inbox.LoadAndDelete(pingID)
	if !ok {
		w.WriteHeader(404)
		return
	}
	w.WriteHeader(204)
}

// --- Router ---

func main() {
	http.HandleFunc("/send", handleSend)
	http.HandleFunc("/outbox/", handleOutbox)
	http.HandleFunc("/ping", handlePing)
	http.HandleFunc("/inbox", handleInbox)
	http.HandleFunc("/pull/", handlePull)
	http.HandleFunc("/ignore/", handleIgnore)

	port := "5000"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	fmt.Printf("PING listening on :%s\n", port)
	http.ListenAndServe(":"+port, nil)
}
