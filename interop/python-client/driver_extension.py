"""A required extension (spec 3.3.4 / 4.6.3), seen from a real other-SDK client.

Run against bal-listener started with -CREQUIRED_EXTENSION=urn:interop:needed. The Python client
sends the A2A-Extensions header through its own `with_a2a_extensions` helper.
"""
import asyncio, sys, uuid
import httpx
from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client import ClientCallContext, ClientConfig
from a2a.client.client_factory import ClientFactory
from a2a.client.service_parameters import ServiceParametersFactory, with_a2a_extensions
from a2a.types import Message, Part, Role, SendMessageRequest
from a2a.utils.constants import TransportProtocol
from a2a.utils.errors import A2AError

URL, NEEDED = "http://localhost:9611", "urn:interop:needed"


async def send(client, context=None):
    got = False
    async for r in client.send_message(SendMessageRequest(message=Message(
            message_id=str(uuid.uuid4()), role=Role.ROLE_USER, parts=[Part(text="hi")])), context=context):
        if r.task.id or r.status_update.task_id:
            got = True
    return got


async def main():
    ok = True
    def check(label, cond, detail=""):
        nonlocal ok
        print(f"{'PASS' if cond else 'FAIL'}: {label}" + (f" -- {detail}" if detail else ""))
        ok = ok and cond

    h = httpx.AsyncClient()
    card = await A2ACardResolver(h, URL).get_agent_card()
    declared = [(e.uri, e.required) for e in card.capabilities.extensions]
    check("the card declares the extension as required", (NEEDED, True) in declared, str(declared))
    c = ClientFactory(ClientConfig(httpx_client=h, supported_protocol_bindings=[TransportProtocol.HTTP_JSON])).create(card)

    try:
        await send(c)
        check("a request without the extension is refused", False, "it was accepted")
    except A2AError as e:
        check("a request without the extension raises the SDK's ExtensionSupportRequiredError",
              type(e).__name__ == "ExtensionSupportRequiredError", f"{type(e).__name__}: {e}")
    except Exception as e:
        check("a request without the extension is refused with a typed error", False, f"{type(e).__name__}: {e}")

    ctx = ClientCallContext(service_parameters=ServiceParametersFactory.create([with_a2a_extensions([NEEDED])]))
    check("the same request naming the extension succeeds", await send(c, ctx))
    print("\nOVERALL:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)

asyncio.run(main())
