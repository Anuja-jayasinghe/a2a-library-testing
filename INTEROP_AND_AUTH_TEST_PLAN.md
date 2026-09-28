# Test plan: interop with other A2A SDKs, and authentication

Two gaps left after the TCK run and the long-running checks:

1. **Interop.** `ballerina/a2a` has never been driven by another SDK's client, and its client has never
   talked to another SDK's server. Everything so far was our client against our listener, or the TCK's
   Python harness against our listener.
2. **Authentication.** The listener has no inbound authentication, the extended agent card is served to
   anyone, and no real request has ever been answered with 401/403.

Only the auth spike (section 2.1) has been run. Facts below were read from the code, the live spec and the
checkouts on this machine; anything marked **(verify)** is an assumption to confirm in Phase 0, not a finding.

---

## Status (2026-09-25): what is built, so what the tests will exercise

Implemented in `module-ballerina-a2a` on `feat/http-json-listener` (403 unit/integration tests pass; TCK default
mode unchanged at 88 passed / 4 failed):

| Built | Commit | Plan cases it makes testable |
|---|---|---|
| `ListenerConfiguration.auth` (JWT, OAuth2 introspection, file/LDAP Basic), identity-scoped tasks | `a53cdb5` | S-A1..S-A7, S-A10, S-A12, S-A13 |
| Extended card without `auth` refuses to start | `f88a341` | S-A11 |
| `securitySchemes` served in the v1.0 wrapped shape (was flat: a strict v1 client rejected the card) | `8288592` | I1 (card discovery); confirmed by parsing the served card with the Python SDK 1.1.5 protobuf types |
| Card `securitySchemes`/`securityRequirements` derived from `auth` | `caf9afc` | S-A8 (advertised = enforced, by construction), C-A1, C-A5, C-A7 |
| `AuthenticationError` / `AuthorizationError` on the client, server binding | `56cf5f2` | C-A2..C-A4, C-A8, C-A9 |

Still open: **S-A14** (API-key check on the server, nothing built), **S-A15** (mutual TLS needs the HTTPS follow-up),
OAuth2 authorization-code / device-code flows and OIDC discovery on the client, refresh-and-retry on 401, and LDAP
(no test server). **Part 1 (interop) has not started.**

### Binding coverage (found while starting Phase 0, confirmed by a real cross-SDK run)

`ballerina/a2a` speaks **only the HTTP+JSON REST binding**, both as client and server. A2A
also has JSON-RPC and gRPC bindings, and a lot of existing agents default to JSON-RPC --
including `a2a-sdk` 1.1.5's own `ClientFactory`, whose `supported_protocol_bindings` defaults
to `["jsonrpc"]` when left empty (`client/client_factory.py`). Confirmed live: the Python
client driver below only reaches our listener once `supported_protocol_bindings=[HTTP_JSON]`
is set explicitly.

**Consequence:** "any other A2A-compatible language" is accurate only for "any implementation
that also serves or calls the HTTP+JSON binding," not every A2A agent regardless of transport.
Worth raising with the Ballerina team as a documented scope boundary, not an interop bug.

### Phase 0/1 status (2026-09-28): first real cross-SDK run, both directions

`interop/` now has a real `a2a-sdk` 1.1.5 agent (`python-agent/agent.py`, built on the SDK's
own `DefaultRequestHandlerV2`/`AgentExecutor`/FastAPI routes -- not a stand-in) and a real
`a2a-sdk` 1.1.5 client driver (`python-client/driver.py`, built on the SDK's own
`ClientFactory`/`Client`), run against `bal-client/` and `bal-listener/`. `interop/run_pair_a_c.sh`
runs both. Full results and four findings (one binding-coverage confirmation, two SDK
ergonomics differences that needed fixing in the test code rather than the library, and one
positive finding: our error reasons round-trip into the reference client's own typed
exceptions) are in `interop/RESULTS.md`.

This proves the TCK's httpx-based conformance checks were not the whole story: pairs A and C
now have a real cross-SDK result for card discovery, a blocking send with an artifact,
`TaskNotFoundError`, and `TaskNotCancelableError`. Streaming, push, multi-turn, tenancy, the
auth grid, and pair B/D (Java) are still open -- see `interop/RESULTS.md`'s last section.

### Update: pairs B/D (Java) and the cross-SDK auth grid (X-A1, X-A3), also real, also run

