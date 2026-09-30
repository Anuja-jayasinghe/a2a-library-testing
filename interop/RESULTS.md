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

Not run: the Claude-backed mode of the Node agent. No `ANTHROPIC_API_KEY` was available in this session, so every Node
result above used the deterministic stub (the artifact text starts with `[stub]`, `[claude]` when the model answers).

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
decoder accepts it. A client that talks to more than one SDK should treat `null` for a repeated field as empty. **Not fixed.**

**25. (SDK divergence from the live spec; not our bug, but it defeats our error mapping) The Go client turns every error from our
listener into a generic `server error`.** `a2a-go` `internal/rest/rest.go` `FromRESTError` returns `a2a.ErrServerError` unless
`Content-Type` starts with `application/json`; our listener (following the live spec, which uses `application/a2a+json` throughout)
answers `application/a2a+json`, so the `google.rpc.Status`/`ErrorInfo` body is never decoded and `errors.Is(err, a2a.ErrTaskNotFound)` is
false. The Go server itself emits plain `application/json`. Same disagreement as the two TCK failures `HTTP_JSON-ERR-001`/`SVC-001`.
Options: report upstream to a2a-go, or have the listener content-negotiate (answer `application/json` when the request's `Accept`
lists only that; the Go client sends `Accept: application/json`). **Not changed**; needs a decision.

**21. (Defect, ours; found by the Node agent) `HttpClient` builds `//message:send` when the card's interface URL ends in
`/`, and the server answers 404.** `@a2a-js/sdk` advertises `http://localhost:9800/` for a root-mounted agent. Every
operation from `a2a:HttpClient` then failed with `REST request failed with HTTP 404` (`curl` confirms `//message:send` is
404, `/message:send` is 200). The reference `@a2a-js/sdk` client, given the same card, works. `http_client.bal` passes
the URL straight to `http:Client` and appends paths that start with `/`. A root-mounted agent is the common case, so this
would hit real users. Proposed fix: strip trailing `/` from the interface URL when building the client. Workaround used
in the rig: `TRAILING_SLASH=0`. **Not fixed**; needs a decision on whether to amend `c167fe3` or add a new commit.

**22. (Defect, ours; root cause of a "pre-existing" TCK failure) `message:send` ignores `configuration.historyLength`.**
TCK `CORE-HIST-003` ("SendMessage with historyLength=0 returned 2 history message(s), expected none") has failed since
the 88/4 baseline. Reproduced without the TCK: `POST /message:send` with `configuration.historyLength: 0` returns
`history` of length 1 from our listener and no `history` key from the Node agent; `historyLength: 1` returns 1 from both.
Spec 3.2.4: "0: No history should be returned; the `history` field SHOULD be omitted". In the library, only `getTask`
(`default_handler.bal:692`) and `listTasks` (`task_store.bal:284`) trim history; `sendMessage` never reads
`configuration.historyLength`. **Not fixed.** That leaves 3 of the 4 TCK failures: `CARD-CACHE-003` (optional
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
