"""Reference-client comparison for the hostile cases: a2a-sdk (Python) against hostile.py."""
import asyncio, sys, time, httpx
from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client import ClientConfig
from a2a.client.client_factory import ClientFactory
from a2a.types import ListTasksRequest, Message, Part, Role, SendMessageRequest
from a2a.utils.constants import TransportProtocol
BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9850"

async def client(case, h):
    card = await A2ACardResolver(h, f"{BASE}/{case}").get_agent_card()
    return ClientFactory(ClientConfig(httpx_client=h, supported_protocol_bindings=[TransportProtocol.HTTP_JSON], streaming=True)).create(card)

def req():
    return SendMessageRequest(message=Message(message_id="h-1", role=Role.ROLE_USER, parts=[Part(text="hi")]))

async def stream(case, h):
    c = await client(case, h); kinds = []; n = 0
    async for ev in c.send_message(req()):
        k = ev.WhichOneof("payload") if hasattr(ev, "WhichOneof") else type(ev).__name__
        if k == "status_update": k = ev.status_update.status.state
        if k == "artifact_update": n += sum(len(p.text) for p in ev.artifact_update.artifact.parts)
        kinds.append(str(k))
    return f"OK events={kinds} artifactText={n}"

async def lst(case, h):
    c = await client(case, h); r = await c.list_tasks(ListTasksRequest())
    return f"OK tasks={len(r.tasks)} next={r.next_page_token!r}"

async def unary(case, h):
    c = await client(case, h); out = []
    async for ev in c.send_message(req()):
        out.append(ev.WhichOneof("payload"))
    return f"OK {out}"

async def main():
    async with httpx.AsyncClient(timeout=20) as h:
        for case, fn in [("s_eof_midtask", stream), ("s_huge", stream), ("s_bom", stream), ("s_no_task_first", stream),
                         ("u_null_fields", unary), ("u_enum_int", unary), ("l_omitted_defaults", lst), ("l_empty_object", lst)]:
            t0 = time.monotonic()
            try: r = await fn(case, h)
            except Exception as e: r = f"ERR {type(e).__name__}: {str(e)[:150]}"
            print(f"{case:20} {r}  [{time.monotonic()-t0:.2f}s]")
asyncio.run(main())
