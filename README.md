# A2A Lifecycle Demo

A complete, working demonstration of `ballerina/a2a`: **three real,
independent LLM agents** -- all built with `ballerina/ai`'s `Agent`
abstraction, all backed by Anthropic's Claude via `ballerinax/ai.anthropic`
-- talking to each other over the actual A2A HTTP+JSON wire protocol.
Nothing here hand-rolls an HTTP call to a remote agent or to Anthropic;
every A2A operation goes through `ballerina/a2a`, and every model call goes
through `ballerina/ai`.

- **`server/`** -- a Trip Planner agent: an `ai:Agent` wrapped as an
  `a2a:Service`, served by an `a2a:Listener`.
- **`server2/`** -- a Packing Assistant agent: a second, structurally
  identical server, a genuinely different remote agent to choose between.
- **`client/`** -- a Traveler agent: a third, separate `ai:Agent`, given
  A2A operations against *both* servers as tools -- not a hand-written,
  per-agent toolkit, but `ai:A2aToolKit`: `ballerina/ai`'s generic,
  multi-agent A2A toolkit. This is the abstraction a real user building
  agents with `ballerina/ai` would actually reach for, the same way
  `ai:McpToolKit` is the generic toolkit for MCP servers -- a registry of
  agents (resolved from their Agent Cards), exposing a small, fixed set of
  agentName-parameterized tools (`discoverAgents`, `delegateToAgent`,
  `getAgentTaskStatus`, `cancelAgentTask`, `listAgentTasks`,
  `streamFromAgent`, `createAgentPushNotificationConfig`, ...) rather than
  one bespoke tool per remote agent. Adding a third agent to this demo would
  be a one-line change to the `agents` array, not a new tool the model has
  to relearn.

Three separate processes, exactly like a real deployment.

## What it demonstrates

The client's Traveler agent is walked through seven scenarios, each a fixed
prompt but a genuine, independent LLM decision about which tool(s) to call
and how -- not a scripted exchange:

1. **Discovery + a fresh request, no destination** -- `discoverAgents` then
   `delegateToAgent` to the Trip Planner. Its own model decides it doesn't
   have enough information and pauses the task at
   `TASK_STATE_INPUT_REQUIRED`, asking a clarifying question.
2. **Continuation** -- `delegateToAgent` again, passing the same `taskId`
   and a destination. The server reuses the *same* underlying LLM
   conversation (the A2A `contextId` doubles as the `ai:Agent` session id),
   so it remembers it already asked the question, and completes the task
   with an itinerary.
3. **`getAgentTaskStatus` + `listAgentTasks`**.
4. **Delegating to the *other* agent** -- `delegateToAgent` to the Packing
   Assistant instead, a fresh task with a different remote agent, using the
   same generic tool.
5. **Push notifications** -- `createAgentPushNotificationConfig` registers
   the client's own local webhook receiver on the Packing Assistant's task;
   delivery is verified independently of what the model reports, by
   actually checking the receiver's state.
6. **`cancelAgentTask`** on a task just started with the Trip Planner --
   reported honestly either way, since the toolkit's `delegateToAgent`
   already waits briefly for the task to settle before returning (see
   "Design notes" below), so the outcome genuinely depends on how fast the
   model call happens to finish.
7. **Live streaming** -- `streamFromAgent` watches the Trip Planner's
   progress as genuinely live events, not a replayed array.

## Design notes

**Why a generic toolkit, not one tool per agent.** An earlier version of
this demo hand-wrote a bespoke `TripPlannerToolKit` with tools named
`sendToTripPlanner`, `continueTripPlannerTask`, etc. -- one class per remote
agent, scoped to it by name. That doesn't match how a real user builds
multi-agent systems with `ballerina/ai`: it doesn't scale (a tenth agent
means a tenth set of named tools), and it diverges from the precedent
`ai:McpToolKit` already sets for wrapping a remote protocol client
generically. `ai:A2aToolKit` fixes this: a registry of agents, a handful of
agentName-parameterized tools, and tool-group flags (`core`, `streaming`,
`extendedCard`, `pushNotifications`) so a caller only pays for the tools it
actually needs -- an `ai:Agent` routes measurably worse as its tool count
grows, so the toolkit doesn't register anything left disabled.

**`delegateToAgent` blocks briefly, on purpose.** Every `sendMessage` under
the hood uses `returnImmediately: true`, then polls the task for up to 20
seconds before returning -- so a fast agent still gets a real answer back in
one tool call, instead of always looking unfinished. A task still running
past that falls through to an honest "here is the state and the id"
summary rather than blocking forever.

