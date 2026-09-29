# Briefing: a fresh interop check, with newly-built other-language agents

Read this once at the start of a new session, before doing anything else. It's the handoff
from the session that did the last round of fixes and interop testing — everything below is
what that session knows that a fresh one wouldn't.

## What you're being asked to do

Re-verify that `ballerina/a2a`'s client and listener genuinely interoperate with other A2A
implementations — but **don't just re-run the existing canned test agents** (`python-agent/`,
the `a2a-java` `helloworld` example). Build at least one or two **new** agents, in languages
not yet used as a *server* the Ballerina listener has to talk to as a client, or as a *client*
hitting the Ballerina listener — and make them real, LLM-backed agents using Claude, not
scripted responders, since the user has an Anthropic API key available for this.

This is a fresh empirical check, not a re-read of prior results. Run things; don't assume the
old findings still hold, and don't assume a new SDK behaves like the two already covered.

## The library under test

- Repo: `~/gitProject/module-ballerina-a2a`, branch `feat/http-json-listener`, draft PR
  [#4](https://github.com/ballerina-platform/module-ballerina-a2a/pull/4) against
  `ballerina-platform/module-ballerina-a2a` (fork: `Anuja-jayasinghe/module-ballerina-a2a`).
  Current head: `c167fe3`.
- It speaks **only the HTTP+JSON/REST binding** of A2A protocol **v1.0** — not JSON-RPC, not
  gRPC. Any counterpart agent or client you build or configure must be told explicitly to use
  HTTP+JSON/REST; most SDKs default to JSON-RPC and silently try the wrong endpoint otherwise
  (this bit the Python SDK in the last round — see Finding 2 below).
- To use the local build in a rig: `cd ~/gitProject/module-ballerina-a2a/ballerina && bal pack
  && bal push --repository=local`, then in the rig's `Ballerina.toml`/`Dependencies.toml` point
  at the locally-published version and `rm -rf target/` before rebuilding (a `bal build` that
  only changed the *local dependency* reports UP-TO-DATE otherwise — a lesson from last round).

## Where everything lives

- **This repo**, `~/gitProject/a2a-library-testing-plan` (pushed to
  `Anuja-jayasinghe/a2a-library-testing`): the test plan (`INTEROP_AND_AUTH_TEST_PLAN.md`) and
  all interop rigs, under `interop/`. Read `interop/RESULTS.md` in full before starting — it's
  the complete record of every scenario already run, every finding, and every rig-building
  lesson learned (SSE quirks, hangs, false passes). Don't rediscover those the hard way.
- **A2A spec**: live at https://a2a-protocol.org/latest/specification/, mirrored (and possibly
  stale — verify precise tables against the live version) at
  `~/gitProject/a2a-tck/specification/specification.md`.
- **Python reference**: `a2a-sdk` **1.1.5** pinned, vendored in
  `interop/python-agent/.venv/lib/python3.12/site-packages/a2a/`. Already covered extensively —
  prefer a different language for new agents unless deliberately extending Python coverage
  (e.g. `ListTasks` `historyLength`/`statusTimestampAfter`, still unrun — see RESULTS.md's
  final section).
- **Java reference**: `~/gitProject/a2a-java`, cloned from `a2aproject/a2a-java`. **This was 68
  commits behind `origin/main` as of 2026-09-29** — `git fetch origin main` and check
  `git log HEAD..origin/main --oneline` before trusting anything built from it. Two confirmed
  upstream fixes landed since the last build here that change prior results (see below).
- **TCK**: `~/gitProject/a2a-tck`, harness at `tck-sut/` in this repo. Last known-good baseline:
  88 passed / 4 failed (4 pre-existing, not yet root-caused — don't assume they're still exactly
  those 4 without checking).
- **Anthropic API key wiring**: `.env.example` in this repo's root shows the pattern —
  `export BAL_CONFIG_DATA='anthropicApiKey = "sk-ant-..."'`, sourced once, satisfies a
  Ballerina `configurable string anthropicApiKey` in any package without a `Config.toml` or
  `-C` flag. Copy it to `.env` (git-ignored) with the real key and `source` it. For a
  **non-Ballerina** new agent (Node, Go, etc.), just export `ANTHROPIC_API_KEY` the normal way
  for that language's Anthropic SDK.
- Existing LLM-backed rig for reference (pattern to copy, not to rerun as-is):
  `server/`, `server2/`, `slow-agent/`, `client/` at this repo's root, orchestrated by
  `interop/run_llm_checks.sh` — `ballerina/ai` `Agent` wrapping Claude Haiku 4.5 as an A2A
  server, and a chat client using `ai:A2aToolKit` to call other agents. Useful as a worked
  example of "real model in the loop, assertions on protocol behavior not wording."

