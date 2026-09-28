"""A deterministic (no-LLM) A2A agent on the real a2a-sdk 1.1.5, for interop
testing against ballerina/a2a.

Behaviour is keyed off a prefix of the inbound message's messageId, the same
in-band-signal contract tck-sut implements (../../tck-sut/main.bal) -- ported
here, not reinvented, so a result on one side means the same thing on the
other. This first pass covers a subset (Part 1's I1-I3, I6, I7 in
INTEROP_AND_AUTH_TEST_PLAN.md); more prefixes are added as the grid grows.

Serves the REST/HTTP+JSON binding only -- the same one ballerina/a2a speaks
-- via the SDK's own FastAPI routes and DefaultRequestHandlerV2, not hand
rolled: this is a real interop counterpart, not a stand-in.
"""

import os
import sys
import time

import jwt as pyjwt
import uvicorn
from fastapi import FastAPI, Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events.event_queue_v2 import EventQueue
from a2a.server.request_handlers.default_request_handler_v2 import (
    DefaultRequestHandlerV2,
)
from a2a.server.routes.agent_card_routes import create_agent_card_routes
from a2a.server.routes.fastapi_routes import add_a2a_routes_to_fastapi
from a2a.server.routes.rest_routes import create_rest_routes
from a2a.server.tasks.inmemory_task_store import InMemoryTaskStore
from a2a.server.tasks.task_updater import TaskUpdater
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentInterface,
    AgentSkill,
    Message,
    Part,
    Role,
    Task,
    TaskState,
    TaskStatus,
)

TCK_SKILL = AgentSkill(
    id="interop",
    name="Interop",
    description="Handles deterministic interop test messages",
    tags=["interop"],
)


def build_card(port: int) -> AgentCard:
    return AgentCard(
        name="Python A2A Interop Agent",
        description="Deterministic, non-LLM agent on a2a-sdk 1.1.5, for interop testing against ballerina/a2a",
        version="1.0.0",
        skills=[TCK_SKILL],
        default_input_modes=["text"],
        default_output_modes=["text"],
        capabilities=AgentCapabilities(streaming=True, push_notifications=False),
        supported_interfaces=[
            AgentInterface(
                url=f"http://localhost:{port}",
                protocol_binding="HTTP+JSON",
                protocol_version="1.0",
            )
        ],
    )


def inbound_text(context: RequestContext) -> str:
    message = context.message
    if message is None:
        return ""
    return "".join(part.text for part in message.parts if part.text)


class InteropAgentExecutor(AgentExecutor):
    """Mirrors tck-sut's TckAgentService.onMessage, prefix for prefix."""

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        message_id = context.message.message_id if context.message else ""
        text = inbound_text(context)

        # I2: a direct Message reply, no task at all.
        if message_id.startswith("interop-message-response"):
            await event_queue.enqueue_event(
                Message(
                    message_id="reply-1",
                    role=Role.ROLE_AGENT,
                    parts=[Part(text="Direct message response")],
                )
            )
            return

        updater = TaskUpdater(event_queue, context.task_id, context.context_id)
        # The Python SDK, unlike ballerina/a2a's TaskUpdater, does not create
        # the initial Task for you: the agent enqueues it before any status
        # update. Real, documented behaviour (a2a.helpers.new_task), not a
        # workaround -- and the source of the first interop finding: sending
        # a completed task against ballerina/a2a's listener failed here until
        # this line was added.
        await event_queue.enqueue_event(
            Task(
                id=context.task_id,
                context_id=context.context_id,
                status=TaskStatus(state=TaskState.TASK_STATE_SUBMITTED),
                history=[context.message] if context.message else [],
            )
        )

        # I6: a task that cannot be canceled once completed -- reached by
        # completing immediately, then the test cancels it afterwards.
        if message_id.startswith("interop-task-immediate-complete"):
            await updater.start_work()
            await updater.add_artifact([Part(text=f"echo: {text}")], name="result")
            await updater.complete()
            return

        # A task that stays cancelable: WORKING and never completes here; the
        # test drives the cancel itself.
        if message_id.startswith("interop-task-cancelable"):
            await updater.start_work()
            return

        # I10 (half): pause for more input.
        if message_id.startswith("interop-task-input-required"):
            await updater.start_work()
            await updater.requires_input(
                updater.new_agent_message([Part(text="which city?")])
            )
            return

        # A failure, cleanly reported.
        if message_id.startswith("interop-task-fail"):
            await updater.start_work()
            await updater.failed(
                updater.new_agent_message([Part(text="deliberate interop failure")])
            )
            return

        # I11: echo raw bytes back as text, so a test can see exactly what
        # bytes this agent received.
        if context.message is not None:
            for part in context.message.parts:
                if part.raw:
                    await updater.start_work()
                    await updater.add_artifact(
                        [Part(text=f"raw: {part.raw.decode('utf-8', 'replace')}")]
                    )
                    await updater.complete()
                    return

        # Default: I3. A completed task with one text artifact.
        await updater.start_work()
        await updater.add_artifact([Part(text=f"echo: {text}")], name="result")
        await updater.complete()

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        updater = TaskUpdater(event_queue, context.task_id, context.context_id)
        await updater.cancel()


# X-A3 (INTEROP_AND_AUTH_TEST_PLAN.md): a shared secret this agent validates
# a Bearer JWT against, when INTEROP_REQUIRE_AUTH is set. Not part of the SDK
# -- a2a-sdk 1.1.5 has no built-in server-side auth of its own, so this is
# the same "auth lives in front of the app" pattern ballerina/a2a's own
# design considered and could have taken; a plain Starlette middleware,
# nothing A2A-specific.
INTEROP_AUTH_SECRET = "interop-auth-shared-secret-0123456789"


class RequireBearerMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path == "/.well-known/agent-card.json":
            return await call_next(request)
        header = request.headers.get("authorization", "")
        if not header.lower().startswith("bearer "):
            return JSONResponse({"error": "missing bearer credential"}, status_code=401,
                                 headers={"WWW-Authenticate": "Bearer"})
        token = header[len("bearer "):]
        try:
            pyjwt.decode(token, INTEROP_AUTH_SECRET, algorithms=["HS256"], audience="a2a", issuer="interop")
        except pyjwt.PyJWTError as e:
            return JSONResponse({"error": f"invalid credential: {e}"}, status_code=401,
                                 headers={"WWW-Authenticate": "Bearer"})
        return await call_next(request)


def build_app(port: int) -> FastAPI:
    card = build_card(port)
    if os.environ.get("INTEROP_REQUIRE_AUTH"):
        card = card.__class__()
        card.CopyFrom(build_card(port))
        card.security_schemes["bearerAuth"].http_auth_security_scheme.scheme = "Bearer"
        card.security_schemes["bearerAuth"].http_auth_security_scheme.bearer_format = "JWT"
        card.security_requirements.add().schemes["bearerAuth"].list.extend([])
    handler = DefaultRequestHandlerV2(
        agent_executor=InteropAgentExecutor(),
        task_store=InMemoryTaskStore(),
        agent_card=card,
    )
    app = FastAPI()
    if os.environ.get("INTEROP_REQUIRE_AUTH"):
        app.add_middleware(RequireBearerMiddleware)
    add_a2a_routes_to_fastapi(
        app,
        agent_card_routes=create_agent_card_routes(card),
        rest_routes=create_rest_routes(handler),
    )
    return app


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9700
    uvicorn.run(build_app(port), host="0.0.0.0", port=port, log_level="warning")
