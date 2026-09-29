"""X-A1 (INTEROP_AND_AUTH_TEST_PLAN.md): the real a2a-sdk 1.1.5 client, using
its own AuthInterceptor/CredentialService, against ballerina/a2a's Listener
with `auth` configured. Nothing here is scripted around our library's
internals -- the client only ever reads the derived card and mints a JWT
matching the shared secret the listener README example would use in the
same spot a real identity provider's token would go.
"""

import asyncio
import sys
import time
import uuid

import jwt as pyjwt  # PyJWT, not a2a's own jwt -- a stand-in for a real IdP

from a2a.client.auth.credentials import CredentialService
from a2a.client.auth.interceptor import AuthInterceptor
from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client import ClientCallContext, ClientConfig
from a2a.client.client_factory import ClientFactory
from a2a.client.errors import A2AClientError
from a2a.types import Message, Part, Role, SendMessageRequest
from a2a.utils.constants import TransportProtocol
import httpx

SHARED_SECRET = "interop-auth-shared-secret-0123456789"


def mint(subject: str, expires_in: int = 300) -> str:
    now = int(time.time())
    return pyjwt.encode(
        {"iss": "interop", "aud": "a2a", "sub": subject, "exp": now + expires_in},
        SHARED_SECRET,
        algorithm="HS256",
    )


class FixedTokenCredentialService(CredentialService):
    """The token this test hands the interceptor for every scheme name."""

    def __init__(self, token: str | None):
        self._token = token

    async def get_credentials(self, security_scheme_name: str, context) -> str | None:
        return self._token


async def try_send(url: str, token: str | None) -> tuple[bool, str]:
    httpx_client = httpx.AsyncClient()
    card = await A2ACardResolver(httpx_client, url).get_agent_card()
    config = ClientConfig(httpx_client=httpx_client, supported_protocol_bindings=[TransportProtocol.HTTP_JSON])
    factory = ClientFactory(config)
    client = factory.create(card)
    await client.add_interceptor(AuthInterceptor(FixedTokenCredentialService(token)))

    message = Message(message_id=str(uuid.uuid4()), role=Role.ROLE_USER, parts=[Part(text="hi")])
    try:
        got_task = False
        async for response in client.send_message(SendMessageRequest(message=message)):
            if response.task.id or response.status_update.task_id:
                got_task = True
        return got_task, "ok"
    except A2AClientError as e:
        return False, str(e)
    finally:
        await client.close()


async def main() -> None:
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9612"
    ok = True

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal ok
        print(f"{'PASS' if cond else 'FAIL'}: {label}" + (f" -- {detail}" if detail else ""))
        ok = ok and cond

    print("== X-A1: the reference client's own AuthInterceptor, valid token ==")
    succeeded, detail = await try_send(url, mint("alice"))
    check("authenticated send succeeds", succeeded, detail)

    print("== X-A1: no credential in the store ==")
    succeeded, detail = await try_send(url, None)
    check("unauthenticated send is rejected", not succeeded, detail)
    if not succeeded:
        print(f"  {detail}")

    print("== X-A1: wrong signature ==")
    forged = pyjwt.encode(
        {"iss": "interop", "aud": "a2a", "sub": "mallory", "exp": int(time.time()) + 300},
        "a-different-secret-entirely-0123456",
        algorithm="HS256",
    )
    succeeded, detail = await try_send(url, forged)
    check("forged token is rejected", not succeeded, detail)

    print("\nOVERALL:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    asyncio.run(main())
