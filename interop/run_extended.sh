#!/usr/bin/env bash
# The remaining Part 1 scenarios, both directions (INTEROP_AND_AUTH_TEST_PLAN.md):
#   I4 returnImmediately+poll, I5 ListTasks, I9 subscribe, I10 multi-turn,
#   I12 push notifications, I13 keep-alive comments, I14 tenancy, I15 malformed body
#     A: ballerina/a2a client -> real a2a-sdk agent  (bal-client/)
#     C: real a2a-sdk client  -> ballerina/a2a listener (python-client/driver_extended.py, driver_i13.py)
#
# Push receivers run as their own processes (push_receiver.py): a Ballerina
# module-level listener only starts after main() returns under `bal run`, so an
# in-process receiver is never reachable during a main()-driven test.
# bal-client's process is given a watchdog rather than trusted to exit.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PY="$HERE/python-agent/.venv/bin/python"
kill_ports() { for p in "$@"; do lsof -ti :"$p" -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true; done; }
trap 'kill_ports 9611 9700 19870 19871' EXIT
kill_ports 9611 9700 19870 19871; sleep 1
wait_for() { for _ in $(seq 1 90); do curl -sf "$1" > /dev/null && return 0; sleep 1; done; echo "did not start: $1"; return 1; }

echo "########## PAIR A (extended): ballerina/a2a client -> real a2a-sdk agent ##########"
"$PY" "$HERE/python-agent/agent.py" 9700 > /tmp/interop_py_agent_ext.log 2>&1 &
"$PY" "$HERE/push_receiver.py" 19870 /tmp/push_receiver_last.json > /dev/null 2>&1 &
wait_for http://localhost:9700/.well-known/agent-card.json
(cd "$HERE/bal-client" && bal build > /dev/null 2>&1 && java -jar target/bin/bal_client.jar) &
CLIENT_PID=$!
for _ in $(seq 1 60); do kill -0 $CLIENT_PID 2>/dev/null || break; sleep 1; done
kill -9 $CLIENT_PID 2>/dev/null || true
kill_ports 9700 19870

echo
echo "########## PAIR C (extended): real a2a-sdk client -> ballerina/a2a listener ##########"
"$PY" "$HERE/push_receiver.py" 19871 /tmp/push_receiver_last_c.json > /dev/null 2>&1 &
(cd "$HERE/bal-listener" && bal run > /tmp/interop_bal_listener_ext.log 2>&1 &)
wait_for http://localhost:9611/.well-known/agent-card.json
"$PY" "$HERE/python-client/driver_extended.py" http://localhost:9611 || true
kill_ports 9611; sleep 1

echo
echo "########## I13: real SSE client vs. keep-alive comment frames (0.5s keep-alive, 4s silence) ##########"
(cd "$HERE/bal-listener" && bal run -- -CKEEPALIVE_SECONDS=0.5 -CPACE_SECONDS=4 > /tmp/interop_bal_listener_i13.log 2>&1 &)
wait_for http://localhost:9611/.well-known/agent-card.json
"$PY" "$HERE/python-client/driver_i13.py" http://localhost:9611
