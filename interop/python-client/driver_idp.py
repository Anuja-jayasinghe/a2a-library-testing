"""The real a2a-sdk 1.1.5 client against ballerina/a2a's Listener, with credentials from a REAL
identity provider (Keycloak, ../keycloak) -- the identity-provider and AUTH_REQUIRED group of
INTEROP_AND_AUTH_TEST_PLAN.md.

  K1  service-account tokens: accepted / read-only scope / missing audience / garbage / no identity
  K3  user tokens from the authorization-code + PKCE flow: identity = the token's `sub`; two users
      cannot see each other's tasks
  K4  the card's openIdConnect scheme parses in the reference SDK and its discovery URL is real
  K5  the issuer rotates its signing key, then withdraws the new one
  B1  a task paused in AUTH_REQUIRED, continued with a credential; cancel from AUTH_REQUIRED

Needs Keycloak on 8180 and bal-listener-idp on 9620 (see run_idp_checks.sh).
"""
import asyncio
import base64
import json
import os
import sys
import uuid

import httpx

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "keycloak"))
import idp  # noqa: E402

from a2a.client.auth.credentials import CredentialService  # noqa: E402
from a2a.client.auth.interceptor import AuthInterceptor  # noqa: E402
from a2a.client.card_resolver import A2ACardResolver  # noqa: E402
from a2a.client.client import ClientConfig  # noqa: E402
from a2a.client.client_factory import ClientFactory  # noqa: E402
from a2a.client.errors import A2AClientError  # noqa: E402
from a2a.types import (  # noqa: E402
    CancelTaskRequest, GetTaskRequest, ListTasksRequest, Message, Part, Role, SendMessageRequest, TaskState,
)
from a2a.utils.constants import TransportProtocol  # noqa: E402

AGENT = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9620"
PAUSED_OR_DONE = (TaskState.TASK_STATE_AUTH_REQUIRED, TaskState.TASK_STATE_INPUT_REQUIRED, TaskState.TASK_STATE_COMPLETED,
                  TaskState.TASK_STATE_FAILED, TaskState.TASK_STATE_CANCELED, TaskState.TASK_STATE_REJECTED)


class Token(CredentialService):
    def __init__(self, t):
        self.t = t

    async def get_credentials(self, name, ctx):
        return self.t


async def client_with(token):
    h = httpx.AsyncClient()
    card = await A2ACardResolver(h, AGENT).get_agent_card()
    c = ClientFactory(ClientConfig(httpx_client=h, supported_protocol_bindings=[TransportProtocol.HTTP_JSON])).create(card)
    if token:
        await c.add_interceptor(AuthInterceptor(Token(token)))
    return c


def message(message_id, text, task_id=None, context_id=None):
    return Message(message_id=message_id, role=Role.ROLE_USER, parts=[Part(text=text)],
                   task_id=task_id or "", context_id=context_id or "")


async def run_task(client, msg):
    """Merges the events send_message yields into one Task, stopping at a paused or terminal state."""
    task = None
    async for r in client.send_message(SendMessageRequest(message=msg)):
        if r.task.id:
            task = r.task
        elif task is not None and r.status_update.task_id == task.id:
            task.status.CopyFrom(r.status_update.status)
        elif task is not None and r.artifact_update.task_id == task.id:
            task.artifacts.append(r.artifact_update.artifact)
        if r.status_update.task_id and task is not None and task.status.state in PAUSED_OR_DONE:
            break
    return task


def artifact_text(task):
    return "".join(p.text for a in task.artifacts for p in a.parts)


async def attempt(token, msg_id="idp-whoami-1"):
    """(True, artifact text) when the call is admitted; (False, first line of the error) when not."""
    c = await client_with(token)
    try:
        t = await run_task(c, message(msg_id + "-" + uuid.uuid4().hex[:6], "hi"))
        return True, artifact_text(t) if t else ""
    except Exception as e:
        return False, str(e).splitlines()[0]
    finally:
        await c.close()


