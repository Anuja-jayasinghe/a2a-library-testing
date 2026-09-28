#!/usr/bin/env bash
# The checks that had never been run against a foreign server or a real token flow:
#   1. client operations against the real a2a-sdk agent (streaming, push-config CRUD,
#      extended card, list filters, cancel, chunked artifacts, typed errors)
#   2. the production-shaped auth flow: OAuth2 client_credentials against a local issuer,
#      listener validating via JWKS, expiry, scope, key rotation; from this client AND the
#      real Python client
#   3. TLS and mutual TLS
# bal-client processes get a watchdog rather than being trusted to exit.
HERE=$(cd "$(dirname "$0")" && pwd); PY="$HERE/python-agent/.venv/bin/python"
kill_ports() { for p in "$@"; do lsof -ti :"$p" -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null; done; }
PORTS="9700 9702 9703 9800 9613 9614 9615 9616"; trap "kill_ports $PORTS" EXIT; kill_ports $PORTS; sleep 1
up() { for _ in $(seq 1 90); do curl -sfk "$1" >/dev/null 2>&1 && return 0; sleep 1; done; echo "not up: $1"; }
run() { (cd "$1" && java -jar "target/bin/$2.jar") & P=$!; for _ in $(seq 1 90); do kill -0 $P 2>/dev/null || break; sleep 1; done; kill -9 $P 2>/dev/null; }
for d in bal-client-ops bal-client-oidc bal-client-tls bal-listener-oidc bal-listener-tls; do (cd "$HERE/$d" && bal build >/dev/null 2>&1); done

echo "########## 1. client operations vs the real a2a-sdk agent ##########"
(cd "$HERE/python-agent" && $PY agent.py 9700 >/dev/null 2>&1 &)
(cd "$HERE/python-agent" && INTEROP_NO_PUSH=1 $PY agent.py 9702 >/dev/null 2>&1 &)
(cd "$HERE/python-agent" && INTEROP_NO_EXTENDED_CARD=1 $PY agent.py 9703 >/dev/null 2>&1 &)
for p in 9700 9702 9703; do up http://localhost:$p/.well-known/agent-card.json; done
run "$HERE/bal-client-ops" bal_client_ops
kill_ports 9700 9702 9703

echo; echo "########## 2. OAuth2 + JWKS flow (local issuer, 4s tokens) ##########"
$PY "$HERE/oidc-provider/provider.py" 9800 4 >/dev/null 2>&1 &
(cd "$HERE/bal-listener-oidc" && bal run >/tmp/oidc_listener.log 2>&1 &)
up http://localhost:9613/.well-known/agent-card.json
echo "--- this client ---"; run "$HERE/bal-client-oidc" bal_client_oidc
echo "--- the real Python client ---"; $PY "$HERE/python-client/driver_oidc.py"
kill_ports 9800 9613

echo; echo "########## 3. TLS and mutual TLS ##########"
bash "$HERE/make_certs.sh" >/dev/null
# From the built jar, one process each: three `bal run`s in one directory race to rewrite target/.
TLS_JAR="$HERE/bal-listener-tls/target/bin/bal_listener_tls.jar"
(java -jar "$TLS_JAR" >/tmp/tls_listener.log 2>&1 &)
(BAL_CONFIG_VAR_PORT=9615 BAL_CONFIG_VAR_MUTUALTLS=true java -jar "$TLS_JAR" >/tmp/mtls_listener.log 2>&1 &)
(BAL_CONFIG_VAR_PORT=9616 BAL_CONFIG_VAR_PUBLIC_URL=https://agents.example.com/travel/ java -jar "$TLS_JAR" >/tmp/pub_listener.log 2>&1 &)
up https://localhost:9614/.well-known/agent-card.json
up https://localhost:9616/.well-known/agent-card.json
up https://localhost:9614/.well-known/agent-card.json
for _ in $(seq 1 60); do curl -sf --cacert /tmp/interop-certs/ca.pem --cert /tmp/interop-certs/client.pem --key /tmp/interop-certs/client.key https://localhost:9615/.well-known/agent-card.json >/dev/null && break; sleep 1; done
run "$HERE/bal-client-tls" bal_client_tls
