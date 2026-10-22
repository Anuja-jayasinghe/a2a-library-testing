#!/usr/bin/env bash
# Fifth-language pair, both directions, against a2a-rs (a2a-server-lf 0.4.4 / a2a-client-lf 0.2.5, HTTP+JSON, A2A v1.0):
#   R-A: ballerina/a2a RestClient -> rust-agent agent (Claude-backed if ANTHROPIC_API_KEY is set, else a stub)
#   R-C: a2a-rs client            -> ballerina/a2a Listener
# The Rust side runs in Docker (rust:1-bookworm), so nothing is installed on the host. Build once with:
#   cd rust-agent && docker run --rm -v "$PWD":/w -v a2a-cargo-reg:/usr/local/cargo/registry -v a2a-rs-target:/w/target \
#     -w /w rust:1-bookworm cargo build --release
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/load_env.sh"
OUT=${OUT:-/tmp/a2a-rust}; mkdir -p "$OUT"
RUN=(docker run --rm -v a2a-rs-target:/t rust:1-bookworm)
cleanup() { docker rm -f a2a-rust-agent >/dev/null 2>&1; pkill -f "interop/bal-listener" 2>/dev/null; pkill -f "push_receiver.py 19875" 2>/dev/null; pkill -f bal_listener 2>/dev/null; true; }
trap cleanup EXIT; cleanup; sleep 1
up() { for _ in $(seq 1 90); do curl -sf "$1" >/dev/null && return; sleep 1; done; echo "NOT UP: $1"; }

echo "########## R-A: ballerina/a2a client -> Rust agent ##########"
docker run -d --name a2a-rust-agent -p 9804:9804 -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" -e CLAUDE_MODEL="${CLAUDE_MODEL:-claude-haiku-4-5}" \
  -e TRAILING_SLASH="${TRAILING_SLASH:-0}" -v a2a-rs-target:/t rust:1-bookworm /t/release/agent 9804 >/dev/null
up http://localhost:9804/.well-known/agent-card.json; docker logs a2a-rust-agent 2>&1 | head -1
(cd "$HERE/bal-client-node" && rm -rf target && bal run -- http://localhost:9804 2>&1 | grep -E "^(PASS|FAIL|==|OVERALL|  artifact)")
docker logs a2a-rust-agent > "$OUT/agent.log" 2>&1
cleanup; sleep 1

echo "########## R-C: a2a-rs client -> ballerina/a2a Listener ##########"
(cd "$HERE/bal-listener" && rm -rf target && bal run -- -CKEEPALIVE_SECONDS=0.5 >"$OUT/listener.log" 2>&1 &)
up http://localhost:9611/.well-known/agent-card.json
rm -f "$OUT/push.json"
python3 "$HERE/push_receiver.py" 19875 "$OUT/push.json" >/dev/null 2>&1 &
sleep 1
"${RUN[@]}" /t/release/client http://host.docker.internal:9611 http://localhost:19875/hook | tee "$OUT/client.out"
for _ in $(seq 1 20); do [ -s "$OUT/push.json" ] && break; sleep 0.5; done
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ("task" in d or "statusUpdate" in d) else 1)' "$OUT/push.json" 2>/dev/null; then
  echo "PASS: webhook delivered as a StreamResponse envelope ($(head -c 60 "$OUT/push.json"))"
else
  echo "FAIL: webhook not delivered as a StreamResponse envelope"
fi
