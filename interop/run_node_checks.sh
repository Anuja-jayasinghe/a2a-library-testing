#!/usr/bin/env bash
# Third-language pair, both directions, against @a2a-js/sdk 1.2.1 (HTTP+JSON, A2A v1.0):
#   N-A: ballerina/a2a HttpClient      -> node-agent/agent.mjs  (Claude-backed if ANTHROPIC_API_KEY is set, else a stub)
#   N-C: @a2a-js/sdk client            -> ballerina/a2a Listener (bal-listener), incl. a 75s silent stream
# Also: J-D, the real a2a-java client streaming against the listener (java-client-stream/StreamDriver.java, needs
# /tmp/interop_java_client_cp.txt from run_pair_b_d.sh).
# Setup once: (cd node-agent && npm install). Requires ballerina/a2a published locally.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
cleanup() { pkill -f "node-agent/agent.mjs\|node agent.mjs" 2>/dev/null; pkill -f "interop/bal-listener" 2>/dev/null; pkill -f push_receiver.py 2>/dev/null; pkill -f bal_listener 2>/dev/null; true; }
trap cleanup EXIT; cleanup; sleep 1
up() { for _ in $(seq 1 90); do curl -sf "$1" >/dev/null && return; sleep 1; done; echo "NOT UP: $1"; }

echo "########## N-A: ballerina/a2a client -> Node agent ##########"
(cd "$HERE/node-agent" && TRAILING_SLASH=0 node agent.mjs 9800 >/tmp/node_agent.log 2>&1 &)
up http://localhost:9800/.well-known/agent-card.json
(cd "$HERE/bal-client-node" && rm -rf target && bal run 2>&1 | grep -E "^(PASS|FAIL|==|OVERALL)")
cleanup; sleep 1

echo "########## N-C: @a2a-js/sdk client -> ballerina/a2a Listener ##########"
(cd "$HERE/bal-listener" && rm -rf target && bal run -- -CKEEPALIVE_SECONDS=0.5 >/tmp/bl_node.log 2>&1 &)
up http://localhost:9611/.well-known/agent-card.json
python3 "$HERE/push_receiver.py" 19872 /tmp/node_client_push.json >/tmp/pr.log 2>&1 &
sleep 1
(cd "$HERE/node-agent" && node client.mjs 2>&1)
echo "########## N-C2: J-D streaming (real a2a-java client) ##########"
CP="$(cat /tmp/interop_java_client_cp.txt):$HOME/gitProject/a2a-java/examples/helloworld/client/target/classes"
(cd "$HERE/java-client-stream" && java -Dquarkus.agentcard.protocol=HTTP+JSON -cp "$CP" StreamDriver.java http://localhost:9611 2>&1 | grep -v SLF4J) \
  || true
# (StreamDriver targets :9999; the default listener port is 9611 -- pass it explicitly)
