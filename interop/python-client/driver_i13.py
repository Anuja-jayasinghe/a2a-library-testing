"""I13 (INTEROP_AND_AUTH_TEST_PLAN.md): does a real other-SDK SSE client sit
through ballerina/a2a's keep-alive *comment* frames (`: keep-alive`) and still
receive the events around them? The plan flagged this as an unverified risk:
comment-only frames are legal SSE, but each parser has to actually ignore them.

Run against bal-listener started with a keep-alive interval well below the
paced task's silence, e.g.:
    bal run -- -CKEEPALIVE_SECONDS=0.5 -CPACE_SECONDS=4
"""
import asyncio, sys, time, uuid
import httpx
from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client import ClientConfig
from a2a.client.client_factory import ClientFactory
from a2a.types import Message, Part, Role, SendMessageRequest, TaskState
from a2a.utils.constants import TransportProtocol


async def main() -> None:
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9611"
    h = httpx.AsyncClient(timeout=30)
    card = await A2ACardResolver(h, url).get_agent_card()
    client = ClientFactory(ClientConfig(httpx_client=h, supported_protocol_bindings=[TransportProtocol.HTTP_JSON])).create(card)

    started = time.time()
    events, final_state = 0, None
    async for r in client.send_message(SendMessageRequest(message=Message(
            message_id="interop-task-paced-" + uuid.uuid4().hex[:6], role=Role.ROLE_USER, parts=[Part(text="quiet")]))):
        events += 1
        if r.status_update.task_id:
            final_state = r.status_update.status.state
            if final_state == TaskState.TASK_STATE_COMPLETED:
                break
    took = time.time() - started

    ok = final_state == TaskState.TASK_STATE_COMPLETED and took >= 3.5
    print(f"{'PASS' if ok else 'FAIL'}: real a2a-sdk SSE client sat through ~{took:.1f}s of silence "
          f"(keep-alive comments every 0.5s) and received {events} events, final state={final_state}")
    await client.close()
    sys.exit(0 if ok else 1)

asyncio.run(main())
