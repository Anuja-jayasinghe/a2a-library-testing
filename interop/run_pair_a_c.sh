#!/usr/bin/env bash
# Runs interop pairs A and C from INTEROP_AND_AUTH_TEST_PLAN.md:
#   A: ballerina/a2a's HttpClient  -> the real a2a-sdk 1.1.5 agent (python-agent/)
#   C: the real a2a-sdk 1.1.5 Client -> ballerina/a2a's Listener (bal-listener/)
#
# Requires: ballerina/a2a already published to the local repository
# (cd module-ballerina-a2a/ballerina && bal pack && bal push --repository=local),
# and python-agent/.venv set up (cd python-agent && uv venv .venv && uv pip
# install --python .venv/bin/python -r requirements.txt).

set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PY="$HERE/python-agent/.venv/bin/python"
PY_AGENT_PORT=9700
BAL_LISTENER_PORT=9611

cleanup() {
  pkill -f "python-agent/agent.py" 2>/dev/null || true
  pkill -f "interop/bal-listener" 2>/dev/null || true
}
trap cleanup EXIT

echo "== starting the real Python agent (a2a-sdk 1.1.5) on $PY_AGENT_PORT =="
"$PY" "$HERE/python-agent/agent.py" "$PY_AGENT_PORT" > /tmp/interop_py_agent.log 2>&1 &
for _ in $(seq 1 40); do curl -sf "http://localhost:$PY_AGENT_PORT/.well-known/agent-card.json" > /dev/null && break; sleep 0.5; done

echo
echo "########## PAIR A: ballerina/a2a client -> Python agent ##########"
(cd "$HERE/bal-client" && bal run -- 2>&1) || true
# bal-client/main.bal is hardcoded to localhost:9700 today; no args needed.

echo
echo "== starting the ballerina/a2a listener on $BAL_LISTENER_PORT =="
(cd "$HERE/bal-listener" && bal run > /tmp/interop_bal_listener.log 2>&1 &)
for _ in $(seq 1 60); do curl -sf "http://localhost:$BAL_LISTENER_PORT/.well-known/agent-card.json" > /dev/null && break; sleep 1; done

echo
echo "########## PAIR C: Python client (a2a-sdk 1.1.5) -> ballerina/a2a listener ##########"
"$PY" "$HERE/python-client/driver.py" "http://localhost:$BAL_LISTENER_PORT"
