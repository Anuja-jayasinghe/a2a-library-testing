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

## Remaining Part 1 scenarios, both directions (`interop/run_extended.sh`)

| Scenario | A: our client -> real Python agent | C: real Python client -> our listener |
|---|---|---|
| I4 `returnImmediately` + poll | PASS | PASS |
| I5 `ListTasks` (`pageSize`) | PASS | PASS |
| I9 subscribe to a running task | PASS | PASS |
| I10 multi-turn continuation (same task id) | PASS | PASS |
| I12 push notification delivered as `{"task": ...}` | PASS | PASS |
| I13 keep-alive comment frames tolerated by a real SSE parser | n/a (our own parser skips them) | PASS (4s silence, 0.5s keep-alive) |
| I14 tenancy: unknown tenant prefix | Python agent accepts it (no validation) | PASS after fix (400; was 500, Finding 7) |
| I15 malformed body is a 4xx | PASS (400) | PASS (400) |

## Auth grid, Java side

| Case | Result |
|---|---|
| X-A2: real `a2a-java` client, its own `AuthInterceptor`, valid token -> our listener | PASS |
| X-A2: no credential in the store | PASS -- rejected |
| X-A2: forged signature | PASS -- rejected |
| X-A4: our client -> a Java agent requiring auth | **NOT RUN, blocked**: the only Java security example (`a2a-samples/.../magic_8_ball_security`) needs Keycloak (Docker Dev Services) and an LLM API key; the `helloworld` server has no security extension. Needs either a Docker-capable environment or a hand-built Quarkus security config. |

## Client operations, production-shaped auth, and TLS (`interop/run_client_checks.sh`)

**Client operations vs the real Python agent: 21 of 21 pass.** Streaming send (initial Task, artifact, COMPLETED,
stream ends), the four push-config operations (create keeps the caller's id, get, list, delete, get-after-delete is an
error), cancelling a *running* task, `getExtendedAgentCard`, `listTasks` filters (`contextId`, `status`, `pageToken`,
`includeArtifacts`), an artifact streamed in chunks (`append`/`lastChunk` decoded; a blocking send returns the merged
parts), and typed errors decoded from a **real server's** bodies (`PushNotificationNotSupportedError`,
`ExtendedAgentCardNotConfiguredError`).

**OAuth2 client_credentials + JWKS, against a local issuer (`oidc-provider/`, RS256, 4s tokens):**

| Case | This client | Real Python client |
|---|---|---|
| Token acquired from the issuer, validated by the listener via JWKS | PASS | PASS |
| Cached token reused (no second token issued) | PASS | n/a |
| Token expires; a fresh one is fetched; call still succeeds | PASS | n/a |
| Same token replayed after expiry | n/a | PASS (401) |
| `a2a:read`-only token vs a listener requiring `a2a:invoke` | PASS (`AuthorizationError`) | PASS (403) |
| No credential / garbage token | PASS (`AuthenticationError`) | PASS (401) |
| Issuer rotates its signing key; listener accepts a token signed with the new key | PASS | n/a |
| Refused or unreachable token endpoint is a *returned* `a2a:Error` | **FAIL -- panic** (Finding 10) | n/a |

**TLS / mutual TLS:** trusted CA works; untrusted certificate is a returned error; mutual TLS accepts a valid client
certificate and refuses none, and a send over mutual TLS works. **But** Finding 11.

## LLM-backed (Claude) checks (`interop/run_llm_checks.sh`, spends API tokens)

Everything above used deterministic agents. With the API key restored, the same library was exercised with real
Claude-backed agents (`ballerina/ai` `Agent`, Haiku 4.5): the Trip Planner and Packing Assistant as A2A servers,
and the Traveler (an `ai:Agent` with `ai:A2aToolKit`) as the client. Assertions are on protocol behaviour (task
counts, states, identity), never the model's wording. **Each scenario was run once, except the regression, which
was run four times; this is evidence, not statistics.**

