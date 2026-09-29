#!/usr/bin/env bash
# The identity-provider and AUTH_REQUIRED group of INTEROP_AND_AUTH_TEST_PLAN.md, against a REAL
# identity provider (Keycloak in Docker) instead of the shared secret / fake provider used earlier:
#   K1/K3/K4/K5/B1  the real a2a-sdk 1.1.5 Python client -> ballerina/a2a's Listener (bal-listener-idp),
#                   which validates Keycloak tokens against the realm's JWKS
#   K2/K3/B2/C1     ballerina/a2a's client -> the Python SDK's agent (validating the same tokens),
#                   and -> our own listener, incl. the refresh-token grant and an agent chain
#
# Needs Docker, ballerina/a2a published locally, python-agent/.venv (a2a-sdk, PyJWT, cryptography, httpx).

set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PY="$HERE/python-agent/.venv/bin/python"
KC=http://localhost:8180/realms/a2a
FAIL=0

cleanup() {
  pkill -f "bal_listener_idp.jar" 2>/dev/null || true
  pkill -f "python-agent/agent.py 9702" 2>/dev/null || true
}
trap cleanup EXIT
cleanup 2>/dev/null || true

echo "== Keycloak (realm a2a) =="
if ! curl -sf "$KC/.well-known/openid-configuration" > /dev/null; then
  docker rm -f a2a-keycloak > /dev/null 2>&1 || true
  docker run -d --name a2a-keycloak -p 8180:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
    -e KC_HOSTNAME_STRICT=false -v "$HERE/keycloak/realm-a2a.json:/opt/keycloak/data/import/realm-a2a.json:ro" \
    quay.io/keycloak/keycloak:26.0 start-dev --import-realm > /dev/null
  for _ in $(seq 1 90); do curl -sf "$KC/.well-known/openid-configuration" > /dev/null && break; sleep 2; done
fi
curl -sf "$KC/.well-known/openid-configuration" > /dev/null || { echo "Keycloak did not come up"; exit 1; }

(cd "$HERE/bal-listener-idp" && bal build > /tmp/idp_build.log 2>&1) || { cat /tmp/idp_build.log; exit 1; }
(cd "$HERE/bal-client-idp" && bal build > /tmp/idp_client_build.log 2>&1) || { cat /tmp/idp_client_build.log; exit 1; }
JAR="$HERE/bal-listener-idp/target/bin/bal_listener_idp.jar"

echo "== agents: A on 9620, B on 9621 (ballerina/a2a), Python SDK agent on 9702 =="
(BAL_CONFIG_VAR_PORT=9620 java -jar "$JAR" > /tmp/idp_a.log 2>&1 &)
(BAL_CONFIG_VAR_PORT=9621 java -jar "$JAR" > /tmp/idp_b.log 2>&1 &)
(INTEROP_REQUIRE_AUTH=1 INTEROP_JWKS_URL="$KC/protocol/openid-connect/certs" INTEROP_ISSUER="$KC" \
  "$PY" "$HERE/python-agent/agent.py" 9702 > /tmp/idp_py.log 2>&1 &)
for p in 9620 9621 9702; do
  for _ in $(seq 1 60); do curl -sf "http://localhost:$p/.well-known/agent-card.json" > /dev/null && break; sleep 1; done
done

echo
echo "########## the real a2a-sdk client, with Keycloak credentials -> ballerina/a2a's listener ##########"
"$PY" "$HERE/python-client/driver_idp.py" http://localhost:9620 || FAIL=1

echo
echo "########## the listener's behaviour toward the IdP's key endpoint (JWKS): fetch rate, cache, outage, rotation ##########"
"$PY" "$HERE/python-client/driver_jwks.py" || FAIL=1

echo
echo "########## ballerina/a2a's client, with Keycloak credentials -> the Python SDK's agent, and our listener ##########"
LOGIN=$("$PY" - <<EOF
import sys; sys.path.insert(0, "$HERE/keycloak")
import idp
t = idp.login_with_code("alice", "alicepw")
print(t["refresh_token"], idp.claims(t["access_token"])["sub"])
EOF
)
REFRESH=${LOGIN%% *}; SUB=${LOGIN##* }
(cd "$HERE/bal-client-idp" && bal run -- -CaliceRefreshToken="$REFRESH" -CaliceSub="$SUB" 2>&1) || FAIL=1

exit $FAIL