Extended the same real-SDK-on-both-sides approach to the Java reference implementation and
to authentication. Full detail and the exact commands are in `interop/RESULTS.md`; headline
results:

- **Pair B** (our client -> the real `a2a-java` reference server, the `examples/helloworld`
  Quarkus app run with `-Dquarkus.agentcard.protocol=HTTP+JSON`): PASS, after a real finding
  -- see below.
- **Pair D** (the real `a2a-java` reference client -> our listener): the task completed
  correctly server-side (confirmed via `GET /tasks`), but the reference client's own SSE
  handling throws after the terminal event (`Stream 1 cancelled`) -- their bug, evidenced by
  checking our listener's own task store directly, not assumed.
- **X-A1** (the real Python client's own `AuthInterceptor`/`CredentialService` -> our listener
  with `auth`): PASS -- valid token accepted, missing/forged token rejected with 401.
- **X-A3** (our client, `credentials = InMemoryCredentialStore` -> a real Python agent
  requiring a bearer credential): PASS -- same three cases.

**New finding (pair B): `ballerina/a2a`'s client cannot reach the real Java reference server
with its own defaults.** `ballerina/http`'s `ClientConfiguration.httpVersion` defaults to
`HTTP_2_0`, which over plain `http://` means HTTP/2 prior-knowledge (h2c). Quarkus/Vert.x's
default listener does not support h2c and answers with a bare 400 *before the request reaches
the A2A routing layer at all* (confirmed: zero server-side log entries for the rejected
request). `httpVersion: http:HTTP_1_1` on the client's `clientConfig` fixes it completely.
This did not surface against the Python agent (uvicorn tolerates the same default) -- it took
a second real reference implementation to find. **This is a decision for the user**: leave it
as a documented workaround, or have `ballerina/a2a`'s `HttpClient` default to HTTP/1.1 itself,
since h2c cleartext is a niche server-side opt-in almost nothing enables by default.

### Update: the remaining Part 1 scenarios (I4, I5, I9, I10, I12, I13, I14, I15) and X-A2

Run in both directions against real SDK code (`interop/run_extended.sh`); the Java side of the
auth grid (X-A2) run with the real `a2a-java` `AuthInterceptor`. Everything passes except one
scenario, which is the most useful result of the pass:

- **I14 (tenancy) found a defect in `ballerina/a2a`.** An unknown tenant prefix, and any path
  that is not an A2A operation, come back as **HTTP 500** (`INVALID_AGENT_RESPONSE` /
  `INTERNAL_ERROR`) although both are the caller's mistake. The spec is silent on both cases; what
  it does define is that 5xx is for system failures and an agent's own malformed response, so the
  defect is the *category*, and either 400 or 404 would be within the spec. Details, the spec
  citations and the proposed statuses (404 unknown path, 400 unserved tenant) in
  `interop/RESULTS.md` Finding 7. Not yet changed: it is a public behaviour change.
- **I13** (the plan's flagged "(verify)": do other SDKs' SSE parsers tolerate comment-only
  keep-alive frames?) -- yes, the real Python SDK sat through 4s of silence with 0.5s keep-alives.
- **X-A2** passes (valid token accepted; no credential and forged signature rejected), and the Java
  client parsing our derived `securitySchemes` is a third-implementation confirmation of the wire fix.
- **X-A4 is blocked, not skipped**: the only Java security example needs Keycloak in Docker and an
  LLM API key.

Still open: `ListTasks` filters beyond `pageSize`; the Java side of streaming/push/multi-turn;
a 70s+ silent stream against a foreign parser; wrong-media-type requests; X-A4.

Also confirmed live: `a2a-java` has no released Maven Central artifacts (0 results for
`org.a2aproject.sdk`); pair B/D needed a local build (`interop/run_pair_b_d.sh` documents the
exact `mvn` invocation and the `http-client-vertx` test-jar pitfall to avoid).


Known consequence: the TCK's *extended* mode cannot run against a conformant listener (the TCK sends no
credentials, spec 13.3 requires them). It is blocked by design, not failing.

---

## What we know (evidence)