async def main():
    ok = True

    def check(label, cond, detail=""):
        nonlocal ok
        print(f"{'PASS' if cond else 'FAIL'}: {label}" + (f" -- {detail}" if detail else ""))
        ok = ok and cond

    def info(label, detail):
        print(f"INFO: {label} -- {detail}")

    print("== K1: service-account tokens from the real IdP ==")
    agent_a = idp.client_credentials("agent-a", "agent-a-secret")["access_token"]
    good, who = await attempt(agent_a)
    check("Keycloak client_credentials token is admitted; identity = the token's sub",
          good and who == idp.claims(agent_a)["sub"], who)
    ok_, d = await attempt(idp.client_credentials("reader", "reader-secret")["access_token"])
    check("a2a:read-only token is refused with 403", not ok_ and "403" in d, d)
    ok_, d = await attempt(idp.client_credentials("no-audience", "no-audience-secret")["access_token"])
    check("valid Keycloak token for a different audience is refused with 401", not ok_ and "401" in d, d)
    ok_, d = await attempt(idp.login_with_code("alice", "alicepw", client=("a2a-webapp-nosub", "nosub-secret"))["access_token"])
    check("valid signature, audience and scope but NO sub is refused with 401 (no identity to scope tasks to)",
          not ok_ and "401" in d, d)
    ok_, d = await attempt("not.a.jwt")
    check("garbage token is refused with 401", not ok_ and "401" in d, d)
    ok_, d = await attempt(None)
    check("no credential is refused with 401", not ok_ and "401" in d, d)

    print("== K3: users, via the authorization-code flow with PKCE ==")
    alice_tokens = idp.login_with_code("alice", "alicepw")
    bob_tokens = idp.login_with_code("bob", "bobpw")
    alice, bob = alice_tokens["access_token"], bob_tokens["access_token"]
    a_sub, b_sub = idp.claims(alice)["sub"], idp.claims(bob)["sub"]
    check("the two users have different subjects", a_sub != b_sub)
    ca, cb = await client_with(alice), await client_with(bob)
    t_alice = await run_task(ca, message("idp-task-" + uuid.uuid4().hex[:6], "alice's private note"))
    check("alice's task completes under her own identity",
          t_alice is not None and t_alice.status.state == TaskState.TASK_STATE_COMPLETED)
    who_a = await run_task(ca, message("idp-whoami-" + uuid.uuid4().hex[:6], "x"))
    who_b = await run_task(cb, message("idp-whoami-" + uuid.uuid4().hex[:6], "x"))
    check("the agent sees alice as her sub and bob as his",
          artifact_text(who_a) == a_sub and artifact_text(who_b) == b_sub, f"{artifact_text(who_a)} / {artifact_text(who_b)}")
    got = await ca.get_task(GetTaskRequest(id=t_alice.id))
    check("alice can read her own task back", got.id == t_alice.id)
    try:
        await cb.get_task(GetTaskRequest(id=t_alice.id))
        check("bob cannot read alice's task", False, "bob was served alice's task")
    except Exception as e:
        check("bob cannot read alice's task (TaskNotFound, not a leak)", "TaskNotFound" in type(e).__name__, type(e).__name__)
    seen = await cb.list_tasks(ListTasksRequest(page_size=100))
    check("bob's task list does not contain alice's task", t_alice.id not in [t.id for t in seen.tasks])
    try:
        await cb.cancel_task(CancelTaskRequest(id=t_alice.id))
        check("bob cannot cancel alice's task", False, "cancel succeeded")
    except Exception as e:
        check("bob cannot cancel alice's task", "TaskNotFound" in type(e).__name__, type(e).__name__)

    print("== K4: the card's openIdConnect scheme, read by the reference SDK ==")
    card = await A2ACardResolver(httpx.AsyncClient(), AGENT).get_agent_card()
    scheme = card.security_schemes["oidc"].open_id_connect_security_scheme
    check("the reference SDK parses the openIdConnect scheme from the card", bool(scheme.open_id_connect_url),
          scheme.open_id_connect_url)
    disc = httpx.get(scheme.open_id_connect_url).json()
    check("the advertised discovery URL is a live OIDC document whose issuer matches the tokens the agent accepts",
          disc["issuer"] == idp.claims(alice)["iss"], disc.get("issuer"))
    via_discovery = httpx.post(disc["token_endpoint"], data={
        "grant_type": "client_credentials", "client_id": "agent-a", "client_secret": "agent-a-secret"}).json()["access_token"]
    good, _ = await attempt(via_discovery)
    check("a token obtained from the token_endpoint the card led to is admitted", good)
    req = card.security_requirements[0].schemes["oidc"].list
    check("the card's requirement names the scope the agent enforces", list(req) == ["a2a:invoke"], str(list(req)))

    print("== K5: the issuer rotates its signing key, then withdraws it ==")
    before_kids = idp.kids()
    old_token = idp.client_credentials("agent-a", "agent-a-secret")["access_token"]
    component = idp.rotate_signing_key()
    try:
        new_token = idp.client_credentials("agent-a", "agent-a-secret")["access_token"]
        kid = lambda t: json.loads(base64.urlsafe_b64decode(t.split(".")[0] + "=="))["kid"]  # noqa: E731
        check("new tokens are signed with a key the listener has not seen", kid(new_token) != kid(old_token))
        good, d = await attempt(new_token)
        check("a token signed with the new key is admitted", good, d)
        good, d = await attempt(old_token)
        check("a token signed with the old (still published) key is still admitted", good, d)
    finally:
        idp.remove_key(component)
    good, d = await attempt(new_token)
    check("once the IdP withdraws its key, tokens it signed are refused (no stale key cache)", not good and "401" in d,
          d if good else d)
    check("the realm's key set is back to what it was", idp.kids() == before_kids)

    print("== B1: in-task AUTH_REQUIRED (spec 7.6) ==")
    t1 = await run_task(ca, message("idp-auth-required-" + uuid.uuid4().hex[:6], "book me a meeting"))
    check("the task pauses in AUTH_REQUIRED", t1 is not None and t1.status.state == TaskState.TASK_STATE_AUTH_REQUIRED,
          str(t1.status.state) if t1 else "none")
    ask = "".join(p.text for p in t1.status.message.parts) if t1 and t1.status.HasField("message") else ""
    check("the status message tells the caller what to do", "link your calendar" in ask, ask)
    polled = await ca.get_task(GetTaskRequest(id=t1.id))
    check("the paused state is what GetTask reports", polled.status.state == TaskState.TASK_STATE_AUTH_REQUIRED)
    t2 = await run_task(ca, message("idp-continue-" + uuid.uuid4().hex[:6], "credential=cal-token-123",
                                    task_id=t1.id, context_id=t1.context_id))
    check("supplying the credential on the same task completes it",
          t2 is not None and t2.id == t1.id and t2.status.state == TaskState.TASK_STATE_COMPLETED,
          str(t2.status.state) if t2 else "none")
    check("the agent received the credential", t2 is not None and "credential=cal-token-123" in artifact_text(t2),
          artifact_text(t2) if t2 else "")
    try:
        await cb.send_message(SendMessageRequest(message=message("idp-steal-1", "x", task_id=t1.id))).__anext__()
        check("another user cannot continue the task", False, "accepted")
    except (Exception, StopAsyncIteration) as e:
        check("another user cannot continue someone else's AUTH_REQUIRED task", "TaskNotFound" in type(e).__name__, type(e).__name__)
    t3 = await run_task(ca, message("idp-auth-required-" + uuid.uuid4().hex[:6], "second"))
    canceled = await ca.cancel_task(CancelTaskRequest(id=t3.id))
    check("a task paused in AUTH_REQUIRED can be canceled", canceled.status.state == TaskState.TASK_STATE_CANCELED,
          str(canceled.status.state))

    print("== K3 (last, so it cannot expire the tokens above): expiry ==")
    await asyncio.sleep(7)          # the webapp client's access tokens live 6 seconds
    stale, why = await attempt(alice)
    check("an expired user token is refused (401) -- so a client that keeps working has refreshed it",
          not stale and "401" in why, why)

    await ca.close()
    await cb.close()
    print("\nOVERALL:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


asyncio.run(main())
