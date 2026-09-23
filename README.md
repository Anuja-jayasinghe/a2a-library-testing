# A2A Lifecycle Demo

A complete, working demonstration of `ballerina/a2a`: a real A2A agent
served by Ballerina's `a2a:Listener`, and a real A2A client (Ballerina's
`a2a:HttpClient`) driving it through every operation the library
implements -- two separate processes, exactly like a real deployment,
communicating over the actual A2A HTTP+JSON wire protocol.

## What it demonstrates

Running the client against the server walks through:

1. **Agent discovery** -- `resolveAgentCard`, printing the discovered
   card's declared capabilities.
2. **`sendMessage`** -- the ordinary blocking path (task created, driven
   to `TASK_STATE_COMPLETED`, one artifact).
3. **A direct `Message` reply** -- no task at all, for a trivial reply.
4. **`sendStreamingMessage`** -- genuinely live events as the agent
   produces them (not a replayed array), watched as they arrive over
   several real seconds.
5. **`subscribeToTask` + `cancelTask`** -- a second, independent
   connection attaches to a task already in flight, sees it live, then
   watches it end the moment the task is canceled.
6. **Push notifications** -- a webhook is registered inline on the send
   request; the client's own local webhook receiver actually receives
   the delivery when the task completes.
7. **Multi-turn continuation** -- the agent pauses at
   `TASK_STATE_INPUT_REQUIRED`, and a second message (naming the same
   `taskId`) continues the *same* task to completion.
8. **`getTask` / `listTasks`**.
9. **Capability-gated rejection** -- `getExtendedAgentCard` against an
   agent that never configured one, decoded as the typed
   `UnsupportedOperationError` the spec requires.

## Why two separate packages

`server/` and `client/` are two independent Ballerina packages, run as
two independent processes -- not one combined program. This is
deliberate, not incidental: a `bal run` program that both starts a
listener and makes outbound client calls in the same process does not
reliably exit on its own even after explicitly stopping the listener
(confirmed empirically while building this demo -- a plain
`http:Client`-only program exits immediately, but a single `http:Listener`
kept the process alive for minutes past `immediateStop()`, seemingly tied
to the underlying HTTP transport's own connection-pool threads, which
outlive any one listener's lifecycle). Splitting into a genuinely
long-running server and a one-shot client sidesteps that entirely, and
happens to be a more realistic demonstration besides -- this is exactly
how the two sides of an A2A conversation actually run in practice.

The client package additionally forces its own process to exit via a
small Java interop call once the demo finishes (`process_exit.bal`) --
see that file's own comment for why.

## Running it

Requires `ballerina/a2a` to be available locally (it is not yet published
to Ballerina Central):

```sh
cd ~/gitProject/module-ballerina-a2a/ballerina
bal pack && bal push --repository=local
```

Then, in one terminal, start the server (it runs until you stop it,
like any real agent deployment):

```sh
cd server
bal run
```

In a second terminal, run the client:

```sh
cd client
bal run
```

The client prints each step as it happens and exits on its own once the
walkthrough completes. Stop the server afterward with Ctrl+C.

### Pointing at different ports

Both packages default to `agentPort = 9095`; the client additionally
defaults its own webhook receiver to `webhookPort = 9096`. Override
either with `bal run -- agentPort=9100` / `webhookPort=9101` (keep both
packages' `agentPort` in sync if you change it).

## Code structure

- `server/main.bal` -- the whole agent: an `a2a:Listener`, the served
  `AgentCard`, and `DemoAgent`, an `a2a:Service` implementing every task
  state via trigger texts (`ping`, `ask`, `slow`, anything else).
- `client/main.bal` -- orchestrates the client package: starts the local
  webhook receiver, runs the walkthrough, exits.
- `client/client_demo.bal` -- the actual lifecycle walkthrough, one
  numbered section per A2A operation.
- `client/webhook.bal` -- a minimal HTTP receiver standing in for "the
  client's own server", proving push-notification delivery actually
  happens.
- `client/process_exit.bal` -- forces the process to exit once the demo
  finishes; see its own comment for why this is needed at all.
