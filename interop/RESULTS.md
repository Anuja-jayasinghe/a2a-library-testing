# Interop results

Grid from `INTEROP_AND_AUTH_TEST_PLAN.md` §1. Each cell: pass / fail / not run, with the
finding and, for a failure, whose fault it was and the fix.

Run with `interop/run_pair_a_c.sh` (starts both sides, runs both pairs, cleans up). Every
result below is a live run, not a design read.

## Pair A: ballerina/a2a `HttpClient` -> real `a2a-sdk` 1.1.5 agent (`python-agent/`)

| Scenario | Result | Notes |
|---|---|---|
| I1 discover card | PASS | Parses the SDK's own served card, including `"HTTP+JSON"` binding |
| I2 blocking send -> Message | PASS | |
| I3 blocking send -> completed Task + artifact | PASS | Required fixing the Python agent first -- see Finding 1 |
| I6 cancel a completed task | PASS | `TaskNotCancelableError` |
| I7 getTask on unknown id | PASS | `TaskNotFoundError` |
| I11 raw bytes part | PASS | Base64-encoded on the wire, decoded correctly on both ends |
| card fetch, closed port | PASS | Typed transport error, not a hang |

## Pair C: real `a2a-sdk` 1.1.5 `Client` -> ballerina/a2a `Listener` (`bal-listener/`)

| Scenario | Result | Notes |
|---|---|---|
| I1 discover card, negotiate HTTP+JSON | PASS | Only after `supported_protocol_bindings=[HTTP_JSON]` is set explicitly -- see Finding 2 |
| I2/I3 send -> completed Task + artifact | PASS | Required fixing the test driver's stream handling -- see Finding 3 |
| I7 getTask on unknown id | PASS | Our 404 + `TASK_NOT_FOUND` is recognised and raised as the SDK's own `TaskNotFoundError` |
| getTask on the real id | PASS | |
| cancelTask on a completed task | PASS | Our 400 + `TASK_NOT_CANCELABLE` raised as the SDK's own `TaskNotCancelableError` |

## Pair B: ballerina/a2a `HttpClient` -> real `a2a-java` reference server (`examples/helloworld`)

Run with `interop/run_pair_b_d.sh` (needs `a2a-java` built once locally -- see the script's
header; no released Maven Central artifacts exist for `org.a2aproject.sdk`, confirmed).

| Scenario | Result | Notes |
|---|---|---|
| I1 discover card | PASS | Only with `httpVersion: http:HTTP_1_1` set -- see Finding 5 |
| I2/I3 blocking send -> Message/Task | PASS | The helloworld agent replies with a direct Message |
| I7 getTask on unknown id | PASS | `TaskNotFoundError` |

## Pair D: real `a2a-java` reference client -> ballerina/a2a `Listener`

| Scenario | Result | Notes |
|---|---|---|
| I1 discover card | PASS | |
| I8 streaming send | Task completes correctly server-side; **client throws after the terminal event** -- see Finding 6 |

## X-A1: real `a2a-sdk` 1.1.5 `AuthInterceptor`/`CredentialService` -> ballerina/a2a `Listener` with `auth`

Run with `interop/run_pair_x_a.sh`. `bal-listener-auth/` derives its card from `auth`
(JWT); the Python client reads the card's `securitySchemes`, not a hardcoded scheme name.

| Case | Result |
|---|---|
| Valid token | PASS -- send succeeds |
| No credential in the store | PASS -- 401 |
| Forged signature | PASS -- 401 |

## X-A3: ballerina/a2a `HttpClient` (`InMemoryCredentialStore`) -> real `a2a-sdk` 1.1.5 agent requiring auth

`python-agent/agent.py` run with `INTEROP_REQUIRE_AUTH=1` validates a Bearer JWT via a plain
Starlette middleware and declares the matching `securitySchemes` on its card.

| Case | Result |
|---|---|
| No credential configured | PASS -- `AuthenticationError` |
| Credential resolved by scheme name from the card alone | PASS -- task completes |

## Findings

**1. (Python SDK ergonomics, not a bug) The agent must enqueue the initial `Task` itself.**
Unlike `a2a:TaskUpdater`, which creates the task implicitly on first use, `a2a-sdk`'s
`TaskUpdater` expects the executor to `event_queue.enqueue_event(Task(...))` before any
`update_status`/`add_artifact` call, or it raises `"Agent should enqueue Task before ...
event"`. Documented via `a2a.helpers.new_task`/`new_task_from_user_message`. Fixed in
`python-agent/agent.py`.