| Check | Result |
|---|---|
| Real Python `a2a-sdk` client -> LLM-backed Trip Planner, two turns (no city -> `INPUT_REQUIRED`, then "Milan") | PASS: same task id, `COMPLETED`, itinerary mentions Milan, exactly 1 task on the server |
| **The original Milan regression** through the Traveler chat (the toolkit continuation returned a stale `INPUT_REQUIRED`, the model retried, and duplicate tasks appeared) | **PASS, 4 of 4 runs: exactly 1 new task each, `COMPLETED`, no retry loop** |
| Two agents in one turn (Trip Planner + Packing Assistant) | PASS: 1 new task on each |
| Cancel a task that already finished, via the model | PASS: the `TaskNotCancelable` error reached the model, which reported "the cancellation did not work" and why, rather than claiming success |
| A ~40s task: the toolkit waits at most 20s, so the model must follow up | PASS: completed at 52s, 1 task, model reported the final result |
| Trip Planner behind a JWT, Traveler with **no** credential | PASS: an authentication error reached the model, which reported it and **did not invent an itinerary** |
| Same, with the credential passed as the toolkit's `secret` | PASS: 1 task, itinerary returned; the token does not appear in the printed conversation (weak evidence: the model-facing tool traffic is not logged) |

To do the last two, the demo gained two optional settings (default behaviour unchanged): `server` `authSecret`
(JWT-protect the listener) and `client` `tripPlannerSecret` (the credential given to the toolkit).

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

**7. (FIXED in `module-ballerina-a2a` `c37f89e`) Caller mistakes were answered with 5xx.**
Found by I14, confirmed against the source (`dispatcher.bal`, `stripTenant` and the fall-through):

| Request to our listener | Status | Reason |
|---|---|---|
| `GET /acme-corp/tasks` (a tenant the card does not declare) | **500** | `INVALID_AGENT_RESPONSE` |
| `GET /nope` (a path that is no A2A operation at all) | **500** | `INTERNAL_ERROR` |

**What the spec says (live spec + `a2a.proto`, checked):** nothing about either case.
- The only 404 rule is for *resources* (3.3.2 "Resource Errors": a task or config that does not
  exist; 5.4 maps `TaskNotFoundError` to 404). Nothing addresses an unknown route.
