# A2A Lifecycle Demo

A complete, working demonstration of `ballerina/a2a`: **two real, independent
LLM agents** -- both built with `ballerina/ai`'s `Agent` abstraction, both
backed by Anthropic's Claude via `ballerinax/ai.anthropic` -- talking to each
other over the actual A2A HTTP+JSON wire protocol via `ballerina/a2a`'s
current client and listener implementation. Nothing here hand-rolls an HTTP
call to the remote agent or to Anthropic; every A2A operation goes through
`ballerina/a2a`, and every model call goes through `ballerina/ai`.

- **`server/`** -- a Trip Planner agent: an `ai:Agent` wrapped as an
  `a2a:Service`, served by an `a2a:Listener`.
- **`client/`** -- a Traveler agent: a second, separate `ai:Agent`, given
  A2A operations against the Trip Planner as tools (`client/toolkit.bal`),
  wrapped around an `a2a:HttpClient`.

Two separate processes, exactly like a real deployment.

## What it demonstrates

The client's Traveler agent is walked through six scenarios, each a fixed
prompt but a genuine, independent LLM decision about which tool(s) to call
and how -- not a scripted exchange:

1. **A fresh request, no destination** -- `sendToTripPlanner`. The server
   agent's own model decides it doesn't have enough information and pauses
   the task at `TASK_STATE_INPUT_REQUIRED`, asking a clarifying question.
2. **Continuation** -- `continueTripPlannerTask` answers with a destination.
   The server reuses the *same* underlying LLM conversation (the A2A
   `contextId` doubles as the `ai:Agent` session id), so it remembers it
   already asked the question, and completes the task with an itinerary.
3. **`getTripPlannerTaskStatus` + `listTripPlannerTasks`**.
4. **Push notifications** -- `registerTripPlannerWebhook` registers the
   client's own local webhook receiver; delivery is verified independently
   of what the model reports, by actually checking the receiver's state.
5. **Cancellation mid-flight** -- `startTripPlannerTaskWithoutWaiting`
   (using `returnImmediately: true` so the call returns before the server's
   model call finishes) immediately followed by `cancelTripPlannerTask`,
   racing a real, still-running LLM call.
6. **Live streaming** -- `streamFromTripPlanner` watches the server agent's
   progress as genuinely live events, not a replayed array.

## Why two separate packages

`server/` and `client/` are two independent Ballerina packages, run as two
independent processes -- not one combined program. This is deliberate, not
incidental: a `bal run` program that both starts a listener and makes
outbound client calls in the same process does not reliably exit on its own
even after explicitly stopping the listener (confirmed empirically while
building this demo -- a plain `http:Client`-only program exits immediately,
but a single `http:Listener` kept the process alive for minutes past
`immediateStop()`, seemingly tied to the underlying HTTP transport's own
connection-pool threads, which outlive any one listener's lifecycle).
Splitting into a genuinely long-running server and a one-shot client
sidesteps that entirely, and happens to be a more realistic demonstration
besides -- this is exactly how the two sides of an A2A conversation actually
run in practice.

The client package additionally forces its own process to exit via a small
Java interop call once the demo finishes (`process_exit.bal`) -- see that
file's own comment for why.

## Running it

Requires `ballerina/a2a` to be available locally (it is not yet published to
Ballerina Central):

```sh
cd ~/gitProject/module-ballerina-a2a/ballerina
bal pack && bal push --repository=local
```

You'll also need an Anthropic API key -- both packages require one via the
same `anthropicApiKey` configurable variable (there is no default; each
package fails fast with a clear error if it's missing). Set it **once, at
the repo root**, and both packages pick it up automatically:

```sh
cp .env.example .env   # then edit .env and paste in a real key
source .env
```

This works because `.env` sets `BAL_CONFIG_DATA`, Ballerina's own mechanism
for satisfying a configurable variable from a plain OS environment variable
(its content is parsed as TOML) -- since both packages declare the same
variable name, one `source .env` covers both, with no per-package
`Config.toml` and no flag on either `bal run`. See `.env.example` for
details.

Then, in one terminal, start the server (it runs until you stop it, like
any real agent deployment):

```sh
cd server
bal run
```

In a second terminal, run the client:

```sh
cd client
bal run
```

(Prefer a one-off override instead? Ballerina also accepts
`bal run -- -CanthropicApiKey=sk-ant-...` on the command line -- note the
required `-C` prefix, since a bare `key=value` silently fails to apply.)

The client prints each scenario and the Traveler agent's report of what
happened as it goes, and exits on its own once the walkthrough completes.
Stop the server afterward with Ctrl+C.

### Pointing at different ports

The server defaults to `agentPort = 9095`; the client's `toolkit.bal`
defaults `agentUrl = "http://localhost:9095"` to match, and its own webhook
receiver defaults to `webhookPort = 9096`. Override with
`-CagentPort=9100` / `-CagentUrl=http://localhost:9100` /
`-CwebhookPort=9101` as needed (keep the client's `agentUrl` in sync with
whatever port the server actually uses).

## Code structure

- `server/main.bal` -- the Trip Planner agent: an `ai:Agent` (Claude-backed,
  via `ballerinax/ai.anthropic`) wrapped as `TripPlannerAgentService`, an
  `a2a:Service` served by an `a2a:Listener`. The model's structured reply
  (`NEEDS_INFO:` / `ITINERARY:` prefixes) drives the A2A task state machine.
- `client/toolkit.bal` -- `TripPlannerToolKit`, giving the client's
  `ai:Agent` real A2A operations (send, continue, stream, status, cancel,
  list, webhook registration) as tools, built directly on `a2a:HttpClient`.
- `client/client_demo.bal` -- the Traveler agent and its six numbered
  scenarios.
- `client/main.bal` -- orchestrates the client package: starts the local
  webhook receiver, runs the walkthrough, exits.
- `client/webhook.bal` -- a minimal HTTP receiver standing in for "the
  client's own server", proving push-notification delivery actually
  happens.
- `client/process_exit.bal` -- forces the process to exit once the demo
  finishes; see its own comment for why this is needed at all.