| Fact | Where it came from |
|---|---|
| The listener returns the extended card to any caller; `ownerResolver` only scopes tasks to an identity someone else supplies | `module-ballerina-a2a/ballerina/default_handler.bal` `getExtendedAgentCard`, `owner_resolver.bal` |
| The client builds credential headers from the card's `securitySchemes`; covered by unit tests only | `auth.bal`, `tests/auth_test.bal` |
| Listener passes every non-A2A field of `ListenerConfiguration` to `http:Listener` | `listener.bal` `httpListenerConfigurationOf` |
| The spec makes this a conformance gap, not a design choice: 7.4 "MUST authenticate every incoming request"; 13.3 "`GetExtendedAgentCard` MUST require authentication"; 13.1 task operations MUST be scoped to the authenticated caller; 5.x "MUST NOT reveal the existence of resources the client is not authorized to access" | live spec `docs/specification.md`, read 2026-09-25 |
| `http:ListenerConfiguration` (http 2.17.2) has **no `interceptors` field**, and the dispatcher is a plain `*http:Service`, so a user cannot put authentication "in front of" `a2a:Listener` through its config | `http_service_endpoint.bal` in the http bala |
| `@http:ServiceConfig{auth}` is a compile-time annotation on a service; our dispatcher is a library-owned service class, so users cannot annotate it | `auth_desugar.bal` |
| The listener auth handlers are public and reusable: `ListenerJwtAuthHandler`, `ListenerOAuth2Handler`, `ListenerFileUserStoreBasicAuthHandler`, `ListenerLdapUserStoreBasicAuthHandler`; `http:ListenerAuthConfig` is a public type. The helper that picks a handler by scheme (`tryAuthenticate`) is private | http bala source |
| Python SDK **1.1.5** on PyPI has a REST client transport, REST server routes, an extended-card route, a client `AuthInterceptor`/`CredentialService`, and a server `owner_resolver` | wheel contents inspected |
| Java SDK checkout is `v1.2.0.Final` + 44 commits (`1.2.1.Final-SNAPSHOT`); it has `reference/rest`, a `helloworld` example, and an `itk/` interop kit whose scenarios include `http_json` star topologies across SDKs | `~/gitProject/a2a-java` |
| `a2a-samples` Python agents pin `a2a-sdk>=0.3.0`, so some may speak the older protocol | `pyproject.toml` files. **Do not use the samples as-is**: use them for ideas only |
| Java 21, Maven, uv and Python 3.12 are installed | `which` |

**Consequence:** the counterparts must be built on the *v1* SDKs (Python `a2a-sdk==1.1.5`, Java
`a2a-java` at the local checkout), pinned by version in the repo, not on the sample agents.

---

## Part 1: Interop

### 1.1 The four directions, plus a control

| Id | Client | Server | Purpose |
|---|---|---|---|
| A | Ballerina `a2a:HttpClient` | Python SDK agent | Does our client understand a real server? |
| B | Ballerina `a2a:HttpClient` | Java SDK agent | Same, second implementation |
| C | Python SDK client | Ballerina `a2a:Listener` | Does a real client understand our server? |
| D | Java SDK client | Ballerina `a2a:Listener` | Same, second implementation |
| Ctl | Python client | Python agent (and Java/Java) | **Control.** When a scenario fails in A-D, run it here first. If the control fails too, the scenario or the SDK is at fault, not us |

Binding is HTTP+JSON only (what our library implements). gRPC and JSON-RPC are out of scope.

### 1.2 Same deterministic agent everywhere

The Python and Java agents implement the **same contract as `tck-sut`**: behaviour is chosen by a prefix
of the incoming `messageId` (echo, streamed steps, input-required, paced/long-running, fail, cancelable,
file/data artifact). Then one scenario list runs against every pair, and results are comparable.
No LLM is involved.

Contract source of truth: `tck-sut/main.bal` (header comment). Port it; do not invent a second one.

### 1.3 Scenario list (each runs on every pair)

