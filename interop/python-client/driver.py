"""The real a2a-sdk 1.1.5 Client against ballerina/a2a's Listener (pair C in
INTEROP_AND_AUTH_TEST_PLAN.md): does an actual other-language client resolve
our card, negotiate the HTTP+JSON binding, and drive a full exchange.

Talks to a ballerina/a2a listener started separately (see run_pair_c.sh).
"""

import asyncio
import sys
import uuid

from a2a.client.client import ClientConfig
from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client_factory import ClientFactory
from a2a.client.errors import A2AClientError
from a2a.utils.errors import A2AError, TaskNotCancelableError, TaskNotFoundError
import httpx
from a2a.types import (
    CancelTaskRequest,
    GetTaskRequest,
    Message,
    Part,
    Role,
    SendMessageRequest,
    TaskState,
)
from a2a.utils.constants import TransportProtocol


def msg(text: str, message_id: str | None = None) -> Message:
    return Message(
        message_id=message_id or str(uuid.uuid4()),
        role=Role.ROLE_USER,
        parts=[Part(text=text)],
    )


async def main() -> None:
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9611"
    ok = True

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal ok
        print(f"{'PASS' if cond else 'FAIL'}: {label}" + (f" -- {detail}" if detail and not cond else ""))
        ok = ok and cond

    # HTTP+JSON must be requested explicitly: an empty supported_protocol_bindings
    # list means "JSON-RPC only" in this SDK, and ballerina/a2a speaks only
    # HTTP+JSON -- the binding-coverage caveat from the plan, confirmed here.
    print("== I1: resolve card and negotiate the binding ==")
    httpx_client = httpx.AsyncClient()
    card = await A2ACardResolver(httpx_client, url).get_agent_card()
    check("card resolved", card.name != "")
    print(f"  agent: {card.name!r}")

    config = ClientConfig(
        httpx_client=httpx_client,
        supported_protocol_bindings=[TransportProtocol.HTTP_JSON],
    )
    factory = ClientFactory(config)
    client = factory.create(card)

    print("== I2/I3: send a message, merging the StreamResponse events the SDK yields ==")
    # send_message always returns an async iterator of StreamResponse -- even
    # for a "blocking" send, per its own docstring. The caller merges the
    # initial Task snapshot with the TaskStatusUpdateEvent/TaskArtifactUpdateEvent
    # that follow; there is no separate blocking call that hands back one
    # final Task. Same shape our own client's raw sendStreamingMessage has;
    # our sendMessage does this merging for the caller, this SDK does not.
    task = None
    async for response in client.send_message(SendMessageRequest(message=msg("Paris"))):
        if response.task.id:
            task = response.task
        elif task is not None and response.status_update.task_id == task.id:
            task.status.CopyFrom(response.status_update.status)
        elif task is not None and response.artifact_update.task_id == task.id:
            task.artifacts.append(response.artifact_update.artifact)
    check("got a task", task is not None)
    if task is not None:
        check(
            "task completed",
            task.status.state == TaskState.TASK_STATE_COMPLETED,
            f"state={task.status.state}",
        )
        check("artifact carried through", len(task.artifacts) > 0 and task.artifacts[0].parts[0].text.startswith("echo:"))

    print("== I7: getTask on an unknown id -> a client error, not a crash ==")
    try:
        await client.get_task(GetTaskRequest(id="no-such-task-ever"))
        check("unknown id raises", False, "no exception raised")
    except TaskNotFoundError as e:
        # This is the finding: our server's 404 + reason "TASK_NOT_FOUND" is
        # recognised by the *reference* Python client and raised as its own
        # typed TaskNotFoundError -- the same named condition ballerina/a2a's
        # client would raise, not a generic HTTP failure.
        check("unknown id raises the SDK's typed TaskNotFoundError", True)
        print(f"  {e}")
    except A2AError as e:
        check("unknown id raises the SDK's typed TaskNotFoundError", False, f"raised {type(e).__name__} instead: {e}")

    if task is not None:
        print("== getTask on the real id ==")
        fetched = await client.get_task(GetTaskRequest(id=task.id))
        check("fetched matches", fetched.id == task.id)

        print("== cancelTask on a completed task -> the SDK's typed TaskNotCancelableError ==")
        try:
            await client.cancel_task(CancelTaskRequest(id=task.id))
            check("cancel of completed task raises", False, "no exception raised")
        except TaskNotCancelableError as e:
            check("cancel of completed task raises TaskNotCancelableError", True)
            print(f"  {e}")
        except A2AError as e:
            check("cancel of completed task raises TaskNotCancelableError", False, f"raised {type(e).__name__} instead: {e}")

    await client.close()
    print("\nOVERALL:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    asyncio.run(main())
