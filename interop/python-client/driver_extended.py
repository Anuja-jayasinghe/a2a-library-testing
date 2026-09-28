"""Extended pair-C scenarios (I4, I5, I9, I10, I12, I13, I14, I15 from
INTEROP_AND_AUTH_TEST_PLAN.md): the real a2a-sdk 1.1.5 Client against
ballerina/a2a's Listener (bal-listener/, same "interop-<kind>-<n>" contract
as python-agent/agent.py).
"""

import asyncio
import json
import os
import sys
import time
import uuid

import httpx

from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client import ClientConfig
from a2a.client.client_factory import ClientFactory
from a2a.types import (
    CancelTaskRequest,
    GetTaskRequest,
    ListTasksRequest,
    Message,
    Part,
    Role,
    SendMessageConfiguration,
    SendMessageRequest,
    SubscribeToTaskRequest,
    TaskPushNotificationConfig,
    TaskState,
)
from a2a.utils.constants import TransportProtocol

PUSH_RECEIVER_OUT_FILE = "/tmp/push_receiver_last_c.json"


def msg(message_id: str, text: str, task_id: str | None = None, context_id: str | None = None) -> Message:
    return Message(
        message_id=message_id,
        role=Role.ROLE_USER,
        parts=[Part(text=text)],
        task_id=task_id or "",
        context_id=context_id or "",
    )


async def first_task_snapshot(client, request: SendMessageRequest):
    """Takes only the first StreamResponse item -- what `returnImmediately`
    is actually for. `collect_final_task` below drains the whole stream to
    the terminal state regardless of returnImmediately, which is right for
    I2/I3 (the point there is the final result) but wrong for I4/I9, where
    the point is to observe the task *before* it finishes."""
    async for response in client.send_message(request):
        return response.task if response.task.id else None
    return None


PAUSED_STATES = (TaskState.TASK_STATE_INPUT_REQUIRED, TaskState.TASK_STATE_AUTH_REQUIRED)
TERMINAL_STATES = (
    TaskState.TASK_STATE_COMPLETED, TaskState.TASK_STATE_FAILED,
    TaskState.TASK_STATE_CANCELED, TaskState.TASK_STATE_REJECTED,
)


async def collect_final_task(client, request: SendMessageRequest):
    """Merges the StreamResponse events send_message yields into one Task
    (see interop/RESULTS.md finding 3): there is no separate blocking call.

    Stops at a terminal *or interrupted* state and does not wait for the
    stream to close on its own: ballerina/a2a's message:stream deliberately
    keeps the connection open on TASK_STATE_INPUT_REQUIRED/AUTH_REQUIRED
    (sse.bal, matching its blocking sendMessage's own documented contract --
    "blocks until the task reaches a terminal or interrupted state" -- and
    design section 8.1), so a caller that wants "the next thing to say" must
    stop there itself rather than wait for EOF."""
    task = None
    async for response in client.send_message(request):
        if response.task.id:
            task = response.task
        elif task is not None and response.status_update.task_id == task.id:
            task.status.CopyFrom(response.status_update.status)
        elif task is not None and response.artifact_update.task_id == task.id:
            task.artifacts.append(response.artifact_update.artifact)
        # Only a status *update* can end the wait: a continuation's opening
        # Task snapshot is legitimately still INPUT_REQUIRED (the state it
        # was left in), and breaking on that would return before the turn ran.
        if (response.status_update.task_id and task is not None
                and task.status.state in PAUSED_STATES + TERMINAL_STATES):
            break
    return task


