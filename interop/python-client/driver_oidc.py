"""Production-shaped auth from a foreign client: the real a2a-sdk 1.1.5 client gets its
token from the issuer (OAuth2 client_credentials, RS256) and its own AuthInterceptor
presents it to ballerina/a2a's Listener, which validates it against the issuer's JWKS.

Needs oidc-provider/provider.py (9800, 4s tokens) and bal-listener-oidc (9613).
"""
import asyncio, sys, uuid
import httpx
from a2a.client.auth.credentials import CredentialService
from a2a.client.auth.interceptor import AuthInterceptor
from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client import ClientConfig
from a2a.client.client_factory import ClientFactory
from a2a.client.errors import A2AClientError
from a2a.types import Message, Part, Role, SendMessageRequest
from a2a.utils.constants import TransportProtocol

ISSUER, AGENT = "http://localhost:9800", "http://localhost:9613"


class Token(CredentialService):
    def __init__(self, t): self.t = t
    async def get_credentials(self, name, ctx): return self.t


async def token_for(client_id, secret, scope):
    async with httpx.AsyncClient() as h:
        r = await h.post(f"{ISSUER}/token", data={"grant_type": "client_credentials", "client_id": client_id,
                                                  "client_secret": secret, "scope": scope})
        r.raise_for_status()
        return r.json()["access_token"]


async def send(token):
    h = httpx.AsyncClient()
    card = await A2ACardResolver(h, AGENT).get_agent_card()
    c = ClientFactory(ClientConfig(httpx_client=h, supported_protocol_bindings=[TransportProtocol.HTTP_JSON])).create(card)
    await c.add_interceptor(AuthInterceptor(Token(token)))
    try:
        async for r in c.send_message(SendMessageRequest(message=Message(
                message_id=str(uuid.uuid4()), role=Role.ROLE_USER, parts=[Part(text="hi")]))):
            if r.task.id or r.status_update.task_id:
                return True, "ok"
        return False, "no events"
    except A2AClientError as e:
        return False, str(e).splitlines()[0]
    finally:
        await c.close()


async def main():
    ok = True
    def check(label, cond, detail=""):
        nonlocal ok
        print(f"{'PASS' if cond else 'FAIL'}: {label}" + (f" -- {detail}" if detail and not cond else ""))
        ok = ok and cond

    good = await token_for("agent-a", "agent-a-secret", "a2a:invoke")
    success, d = await send(good)
    check("RS256 token from the issuer, validated by the listener via JWKS", success, d)

    reader = await token_for("reader", "reader-secret", "a2a:read")
    success, d = await send(reader)
    check("a2a:read-only token is rejected", not success and "403" in d, d)

    success, d = await send("not.a.token")
    check("garbage token is rejected (401)", not success and "401" in d, d)

    await asyncio.sleep(5.5)   # the issuer's tokens live 4s
    success, d = await send(good)
    check("the same token after it has expired is rejected (401)", not success and "401" in d, d)
    print("\nOVERALL:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)

asyncio.run(main())