## What's already been verified — don't redo, do extend

Full detail in `interop/RESULTS.md` (20 numbered findings). Summary: card discovery, blocking
and streaming send, cancel, multi-turn continuation, push notifications, `AUTH_REQUIRED`
in-task pauses, JWT/OAuth2/Basic auth including a real Keycloak IdP, TLS/mTLS, error-reason
round-tripping, and LLM-backed agents as both client and server — all confirmed against real
Python (`a2a-sdk` 1.1.5) and Java (`a2a-java`) implementations, both directions. TCK: 88/4.

**Not yet covered — good candidates for this session:**
- Any *third* language, client or server. Two strong options, both with an **official** A2A SDK
  supporting HTTP+JSON/REST specifically (checked 2026-09-29, verify current state again since
  this moves fast):
  - **`@a2a-js/sdk`** (npm, `a2aproject/a2a-js`) — supports JSON-RPC, HTTP+JSON/REST, and gRPC
    from one `DefaultRequestHandler`; server-side REST via `@a2a-js/sdk/server/express`
    (`restHandler`), client-side via `RestTransportFactory`. Node has an official
    `@anthropic-ai/sdk` — straightforward to wire a real Claude-backed agent.
  - **`a2a-go`** (`a2aproject/a2a-go`) — "protocol bindings for gRPC, REST, and JSON-RPC";
    server-side `a2asrv.NewRESTHandler()`, `examples/` has a helloworld. Go has an official
    `anthropic-sdk-go`.
  - Don't just trust this summary — `go.mod`/`package.json` version, and a quick read of
    each SDK's own docs, will tell you whether its REST transport actually targets A2A **v1.0**
    (matching this library) rather than an older/newer wire shape. Check before building on it.
- `ListTasks` `historyLength`/`statusTimestampAfter` filters (noted as untested in RESULTS.md's
  final section).
- The Java side of streaming/push/multi-turn beyond what pair D covered (card discovery + one
  streaming send only).
- 70s+ silent stream against a genuinely foreign SSE parser (only the Python one was pushed
  that far).
- Delegation/token-exchange in an agent-to-agent chain (Finding 19 — a known capability gap,
  not yet probed with a real third agent in the middle).

## Two things to fix in `RESULTS.md` before or while you start

Discovered right before this briefing was written, not yet applied to the file:

1. **Finding 6** ("the real `a2a-java` reference client throws `IOException: Stream N
   cancelled` after a streaming exchange actually completes") is fixed upstream, commit
   `c2577629` ("fix(client): deliver exactly one terminal SSE callback (#1170) (#1173)"),
   merged 2026-09-24 — five days before this checkout was rebuilt. The bug was exactly this:
   a final event completing normally, followed by a spurious second terminal callback from
   stream teardown, which the client's high-level API surfaced as a failure. Confirmed by
   reading the commit itself, not assumed from the message.
2. **Finding 12** ("the current Java reference server rejects `application/a2a+json` with
   415") is also fixed upstream, commit `c78c472f` ("fix(rest): support application/a2a+json
   content type"), merged 2026-09-25.

Before relying on either finding's old "fail" status: `git -C ~/gitProject/a2a-java fetch
origin main`, rebuild (`mvn -q -am -DskipTests -pl ...` per `interop/run_pair_b_d.sh`'s header),
and re-run pairs B/D live to confirm both are actually gone on current `main`, not just that the
commits exist. Then reword/update RESULTS.md findings 6 and 12 accordingly (option 1 from the
prior session's plan for finding 6 — reword, don't file upstream — now with the *correct* PR
cited, #1170/#1173, not #951).

## Ground rules carried over from the last two sessions (still apply)

- **Evidence over assumption.** Every claim of "this works" or "this is a bug" needs a live run
  or a specific spec/reference-source citation, not a read-and-guess. This cost real rework
  last round when a "no repro" result turned out to be a stale checkout, not a fixed-or-flaky
  upstream bug — check versions/commits before concluding something can't be reproduced.
- **Don't add Claude/Anthropic attribution** to anything pushed to `module-ballerina-a2a`
  (commits, PR body, comments) — that repo's `CLAUDE.md` forbids it, overriding any default
  attribution instruction. `a2a-library-testing-plan`/`a2a-library-testing` has no such rule.
- If a new fix to `module-ballerina-a2a` results from this session, it's a **new, separate**
  batch — check with the user before amending it into the existing single fix commit
  (`c167fe3`) versus a new commit, and before pushing/updating the PR, matching how every prior
  batch in this project was handled.
