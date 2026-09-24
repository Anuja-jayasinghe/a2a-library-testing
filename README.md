# A2A Library Testing

Three Claude-backed Ballerina agents talking over the A2A protocol, built only
with `ballerina/a2a`, `ballerina/ai` and `ballerinax/ai.anthropic`.

```
 you ──> client (Traveler) ──A2A──> server  (Trip Planner)      :9095
                           ──A2A──> server2 (Packing Assistant) :9097
```

| Package   | What it is                                                        | Port |
|-----------|-------------------------------------------------------------------|------|
| `server`  | Trip Planner agent (`a2a:Listener` + `ai:Agent`)                  | 9095 |
| `server2` | Packing Assistant agent (same shape, different persona)           | 9097 |
| `client`  | Traveler agent using `ai:A2aToolKit`; you chat with it in a prompt | 9096 (webhook receiver) |

## Prerequisites

- Ballerina 2201.13.5
- An Anthropic API key
- Sibling checkouts of `module-ballerina-a2a` and `module-ballerina-ai`
  (neither `ballerina/a2a` nor `ai:A2aToolKit` is on Ballerina Central yet)

## One-time setup

Publish both libraries to your local Ballerina repository:

```sh
cd ~/gitProject/module-ballerina-a2a/ballerina && bal pack && bal push --repository=local
cd ~/gitProject/module-ballerina-ai/ballerina  && bal pack && bal push --repository=local
```

Set your API key once in a root `.env` file (git-ignored):

```sh
cd ~/gitProject/a2a-library-testing
cp .env.example .env     # then put your real key in .env
```

## Run it

Open three terminals. In **each one**, load the key first, then start the
package. Start the servers before the client.

```sh
# terminal 1
source .env && cd server  && bal run

# terminal 2
source .env && cd server2 && bal run

# terminal 3
source .env && cd client  && bal run
```

The client shows a `You:` prompt. Type a message, press Enter, and the
Traveler agent decides which server agent(s) to call. Type `exit` to quit;
stop the servers with Ctrl+C.

## Things to try

Type these into the client, in order:

1. `What agents are available?`
2. `Ask the Trip Planner for a fun day trip.` — it asks which city (task pauses at `INPUT_REQUIRED`)
3. `Tell it Paris.` — continues the same task and returns an itinerary
4. `What's the status of that task? List all the Trip Planner's tasks.`
5. `Ask the Packing Assistant what to pack for that trip.`
6. `Register the webhook http://localhost:9096/webhook/receiver for that packing task.` — the client logs a line when the notification arrives
7. `Ask the Trip Planner for a Tokyo day trip, then cancel it.`
8. `Stream a Rome day trip from the Trip Planner.`

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `value not provided for required configurable variable 'anthropicApiKey'` | Run `source .env` in that terminal, and check `.env` has a real key. |
| `could not resolve the Agent Card for: http://localhost:...` | That server isn't running yet. Start `server` and `server2` first. |
| A package fails to start with a port error | Something is already on 9095/9096/9097. Stop it, or override the port (below). |
| `Unable to obtain valid answer from the agent` | The Anthropic call failed — invalid key or no network. |
| Build error about `ballerina/a2a` or `ballerina/ai` not found | Redo the one-time setup; the local repository push is missing. |

## Configuration

Everything has a default. Override any of these with `bal run -- -C<name>=<value>`
(the `-C` prefix is required):

| Package   | Option                 | Default                  |
|-----------|------------------------|--------------------------|
| `server`  | `agentPort`            | `9095`                   |
| `server2` | `agentPort`            | `9097`                   |
| `client`  | `tripPlannerUrl`       | `http://localhost:9095`  |
| `client`  | `packingAssistantUrl`  | `http://localhost:9097`  |
| `client`  | `webhookPort`          | `9096`                   |

`anthropicApiKey` is required by all three packages and comes from `.env`
(`BAL_CONFIG_DATA`, which Ballerina reads as TOML). `-CanthropicApiKey=...`
also works for a one-off.

## Code map

- `server/main.bal`, `server2/main.bal` — an `ai:Agent` wrapped as an `a2a:Service`. The model's reply prefix (`NEEDS_INFO:` vs `ITINERARY:` / `PACKING_LIST:`) decides the A2A task state.
- `client/traveler.bal` — builds the Traveler `ai:Agent` with `ai:A2aToolKit` pointed at both servers.
- `client/main.bal` — starts the webhook receiver, runs the `You:` prompt loop.
- `client/webhook.bal` — small HTTP receiver that logs push notifications.
- `client/process_exit.bal` — forces the JVM to exit when you type `exit` (a running listener otherwise keeps it alive).
