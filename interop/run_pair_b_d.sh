#!/usr/bin/env bash
# Runs interop pairs B and D from INTEROP_AND_AUTH_TEST_PLAN.md:
#   B: ballerina/a2a's HttpClient           -> the real a2a-java reference server (helloworld example)
#   D: the real a2a-java reference client   -> ballerina/a2a's Listener
#
# Unlike the Python pair, this doesn't vendor a runnable copy of the Java side:
# a2a-java has no released artifacts (confirmed: zero results for
# org.a2aproject.sdk on Maven Central), so it has to be built from the
# A2A_JAVA_DIR checkout. That build is heavy (Quarkus + gRPC + protobuf
# codegen, several hundred MB of dependencies) and this script does not try
# to make it fast -- it is meant to be run occasionally, not on every change.
#
# Requires:
#   - ballerina/a2a already published locally (see interop/run_pair_a_c.sh's header)
#   - A2A_JAVA_DIR (default ~/gitProject/a2a-java) built once:
#       cd "$A2A_JAVA_DIR" && mvn -q -am -DskipTests \
#         -pl "examples/helloworld/server,examples/helloworld/client" install
#     (skip http-client-vertx/-android/-cdi if you hit a missing test-jar
#     error from a *different* -pl selection -- the full build above does not)

set -e
HERE=$(cd "$(dirname "$0")" && pwd)
A2A_JAVA_DIR=${A2A_JAVA_DIR:-$HOME/gitProject/a2a-java}
JAVA_AGENT_PORT=9999   # hardcoded in the example client (SERVER_URL); do not change without editing it there too
BAL_LISTENER_PORT=9999 # pair D target -- reuses the same port, since the two pairs run one after another

cleanup() {
  pkill -f "quarkus-run.jar" 2>/dev/null || true
  pkill -f "interop/bal-listener" 2>/dev/null || true
}
trap cleanup EXIT
cleanup 2>/dev/null || true
sleep 1

echo "== starting the real a2a-java reference server (helloworld example) on $JAVA_AGENT_PORT =="
( cd "$A2A_JAVA_DIR/examples/helloworld/server/target/quarkus-app" \
  && java -Dquarkus.agentcard.protocol=HTTP+JSON -Dquarkus.http.port=$JAVA_AGENT_PORT -jar quarkus-run.jar \
     > /tmp/interop_java_agent.log 2>&1 & )
for _ in $(seq 1 60); do curl -sf "http://localhost:$JAVA_AGENT_PORT/.well-known/agent-card.json" > /dev/null && break; sleep 1; done

echo
echo "########## PAIR B: ballerina/a2a client -> real a2a-java reference server ##########"
echo "NOTE: ballerina/http's ClientConfiguration.httpVersion defaults to HTTP_2_0, which over"
echo "plain HTTP means prior-knowledge h2c. Quarkus/Vert.x's default listener here does not"
echo "support that and answers with a bare 400 before the request reaches the A2A routing layer"
echo "at all (confirmed: no server-side log entry for the rejected request). Forcing HTTP/1.1"
echo "on the client fixes it completely -- see interop/RESULTS.md finding 5. bal-client-java/"
echo "already does this."
(cd "$HERE/bal-client-java" && bal run 2>&1) || true

pkill -f "quarkus-run.jar" 2>/dev/null || true
sleep 1

echo
echo "== starting the ballerina/a2a listener on $BAL_LISTENER_PORT (port matches the Java client's hardcoded SERVER_URL) =="
(cd "$HERE/bal-listener" && bal run -- -CPORT=$BAL_LISTENER_PORT > /tmp/interop_bal_listener_java.log 2>&1 &)
for _ in $(seq 1 60); do curl -sf "http://localhost:$BAL_LISTENER_PORT/.well-known/agent-card.json" > /dev/null && break; sleep 1; done

echo
echo "########## PAIR D: real a2a-java reference client -> ballerina/a2a listener ##########"
CP_FILE=/tmp/interop_java_client_cp.txt
( cd "$A2A_JAVA_DIR/examples/helloworld/client" \
  && mvn -q dependency:build-classpath -Dmdep.outputFile="$CP_FILE" )
CP="$(cat "$CP_FILE"):$A2A_JAVA_DIR/examples/helloworld/client/target/classes"
java -Dquarkus.agentcard.protocol=HTTP+JSON -cp "$CP" \
  org.a2aproject.sdk.examples.helloworld.client.HelloWorldClient