**`delegateToAgent` takes an optional `taskId`.** The A2A operations this
toolkit generalizes are fixed by the protocol (send, get, cancel, list,
stream, subscribe, push-notification config) -- there's no MCP-style
`listTools()` to discover *arbitrary* per-agent capabilities, since what
varies agent to agent is the *content* of a natural-language message, not
the operation set. Continuing a paused task (this demo's flagship
`INPUT_REQUIRED` scenario) needs `message.taskId` set on the wire, so
`delegateToAgent` accepts an optional `taskId` for exactly that -- omit it
for a fresh request, pass it to continue one.

## Why three separate packages

`server/`, `server2/`, and `client/` are three independent Ballerina
packages, run as three independent processes -- not one combined program.
This is deliberate, not incidental: a `bal run` program that both starts a
listener and makes outbound client calls in the same process does not
reliably exit on its own even after explicitly stopping the listener
(confirmed empirically while building this demo -- a plain `http:Client`-
only program exits immediately, but a single `http:Listener` kept the
process alive for minutes past `immediateStop()`, seemingly tied to the
underlying HTTP transport's own connection-pool threads, which outlive any
one listener's lifecycle). Splitting into two genuinely long-running
servers and a one-shot client sidesteps that entirely, and happens to be a
more realistic demonstration besides -- this is exactly how the sides of an
A2A conversation actually run in practice.

The client package additionally forces its own process to exit via a small
Java interop call once the demo finishes (`process_exit.bal`) -- see that
file's own comment for why.

## Running it

Requires `ballerina/a2a` **and** a locally patched `ballerina/ai` to be
available locally -- neither `ai:A2aToolKit` nor `ballerina/a2a` itself is
on Ballerina Central yet:

```sh
cd ~/gitProject/module-ballerina-a2a/ballerina
bal pack && bal push --repository=local

cd ~/gitProject/module-ballerina-ai/ballerina
bal pack && bal push --repository=local
```

(The second step is a local, uncommitted working-tree change to
`module-ballerina-ai` -- see that repo's own `a2a-toolkit.bal` -- that pins
its `ballerina/a2a` dependency to the version above and ports
`ai:A2aToolKit` to its current client API.)

You'll also need an Anthropic API key -- all three packages require one via
the same `anthropicApiKey` configurable variable (there is no default; each
package fails fast with a clear error if it's missing). Set it **once, at
the repo root**, and all three packages pick it up automatically:

```sh
cp .env.example .env   # then edit .env and paste in a real key
source .env
```

This works because `.env` sets `BAL_CONFIG_DATA`, Ballerina's own mechanism
for satisfying a configurable variable from a plain OS environment variable
(its content is parsed as TOML) -- since every package declares the same
variable name, one `source .env` covers all of them, with no per-package
`Config.toml` and no flag on any `bal run`. See `.env.example` for details.

Then, in two terminals, start the servers (they run until you stop them,
like any real agent deployment):

```sh
cd server && bal run    # terminal 1
cd server2 && bal run   # terminal 2
```

In a third terminal, run the client:

```sh
cd client && bal run
```

(Prefer a one-off override instead? Ballerina also accepts
`bal run -- -CanthropicApiKey=sk-ant-...` on the command line -- note the
required `-C` prefix, since a bare `key=value` silently fails to apply.)

The client prints each scenario and the Traveler agent's report of what
happened as it goes, and exits on its own once the walkthrough completes.
Stop both servers afterward with Ctrl+C.

### Pointing at different ports

`server/` defaults to `agentPort = 9095`, `server2/` to `agentPort = 9097`;
`client/client_demo.bal` defaults `tripPlannerUrl`/`packingAssistantUrl` to
match, and its own webhook receiver defaults to `webhookPort = 9096`.
Override with `-CagentPort=...` on either server and
`-CtripPlannerUrl=...` / `-CpackingAssistantUrl=...` / `-CwebhookPort=...`
on the client as needed, keeping them in sync.

## Code structure

- `server/main.bal` -- the Trip Planner agent: an `ai:Agent` (Claude-backed,
  via `ballerinax/ai.anthropic`) wrapped as `TripPlannerAgentService`, an
  `a2a:Service` served by an `a2a:Listener`. The model's structured reply
  (`NEEDS_INFO:` / `ITINERARY:` prefixes) drives the A2A task state machine.
- `server2/main.bal` -- the Packing Assistant agent, structurally identical
  to the Trip Planner (`NEEDS_INFO:` / `PACKING_LIST:` prefixes), on a
  different port -- exists purely so the client's toolkit has a genuine
  second agent to choose between.
- `client/client_demo.bal` -- the Traveler agent, built with `ai:A2aToolKit`
  pointed at both servers, and its seven numbered scenarios.
- `client/main.bal` -- orchestrates the client package: starts the local
  webhook receiver, runs the walkthrough, exits.
- `client/webhook.bal` -- a minimal HTTP receiver standing in for "the
  client's own server", proving push-notification delivery actually
  happens.
- `client/process_exit.bal` -- forces the process to exit once the demo
  finishes; see its own comment for why this is needed at all.
