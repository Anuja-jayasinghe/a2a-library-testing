#!/usr/bin/env bash
# Fourth-language pair, both directions, against a2a-go v2.6.0 (HTTP+JSON, A2A v1.0):
#   G-A: ballerina/a2a HttpClient -> go-agent/agent  (Claude-backed if ANTHROPIC_API_KEY is set, else a stub)
#   G-C: a2a-go client            -> ballerina/a2a Listener
# Known, recorded failures (RESULTS.md findings 24, 25): G-A "statusTimestampAfter in the future" (Go sends "tasks":null);
# G-C typed errors (Go client only decodes application/json error bodies).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/../.env" ] && . "$HERE/../.env"
case "${ANTHROPIC_API_KEY:-}" in sk-ant-PASTE*) unset ANTHROPIC_API_KEY;; esac
unset BAL_CONFIG_DATA  # these rigs declare no anthropicApiKey; bal rejects an unused configuration value
cleanup() { pkill -f "/tmp/goagent" 2>/dev/null; pkill -f "interop/bal-listener" 2>/dev/null; pkill -f push_receiver.py 2>/dev/null; pkill -f bal_listener 2>/dev/null; true; }
trap cleanup EXIT; cleanup; sleep 1
up() { for _ in $(seq 1 90); do curl -sf "$1" >/dev/null && return; sleep 1; done; echo "NOT UP: $1"; }
(cd "$HERE/go-agent" && go build -o /tmp/goagent ./agent && go build -o /tmp/goclient ./client) || exit 1

echo "########## G-A: ballerina/a2a client -> Go agent ##########"
(TRAILING_SLASH=0 /tmp/goagent -port 9802 >/tmp/goagent.log 2>&1 &)
up http://localhost:9802/.well-known/agent-card.json; head -1 /tmp/goagent.log
(cd "$HERE/bal-client-node" && rm -rf target && bal run -- http://localhost:9802 2>&1 | grep -E "^(PASS|FAIL|==|OVERALL|  artifact)")
cleanup; sleep 1

echo "########## G-C: a2a-go client -> ballerina/a2a Listener ##########"
(cd "$HERE/bal-listener" && rm -rf target && bal run -- -CKEEPALIVE_SECONDS=0.5 >/tmp/bl_go.log 2>&1 &)
up http://localhost:9611/.well-known/agent-card.json
python3 "$HERE/push_receiver.py" 19873 /tmp/go_client_push.json >/dev/null 2>&1 &
sleep 1
/tmp/goclient