async def main() -> None:
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9611"
    ok = True

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal ok
        print(f"{'PASS' if cond else 'FAIL'}: {label}" + (f" -- {detail}" if detail else ""))
        ok = ok and cond

    httpx_client = httpx.AsyncClient()
    card = await A2ACardResolver(httpx_client, url).get_agent_card()
    config = ClientConfig(httpx_client=httpx_client, supported_protocol_bindings=[TransportProtocol.HTTP_JSON])
    client = ClientFactory(config).create(card)

    print("== I4: returnImmediately + poll ==")
    task = await first_task_snapshot(client, SendMessageRequest(
        message=msg("interop-task-paced-" + str(uuid.uuid4())[:8], "poll me"),
        configuration=SendMessageConfiguration(return_immediately=True),
    ))
    check("got an immediate, non-terminal task", task is not None and task.status.state != TaskState.TASK_STATE_COMPLETED,
          f"state={task.status.state if task else None}")
    if task is not None:
        state = task.status.state
        for _ in range(20):
            polled = await client.get_task(GetTaskRequest(id=task.id))
            state = polled.status.state
            if state == TaskState.TASK_STATE_COMPLETED:
                break
            await asyncio.sleep(0.3)
        check("polled to completion", state == TaskState.TASK_STATE_COMPLETED, f"state={state}")

    print("== I9: subscribe to an already-running task ==")
    task2 = await first_task_snapshot(client, SendMessageRequest(
        message=msg("interop-task-paced-" + str(uuid.uuid4())[:8], "subscribe me"),
        configuration=SendMessageConfiguration(return_immediately=True),
    ))
    saw_completed = False
    if task2 is not None:
        count = 0
        async for response in client.subscribe(SubscribeToTaskRequest(id=task2.id)):
            count += 1
            if response.status_update.status.state == TaskState.TASK_STATE_COMPLETED:
                saw_completed = True
                break
            if response.task.id and response.task.status.state == TaskState.TASK_STATE_COMPLETED:
                saw_completed = True
                break
            if count > 20:
                break
    check("subscribed and observed completion", saw_completed)

    print("== I10: multi-turn continuation ==")
    turn1 = await collect_final_task(client, SendMessageRequest(
        message=msg("interop-task-input-required-1", "plan a trip"),
    ))
    check("first turn is INPUT_REQUIRED", turn1 is not None and turn1.status.state == TaskState.TASK_STATE_INPUT_REQUIRED,
          f"state={turn1.status.state if turn1 else None}")
    if turn1 is not None:
        turn2 = await collect_final_task(client, SendMessageRequest(
            message=msg("interop-continue-1", "Paris", task_id=turn1.id, context_id=turn1.context_id),
        ))
        check("continued on the same task id, to completion",
              turn2 is not None and turn2.id == turn1.id and turn2.status.state == TaskState.TASK_STATE_COMPLETED)

    print("== I5: ListTasks with pageSize ==")
    listed = await client.list_tasks(ListTasksRequest(page_size=2))
    check("ListTasks respects pageSize", len(listed.tasks) <= 2, f"got {len(listed.tasks)}")

    print("== I6: cancel a completed task ==")
    done = await collect_final_task(client, SendMessageRequest(message=msg(str(uuid.uuid4()), "done quickly")))
    try:
        await client.cancel_task(CancelTaskRequest(id=done.id))
        check("cancel of completed task raises", False, "no exception")
    except Exception as e:  # a2a.utils.errors.TaskNotCancelableError
        check("cancel of completed task raises TaskNotCancelableError", type(e).__name__ == "TaskNotCancelableError",
              type(e).__name__)

    print("== I12: push notifications ==")
    if os.path.exists(PUSH_RECEIVER_OUT_FILE):
        os.remove(PUSH_RECEIVER_OUT_FILE)
    task3 = await first_task_snapshot(client, SendMessageRequest(
        message=msg("interop-task-paced-" + str(uuid.uuid4())[:8], "notify me"),
        configuration=SendMessageConfiguration(
            return_immediately=True,
            task_push_notification_config=TaskPushNotificationConfig(url="http://localhost:19871/hook"),
        ),
    ))
    delivered = False
    body = None
    for _ in range(20):
        if os.path.exists(PUSH_RECEIVER_OUT_FILE):
            with open(PUSH_RECEIVER_OUT_FILE) as f:
                body = f.read()
            delivered = True
            break
        await asyncio.sleep(0.3)
    check("webhook delivered", delivered, body or "not delivered")
    if delivered:
        parsed = json.loads(body)
        check("delivered as a StreamResponse envelope ({\"task\": ...})", "task" in parsed, str(list(parsed.keys())))

    print("== I15: malformed body -> 400, not 500 ==")
    r = await httpx_client.post(f"{url}/message:send", content="{not json",
                                 headers={"A2A-Version": "1.0", "Content-Type": "application/json"})
    check("malformed JSON is 400", r.status_code == 400, f"got {r.status_code}")

    print("== I14: tenancy (does the server accept a tenant-prefixed path?) ==")
    r2 = await httpx_client.get(f"{url}/acme-corp/tasks", headers={"A2A-Version": "1.0"})
    # Our listener requires the tenant to match the card's declared one; this
    # agent declares none, so a tenant prefix is expected to be rejected.
    # The scenario's value is confirming *that* -- a clear, typed rejection,
    # not a hang or a 500.
    check("tenant prefix answers cleanly (not 500/hang)", r2.status_code in (400, 404),
          f"got {r2.status_code}: {r2.text[:200]}")

    await client.close()
    print("\nOVERALL:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    asyncio.run(main())