**2. (Real interop-relevant behaviour, now in the plan's caveats) `a2a-sdk`'s `ClientFactory`
defaults to JSON-RPC only.** An empty `ClientConfig.supported_protocol_bindings` means
"JSON-RPC", not "any". Since `ballerina/a2a` speaks only HTTP+JSON, a Python caller must
opt in with `supported_protocol_bindings=[TransportProtocol.HTTP_JSON]` or it will try to
call our listener's non-existent JSON-RPC endpoint. This confirms, with a real client, the
binding-coverage caveat already recorded below.

**3. `send_message` always returns a raw stream of `StreamResponse`, even for a "blocking"
send -- there is no separate call that hands back one merged `Task`.** The caller merges
the initial `Task` snapshot with the `TaskStatusUpdateEvent`/`TaskArtifactUpdateEvent` that
follow, tracking by `task_id`, itself. This is not a bug in either implementation -- it's
the same raw-stream shape our own client's `sendStreamingMessage` has, and our
`sendMessage`'s merging is a convenience `a2a-sdk`'s `send_message` does not give for free.
Fixed in `python-client/driver.py`. **Consequence for the plan:** any interop test written
against `a2a-sdk`'s `send_message` needs this merge loop; a driver that only reads
`response.task` will silently see a SUBMITTED/WORKING snapshot from the first chunk and
never the final state, which is exactly the bug the unfixed driver had.

**4. Error-reason round trip confirmed, both directions.** Our server's `google.rpc.Status`
`ErrorInfo.reason` values (`TASK_NOT_FOUND`, `TASK_NOT_CANCELABLE`) are recognised by the
*reference* Python client and raised as its own typed exceptions
(`a2a.utils.errors.TaskNotFoundError`/`TaskNotCancelableError`), not a generic HTTP failure.
This is the strongest evidence so far that the error-handling side of the spec is genuinely
interoperable, not just internally consistent.

**5. (Real finding, ours to decide) `ballerina/a2a`'s client cannot reach the real Java
reference server without a config override.** `ballerina/http`'s `ClientConfiguration.httpVersion`
defaults to `HTTP_2_0`; over plain HTTP that means attempting HTTP/2 with prior knowledge
(h2c). Quarkus/Vert.x's default HTTP listener does not support h2c and answers with a bare
400 *before the request reaches the A2A routing layer at all* -- confirmed by checking the
Java server's own log: zero entries for the rejected requests, versus a normal request/response
log line for every request that used HTTP/1.1. Isolated with a minimal `http:Client` probe
(no `ballerina/a2a` involved) to rule out anything in this library's own code, then confirmed
the fix: `clientConfig = {httpVersion: http:HTTP_1_1}` on both the card-resolution step and the
`HttpClient` construction (one `clientConfig` covers both when constructing `HttpClient` from
a URL string directly, since it threads the same config into its own internal card resolution).

This did **not** surface against the Python agent (`uvicorn` tolerates the same h2c-first
request), which is exactly why testing against a second real reference implementation mattered
-- a single-SDK interop pass would have missed it entirely. Open question for the user: keep
this as a documented `clientConfig` workaround, or have `ballerina/a2a`'s `HttpClient` default
to HTTP/1.1 itself, since h2c-cleartext is a niche server opt-in almost nothing enables.

**6. (Their bug, evidenced not assumed) The real `a2a-java` reference client throws after a
streaming exchange completes successfully.** Sending a message via the Java client's streaming
path against our listener: the client receives a `TaskEvent` and three `TaskUpdateEvent`s
correctly, then throws `java.io.IOException: Stream 1 cancelled` from its own
`AbstractSSEEventListener.handleEvent`, surfaced to the caller as `"Failed to get response"`.
Checked directly with `GET /tasks` on our listener afterward: the task is `TASK_STATE_COMPLETED`.
So the exchange succeeded end to end; the client's own HTTP/2 stream teardown after the last
event throws in a way its own high-level API treats as failure. Nothing on our side logged an
error for the request. Recorded as a finding about the reference client, not something to fix
in `ballerina/a2a`.

## What this covers, and what it doesn't

- Confirms the highest-value slice of Part 1: card discovery, blocking send with an
  artifact, task-not-found, task-not-cancelable, and raw bytes -- against a **real** SDK
  client and a **real** SDK server, both built on the actual `a2a-sdk` 1.1.5 API (not a
  stand-in). This is the first evidence of that kind for this library.
- Not yet run: I4 (returnImmediately + poll), I5 (ListTasks filters), I9 (subscribe to an
  already-running task specifically), I10 (multi-turn continuation), I12 (push
  notifications), I13 (long silent stream / keep-alives), I14 (tenancy), I15
  (malformed/wrong-media-type bodies), and X-A2/X-A4 (the Java side of the auth grid).
- `python-agent/agent.py` covers a subset of the `tck-sut` contract (echo, completed+artifact,
  input-required, fail, immediate-complete, cancelable, raw bytes) -- enough for this pass,
  not the full grid yet.