- The `/{tenant}` path prefix appears only as `additional_bindings` in the proto, never in the spec
  prose. The only tenant rule is client-side (section 8.3: set `tenant` to the card's value).
  What a server does with a different one is unspecified.
- What the spec does define is the *category*: 5xx is for system failures (3.3.2 "System Errors")
  and for `InvalidAgentResponseError` -- "an agent returned a response that does not conform"
  (section 3.3.2 error list; 5.4 maps it to 500). A caller's own mistake is neither.
  Validation Errors are 400 (3.3.2), and Resource Errors 404, so either 4xx is defensible.

So the defect is that a caller's mistake is reported as a server fault, not that a specific status
is missing. That has practical cost: clients and gateways treat 5xx as retryable and alert on it.
Ecosystem reference points (not spec): Quarkus and FastAPI answer 404 for an unknown path; the
Python agent accepts any tenant prefix.

Proposed: **404** for an unknown path (ordinary HTTP), **400** for an unserved tenant (the spec
treats `tenant` as a request field, and 400 is its validation category). Both are design choices
within what the spec allows.

**Fixed** as proposed, following the library's existing `invalidRequest` pattern (an `InternalError`
carrying a JSON-RPC code): unknown path -> 404 `METHOD_NOT_FOUND` (-32601, which the client already
decodes, and which matches the Python SDK's REST client mapping a 404 to its `MethodNotFoundError`);
unserved tenant -> 400 `INVALID_PARAMS` (-32602). Verified: 407 unit tests, which fail with either half of
the fix reverted; TCK default mode unchanged (88 passed / 4 failed); the real Python client's
`driver_extended.py` now passes I14 (`OVERALL: PASS`).

Two things learned while fixing it:
- The dispatcher already built `InternalError(code = 404)` for the unknown path; `errorBindingFor`
  only read -32600/-32602, so the intent was silently dropped. The library's own comment called it a
  "404-shaped InternalError".
- A `Listener` **cannot serve a tenant at all**: `deriveServedCard` always replaces `supportedInterfaces`
  with a single tenant-less entry, so `declaredTenant` is always `()` and every tenant-prefixed request is
  refused. The `/{tenant}` bindings in the proto are therefore unreachable through the public API. That is a
  separate, larger gap (server-side multi-tenancy), not addressed here.
- Left as is: a *known* path with the wrong method (`POST /tasks/x`) is now 404 like any unmatched path;
  405 would be more precise. Also `PUT` never reaches the dispatcher at all (the HTTP layer answers 405).

**8. (Positive) A third implementation parses our card's security declaration.** The real
`a2a-java` client read the derived `securitySchemes` (`[bearerAuth]`) off our listener and its own
`AuthInterceptor` attached the token, alongside the Python SDK (Finding 4's counterpart). Together with
the Python protobuf parser rejecting the old flat shape and accepting the new one, the wire fix in
`module-ballerina-a2a` `8288592` now has two independent confirmations.

**9. (Test-harness lessons, not library bugs -- each cost a wrong first result)**
- `bal run` with a `main()` starts module-level listeners only *after* `main()` returns, so a receiver
  declared in the same program is never reachable during the test (minimal repro: unreachable at t=1s,
  reachable at t=7s after `main` ended). Push receivers now run as separate processes.
- `message:stream` deliberately stays open on `INPUT_REQUIRED`/`AUTH_REQUIRED` (`sse.bal`, design 8.1);
  a client that waits for EOF there hangs. Correct behaviour; harness must stop on the state.
- A continuation's opening `Task` snapshot is still `INPUT_REQUIRED` -- it must not end the wait.
- `returnImmediately` on a *streaming* send still delivers the whole stream to a caller who drains it;
  to observe the task before it finishes, take only the first event.

**10. (Defect, escapes `a2a:HttpClient`'s contract) A refused or unreachable OAuth2 token endpoint makes client
construction *panic*.** `ballerina/oauth2` fetches the first token while the client is being built, and
`ClientOAuth2Handler.init` has no error return, so a failure (wrong client secret, issuer down) is a panic, not a
returned error. Isolated with `trap`: a plain `http:Client` panics too, and so does `a2a:HttpClient`, whose `init`
documents a typed `Error?` and whose README says no operation returns a bare error. The cause is in `ballerina/http` +
`ballerina/oauth2`, but this library can contain it (`trap` around the `http:Client` creation in `HttpClient.init` and
in card resolution). Practically: a mistyped client secret or an issuer outage at start-up crashes the caller instead
of being handled. Token *refresh* failures later are returned errors, not panics.

**11. (Defect, breaks HTTPS) A `Listener` served over TLS advertises an `http://` interface URL.**
`dispatcher.bal:173` builds the URL as `http://${Host}`, so a listener configured with `secureSocket` hands out a card
pointing clients at plain HTTP on a TLS port. Impact, verified: a client built from `https://host` follows the card
and fails ("Remote host closed the connection"); correcting the scheme by hand makes TLS work end to end, so the
transport is fine. Spec 7.1 says production deployments MUST use HTTPS. The same code is also wrong behind a
TLS-terminating proxy (the `Host` header and scheme are the internal ones), and there is no way to configure the
public URL. Proposed: derive `https` when `secureSocket` is configured, plus an explicit public-URL setting for
proxies and pre-built `http:Listener`s.

**12. (Context that changes how to read earlier results) The current Java reference server rejects
`application/a2a+json` with 415.** Checked directly against the freshly built `a2a-java` server: `POST /message:send`
with `Content-Type: application/a2a+json` is **415**, with `application/json` it is **200**. So pair B passed only
because this client's content-type fallback retried with `application/json`. The fallback is essential for
reaching the Java reference implementation, not a legacy leftover. (The live spec's own media type is
`application/a2a+json`; this is the Java server disagreeing with it.)

## What this covers, and what it doesn't

- Confirms the highest-value slice of Part 1: card discovery, blocking send with an
  artifact, task-not-found, task-not-cancelable, and raw bytes -- against a **real** SDK
  client and a **real** SDK server, both built on the actual `a2a-sdk` 1.1.5 API (not a
  stand-in). This is the first evidence of that kind for this library.
- Still not covered: `ListTasks` `historyLength`/`statusTimestampAfter`; the Java side of streaming/push/multi-turn
  (pair D exercised only card discovery and one streaming send; pair B only `sendMessage`/`getTask` because the
  hello-world agent has no tasks); a 70s+ silent stream against a foreign parser; `A2A-Extensions`; the remaining
  typed errors (`UnsupportedOperation`, `ContentTypeNotSupported`, `VersionNotSupported`, `ExtensionSupportRequired`);
  stream reconnection; a real identity provider (Keycloak/Auth0) rather than the local issuer; authorization-code
  and OIDC-discovery flows; the in-task `AUTH_REQUIRED` flow; agent-to-agent identity propagation; **X-A4**
  (blocked); and (now that the key is back) LLM behaviour beyond the scenarios above: streaming/push tools driven by the model,
  larger models, and repeated runs of the non-regression scenarios.
- `python-agent/agent.py` covers a subset of the `tck-sut` contract (echo, completed+artifact,
  input-required, fail, immediate-complete, cancelable, raw bytes) -- enough for this pass,
  not the full grid yet.