| Id | Scenario | What it proves | Watch for |
|---|---|---|---|
| I1 | Discover card at `/.well-known/agent-card.json` | Card parses both ways; `supportedInterfaces` / `capabilities` | field casing, missing optional fields, unknown fields kept (open records) |
| I2 | Blocking `message:send` -> Message | Basic round trip | `Content-Type`, `A2A-Version` header |
| I3 | Blocking send -> Task COMPLETED with artifact | Task shape | timestamps, ids |
| I4 | `returnImmediately` then poll `GetTask` | Non-blocking path | state at return (SUBMITTED / WORKING) |
| I5 | `ListTasks` with `pageSize`, `pageToken`, `status`, `contextId`, `historyLength` | Filters and paging | the Codecov-uncovered code lives here |
| I6 | `CancelTask` on a cancelable task; on a finished task | Success and `TASK_NOT_CANCELABLE` | error status is 400 per spec 5.4 |
| I7 | Unknown task id | `TASK_NOT_FOUND` decodes to the typed error | status 404, `ErrorInfo.reason` |
| I8 | `message:stream` | SSE framing both ways | `event:` names vs data-only frames, final event, connection close |
| I9 | `SubscribeToTask` on a running task | Resubscribe | first event is the current task |
| I10 | Multi-turn: INPUT_REQUIRED, then a reply with `taskId` + `contextId` | Continuation | contextId mismatch handling |
| I11 | File part (bytes), data part, URL part, both directions | Base64 and part variants | the raw-bytes bug (#65) class |
| I12 | Push notification: create / get / list / delete config; delivery to a webhook | Config CRUD and delivery body | body is a StreamResponse, `Content-Type` `application/a2a+json`, config id preserved |
| I13 | 70-second silent stream, default timeouts on both sides | Keep-alive comments are accepted by other clients | other SDKs' SSE parsers on comment-only frames **(verify)** |
| I14 | Tenant path prefix `/{tenant}/...` | Multi-tenancy | only if the other SDK supports it **(verify)** |
| I15 | Malformed body, wrong media type, unsupported `A2A-Version` | Error responses | 400 vs 415 vs 500; the spec has no type for malformed requests |

For each cell record: pass / fail / not-applicable (SDK lacks the feature), with the raw request and
response on failure.

### 1.4 Triage rule (decide *before* running, so results are not argued afterwards)

For every failure, in order:
1. Re-read the **live** spec text for that behaviour (the TCK snapshot has been stale before).
2. Run the same scenario in the control pair.
3. Classify as **ours** (fix it, add a regression test in `module-ballerina-a2a`), **theirs** (open an
   issue upstream or note as known difference), or **spec ambiguity** (record both readings, pick one,
   say why).

### 1.5 Layout in this repo

```
interop/
  python-agent/     pyproject.toml (a2a-sdk==1.1.5), agent + server, same contract as tck-sut
  python-client/    script that runs I1-I15 against a URL
  java-agent/       Maven module built from a2a-java helloworld, same contract
  java-client/      Maven module running I1-I15
  bal-checks/       Ballerina driver (same pattern as long-run-checks) running I1-I15 against a URL
  run_interop.sh    starts each agent, runs the matching clients, writes interop/RESULTS.md
```

The Ballerina driver takes the target URL and the scenario name, exactly like `long-run-checks`.

### 1.6 Optional: reuse the Java ITK

`a2a-java/itk/` already runs cross-SDK matrices over `http_json` with `send_message` and streaming
behaviours. **(verify)** whether it can take an external, non-Java/Python SUT. If it can, wire our
listener in as another "sdk" and get a second opinion for free. If not, skip: our own matrix covers it.

---

## Part 2: Authentication and the extended agent card

### 2.1 Reuse Ballerina's auth libraries; design and spike result

**Mapping of A2A's five scheme kinds to what `ballerina/http`, `ballerina/oauth2`, `ballerina/jwt` and
`ballerina/auth` already provide** (the linked Ballerina auth spec covers Basic Auth only; OAuth2 and JWT
are their own modules):

| A2A scheme | Client | Server |
|---|---|---|
| HTTP Basic | `http:CredentialsConfig` | file-store / LDAP listener handlers |
| HTTP Bearer | `http:BearerTokenConfig`, or `JwtIssuerConfig` | `ListenerJwtAuthHandler` (`jwt:validate`: shared secret, cert, trust store, JWKS URL) |
| OAuth2 | `http:OAuth2ClientCredentialsGrantConfig`, `PasswordGrantConfig`, `RefreshTokenGrantConfig`, `JwtBearerGrantConfig` | `ListenerOAuth2Handler` (introspection), or the JWT handler for JWT access tokens |
| OpenID Connect | OAuth2 grants once the token endpoint is known; no `openIdConnectUrl` discovery seen in these modules **(verify)** | JWT handler against the issuer's JWKS |
| Mutual TLS | `secureSocket` | `ListenerSecureSocket.mutualSsl` |
| API key | ours today (`CredentialProvider`) | **nothing built in: a small check of ours** |

Not covered by the grant configs: authorization-code and device-code OAuth2 flows (interactive login).
The client can still start from a refresh token it already holds.

**Proposed design (needs the user's decision).** New optional
`ListenerConfiguration.auth: http:ListenerAuthConfig[]?`, the same shape developers already write in
`@http:ServiceConfig`. Checked in the dispatcher before `ownerResolver` and before any operation:

- the public card stays open;
- missing or invalid credentials -> 401 with a `WWW-Authenticate` challenge; insufficient scope -> 403;
- if an extended card is configured and `auth` is not, the listener **fails at startup** (spec 13.3);
- the authenticated subject feeds task scoping, so 13.1 needs no hand-written resolver;
- optional: derive the card's `securitySchemes` from `auth`, so "advertised" and "enforced" cannot drift
  (this makes S-A8 true by construction).

Alternatives considered: (A) "auth in front of the listener" is **not available** through `a2a:Listener`
today (no interceptors, see evidence). (C) parsing the card's own `securityRequirements` to enforce
automatically needs a validator per scheme anyway; the `auth` field is that, made explicit.

**Spike result (2026-09-25, throwaway package, not committed to any library).** A `*http:Service` service
class shaped like our dispatcher, with one catch-all resource taking `http:Request` and using
`ListenerJwtAuthHandler` (HS256 shared secret), behaved as designed:

| Case | Result |
|---|---|
| public card, no credentials | 200 |
| extended card, no credentials / garbage token / wrong secret | 401 with `WWW-Authenticate` |
| extended card, valid token | 200, subject `alice` available |
| listener requiring scope `a2a:write`, token with only `a2a:read` | 403 |
| same, token with `a2a:write` | 200 |
| expired token | 401 |

Two implementation notes from it:
1. `authenticate` returns `jwt:Payload|http:Unauthorized`, and `Payload` is an open record, so `is Unauthorized`
   does **not** narrow the union; an explicit cast is needed after the check.
2. With no `Authorization` header the handler still logs an ERROR ("Authorization header not available").
   The real implementation should test for the header first and skip the handler when it is absent.

The spike did not cover OAuth2 introspection, file/LDAP Basic, SSE requests, or the wiring into
`ownerResolver`; those remain Phase 0 items.

Phase 0 must still answer, with evidence:
- What do Python and Java do for the extended card? Is it gated, and by what?
- What does the live spec say the 401/403 body should look like for the HTTP+JSON binding?
- Can the authenticated subject reach `ownerResolver` cleanly, or does the resolver contract change?

### 2.2 Server-side tests (our listener)

Set-up: listener with a Bearer scheme declared on the card, a deterministic token check in front of it
(mechanism per the decision), an `ownerResolver` mapping the token to `alice` / `bob`, and an extended
card configured.

| Id | Case | Expected |
|---|---|---|
| S-A1 | `GET /.well-known/agent-card.json` with no credentials | 200. The public card is public |
| S-A2 | `GET /extendedAgentCard` with no credentials | 401 (per decision and live spec) |
| S-A3 | Same, with a wrong token | 401 or 403, whichever the spec says |
| S-A4 | Same, with the right token | 200 and the *extended* card, with `capabilities.extendedAgentCard: true` on the public one |
| S-A5 | `message:send` with no credentials | rejected before reaching the agent (agent code never runs: assert with a counter) |
| S-A6 | alice creates a task; bob calls `GetTask`, `ListTasks`, `CancelTask`, `SubscribeToTask` on it | `TASK_NOT_FOUND` for get/cancel/subscribe; absent from bob's list |
| S-A7 | bob registers a push config on alice's task | `TASK_NOT_FOUND` |
| S-A8 | Card says `securityRequirements`, server enforces nothing | **Consistency check**: the test fails when advertised != enforced. Encodes the gap we found |
| S-A9 | Extended card configured but `capabilities.extendedAgentCard` false (and the reverse) | typed errors per spec, not a 500 |
| S-A10 | Error body for 401/403 | `google.rpc.Status` shape the client can decode, or plain HTTP error; note which |
| S-A11 | Extended card configured, no `auth` configured | listener refuses to start (spec 13.3) |
| S-A12 | JWT with a `scope` claim below the configured scopes | 403; the message does not name resources |
| S-A13 | Streaming (`message:stream`, `subscribe`) with no / invalid credentials | rejected as a plain 401 *before* the SSE stream opens, not as an SSE error event |
| S-A14 | API-key scheme (header) declared on the card | enforced by the small custom check; missing or wrong key -> 401 |
| S-A15 | Mutual TLS (`mutualSsl`, `verifyClient = REQUIRE`) | call without a client certificate fails at the TLS layer (needs the HTTPS follow-up) |

### 2.3 Client-side tests (`a2a:HttpClient`)

Against our listener with auth, and against the Python agent with auth (a Starlette middleware checking a
static bearer token, **(verify)** the cleanest way in SDK 1.1.5).

| Id | Case | Expected |
|---|---|---|
| C-A1 | Card declares `Bearer`; client configured with a credential store holding the token | requests carry `Authorization: Bearer ...`; call succeeds |
| C-A2 | Store has no credential for the required scheme | clear local error, no request sent (or a 401 mapped to a typed error; **record which**) |
| C-A3 | Server answers 401 | client surfaces a typed authentication error, not `InvalidAgentResponse` / `InternalError` |
| C-A4 | Server answers 403 | same, distinguishable from 401 |
| C-A5 | Token rotated in the store between two calls | second call uses the new token (unit test already covers header building; this proves it over the wire) |
| C-A6 | API-key scheme (header) and HTTP Basic | same as C-A1 |
| C-A7 | Two requirements offered (OR): only the second is satisfiable | second is chosen |
| C-A8 | `GetExtendedAgentCard` with and without credentials | as S-A2 / S-A4 seen from the client |
| C-A9 | Credential attached to an SSE stream request | header present on `message:stream` and `subscribe`, not just unary calls |

### 2.4 Cross-SDK auth

| Id | Case |
|---|---|
| X-A1 | Python client with its `AuthInterceptor` + `CredentialService` -> our listener with Bearer. Authenticated calls succeed, unauthenticated are rejected |
| X-A2 | Java client (its auth interceptor **(verify)**) -> our listener |
| X-A3 | Our client -> Python agent with Bearer (this is C-A1 against a foreign server) |
| X-A4 | Our client -> Java agent with a security sample, if one speaks v1 over HTTP+JSON **(verify)** |

### 2.5 Out of scope here (noted so it is not forgotten)

- HTTPS / mutual TLS. Bearer tokens over plain HTTP are only acceptable on localhost; a follow-up plan
  should run the same cases over `secureSocket` with a self-signed certificate.
- OAuth2 / OIDC flows that mint tokens (only the resulting header is tested).
- Agent card signature verification (`signatures` is parsed and never verified).

---

## Order of work

| Phase | Work | Done when |
|---|---|---|
| 0 | Spikes: install `a2a-sdk==1.1.5`; build Java `helloworld`; confirm both speak HTTP+JSON v1; read how Python and Java gate the extended card; extend the JWT spike to OAuth2 introspection, file-store Basic and an SSE request; confirm the live spec's 401/403 text | Every **(verify)** above is resolved or struck. **The `auth` field design (2.1) is put to the user** |
| 1 | Port the `tck-sut` contract to Python and Java agents; get I1-I3 green on the control pair | Control pair passes I1-I3 |
| 2 | Pairs A and C with I1-I12 (Python), then B and D (Java) | `RESULTS.md` has a full grid with a failure classification per cell |
| 3 | I13 (70 s silent stream) and I14-I15 on every pair | Grid complete |
| 4 | Part 2 server-side tests (S-A*) once the decision is made | All pass, or the failures are filed |
| 5 | Part 2 client-side and cross-SDK (C-A*, X-A*) | Same |
| 6 | For each "ours" failure: fix + regression test in `module-ballerina-a2a`; update the "The A2A Test Run" artifact | Nothing left classified "ours" and unfixed |

## Deliverables

- `interop/` directory (layout above), pinned SDK versions, runnable with one script
- `interop/RESULTS.md`: the grid, with each failure classified and linked to an issue or commit
- README section on how authentication is meant to be used with the listener (whichever option is chosen)
- Regression tests in `module-ballerina-a2a` for every bug found

## Risks

- **Python samples are not v1.** Mitigated by pinning `a2a-sdk==1.1.5` and writing the agent ourselves.
- **SDK v1 is young.** A failure may be theirs. The control pair is what tells us.
- **Java build weight.** A Maven build of `a2a-java` is heavy; prefer released `1.2.0.Final` artifacts over
  building the checkout **(verify availability)**.
- **Two agents, one contract.** The Python and Java agents must implement the contract identically; a
  shared scenario spec (table above) is the guard.
- **Auth decision blocks Part 2.** Phases 0-3 do not depend on it, so interop can start immediately.
