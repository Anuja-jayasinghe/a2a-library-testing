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

## Typed errors, extensions, negotiation and reconnection, against real servers (`interop/run_more_checks.sh`)

| Check | Result |
|---|---|
| `VersionNotSupportedError` decoded from a **real** `VERSION_NOT_SUPPORTED` (client sends `A2A-Version: 2.0`) | PASS against both the Python and the Java reference servers |
| `UnsupportedOperationError` raised by a real server: `sendStreamingMessage` and `subscribeToTask` against a server that withholds streaming | PASS (the client was made to believe streaming existed, so the *server* is what refused) |
| Subscribing to an already-finished task on the Python server | PASS as a client check (decoded faithfully); **the server deviates from the spec**, Finding 13 |
| `A2A-Extensions` header: two requested extensions arrive intact at a real server; none requested -> none arrive | PASS |
| An extension the Java server does not know | PASS: ignored, no error |
| Java server rejects `application/a2a+json` (415): first call falls back, later calls keep working | PASS |
| A *required* extension, from the real Python client: refused without it (its own `ExtensionSupportRequiredError`), accepted with it | PASS |
| Opt-in stream reconnection: a proxy cuts the first stream after 3s of a ~6s task | PASS: `maxReconnectAttempts = 0` does not reach `COMPLETED`; with `2` the client resubscribes and does |

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

**6. (Their bug, since FIXED upstream; re-verified live 2026-09-29) The real `a2a-java` reference client threw after a
streaming exchange completed successfully.** Against our listener the client received a `TaskEvent` and three
`TaskUpdateEvent`s, then threw `java.io.IOException: Stream 1 cancelled` from `AbstractSSEEventListener.handleEvent`
(surfaced as "Failed to get response"), although the task was `TASK_STATE_COMPLETED` on our side. Fixed upstream by
`c2577629` "fix(client): deliver exactly one terminal SSE callback (#1170) (#1173)", merged 2026-09-24. **Re-run on
`a2a-java` `ad9571c9` (68 commits newer, rebuilt):** `java-client-stream/StreamDriver.java` gets the same 4 events, **0
error callbacks and exactly one normal-completion callback**. Note the new contract: the stream's error handler is now
called with a **`null` Throwable** on normal completion, so a handler that dereferences its argument (as the stock
`HelloWorldClient` does) will NPE, and that sample also hangs against any task-producing agent because it only completes
on a `Message` reply. Neither is a `ballerina/a2a` issue. Nothing to fix on our side.

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
**Fixed** in `module-ballerina-a2a` `9a90e33`: both places that build an `http:Client` from the caller's configuration go through a trapped constructor, and the caller gets an `InternalError` naming the agent URL and carrying the token endpoint's message. `bal-client-oidc`'s two contract checks (refused secret, unreachable endpoint) now pass. A `bal build` of a rig reports UP-TO-DATE when only the *local dependency* changed, so a rig must have its `target/` removed to see a republished library.

**11. (Defect, breaks HTTPS) A `Listener` served over TLS advertises an `http://` interface URL.**
`dispatcher.bal:173` builds the URL as `http://${Host}`, so a listener configured with `secureSocket` hands out a card
pointing clients at plain HTTP on a TLS port. Impact, verified: a client built from `https://host` follows the card
and fails ("Remote host closed the connection"); correcting the scheme by hand makes TLS work end to end, so the
transport is fine. Spec 7.1 says production deployments MUST use HTTPS. The same code is also wrong behind a
TLS-terminating proxy (the `Host` header and scheme are the internal ones), and there is no way to configure the
public URL. Proposed: derive `https` when `secureSocket` is configured, plus an explicit public-URL setting for
proxies and pre-built `http:Listener`s.
**Fixed** in `module-ballerina-a2a` `94b0212`: the scheme comes from the HTTP listener itself (`getConfig().secureSocket`), so it is right for a port and for a listener passed in, and `ListenerConfiguration.publicUrl` is served verbatim for proxies and gateways (validated; `X-Forwarded-*` deliberately ignored). The TLS rig now passes without the by-hand URL correction, and a `publicUrl` listener (9616) serves the configured address.

**12. (Was a Java reference-server bug, since FIXED upstream; re-verified live 2026-09-29) The Java reference server
rejected `application/a2a+json` with 415.** Fixed by `c78c472f` "fix(rest): support application/a2a+json content type"
(2026-09-25). On `a2a-java` `ad9571c9`, `POST /message:send` returns **200 for both `application/a2a+json` and
`application/json`**. This client's content-type fallback is therefore no longer needed for current Java `main`, but is
still needed for older builds, so it stays. (`run_more_checks.sh`'s fallback check now passes without exercising the
fallback against current Java; it only guards older builds.)

**13. (Deviation by the Python reference server) Subscribing to a finished task is `400 INVALID_PARAMS`.**
Spec 3.1.6 lists `UnsupportedOperationError` for "the operation is attempted on a task that is in a terminal
state". `a2a-sdk` 1.1.5's REST server answers `400`, reason `INVALID_PARAMS`, message "Task ... is in terminal
state: 3". This library's `Listener` follows the spec (`UnsupportedOperationError`), and this client decodes what
each server actually sends. Worth reporting upstream.
**Fixed upstream in `a2a-sdk` 1.2.0** (verified live 2026-09-30): the same request now gets `400`, `"status": "FAILED_PRECONDITION"`,
reason `UNSUPPORTED_OPERATION`. `run_more_checks.sh`'s check that asserts the old `INVALID_PARAMS` now fails against 1.2.0 for that reason.

