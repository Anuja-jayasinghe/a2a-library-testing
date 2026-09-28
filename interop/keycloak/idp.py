"""Helpers for driving the real Keycloak in this directory (realm-a2a.json).

Nothing here is A2A-specific: it is what a deployment does to *get* a credential --
the part the earlier shared-secret and fake-provider tests could not show.
"""
import base64
import hashlib
import html
import json
import re
import secrets
import urllib.parse

import httpx

BASE = "http://localhost:8180"
REALM = f"{BASE}/realms/a2a"
TOKEN_URL = f"{REALM}/protocol/openid-connect/token"
AUTH_URL = f"{REALM}/protocol/openid-connect/auth"
DISCOVERY_URL = f"{REALM}/.well-known/openid-configuration"
JWKS_URL = f"{REALM}/protocol/openid-connect/certs"
REDIRECT_URI = "http://localhost:9999/cb"


def claims(token: str) -> dict:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def client_credentials(client_id: str, secret: str, scope: str | None = None) -> dict:
    data = {"grant_type": "client_credentials", "client_id": client_id, "client_secret": secret}
    if scope:
        data["scope"] = scope
    r = httpx.post(TOKEN_URL, data=data)
    r.raise_for_status()
    return r.json()


def login_with_code(username: str, password: str, scope: str = "openid a2a:invoke a2a:read",
                    client: tuple[str, str] = ("a2a-webapp", "webapp-secret")) -> dict:
    """The authorization-code flow with PKCE, as a browser would do it: load the
    login page, submit the user's credentials, follow the redirect, exchange the code."""
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(8)
    with httpx.Client(follow_redirects=False) as browser:
        page = browser.get(AUTH_URL, params={
            "client_id": client[0], "redirect_uri": REDIRECT_URI, "response_type": "code",
            "scope": scope, "state": state, "code_challenge": challenge, "code_challenge_method": "S256"})
        page.raise_for_status()
        form = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', page.text) \
            or re.search(r'action="([^"]+)"[^>]*id="kc-form-login"', page.text)
        if not form:
            raise RuntimeError("login form not found: " + page.text[:300])
        # Keycloak marks its session cookies Secure even over plain-HTTP localhost. Browsers exempt
        # localhost from that; the stdlib cookie jar does not, and would never send them back
        # (Keycloak then reports cookie_not_found). Carry them by hand instead.
        cookies = "; ".join(v.split(";")[0] for k, v in page.headers.multi_items() if k.lower() == "set-cookie")
        posted = browser.post(html.unescape(form.group(1)), data={"username": username, "password": password},
                              headers={"Cookie": cookies})
        if posted.status_code != 302:
            raise RuntimeError(f"login did not redirect ({posted.status_code}): {posted.text[:300]}")
        location = urllib.parse.urlparse(posted.headers["location"])
        query = urllib.parse.parse_qs(location.query)
        if query.get("state", [""])[0] != state:
            raise RuntimeError("state mismatch")
        code = query["code"][0]
    r = httpx.post(TOKEN_URL, data={
        "grant_type": "authorization_code", "code": code, "redirect_uri": REDIRECT_URI,
        "client_id": client[0], "client_secret": client[1], "code_verifier": verifier})
    r.raise_for_status()
    return r.json()


def _admin_token() -> str:
    r = httpx.post(f"{BASE}/realms/master/protocol/openid-connect/token", data={
        "grant_type": "password", "client_id": "admin-cli", "username": "admin", "password": "admin"})
    r.raise_for_status()
    return r.json()["access_token"]


def rotate_signing_key() -> str:
    """Adds a higher-priority RSA key to the realm, so new tokens are signed with a `kid`
    no relying party has seen yet. Returns the component id (for removal)."""
    h = {"Authorization": f"Bearer {_admin_token()}"}
    r = httpx.post(f"{BASE}/admin/realms/a2a/components", headers=h, json={
        "name": "rotated-" + secrets.token_hex(3), "providerId": "rsa-generated",
        "providerType": "org.keycloak.keys.KeyProvider",
        "config": {"priority": ["500"], "keySize": ["2048"], "enabled": ["true"], "active": ["true"]}})
    r.raise_for_status()
    return r.headers["location"].rsplit("/", 1)[1]


def remove_key(component_id: str) -> None:
    h = {"Authorization": f"Bearer {_admin_token()}"}
    httpx.delete(f"{BASE}/admin/realms/a2a/components/{component_id}", headers=h).raise_for_status()


def kids() -> list[str]:
    return [k["kid"] for k in httpx.get(JWKS_URL).json()["keys"] if k.get("use") == "sig"]
