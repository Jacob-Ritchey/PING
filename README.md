# PING

One protocol. Any language that can do networking.

PING is a lightweight, asynchronous, consent-based notification primitive — a state machine describing how two independent peers exchange a notification and decide whether to follow through. This repository demonstrates that protocol in Python, JavaScript, Go, and Rust. The same state machine. The same API surface. Four different runtimes.

The purpose is to prove the protocol's language-agnosticism, not to provide a library. Read the implementations; reason about the design. Careful consideration should be taken before integrating any of this code into a system — especially security or privacy oriented ones.

For a full introduction to the protocol and its design, the [landing page](https://p1n6.org/) covers the motivation, behaviour, and intended use.

## The Idea

Think of it like post, not a phone call. The sender prepares a notification and posts it. The receiver collects when they choose. Neither needs to be online at the same moment. No one sits in between.

Async state, not federation. The sender announces. The receiver pulls.

## State Machine


| PING EXISTS | → | PING RECEIVED | → | CONTENT PULLED | → | ACKNOWLEDGED |
|-------------|---|---------------|---|----------------|---|--------------|
| Sender      |   | Receiver      |   | Receiver       |   | Sender       |
| Sends       |   | Notified      |   | Fetches        |   | Confirmed    |


## API Surface

| Method | Path                  | Role     | Purpose                                          |
|--------|-----------------------|----------|--------------------------------------------------|
| POST   | /send                 | Sender   | Compose content, ping a target                   |
| GET    | /outbox/:id           | Sender   | Serve content for pull                           |
| POST   | /outbox/:id/ack       | Sender   | Accept delivery confirmation                     |
| POST   | /ping                 | Receiver | Accept a ping notification                       |
| GET    | /inbox                | Receiver | List pending pings before deciding to pull       |
| POST   | /pull/:id             | Receiver | Fetch content from sender                        |
| POST   | /ignore/:id           | Receiver | Silently discard a ping — no notification sent   |

## The Ping Object

```json
{
  "ping_id": "uuid",
  "origin": "https://sender.example.com",
  "payload_type": "ask",
  "content_hash": "optional"
}
```

No content. Just a knock on the door.

## Run

**Python**
```
cd python && pip install -r requirements.txt
python3 ping.py 5000  # Sender
python3 ping.py 5001  # Receiver
```

**JavaScript**
```
cd javascript && npm install
node ping.js 5000
node ping.js 5001
```

**Go**
```
cd go && go run . 5000
cd go && go run . 5001
```

**Rust**
```
cd rust && cargo run -- 5000
cd rust && cargo run -- 5001
```

## Demo Scripts

Python, Go, and Rust each include a `demo.sh`. It runs the full state machine — happy path, then a retry demo with the receiver starting late. Pass `--quick` to skip the retry.

```bash
cd python  && ./Python-Demo.sh
cd go      && ./GO-demo.sh
cd rust    && ./Rust-Demo.sh
```

## Test

```bash
# Sender pings a receiver
curl -X POST http://localhost:5000/send \
  -H 'Content-Type: application/json' \
  -d '{
    "origin": "http://localhost:5000",
    "target": "http://localhost:5001",
    "payload_type": "ask",
    "content": "What inspires your writing?"
  }'

# Returns: {"ping_id": "<uuid>", "state": "PING_EXISTS"}

# Receiver checks inbox before deciding
curl http://localhost:5001/inbox

# Receiver pulls
curl -X POST http://localhost:5001/pull/<uuid>

# Returns the content. Sender is now ACKNOWLEDGED.

# Or receiver ignores — sender hears nothing either way
curl -X POST http://localhost:5001/ignore/<uuid>
```