**14. (Reference servers agree with each other and with this library, except on the content-type status.)**
Both real servers answer `400 VERSION_NOT_SUPPORTED` for `A2A-Version: 2.0`, for `0.3`, and for an absent header,
matching this listener. Neither rejects an unknown `A2A-Extensions` URI. For a wrong `Content-Type`, Java answers
**415** with reason `CONTENT_TYPE_NOT_SUPPORTED` (the live spec's table says 400; the TCK also expects 415), while
Python accepts `text/plain` outright. The client decodes by reason, so both decode correctly.

**15. (Test-rig lessons, each of which had produced a *vacuous* pass)** A proxy meant to cut a stream cut nothing, and
the "reconnection works" run passed anyway: (a) the client reuses one keep-alive connection for the card `GET` and the
stream `POST`, so inspecting only a connection's first request missed the `POST`; (b) the agent's card advertises its
own address, so the client bypassed the proxy after fetching the card; (c) under HTTP/2 the request line is not
visible to a byte-level proxy. The `attempts = 0` run *failed its own check* and exposed it. The runner now also
verifies that the proxy really cut the stream, so a result that did not exercise the fault cannot pass silently.

**16. (Real IdP, positive) Keycloak-issued credentials work end to end, and the listener refuses the two shapes
that matter.** `interop/run_idp_checks.sh` runs against Keycloak 26 in Docker (`interop/keycloak/`). Service-account
tokens and *user* tokens from a scripted authorization-code + PKCE login are admitted by the listener (issuer,
audience `a2a`, scope `a2a:invoke`, RS256 via the realm's JWKS); a read-only scope is 403; a valid token for another
audience is 401; **a token with a valid signature, audience and scope but no `sub` is 401** (admitting it would put
every such caller in one shared owner scope). The agent's identity for a caller is the token's `sub`, so two users
cannot read, list or cancel each other's tasks (TaskNotFound, no leak), including a task paused in `AUTH_REQUIRED`.
The card's `openIdConnect` scheme and its scope requirement are parsed by the reference Python SDK and by this
library's client, and the advertised discovery URL is a live OIDC document whose `issuer` matches the tokens accepted.
The Ballerina client refreshes a user's access token with `ballerina/oauth2`'s refresh-token grant; an expired token
alone is refused (401), so the refresh is what kept the calls working. *Rig lessons:* a Keycloak realm import that
lists `clientScopes` silently drops the built-in `basic` scope, which is what supplies `sub`; and Keycloak marks its
session cookies `Secure` on plain-HTTP localhost, which Python's cookie jar will not send back.

**17. (Operational, `ballerina/jwt` behaviour reached through `a2a:Listener`) The IdP is asked for its keys on every
request, and the cache does not do what it suggests.** `driver_jwks.py`, with a counting proxy in front of Keycloak:
without `jwksConfig.cacheConfig` (the default), 20 authenticated requests cause **20 JWKS fetches**. With a cache,
requests for keys present at startup cost none, but `ballerina/jwt` writes the cache **only once, at startup**
(`preloadJwksToCache`); a key fetched after a miss is never stored. So a key rotated in later costs a fetch on every
request from then on (10 requests -> 10 fetches), and once `defaultMaxAge` passes the whole cache is gone and never
refilled (10 requests -> 10 fetches). Consequence for production: latency and load on the IdP per call, and while
the IdP is unreachable a caller with a perfectly valid token gets **401** (which invites clients to discard and refresh
a good credential), unless its key happens to still be in the startup cache. Key rotation itself is handled (a new
`kid` is fetched on the miss) and a withdrawn key is refused once it is no longer cached.

**18. (Defect, same class as finding 10) An IdP that is down at startup panics out of `a2a:Listener`'s init when a
JWKS cache is configured.** `ballerina/jwt` does `panic` when it cannot preload the JWKS; the trace runs through
`ballerina.a2a.0.Listener:init` (`listener.bal:215` -> `AuthEntry:init` -> `ListenerJwtAuthHandler:init`) and the
process exits 1. `Listener.init` documents typed errors for bad `auth` config; this one is not returned. Together
with finding 10 (OAuth2 token failure at `HttpClient` construction) the pattern is: any `ballerina/http`/`jwt`/`oauth2`
handler whose constructor can panic needs a `trap` at the library boundary. The fix is small and local.
**Fixed** in `module-ballerina-a2a` `760d53f`: each handler is built under `trap`, and `Listener.init` returns an `InternalError` naming the entry (`ListenerConfiguration.auth[0] (jwtValidatorConfig) could not be initialised: ...`), before the HTTP listener is created. `driver_jwks.py` J4 now asserts this instead of recording the panic. The same applies to an unreachable LDAP server. Not changed, because it is upstream: `ballerina/jwt`'s cache is filled only at startup (17), documented in the README (`527b331`).

**19. (Gap, not a spec violation) There is no way for an agent to act *as the caller* when it calls another agent.**
Chain user -> A -> B: A sees the user (`context.owner` is the user's `sub`); B sees **A's own service identity**, not the
user. `RequestContext` carries only the derived `owner` string, not the token or its claims, so a handler cannot
forward the caller's credential or perform an RFC 8693 token exchange; the only options are calling as a service or
hand-carrying the identity in the message, which B cannot verify. The spec does not define delegation, so this is a
capability gap for multi-agent deployments rather than a defect. Recorded here so the decision (expose the verified
claims/token on `RequestContext`, or document the service-identity model) is made deliberately.

**20. (Positive) In-task `AUTH_REQUIRED` (spec 7.6) works in both directions.** Our listener pauses a task in
`AUTH_REQUIRED` with a status message; the real Python client sees it (blocking `GetTask` reports it, the credential
sent on the same task id completes it, another user cannot continue it, and it can be canceled). The reverse holds:
this client surfaces a Python-SDK agent's `AUTH_REQUIRED` as a `Task` in that state, decodes its status message,
continues it, cancels a paused one, and also receives the transition as an event on the streaming operation.
*Harness note:* `a2a-sdk`'s `TaskNotFoundError` is not an `A2AClientError`; a driver that catches only the latter
misses it.

## Session of 2026-09-29: fresh re-run on current code, plus a third language (Node, `@a2a-js/sdk` 1.2.1)

Library: `module-ballerina-a2a` `feat/http-json-listener` @ `c167fe3`, republished locally. Java reference rebuilt from
`a2a-java` `ad9571c9`. Everything below is a live run from this session.

**Re-run of the existing grid (no regressions):** pair A/C (Python) PASS; `run_extended.sh` PASS (I4, I5, I9, I10, I12,
I13, I14, I15); `run_client_checks.sh` all sections `OVERALL: PASS` (client ops, OAuth2/JWKS, TLS/mTLS); `run_pair_x_a.sh`
PASS; `run_more_checks.sh` PASS (version/extension/streaming errors, reconnection); pair B (our client -> current Java
server) PASS; pair D via `StreamDriver` PASS (Finding 6 gone). TCK: **88 passed / 4 failed, unchanged** (checkout is 11
commits behind `origin/main`).

**New: Node agent, `interop/node-agent/agent.mjs`** (`@a2a-js/sdk` 1.2.1, `restHandler` only, A2A v1.0; the SDK's
`A2A_PROTOCOL_VERSION` is `"1.0"`, with a separate `compat/v0_3` layer left disabled). Run with `run_node_checks.sh`.

| Scenario | N-A: our client -> Node agent | N-C: Node client -> our listener |
|---|---|---|
| Card discovery / HTTP+JSON v1.0 negotiation | PASS | PASS |
| Blocking send -> COMPLETED Task + artifact; direct Message reply | PASS | PASS (Task) |
| Streaming send (Task, artifact, COMPLETED, EOF) | PASS | PASS |
| Multi-turn INPUT_REQUIRED -> same task id -> COMPLETED | PASS | PASS |
| `returnImmediately`, then subscribe / cancel a **running** task | PASS (cancel -> CANCELED) | PASS (subscribe to COMPLETED) |
| Typed errors: TaskNotFound, TaskNotCancelable | PASS | PASS |
| `getTask` `historyLength` (0, 1) | PASS | PASS |
| `ListTasks`: `pageSize`+`pageToken`, `status`, **`historyLength`, `statusTimestampAfter`** (previously unrun) | PASS | PASS |
| Push config create/list/delete | PASS | PASS |
| Push webhook delivery as a `StreamResponse` envelope | not run (the Node agent's sender was not exercised) | PASS |
| 75s stream silent except 15s keep-alives, read by Node's undici SSE parser (previously only Python) | n/a | PASS (75.1s) |

**Claude-backed re-run (2026-09-30, Haiku 4.5):** with the key loaded (`load_env.sh`), the Node agent (`node agent on ... (Claude claude-haiku-4-5-20251001)`) and the Go agent (`go agent on ... (Claude ...)`) answered with real model output (`[claude] 2 + 2 = 4`) and the same results as the stub runs: Node 43 PASS, `OVERALL: PASS` both directions; Go 38 PASS with only the three known failures (findings 24, 25). Zero `[stub]` replies in either log. Assertions are on protocol behaviour, never wording. `run_llm_checks.sh` (Ballerina `ai:Agent` Trip Planner, two-turn Python client) also passed; it needs `interop/python-agent/.venv` created first (`uv venv .venv && uv pip install -r requirements.txt`) and the `.env` exported (`set -a; . ../.env`).

### Go: `a2a-go` v2.6.0 (`interop/go-agent`, run with `run_go_checks.sh`)

`a2a-go` module `github.com/a2aproject/a2a-go/v2` v2.6.0 (`a2a.Version == "1.0"`); server via `a2asrv.NewRESTHandler`, client
via `a2aclient.WithRESTTransport` with defaults disabled (REST only). Same behaviour contract as the Node agent; `bal-client-node`
is reused against it. As with Node, the Claude-backed mode was not run (no key yet), so these used the `[stub]` responder.

| Scenario | G-A: our client -> Go agent | G-C: Go client -> our listener |
|---|---|---|
| Card discovery / REST negotiation | PASS | PASS |
| Blocking send (Task+artifact), direct Message | PASS | PASS (Task) |
| Streaming send | PASS | PASS |
| Multi-turn INPUT_REQUIRED -> COMPLETED, same task id | PASS | PASS |
| `returnImmediately`, subscribe / cancel a running task | PASS (CANCELED) | PASS (subscribe) |
| Typed errors TaskNotFound / TaskNotCancelable | PASS | **FAIL, finding 25** |
| `getTask` `historyLength` | PASS | PASS |
| `ListTasks` pageSize, status, `historyLength`, `statusTimestampAfter` (past) | PASS | PASS |
| `ListTasks` `statusTimestampAfter` (future, empty result) | **FAIL, finding 24** | PASS |
| Push config CRUD; push webhook delivery | PASS; n/a | PASS; PASS |

Harness notes: a2a-go scopes `ListTasks` to an authenticated owner, so the agent installs a `CallInterceptor` that sets a fixed user
(without it `ListTasks` is `unauthenticated`); the Go client joins paths with `url.JoinPath`, so it copes with a trailing-slash card URL
that broke ours (finding 21).

**24. (Their deviation; our client is stricter than proto3 JSON allows) The Go server encodes an empty `ListTasks` result as
`"tasks":null`.** Seen with `curl` (`{"tasks":null,"totalSize":0,...}`), from Go's nil slice under a non-`omitempty` tag. Our
`HttpClient.listTasks` then fails with `ListTasks response did not match the expected shape: ConversionError`. The spec models `tasks`
as a repeated (always-present) field, so the Go output is sloppy, but proto3 JSON says `null` means the field default, and the Node SDK's
decoder accepts it. A client that talks to more than one SDK should treat `null` for a repeated field as empty. **Fixed**
(`module-ballerina-a2a@26e37f7`, stale here since): `HttpClient.listTasks` now normalizes `"tasks": null` to `[]` before decoding.
Covered by `testRestClientTreatsNullTasksAsEmpty`; verified with a mutation check and a live TCK rerun at the time.

**25. (Verified 2026-09-30; a2a-go client bug against a SHOULD-level spec media type) The Go client turns every error from our
listener into a generic `server error`.** `a2a-go` v2.6.0 (`main` was identical) `internal/rest/rest.go` `FromRESTError` returns
`a2a.ErrServerError` unless `Content-Type` starts with `application/json`. **Spec:** section 11.1 says `application/a2a+json` "SHOULD be
used for requests and responses" (SHOULD, not MUST), and section 11.6's own 404 TASK_NOT_FOUND example is served as `application/a2a+json`;
so our listener is doing what the spec's example shows, and `application/json` servers remain legitimate. (The spec is internally
inconsistent elsewhere: section 6 examples use `application/problem+json` and a different body.) **Reproduced in isolation**
(`go-agent/repro_ct`, a bare `httptest` server, header is the only variable): `application/json` and `application/json; charset=utf-8` ->
`ErrTaskNotFound`; `application/a2a+json` and `application/problem+json` -> `server error`. Success responses and requests are unaffected
(the Go server accepts `a2a+json` and any other request type). No existing upstream issue or PR covers it (searched `a2aproject/a2a-go`).
**Fix prototyped**, local branch `fix/rest-error-json-suffix` in `~/gitProject/a2a-go` (not pushed): `mime.ParseMediaType`, accept
`application/json` and `application/a2a+json`; two new table cases in `TestFromRESTErrorEdgeCases` fail without it and pass with it,
`internal/rest`, `a2aclient`, `a2asrv`, `a2acompat` suites pass; the patched client passes the two typed-error checks against our listener
(stock v2.6.0: 2 FAIL). Draft issue text: `go-agent/UPSTREAM_ISSUE_DRAFT.md`. Their CONTRIBUTING asks for an issue before a PR. **Filed 2026-09-30:** issue https://github.com/a2aproject/a2a-go/issues/447, draft PR https://github.com/a2aproject/a2a-go/pull/448. The listener-side alternative (answer `application/json` when `Accept` lists only that) is not needed if this is fixed upstream.

**21. (Defect, ours; found by the Node agent) `HttpClient` builds `//message:send` when the card's interface URL ends in
`/`, and the server answers 404.** `@a2a-js/sdk` advertises `http://localhost:9800/` for a root-mounted agent. Every
operation from `a2a:HttpClient` then failed with `REST request failed with HTTP 404` (`curl` confirms `//message:send` is
404, `/message:send` is 200). The reference `@a2a-js/sdk` client, given the same card, works. `http_client.bal` passes
the URL straight to `http:Client` and appends paths that start with `/`. A root-mounted agent is the common case, so this
would hit real users. Proposed fix: strip trailing `/` from the interface URL when building the client. Workaround used
in the rig: `TRAILING_SLASH=0`. **Fixed** (`module-ballerina-a2a@26e37f7`, stale here since): as a new commit, reusing
`discovery.bal`'s existing `stripTrailingSlash`. Covered by `testRestClientStripsTrailingSlashFromInterfaceUrl`.

**22. (Defect, ours; root cause of a "pre-existing" TCK failure) `message:send` ignores `configuration.historyLength`.**
TCK `CORE-HIST-003` ("SendMessage with historyLength=0 returned 2 history message(s), expected none") has failed since
the 88/4 baseline. Reproduced without the TCK: `POST /message:send` with `configuration.historyLength: 0` returns
`history` of length 1 from our listener and no `history` key from the Node agent; `historyLength: 1` returns 1 from both.
Spec 3.2.4: "0: No history should be returned; the `history` field SHOULD be omitted". In the library, only `getTask`
(`default_handler.bal:692`) and `listTasks` (`task_store.bal:284`) trim history; `sendMessage` never reads
`configuration.historyLength`. **Fixed** (`module-ballerina-a2a@26e37f7`, stale here since): `sendMessage`'s
driven-synchronously return, its `returnImmediately` early return, and the one `Task` snapshot `sendStreamingMessage`
broadcasts live now all honor it (the last via a new `TaskUpdater` constructor parameter, applied only to that
broadcast, not `self.base`). `getTask`'s own inline trim was also replaced with the `projectTask` helper `listTasks`
already used. Confirmed live against a real Node (`@a2a-js/sdk`) client and by a TCK rerun: `CORE-HIST-003` gone.
That leaves 3 of the 4 TCK failures (still true today): `CARD-CACHE-003` (optional
`Last-Modified` on the card), and `HTTP_JSON-ERR-001` / `HTTP_JSON-SVC-001` (the TCK's stale snapshot expects
`application/json`; our `application/a2a+json` matches the live spec and is now accepted by current Java too).

**23. (Positive) The Node SDK's REST server and client interoperate with this library in both directions with no
config workarounds** other than the trailing-slash issue (21); `ListTasks` `historyLength`/`statusTimestampAfter`, listed as
untested, now pass against two independent implementations' worth of semantics (Node server via our client, our server
via the Node client).

## Session of 2026-09-30: the A2A low-code toolkit (`a2a-ai-toolkit`), client and server, in a real BI project

Separate track from the sessions above: not the library's own protocol conformance, but whether
`ballerina/a2a` is usable the way `ballerina/mcp` already is from WSO2 Integrator (BI) -- a
client toolkit an `ai:Agent` can hold (`A2aToolKit`, mirroring `ai:McpToolKit`) and a server-side
helper that turns an `ai:Agent` into an A2A agent (`runAgent`, new this session -- MCP has no
equivalent, since MCP never exposes an agent, only functions as tools). Full detail, including
what BI's actual low-code *tiles* still need (deliberately out of scope this round) and where
their MCP equivalents live in the tooling, is in `a2a-ai-toolkit/BI_LOWCODE_NOTES.md`.

`A2aToolKit` was rebuilt from scratch this session (the prototype and its `ai:McpBaseToolKit`-style
port had both drifted onto the dead 0.2.1 client API) and `runAgent` is new. Both are unit-tested in
`a2a-ai-toolkit` -- 15 tests, 3 of them real calls to the Anthropic API (Claude Haiku 4.5), not a
hand-built fake -- and then exercised together in a real BI workspace
(`~/WSO2Integrator/wso2-integrator-a2a`): the existing demo client package (`a2ademoassistant`, its
~250 lines of hand-rolled JSON-RPC glue replaced by one `A2aToolKit` instance) and a new server
package (`tripplanneragent`) whose entire `onMessage` is one call to `runAgent` -- exactly the shape
a low-code "A2A Service" tile would generate.

**Cross-language confirmation**: the real Python `a2a-sdk` client
(`interop/python-client/driver_llm.py`, unmodified except for the port argument) driven against
`tripplanneragent`, live:

| Check | Result |
|---|---|
| Card discovery | PASS |
| Turn 1, no city named -> `INPUT_REQUIRED` | PASS -- agent asked "Which city would you like to visit for your day trip?" |
| Turn 2 ("Milan"), same task id | PASS |
| Turn 2 completes with an on-topic itinerary | PASS -- real Claude Haiku 4.5 output, mentions Milan |
| Exactly one task existed on the server after both turns | PASS |

`OVERALL: PASS`. So a low-code-shaped server built from this toolkit's `runAgent` genuinely
interoperates with a real other-language client, not only with this library's own client.

## What this covers, and what it doesn't

- Confirms the highest-value slice of Part 1: card discovery, blocking send with an
  artifact, task-not-found, task-not-cancelable, and raw bytes -- against a **real** SDK
  client and a **real** SDK server, both built on the actual `a2a-sdk` 1.1.5 API (not a
  stand-in). This is the first evidence of that kind for this library.
- Still not covered: the Java side of push/multi-turn (pair D now covers discovery and streaming; pair B only
  `sendMessage`/`getTask`); Claude-backed Node and Go agents (need an API key); other identity providers (Auth0,
  Entra) and their quirks; the interactive authorization-code redirect handled *by this library* (the client only
  consumes the resulting refresh token; there is no code-flow support to test); token exchange / delegation (finding
  19); **X-A4** (blocked: the Java security sample needs an LLM key as well as Keycloak); API-key server auth (not built);
  and LLM behaviour beyond the scenarios above: streaming/push tools driven by the model, larger models, repeated runs.
- `python-agent/agent.py` covers a subset of the `tck-sut` contract (echo, completed+artifact,
  input-required, fail, immediate-complete, cancelable, raw bytes) -- enough for this pass,
  not the full grid yet.

## Session of 2026-09-30 (later): full re-run on the republished build, plus raw-HTTP spec probes (`spec-probes/probe.py`)

Build under test: `module-ballerina-a2a` `feat/http-json-listener` (PR #4, draft), republished to the local repo; 454 unit tests pass.
Regression: every interop script passes (Python pair, extended, Java pair, auth, client ops/OAuth/TLS, typed errors, Node with Claude,
Go with Claude) except the two Go typed-error checks, which are finding 25 (a2a-go client bug), unchanged. `run_pair_b_d.sh` gained a
25s bound: the Java sample client waits forever for a `MessageEvent` a task-producing agent never sends (it had received the Task and
all 3 updates, including COMPLETED). Harness artifact, not a library bug.

**26. (Defect, ours; spec 3.6) A patch version in `A2A-Version` is rejected.** `dispatcher.bal` `checkVersion` compares the header to
"1.0" exactly, so `1.0.5` -> `VERSION_NOT_SUPPORTED`. Spec 3.6: patch numbers "MUST not be considered" in negotiation; agents match
`Major.Minor`. Python `a2a-sdk` (`utils/version_validator.py`) and `a2a-java` (`A2AVersionValidator`) both accept it. Fix: compare major.minor.
(`1.1` is correctly refused per the spec's Major.Minor rule; both reference SDKs are laxer, accepting any 1.x.)
**Fixed** in `module-ballerina-a2a` `2164445`: a new `majorMinor` helper drops any third-or-later dot-separated component before
comparing. Verified with a dedicated test, mutation-checked, and reconfirmed live with `probe.py` itself against the republished
listener -- V3 (`1.0.5`) now `200`, V4 (`1.1`) still correctly `400 VERSION_NOT_SUPPORTED`.

**27. (Deviation, low; spec 3.6.1 MAY) `A2A-Version` as a query parameter is ignored,** so the request is treated as version 0.3 and refused.
Neither reference SDK reads it either.

**28. (Defect, ours; proto `ListTasksRequest`, spec 6.5) `GET /tasks` paging is unbounded and fails silently.** Measured on 130 tasks:
no `pageSize` -> all 130 (spec/proto/Python: default 50); `pageSize=101` and `100000` -> 101 / all (max is 100); `pageSize=0` and `-3`
-> an empty page with `totalSize` 130 and no `nextPageToken`, so a caller sees "no results". Python `validate_page_size` raises
InvalidParams outside 1..100 (proto: min 1, max 100). In `InMemoryTaskStore.list` (`task_store.bal`) the size falls back to
`matched.length()`, and negatives are clamped to 0.
**Fixed** in `module-ballerina-a2a` `2164445`: defaults to 50 (`LIST_TASKS_DEFAULT_PAGE_SIZE`); an explicit value outside 1..100 is now
`InvalidParams` (400), matching spec 6.5's own validation example rather than clamping. Verified with dedicated tests (default,
each out-of-range case), mutation-checked, and reconfirmed live with `probe.py` -- L1-L4 (`pageSize` 0, -1, 101, 1000000) all now
`400 INVALID_PARAMS`.

**29. (Defect, ours) Invalid `GET /tasks` query values are silently ignored or return nothing.** `pageToken=bogus` -> empty page (Python:
InvalidParams "Invalid page token"); `status=nonsense` -> the filter is dropped and every task returns; `pageSize=abc`, `historyLength=abc`
-> ignored; `statusTimestampAfter=garbage` -> 0 tasks. Spec 6.5 shows 400 with per-field errors. `queryToListFilter` (`dispatcher.bal`).
**Fixed** in `module-ballerina-a2a` `2164445`: `queryToListFilter` now returns `ListTasksRequest|Error`, rejecting an unrecognized
`status`, or a non-numeric `pageSize`/`historyLength`/unparseable `statusTimestampAfter`, with `InvalidParams`; a `pageToken` naming no
task in the current result set is rejected the same way in `InMemoryTaskStore.list` (a business rule, not a wire-format one, so it
lives with the store instead of the dispatcher). `historyLength`'s own *range* (a negative value) is untouched -- that's finding 31,
not this one, and wasn't part of this batch. Verified with dedicated tests, mutation-checked, and reconfirmed live with `probe.py` --
L5 (`pageSize=abc`), L6 (`pageToken=garbage`), L8 (`status=working`), L12 (`statusTimestampAfter=notadate`) all now
`400 INVALID_PARAMS`.

**30. (Minor) Push-config registration accepts any `url`,** including `""`, `not a url`, `file:///etc/passwd` (proto marks `url` REQUIRED).
Rejection happens only at delivery and is swallowed, so a client is never told. Delivery-time SSRF guard (default on) verified end to end
against a local receiver: `127.0.0.1`, `localhost`, `LOCALHOST.`, `127.1`, decimal, hex, octal, `0.0.0.0`, `[::1]`, both v4-mapped v6 forms,
userinfo and backslash tricks, and the host's LAN address were all blocked. **Not blocked: a hostname resolving to loopback**
(`localtest.me` was delivered), the DNS gap the source already concedes; spec 13.2 SHOULD.

**31. (Minor) Required-field checks are uneven.** Missing `messageId` -> 400, but `messageId: ""` and `role: ROLE_UNSPECIFIED` are
accepted; negative `historyLength` accepted on `GET /tasks/{id}`, and on `message:send` configuration.

**32. (Spec vs every reference SDK, not a Ballerina-only bug) Error statuses.** Spec 5.4 lists `TaskNotCancelable` 409,
`ContentTypeNotSupported` 415, `InvalidAgentResponse` 502. The listener returns 400 / 400 / 500, exactly like `a2a-sdk` 1.1.2
(`A2A_ERROR_MAPPING`), `a2a-go` (`internal/rest/rest.go`) and `@a2a-js/sdk` (`REST_ERROR_HTTP_STATUS`). The a2a-java REST mapping was not
checked. The comment above `errorBindingFor` in `server_errors.bal` describes the spec table wrongly and should be corrected.
**Comment fixed** in `module-ballerina-a2a` `2164445`; the returned statuses are unchanged (400/400/500, deliberately, matching
the ecosystem over the spec text).
**Corrected 2026-09-30, see finding 38:** the 409/415/502 figures came from the TCK's older spec mirror. The released v1.0.1 spec and
current `main` (section 5.4) say 400/400/500, so the listener matches the spec, not only the ecosystem. a2a-java is now the outlier.

Probed and fine: card ETag + 304, concurrent sends (40 parallel), malformed/empty/array/non-UTF-8 bodies (400), unknown path (404),
terminal-task send and subscribe (`UNSUPPORTED_OPERATION`), encoded `%3Acancel`, path traversal and 5000-char ids (no 5xx), 5 MB body,
unknown fields ignored, lower-case header name, extended-card error correctly `UNSUPPORTED_OPERATION` when the capability is false.

**Not done:** hostile-server probe of our *client* (unknown enum values, `tasks:null` per finding 24, split/CRLF/huge SSE frames,
redirects, gzip, truncated bodies); X-A4 (needs Keycloak + LLM key for the Java sample); a2a-java REST error statuses.
(The hostile probe and the a2a-java statuses were done in the next session, below.)

## Session of 2026-09-30 (evening): two more languages (Rust, .NET), newer SDK releases, and the hostile-server probe of our client

Build under test: `module-ballerina-a2a` `feat/http-json-listener` @ `2164445`, locally published (published `.bal` sources checked
byte-identical to HEAD). Spec authority: A2A **v1.0.1** (`a2aproject/A2A` tag, `docs/specification.md` + `specification/a2a.proto`),
cross-checked against `main`. Claude-backed agents use Claude Haiku 4.5, same as the earlier rigs. Rust and .NET run in Docker, so no
toolchain was installed on the host. Everything below is a live run.

### References used

| Library | Version | Role |
|---|---|---|
| `a2a-rs` (`a2a-lf` 0.3.1, `a2a-client-lf` 0.2.5, `a2a-server-lf` 0.4.4, crates.io = `main` c3952b6) | **new** | agent + client, `rust-agent/`, `run_rust_checks.sh` |
| `a2a-dotnet` built from `main` 76de7f3 (2026-09-26) | **new** | agent + client, `dotnet-agent/`, `run_dotnet_checks.sh`. The only NuGet release, 1.0.0-preview2, is from 2026-04-09 and predates the current API. |
| `a2a-sdk` (Python) | 1.2.0 (was 1.1.5) | full re-run of pairs A/C, extended, more, client checks (`PY=... ./run_*.sh`) |
| `@a2a-js/sdk` | 1.3.0 (was 1.2.1) | re-run of `run_node_checks.sh` (`NODE_DIR=...`) |
| `a2a-java` | `ad9571c9` (level with `main`; 1.4.0.Final released) | pair B/D re-run, REST error table read |
| `a2a-go` | v2.6.0 | re-run |
| A2A TCK | `5996b79` | all four modes |

### Results

| Pair | Result |
|---|---|
| R-A: our client -> Rust agent (Claude) | Card, blocking send + artifact (`[claude] 2 + 2 = 4`), direct Message, multi-turn, returnImmediately + cancel running, typed errors (their `application/problem+json` bodies decode correctly), getTask historyLength, pageSize/pageToken, push CRUD: **PASS**. Stream: passes events through faithfully, but the Rust server never sends the opening Task (R1). ListTasks without `pageSize`: **FAIL, finding 33**. |
| R-C: Rust client -> our listener | 27 of 28 **PASS**, including push delivery as a StreamResponse envelope. The 1 fail is the Rust client's (R3). |
| D-A: our client -> .NET agent (Claude) | Everything **PASS** except multi-turn continuation (.NET bug D1), status filter (D2) and statusTimestampAfter (D3). Push withheld by the card -> `PushNotificationNotSupportedError` raised client-side. Our client's GET->POST subscribe fallback was needed and worked (.NET routes `:subscribe` as POST only). |
| D-C: .NET client -> our listener | All flows **PASS**. The 3 fails are all D4 (their client ignores our `application/a2a+json` error bodies). |
| Python 1.2.0, all rigs | 78/79; the 1 "fail" is finding 13 **fixed upstream** |
| Node 1.3.0 | 43/43 PASS |
| Java B/D, Go v2.6.0 | unchanged (Go: only the 2 known finding-25 failures) |
| TCK default / no-capabilities | 89/4 and 71/5: the same 3 known requirements (CARD-CACHE-003, and HTTP_JSON-ERR-001 / SVC-001 from the TCK's stale `application/json` expectation). The extended mode no longer starts, see finding 42. |
| `ai:A2aToolKit` (Traveler, Claude) -> Rust + .NET Claude agents | Rust: discovery, INPUT_REQUIRED, continuation on the same task id, exactly 1 task: **PASS**. "List the tasks": the model got finding 33's error. .NET: the continuation hit D1, and the model's retry created a 2nd task (finding 41). |

### Findings (ours)

**33. (Defect, client) `listTasks` rejects a ProtoJSON response that omits default-valued fields.** `ListTasksResponse` (`types.bal:490`)
makes `nextPageToken`, `pageSize` and `totalSize` required, non-optional fields. ProtoJSON omits `""` and `0`, so a real a2a-rs server's last
page (`{"pageSize":50,"tasks":[...],"totalSize":2}`) fails with `ListTasks response did not match the expected shape: ConversionError`. So
does `{}`, the canonical ProtoJSON rendering of an empty page. The `tasks: null` fix (finding 24) covered only `tasks`. Spec 5.7 says REQUIRED
fields "MUST be present and set", so a2a-rs is also deviating (R4). But proto3 cannot tell an empty token from an absent one, and both
reference clients accept it: `a2a-sdk` 1.2.0 -> `next_page_token=''`, `@a2a-js/sdk` -> `nextPageToken=""`. Users hit this in practice: the
Traveler's model reported "the agent's response didn't match the expected format". Proposed: default a missing or `null` `nextPageToken`
to `""`, and `pageSize`/`totalSize` to `0`, in `decodeListTasksResponse`. **Do finding 34 first**, or an unparseable body (-> `{}`) turns
into a silent empty page. (Also: the comment above that normalisation in `http_client.bal:185-200` is pasted in twice.) **Fixed**
(`module-ballerina-a2a@4d8c851`): `decodeListTasksResponse` now defaults a missing/null `nextPageToken`/`pageSize`/`totalSize` to
`""`/`0`/`0` before decoding, after finding 34's fix. Covered by `testRestClientDefaultsOmittedListTasksFieldsToZeroValue` and
`testRestClientDecodesEmptyListTasksObject`; the pasted-twice comment is also corrected.

**34. (Defect, client) An unparseable 2xx body is silently replaced with `{}`** (`http_client.bal:526`, `restCall`). For
`listTaskPushNotificationConfigs`, whose response type is all-optional, a **truncated or HTML 200 body returns success with 0 configs**
(hostile cases `p_truncated`, `p_html`). A caller concludes nothing is registered. For other operations the error is typed but misleading
("Response contained neither a task nor a message" for a truncated body or a BOM). `a2a-sdk` raises on both (network error, JSON decode
error). Proposed: only an operation that expects an empty body (DELETE) may treat an empty body as `{}`. Anything else unparseable is
`InvalidAgentResponseError` carrying the parse error. **Fixed** (`module-ballerina-a2a@4d8c851`): `restCall` now returns
`InvalidAgentResponseError` for an unparseable 2xx body on every operation except `deleteTaskPushNotificationConfig` (the only DELETE,
matching its google.protobuf.Empty wire response). Covered by `testRestClientRejectsUnparseableTwoxxBody` and
`testRestClientDeleteToleratesUnparseableEmptyBody`.

**35. (Minor, client) Other ProtoJSON leniencies the reference client has and ours lacks.** `"history": null` / `"metadata": null` on a
Task -> `ConversionError` (ProtoJSON: `null` is the field default; `a2a-sdk` accepts). An integer enum (`"state": 3`) is rejected (ProtoJSON
parsers accept integers; `a2a-sdk` accepts). Spec 5.5 requires senders to emit names, so this only matters against a non-conforming
server. Low. No real server seen doing either yet. **Fixed** (`module-ballerina-a2a@4d8c851`): a new `normalizeTaskStateJson`, applied at
every Task/TaskStatusUpdateEvent decode site (unary and streaming), removes a null `history`/`metadata` and remaps an integer `state`
ordinal to its name before decoding. Covered by `testRestClientAcceptsNullHistoryAndMetadataOnATask` and
`testRestClientAcceptsIntegerTaskState`.

**36. (Upstream `ballerina/http`, reached through the client) SSE parsing is roughly 100x slower than JSON.** A 2 MB artifact takes
**0.064 s** as a unary reply but **7–8.4 s** as one SSE event, with a warm JIT. `a2a-sdk` reads the same event in **0.06 s**. The trace goes
through `http:BytesToEventStreamGenerator.getNextByte` / `readUntilDoubleLineBreaks`, a byte-at-a-time reader. Impact: streaming large
artifacts (documents, code, images as base64) through `ballerina/a2a`. Report to `ballerina/http`.

**37. (Minor, listener) `GET /tasks/a/b/c` is served as `GetTask` for id `a/b/c`** (`dispatcher.bal:365-367`; the `:cancel` / `:subscribe`
branches slice the same way). The proto's `{id=*}` matches one path segment. `POST` to the same path is already `METHOD_NOT_FOUND`. Found
because the Rust client's legacy fallback calls `GET /tasks/{id}/subscribe` and got `TASK_NOT_FOUND "no task with id <id>/subscribe"`.
Practical impact is small (still a 404). The fix is to reject an id containing `/`. **Fixed** (`module-ballerina-a2a@4d8c851`): all
three branches (`GetTask`, `:cancel`, `:subscribe`) now fall through to the same `404 METHOD_NOT_FOUND` an unmatched route gets when
`{id}` contains `/`. Covered by `testTaskIdWithASlashIs404NotACrossSegmentLookup`.

**38. (Correction of finding 32) Our error statuses match the released spec.** v1.0.1 and `main` section 5.4: `TaskNotCancelable`,
`ContentTypeNotSupported`, `PushNotificationNotSupported`, `UnsupportedOperation`, `VersionNotSupported` -> **400**,
`InvalidAgentResponse` -> **500**, which is what the listener sends. The 409/415/502 figures were from the TCK's mirror
(`a2a-tck/specification/specification.md:1185`). a2a-java (`spec/.../A2AErrorCodes.java`) uses 409 / 415 / 502 and also **422** for
`InvalidParams`, so it is the implementation that differs from the current text. Every client tested decodes by `reason` either way. One
cosmetic gap: our error body has no `"status"` (gRPC status name). The Rust, .NET and Python servers include one and spec 11.6's example
shows it, but its field list names only code, message and details.

**39. (Positive) Hostile-server probe of our client** (`hostile-server/hostile.py` + `bal-client-hostile`; 38 cases, each compared with
`a2a-sdk` where relevant). These are handled correctly and promptly: unknown fields and unknown StreamResponse arms are skipped (spec 5.7);
unknown enum values give a typed error; a two-arm oneof is refused; HTML / 500 / 503 bodies; gzip; chunked encoding; a hung server times out
at the configured timeout; `application/problem+json` error bodies decode to the typed error (the Go and .NET clients cannot do this);
CRLF-only, CR-only, `data:` without a space, multi-line `data:`, frames split mid-JSON, `id` / `event` / `retry` fields and comments;
malformed event JSON and named `error` frames give typed errors; events after the terminal state are not delivered; a silent stream times
out. A 307 redirect is not followed by default (`clientConfig.followRedirects` exists). Our client and `a2a-sdk` behave the same, so these
are not ours to fix alone: a stream that closes before any terminal state ends cleanly, with no error (the caller must check the last state),
and a leading UTF-8 BOM makes the first event disappear silently (WHATWG SSE says to strip it).

**40. (Positive) Python `a2a-sdk` 1.2.0 fixed finding 13** (see above).

**41. (Toolkit observation, triggered by .NET bug D1) A 5xx on a continuation leads the model to retry, creating a duplicate task.** The
.NET server ran the handler and completed the task, but answered 500. The model, told the call failed, resent: first "terminal state",
then a new task. That makes 2 tasks where 1 was intended. The root cause is theirs. But `A2aToolKit` could tell the model, on an error for
a continuation, to check the task with `getTask` before resending (the same class as the earlier Milan duplicate-task regression).

**42. (Rig) TCK extended mode can no longer run.** `tck-sut -CextendedCard=true` is refused at startup: "`extendedAgentCard` requires
`ListenerConfiguration.auth`". That is correct per spec 13.3 ("MUST require authentication"). The TCK sends no credentials, so the mode
needs redefining, e.g. declare the capability without configuring a card, which is what the TCK's `ExtendedAgentCardNotConfigured`
tests check.

### Findings (other SDKs; none has an existing upstream issue, searched 2026-09-30)

**a2a-rs** (`a2a-server-lf` 0.4.4 / `a2a-client-lf` 0.2.5):
- **R1** A task-lifecycle stream starts with a `statusUpdate` and never sends the opening `Task`. Spec 3.1.2: "the stream MUST begin with
  the Task object". Our client tolerates it.
- **R2** `InMemoryTaskStore::list` (`task_store/inmemory.rs:91-111`) ignores `statusTimestampAfter`; the REST layer parses it, then drops it.
- **R3** The client treats `UNSUPPORTED_OPERATION` as "use the legacy path" (`should_retry_subscribe_with_legacy_path`, `a2a-client/src/rest.rs:255`).
  So subscribing to a finished task hides the spec 3.1.6 error behind the second call's `TASK_NOT_FOUND`.
- **R4** The last `ListTasks` page omits `nextPageToken` (spec 5.7 REQUIRED). List responses are also `application/json`, while other
  responses are `application/a2a+json`.
- *Rig lesson:* `ExecutorContext.stored_task` is already `Some` on a task's first turn; use `message.task_id` to detect a continuation.

**a2a-dotnet** (`main` 76de7f3):
- **D1** A blocking `SendMessage` continuing an `INPUT_REQUIRED` task always fails, `500 INVALID_AGENT_RESPONSE "Agent handler did not
  produce any response events"`. The handler still runs and completes the task. Reproduced with the SDK's **own** `ResearcherAgent`
  sample over JSON-RPC (so not the REST binding, and not this rig), following the SDK's documented multi-turn pattern.
- **D2** The server's `GET /tasks?status=` accepts only C# enum names (`Enum.TryParse`, `A2AHttpProcessor.cs:174`). It rejects
  `TASK_STATE_CANCELED`, which is what its own client sends, and it answers with an RFC 9457 problem document instead of `google.rpc.Status`
  (spec 11.6).
- **D3** The REST `ListTasks` route never binds `statusTimestampAfter` or `includeArtifacts`, so both are ignored.
- **D4** The client parses an error body only when `Content-Type` is exactly `application/json` (`A2AHttpJsonClient.cs:417`), the same bug
  as a2a-go #447. Against our `application/a2a+json` errors, every 400 becomes `InvalidRequest` and only 404 comes out right, by
  coincidence. Its reason table also lacks `INVALID_PARAMS` and the other JSON-RPC-range reasons.
- Known upstream: no push notifications (#504). The NuGet 1.0.0-preview2 release is about six months behind `main`.

## Session of 2026-10-15: the resource-based service on `a2a:RestListener` (`feat/rest-listener`)

`module-ballerina-a2a` `feat/rest-listener` at `39856a9` replaces `a2a:HttpListener` and the `remote on*` operations with
`a2a:RestListener` and one `resource` function per HTTP+JSON route. Every Ballerina listener here was migrated to that shape
(`tck-sut`, `bal-listener`, `-auth`, `-tls`, `-oidc`, `-idp`, `server`, `server2`, `slow-agent`), and the whole grid re-run.

The library was built from a clean `git archive` of `39856a9`, not the shared checkout, with the native jar compiled from that
commit's own sources (it contains `ResourceInvoker.class`, and so does the packed bala). Another session pushed a different build
of `ballerina/a2a` 0.1.0 to the shared local repository mid-run, so the LLM-backed runs were repeated with
`BALLERINA_HOME_DIR` pointing at an isolated home that holds only this branch's bala (Central cache shared by symlink).

### References used

| Library | Version |
|---|---|
| `a2a-sdk` (Python) | 1.1.5 |
| `@a2a-js/sdk` | 1.2.1 |
| `a2a-java` | 1.4.1.Final-SNAPSHOT (local build) |
| `a2a-go` | v2.6.0 |
| A2A TCK | `263b9cf` (HTTP+JSON only) |

### Results

| Check | Result |
|---|---|
| `bal test` in the module (clean export) | 512 passing, 0 failing |
| TCK default | 88 passed, 5 failed (4 requirements): `CARD-CACHE-003`, `HTTP_JSON-ERR-001`, `HTTP_JSON-SVC-001` (known), and `CORE-CANCEL-002`, see finding 43 |
| TCK no-capabilities | 70 passed, the same 5 failed. The listener attached only the five base operations, and the card withholds streaming and push |
| TCK extended | Starts now (finding 42): `auth` is a file user store with no users, run with `-k extended_card`. 7 skipped, as the probe sees the 401 challenge |
| TCK extension | 1 passed |
| Pair C (Python client -> `bal-listener`), `run_extended.sh` both directions | PASS, incl. I12 push as a `StreamResponse`, I13 keep-alive, tenancy, malformed body |
| Pair A | PASS. Its one "webhook NOT delivered" is the script: `run_pair_a_c.sh` starts no receiver on 19870 (`run_extended.sh` does) |
| Pair B / D (Java) | Unchanged: D gets `TaskEvent` + 3 updates and is stopped by its alarm, as the script expects |
| Go G-A / G-C | G-A PASS. G-C: only the 2 known finding-25 failures |
| Node N-A / N-C, J-D `StreamDriver` | PASS |
| `run_client_checks.sh` | PASS once `bal-client-tls` expects the `/rest` interface URL (finding 44) |
| `run_more_checks.sh`, `run_pair_x_a.sh` (X-A1, X-A2, X-A3) | PASS |
| `run_idp_checks.sh` (Keycloak) | PASS, 59 checks: audience, scope, `sub`, per-user task isolation, OIDC discovery, key rotation and withdrawal, AUTH_REQUIRED |
| `run_llm_checks.sh` | PASS: Python client two-turn on one task; Traveler duplicate-task regression (1 task); two agents, honest cancel failure; 40s task |
| Trip Planner / Packing Assistant / Traveler, the README's 8 prompts | PASS, incl. the webhook receiving the Kyoto task's push |
| `a2a-ai-toolkit` `bal test` | 14 passing |
| `a2a-interop-tests` `bal test`, with the real Claude-backed dice agent on HTTP+JSON | 16 passing; `testDiceAgentSendMessageRest` completed |
| Operations Desk (`multi-agent-a2a-demo`), the README's 8 prompts | PASS (second run 8/8; the first run's prompt 2 hit an Anthropic API idle timeout inside the chat agent, not A2A) |

The `:action` routes were probed directly: `tasks/{id}:cancel` and `:subscribe` reach the operation with a literal colon, `%3A`,
`%3a` and a trailing slash; `tasks/{id}/cancel` is 404, as it should be. No listener log in any of these runs contains
`response has already been sent`; the module's own suite logs it twice, from the listener-timeout test, where the HTTP layer has
already answered.

### Findings

**43. (Spec gap, TCK newly strict) `TaskNotCancelableError` is 400; the spec's table says 409.** TCK `de6af18` ("assert the
specific spec-mandated error") made `CORE-CANCEL-002` check the status, so it now fails. Not a `feat/rest-listener` regression:
`server_errors.bal` has returned 400 on purpose since earlier commits, its comment citing `a2a-sdk`, `a2a-go` and `@a2a-js/sdk`.
The spec's section 5.4 table and 11.6 say 409 (`ContentTypeNotSupportedError` 415, `InvalidAgentResponseError` 502). Worth
deciding whether to follow the spec now that the TCK enforces it.

**44. (Rig) `bal-client-tls` expected the interface URL without `/rest`.** The served card's HTTP+JSON interface is the listener's
address plus `/rest`, as the module README says. The three checks that compared against the bare address (and the mutual-TLS
send that overwrote the card's URL with it) now include `/rest`.

**45. (Rig) Re-pushing `ballerina/a2a` at the same version leaves dependents' compiled caches stale.** The Traveler client
failed with `NoClassDefFoundError: ballerina/a2a/0/identifiers/global_vars/$resolveAgentCard_clientConfig` from
`A2aToolKit.init`, although its `target` was rebuilt: `~/.ballerina/repositories/local/cache-2201.13.5/ballerina/ai` was
compiled against an older `a2a` and is not invalidated when `a2a` 0.1.0 is replaced. Clear that cache directory (or use a fresh
`BALLERINA_HOME_DIR`) after each re-push.

Not covered this session: Rust and .NET (no `cargo` or `dotnet` on this machine), and the GraalVM native-image build (no
`native-image` installed).
