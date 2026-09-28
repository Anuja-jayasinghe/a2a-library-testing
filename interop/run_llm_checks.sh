#!/usr/bin/env bash
# Claude-backed checks. These spend real API tokens (Haiku, a few short conversations) and
# need the key: `source ~/gitProject/a2a-library-testing/.env` first (BAL_CONFIG_DATA).
# Assertions are on protocol behaviour (task counts, states, identity), never on the model's
# wording, which varies from run to run. NOTE: assembled from the manual runs recorded in
# RESULTS.md; steps 2-4 read the transcripts, so they report rather than assert.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd); PY="$HERE/interop/python-agent/.venv/bin/python"
[ -n "$BAL_CONFIG_DATA" ] || { echo "source the .env first"; exit 2; }
kill_ports() { for p in "$@"; do lsof -ti :"$p" -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true; done; }
trap 'kill_ports 9095 9097 9098' EXIT; kill_ports 9095 9097 9098
up() { for _ in $(seq 1 60); do curl -sf "$1" >/dev/null && return 0; sleep 1; done; }
tasks() { curl -s -H "A2A-Version: 1.0" localhost:"$1"/tasks | python3 -c "import json,sys;print(len(json.load(sys.stdin)['tasks']))"; }
chat() { (cd "$HERE/client" && printf "$1" | java -jar target/bin/a2a_demo_client.jar "${@:2}" 2>&1 | sed -n '/^You:/,$p'); }
for d in server server2 client; do (cd "$HERE/$d" && bal build >/dev/null 2>&1); done
(cd "$HERE/server" && java -jar target/bin/a2a_demo_server.jar >/tmp/llm_planner.log 2>&1 &)
(cd "$HERE/server2" && java -jar target/bin/*.jar >/tmp/llm_packing.log 2>&1 &)
up http://localhost:9095/.well-known/agent-card.json; up http://localhost:9097/.well-known/agent-card.json

echo "== 1. real Python client -> LLM-backed Trip Planner (two-turn task) =="
"$PY" "$HERE/interop/python-client/driver_llm.py"

echo; echo "== 2. Traveler chat: the original duplicate-task regression (expect exactly 1 new task) =="
B=$(tasks 9095); chat 'Ask the Trip Planner agent to plan me a one-day trip. I have not decided on a city yet.\nMilan\nexit\n' | head -20
echo "new planner tasks: $(( $(tasks 9095) - B ))"

echo; echo "== 3. two agents in one turn, then cancel a finished task (expect the failure reported honestly) =="
P=$(tasks 9095); K=$(tasks 9097)
chat 'Ask the Trip Planner for a one-day trip to Kyoto, and separately ask the Packing Assistant what to pack for a day in Kyoto in autumn.\nNow cancel the Kyoto trip-planning task you created with the Trip Planner, and tell me honestly whether the cancellation worked.\nexit\n' | head -30
echo "new tasks: planner $(( $(tasks 9095) - P )), packing $(( $(tasks 9097) - K ))"

echo; echo "== 4. a ~40s task through the model (toolkit waits 20s, the model must follow up) =="
(cd "$HERE/slow-agent" && env -u BAL_CONFIG_DATA java -jar target/bin/a2a_slow_agent.jar -CagentPort=9098 -Csteps=4 -CstepSeconds=10 >/tmp/slow_agent.log 2>&1 &)
up http://localhost:9098/.well-known/agent-card.json
chat 'The agent at the trip planner address does long-running work. Send it the request "run the long task", and keep me posted: do not give up early. Tell me its final result once it has finished.\nexit\n' -CtripPlannerUrl=http://localhost:9098 | head -20
