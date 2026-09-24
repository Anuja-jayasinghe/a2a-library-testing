#!/usr/bin/env bash
# Runs the A2A TCK against this agent (HTTP+JSON only) in one configuration.
#
#   ./run_tck.sh [default|no-capabilities|extended|extension]
#
# The TCK skips requirements that depend on how the agent is configured, so
# run all four to cover them:
#   default          every capability on, no extended card
#   no-capabilities  streaming and push notifications withheld
#   extended         extended card configured
#   extension        one required extension declared. Runs ONLY the TCK's
#                    missing-required-extension test: every ordinary TCK
#                    request omits the extension header, so with a required
#                    extension the server (correctly) refuses all of them.
#
# Environment: TCK_DIR (default ~/gitProject/a2a-tck, already set up with
# `uv venv && uv pip install -e .`), PORT (default 9999).

MODE=${1:-default}
TCK_DIR=${TCK_DIR:-$HOME/gitProject/a2a-tck}
PORT=${PORT:-9999}
HERE=$(cd "$(dirname "$0")" && pwd)

case "$MODE" in
  default)         ARGS=() ;;
  no-capabilities) ARGS=(-Cstreaming=false -CpushNotifications=false) ;;
  extended)        ARGS=(-CextendedCard=true) ;;
  extension)       ARGS=(-CrequiredExtension=true); ONLY=(-k missing_required_extension) ;;
  *) echo "unknown mode '$MODE' (default | no-capabilities | extended | extension)"; exit 2 ;;
esac

stop_sut() {
  pid=$(lsof -ti :"$PORT" 2>/dev/null)
  [ -n "$pid" ] && kill -9 $pid 2>/dev/null
}
trap stop_sut EXIT

stop_sut
cd "$HERE" || exit 1
bal run -- -CagentPort="$PORT" "${ARGS[@]}" > "/tmp/tck_sut_$MODE.log" 2>&1 &

for _ in $(seq 1 60); do
  curl -sf "http://localhost:$PORT/.well-known/agent-card.json" > /dev/null && break
  sleep 1
done
curl -sf "http://localhost:$PORT/.well-known/agent-card.json" > /dev/null \
  || { echo "agent did not start; see /tmp/tck_sut_$MODE.log"; exit 1; }

echo "== mode: $MODE =="
cd "$TCK_DIR" || exit 1
# shellcheck disable=SC1091
source .venv/bin/activate
./run_tck.py --sut-host "http://localhost:$PORT" --transport http_json -- -rs "${ONLY[@]}"
status=$?
mkdir -p "reports/$MODE" && cp reports/junitreport.xml reports/tck_report.html "reports/$MODE/" 2>/dev/null
exit $status
