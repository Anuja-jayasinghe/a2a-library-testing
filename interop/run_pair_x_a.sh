#!/usr/bin/env bash
# Runs the cross-SDK authentication pairs from INTEROP_AND_AUTH_TEST_PLAN.md's
# Part 2:
#   X-A1: the real a2a-sdk 1.1.5 Client's own AuthInterceptor/CredentialService
#         -> ballerina/a2a's Listener with `auth` configured (bal-listener-auth/)
#   X-A3: ballerina/a2a's HttpClient (credentials = InMemoryCredentialStore)
#         -> a real a2a-sdk 1.1.5 agent that requires a bearer credential
#         (python-agent/agent.py with INTEROP_REQUIRE_AUTH=1)
#
# Both sides authenticate using nothing but the card: no scheme name, header
# shape or credential format is hardcoded on the caller's side beyond "read
# the card, mint a token for the scheme it names."
#
# Requires the same setup as run_pair_a_c.sh (ballerina/a2a published
# locally, python-agent/.venv installed), plus PyJWT in that venv:
#   uv pip install --python python-agent/.venv/bin/python PyJWT==2.10.1

set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PY="$HERE/python-agent/.venv/bin/python"
BAL_AUTH_LISTENER_PORT=9612
PY_AUTH_AGENT_PORT=9701

cleanup() {
  pkill -f "interop/bal-listener-auth" 2>/dev/null || true
  pkill -f "python-agent/agent.py $PY_AUTH_AGENT_PORT" 2>/dev/null || true
}
trap cleanup EXIT
cleanup 2>/dev/null || true
sleep 1

echo "== starting the authenticated ballerina/a2a listener on $BAL_AUTH_LISTENER_PORT =="
(cd "$HERE/bal-listener-auth" && bal run > /tmp/interop_bal_listener_auth.log 2>&1 &)
for _ in $(seq 1 60); do curl -sf "http://localhost:$BAL_AUTH_LISTENER_PORT/.well-known/agent-card.json" > /dev/null && break; sleep 1; done

echo
echo "########## X-A1: real a2a-sdk client's AuthInterceptor -> ballerina/a2a listener ##########"
"$PY" "$HERE/python-client/driver_auth.py" "http://localhost:$BAL_AUTH_LISTENER_PORT"

echo
echo "########## X-A2: real a2a-java client's AuthInterceptor -> ballerina/a2a listener ##########"
# Needs a2a-java built once (see run_pair_b_d.sh's header) and java-client-auth/AuthClient.java compiled:
#   javac -cp "$(cat /tmp/interop_java_client_cp.txt)" -d /tmp/authclient_out java-client-auth/AuthClient.java
A2A_JAVA_DIR=${A2A_JAVA_DIR:-$HOME/gitProject/a2a-java}
if [ -f /tmp/interop_java_client_cp.txt ]; then
  mkdir -p /tmp/authclient_out
  javac -cp "$(cat /tmp/interop_java_client_cp.txt)" -d /tmp/authclient_out "$HERE/java-client-auth/AuthClient.java"
  mint() { "$PY" -c "import jwt,time,sys;print(jwt.encode({'iss':'interop','aud':'a2a','sub':'alice','exp':int(time.time())+300},sys.argv[1],algorithm='HS256'))" "$1"; }
  for spec in "valid token|$(mint interop-auth-shared-secret-0123456789)" "no credential|" "forged signature|$(mint a-different-secret-entirely-0123456)"; do
    echo "-- ${spec%%|*}"; java -cp "$(cat /tmp/interop_java_client_cp.txt):/tmp/authclient_out" AuthClient "http://localhost:$BAL_AUTH_LISTENER_PORT" "${spec#*|}" 2>&1 | grep -v SLF4J | tail -1
  done
else
  echo "(skipped: run run_pair_b_d.sh once first, so the Java client classpath exists)"
fi
# X-A4 (our client -> a Java agent requiring auth) is NOT run: the only Java security example
# (a2a-samples magic_8_ball_security) needs Keycloak via Docker plus an LLM API key.

echo
echo "== starting the real a2a-sdk agent, requiring a bearer credential, on $PY_AUTH_AGENT_PORT =="
(INTEROP_REQUIRE_AUTH=1 "$PY" "$HERE/python-agent/agent.py" "$PY_AUTH_AGENT_PORT" > /tmp/interop_py_auth_agent.log 2>&1 &)
for _ in $(seq 1 40); do curl -sf "http://localhost:$PY_AUTH_AGENT_PORT/.well-known/agent-card.json" > /dev/null && break; sleep 0.5; done

echo
echo "########## X-A3: ballerina/a2a client -> real a2a-sdk agent requiring auth ##########"
(cd "$HERE/bal-client-auth" && bal run -- 2>&1) || true
# bal-client-auth/main.bal is hardcoded to localhost:9701 today; no args needed.
