#!/usr/bin/env bash
# Sixth-language pair, both directions, against a2a-dotnet (built from main 76de7f3; HTTP+JSON, A2A v1.0):
#   D-A: ballerina/a2a RestClient -> dotnet-agent (Claude-backed via the official Anthropic C# SDK if ANTHROPIC_API_KEY is set)
#   D-C: a2a-dotnet client        -> ballerina/a2a Listener
# Runs in Docker (mcr.microsoft.com/dotnet/sdk:10.0). Build once with:
#   cd dotnet-agent && docker run --rm -v "$PWD":/w -v ~/gitProject/a2a-dotnet:/sdk -v a2a-nuget:/root/.nuget/packages \
#     -w /w mcr.microsoft.com/dotnet/sdk:10.0 dotnet publish -c Release -f net10.0 -o /w/out
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/load_env.sh"
OUT=${OUT:-/tmp/a2a-dotnet}; mkdir -p "$OUT"
IMG=mcr.microsoft.com/dotnet/sdk:10.0
cleanup() { docker rm -f a2a-dotnet-agent >/dev/null 2>&1; pkill -f "interop/bal-listener" 2>/dev/null; pkill -f bal_listener 2>/dev/null; true; }
trap cleanup EXIT; cleanup; sleep 1
up() { for _ in $(seq 1 90); do curl -sf "$1" >/dev/null && return; sleep 1; done; echo "NOT UP: $1"; }

echo "########## D-A: ballerina/a2a client -> .NET agent ##########"
docker run -d --name a2a-dotnet-agent -p 9806:9806 -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" -e CLAUDE_MODEL="${CLAUDE_MODEL:-claude-haiku-4-5}" \
  -v "$HERE/dotnet-agent/out":/app $IMG dotnet /app/DotnetInterop.dll agent 9806 >/dev/null
up http://localhost:9806/.well-known/agent-card.json; docker logs a2a-dotnet-agent 2>&1 | head -1
(cd "$HERE/bal-client-node" && rm -rf target && bal run -- http://localhost:9806 2>&1 | grep -E "^(PASS|FAIL|==|OVERALL|  artifact)")
docker logs a2a-dotnet-agent > "$OUT/agent.log" 2>&1
cleanup; sleep 1

echo "########## D-C: a2a-dotnet client -> ballerina/a2a Listener ##########"
(cd "$HERE/bal-listener" && rm -rf target && bal run -- -CKEEPALIVE_SECONDS=0.5 >"$OUT/listener.log" 2>&1 &)
up http://localhost:9611/.well-known/agent-card.json
docker run --rm -v "$HERE/dotnet-agent/out":/app $IMG dotnet /app/DotnetInterop.dll client http://host.docker.internal:9611 | tee "$OUT/client.out"
