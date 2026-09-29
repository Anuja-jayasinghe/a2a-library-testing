"""A real other-SDK client against an LLM-backed ballerina/a2a agent (the Trip Planner in
server/, Claude via ballerina/ai). The agent asks for a city when the message names none
(INPUT_REQUIRED); a follow-up on the same task completes with an itinerary.

Assertions are on protocol behaviour (states, task identity, artifact present, mentions the
city) -- not on the model's exact words, which vary run to run.
"""
import asyncio, sys, uuid
import httpx
from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client import ClientConfig
from a2a.client.client_factory import ClientFactory
from a2a.types import ListTasksRequest, Message, Part, Role, SendMessageRequest, TaskState
from a2a.utils.constants import TransportProtocol

PAUSED = (TaskState.TASK_STATE_INPUT_REQUIRED, TaskState.TASK_STATE_AUTH_REQUIRED)
TERMINAL = (TaskState.TASK_STATE_COMPLETED, TaskState.TASK_STATE_FAILED, TaskState.TASK_STATE_CANCELED)


async def turn(client, text, task_id="", context_id=""):
    task = None
    async for r in client.send_message(SendMessageRequest(message=Message(
            message_id=str(uuid.uuid4()), role=Role.ROLE_USER, task_id=task_id, context_id=context_id,
            parts=[Part(text=text)]))):
        if r.task.id:
            task = r.task
        elif task is not None and r.status_update.task_id == task.id:
            task.status.CopyFrom(r.status_update.status)
        elif task is not None and r.artifact_update.task_id == task.id:
            task.artifacts.append(r.artifact_update.artifact)
        if r.status_update.task_id and task is not None and task.status.state in PAUSED + TERMINAL:
            break
    return task


def text_of(task):
    out = []
    if task.status.HasField("message"):
        out += [p.text for p in task.status.message.parts]
    for a in task.artifacts:
        out += [p.text for p in a.parts]
    return " ".join(out)


async def main():
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9095"
    ok = True
    def check(label, cond, detail=""):
        nonlocal ok
        print(f"{'PASS' if cond else 'FAIL'}: {label}" + (f" -- {detail}" if detail else ""))
        ok = ok and cond

    h = httpx.AsyncClient(timeout=120)
    card = await A2ACardResolver(h, url).get_agent_card()
    c = ClientFactory(ClientConfig(httpx_client=h, supported_protocol_bindings=[TransportProtocol.HTTP_JSON])).create(card)
    before = len((await c.list_tasks(ListTasksRequest())).tasks)

    t1 = await turn(c, "Plan me a day trip.")
    check("turn 1 (no city): the LLM-backed agent asks for one -> INPUT_REQUIRED",
          t1 is not None and t1.status.state == TaskState.TASK_STATE_INPUT_REQUIRED,
          f"state={t1.status.state if t1 else None}")
    if t1 is None:
        sys.exit(1)
    print("   agent asked:", text_of(t1)[:110].replace("\n", " "))

    t2 = await turn(c, "Milan", task_id=t1.id, context_id=t1.context_id)
    check("turn 2 (\"Milan\") continues the SAME task", t2 is not None and t2.id == t1.id)
    check("turn 2 completes", t2 is not None and t2.status.state == TaskState.TASK_STATE_COMPLETED,
          f"state={t2.status.state if t2 else None}")
    answer = text_of(t2) if t2 else ""
    check("the itinerary is present and about Milan", "milan" in answer.lower(), answer[:120].replace("\n", " "))

    after = len((await c.list_tasks(ListTasksRequest())).tasks)
    check("the whole two-turn conversation created exactly ONE task on the server", after - before == 1,
          f"tasks before={before} after={after}")
    print("\nOVERALL:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)

asyncio.run(main())
