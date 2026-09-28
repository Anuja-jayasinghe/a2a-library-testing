#!/usr/bin/env bash
# Typed errors, extensions, negotiation and reconnection against REAL servers:
#   1. VersionNotSupported (Python + Java servers), UnsupportedOperation (Python), the A2A-Extensions
#      header, and content-type negotiation against Java              (bal-client-errors)
#   2. a REQUIRED extension seen from the real Python client         (driver_extension.py)
#   3. opt-in stream reconnection through a proxy that cuts the stream (bal-client-reconnect)
# Needs a2a-java built (see run_pair_b_d.sh) for the Java half of step 1.
HERE=$(cd "$(dirname "$0")" && pwd); PY="$HERE/python-agent/.venv/bin/python"
A2A_JAVA_DIR=${A2A_JAVA_DIR:-$HOME/gitProject/a2a-java}
kill_ports() { for p in "$@"; do lsof -ti :"$p" -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null; done; }
trap 'kill_ports 9611 9700 9704 9705 9999' EXIT; kill_ports 9611 9700 9704 9705 9999; sleep 1
up() { for _ in $(seq 1 90); do curl -sf "$1" >/dev/null 2>&1 && return 0; sleep 1; done; echo "not up: $1"; }
run() { (cd "$1" && java -jar "target/bin/$2.jar" "${@:3}") & P=$!; for _ in $(seq 1 90); do kill -0 $P 2>/dev/null || break; sleep 1; done; kill -9 $P 2>/dev/null; }
for d in bal-client-errors bal-client-reconnect bal-listener; do (cd "$HERE/$d" && bal build >/dev/null 2>&1); done

echo "########## 1. typed errors, extensions header, content-type negotiation ##########"
(cd "$HERE/python-agent" && $PY agent.py 9700 >/dev/null 2>&1 &)
(cd "$HERE/python-agent" && INTEROP_NO_STREAMING=1 $PY agent.py 9704 >/dev/null 2>&1 &)
(cd "$A2A_JAVA_DIR/examples/helloworld/server/target/quarkus-app" && java -Dquarkus.agentcard.protocol=HTTP+JSON -Dquarkus.http.port=9999 -jar quarkus-run.jar >/dev/null 2>&1 &)
for p in 9700 9704 9999; do up http://localhost:$p/.well-known/agent-card.json; done
run "$HERE/bal-client-errors" bal_client_errors

echo; echo "########## 2. a required extension, from the real Python client ##########"
(cd "$HERE/bal-listener" && bal run -- -CREQUIRED_EXTENSION=urn:interop:needed >/tmp/ext_listener.log 2>&1 &)
up http://localhost:9611/.well-known/agent-card.json
$PY "$HERE/python-client/driver_extension.py"
kill_ports 9611

echo; echo "########## 3. stream reconnection (proxy cuts the first stream after 3s) ##########"
for n in 0 2; do
  kill_ports 9705; sleep 0.5
  python3 "$HERE/flaky_proxy.py" 9705 9700 3 >/tmp/rc_proxy.log 2>&1 &
  sleep 1
  run "$HERE/bal-client-reconnect" bal_client_reconnect -Cattempts=$n 2>&1 | grep -v "^time=\|^warning"
  grep -q cutting /tmp/rc_proxy.log && echo "(proxy cut the stream)" || echo "(!! proxy did NOT cut -- result is vacuous)"
done
