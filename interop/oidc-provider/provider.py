#!/usr/bin/env python3
"""A small local OpenID-Connect-style identity provider, so the A2A auth flow can
be exercised the way production does it: a credential is *acquired from an
issuer*, and the server validates it against the issuer's *published keys*.

It is not a real IdP and makes no security claims. What it does provide, and what
the earlier shared-secret tests could not:

  GET  /.well-known/openid-configuration   discovery document
  GET  /jwks.json                          the public key(s), by `kid`
  POST /token                              OAuth2 client_credentials grant -> RS256 JWT
  POST /admin/rotate                       start signing with a new key (old one is
                                           dropped from the JWKS), to test rotation
  GET  /admin/stats                        how many tokens were issued

Usage: provider.py [port] [token_ttl_seconds]
"""

import base64
import json
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9800
TTL = int(sys.argv[2]) if len(sys.argv) > 2 else 300
ISSUER = f"http://localhost:{PORT}"
AUDIENCE = "a2a"

# client_id -> (secret, scopes the client may be granted)
CLIENTS = {
    "agent-a": ("agent-a-secret", {"a2a:invoke", "a2a:read"}),
    "reader": ("reader-secret", {"a2a:read"}),
}

_lock = threading.Lock()
_state = {"issued": 0, "kid": None, "key": None, "counter": 0}


def _new_key() -> None:
    _state["counter"] += 1
    _state["kid"] = f"key-{_state['counter']}"
    _state["key"] = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _b64(n: int) -> str:
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _jwks() -> dict:
    numbers = _state["key"].public_key().public_numbers()
    return {"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": _state["kid"],
                      "n": _b64(numbers.n), "e": _b64(numbers.e)}]}


def _issue(client_id: str, scope: str) -> str:
    now = int(time.time())
    pem = _state["key"].private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption())
    return jwt.encode({"iss": ISSUER, "aud": AUDIENCE, "sub": client_id, "scope": scope,
                       "iat": now, "exp": now + TTL},
                      pem, algorithm="RS256", headers={"kid": _state["kid"]})


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, body: dict, headers: dict | None = None) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if self.path == "/.well-known/openid-configuration":
            self._send(200, {"issuer": ISSUER, "jwks_uri": f"{ISSUER}/jwks.json",
                             "token_endpoint": f"{ISSUER}/token",
                             "grant_types_supported": ["client_credentials"],
                             "id_token_signing_alg_values_supported": ["RS256"]})
        elif self.path == "/jwks.json":
            with _lock:
                self._send(200, _jwks())
        elif self.path == "/admin/stats":
            with _lock:
                self._send(200, {"issued": _state["issued"], "kid": _state["kid"]})
        else:
            self._send(404, {"error": "not_found"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        if self.path == "/admin/rotate":
            with _lock:
                _new_key()
                self._send(200, {"kid": _state["kid"]})
            return
        if self.path != "/token":
            self._send(404, {"error": "not_found"})
            return

        form = dict(urllib.parse.parse_qsl(body))
        client_id, secret = form.get("client_id"), form.get("client_secret")
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("basic "):
            try:
                client_id, secret = base64.b64decode(auth[6:]).decode().split(":", 1)
            except Exception:
                pass
        if form.get("grant_type") != "client_credentials":
            self._send(400, {"error": "unsupported_grant_type"})
            return
        entry = CLIENTS.get(client_id or "")
        if entry is None or entry[0] != secret:
            self._send(401, {"error": "invalid_client"}, {"WWW-Authenticate": 'Basic realm="oidc"'})
            return
        wanted = set((form.get("scope") or "").split()) or entry[1]
        if not wanted <= entry[1]:
            self._send(400, {"error": "invalid_scope"})
            return
        with _lock:
            _state["issued"] += 1
            token = _issue(client_id, " ".join(sorted(wanted)))
        self._send(200, {"access_token": token, "token_type": "Bearer", "expires_in": TTL,
                         "scope": " ".join(sorted(wanted))})

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        pass


if __name__ == "__main__":
    _new_key()
    ThreadingHTTPServer(("localhost", PORT), Handler).serve_forever()
