"""How ballerina/a2a's Listener behaves toward the identity provider's key endpoint (JWKS) -- the
operational side of "validate against the issuer's published keys":

  J1  without a cache: how often is the IdP asked for its keys?
  J2  the IdP becomes unreachable while the agent is running: what does a caller with a valid token see?
  J3  with jwksConfig.cacheConfig: fetch count, key rotation, key withdrawal, IdP outage
  J4  with a cache and the IdP unreachable at startup

Lines starting KNOWN describe behaviour observed and recorded in RESULTS.md; they do not fail the run.
Needs Keycloak on 8180, bal-listener-idp built (bal-listener-idp/target/bin/bal_listener_idp.jar).
"""
import os
import subprocess
import sys
import time

import httpx

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
sys.path.insert(0, os.path.join(ROOT, "keycloak"))
import idp  # noqa: E402

JAR = os.path.join(ROOT, "bal-listener-idp", "target", "bin", "bal_listener_idp.jar")
PY = sys.executable
PROXY = "http://localhost:9830"
JWKS_VIA_PROXY = PROXY + "/realms/a2a/protocol/openid-connect/certs"
procs = []
ok = True


def check(label, cond, detail=""):
    global ok
    print(f"{'PASS' if cond else 'FAIL'}: {label}" + (f" -- {detail}" if detail else ""))
    ok = ok and cond


def known(label, detail):
    print(f"KNOWN: {label} -- {detail}")


def start(cmd, env=None, log="/dev/null"):
    p = subprocess.Popen(cmd, env={**os.environ, **(env or {})}, stdout=open(log, "w"), stderr=subprocess.STDOUT)
    procs.append(p)
    return p


def stop(p):
    p.terminate()
    try:
        p.wait(5)
    except subprocess.TimeoutExpired:
        p.kill()
    if p in procs:
        procs.remove(p)


def wait_up(url, seconds=60):
    for _ in range(seconds * 2):
        try:
            if httpx.get(url, timeout=1).status_code == 200:
                return True
        except httpx.HTTPError:
            pass
        time.sleep(0.5)
    return False


def start_proxy():
    p = start([PY, os.path.join(ROOT, "keycloak", "counting_proxy.py"), "9830"])
    assert wait_up(PROXY + "/_count", 10), "proxy did not start"
    return p


def start_listener(port, log, **cfg):
    env = {"BAL_CONFIG_VAR_PORT": str(port), "BAL_CONFIG_VAR_JWKSURL": JWKS_VIA_PROXY}
    env.update({f"BAL_CONFIG_VAR_{k.upper()}": v for k, v in cfg.items()})
    p = start(["java", "-jar", JAR], env, log)
    return p, wait_up(f"http://localhost:{port}/.well-known/agent-card.json")


def fetches():
    return int(httpx.get(PROXY + "/_count").text)


def call(port, token):
    return httpx.get(f"http://localhost:{port}/tasks", headers={"A2A-Version": "1.0", "Authorization": "Bearer " + token},
                     timeout=20).status_code


def token():
    return idp.client_credentials("agent-a", "agent-a-secret")["access_token"]


try:
    print("== J1/J2: no JWKS cache (the default) ==")
    proxy = start_proxy()
    l1, up = start_listener(9622, "/tmp/jwks_l1.log")
    check("listener starts", up)
    t = token()
    before = fetches()
    codes = {call(9622, t) for _ in range(20)}
    n = fetches() - before
    check("valid token is admitted", codes == {200}, str(codes))
    known("without a cache the IdP's JWKS is fetched on EVERY authenticated request", f"20 requests -> {n} fetches")
    stop(proxy)
    status = call(9622, t)
    known("IdP unreachable, caller holds a valid token", f"HTTP {status}"
          + (" (a 401 tells the caller its good credential is bad)" if status == 401 else ""))
    stop(l1)

    print("== J3: jwksConfig.cacheConfig (max age 300s) ==")
    proxy = start_proxy()
    l2, up = start_listener(9623, "/tmp/jwks_l2.log", cacheJwks="true", jwksMaxAge="300")
    check("listener starts with a cache", up)
    original = token()
    before = fetches()
    codes = {call(9623, original) for _ in range(20)}
    check("with a cache, 20 requests for a key present at startup cost no key fetch",
          codes == {200} and fetches() - before == 0, f"{codes}, {fetches() - before} fetches")

    component = idp.rotate_signing_key()
    fresh = token()
    before = fetches()
    check("a token signed with a rotated-in key is admitted (a cache miss refetches)", call(9623, fresh) == 200)
    codes = {call(9623, fresh) for _ in range(9)}
    n = fetches() - before
    check("...and keeps being admitted", codes == {200}, str(codes))
    known("a key rotated in AFTER startup is never cached (ballerina/jwt only writes the cache at startup)",
          f"10 requests with the new key -> {n} fetches")
    check("a token from before the rotation is still admitted, from the cache", call(9623, original) == 200)
    stop(proxy)
    check("IdP down: a caller whose key was cached at startup is unaffected", call(9623, original) == 200)
    st = call(9623, fresh)
    known("IdP down: a caller whose key was rotated in after startup", f"HTTP {st}")
    idp.remove_key(component)
    stop(l2)

    print("== J3b: cache entry max age 3s ==")
    proxy = start_proxy()
    l2b, up = start_listener(9625, "/tmp/jwks_l2b.log", cacheJwks="true", jwksMaxAge="3")
    t = token()
    call(9625, t)
    time.sleep(4)
    before = fetches()
    codes = {call(9625, t) for _ in range(10)}
    n = fetches() - before
    check("still admitted after the cache entry expired", codes == {200}, str(codes))
    known("after `defaultMaxAge` the cache is never refilled: back to a fetch per request", f"10 requests -> {n} fetches")
    stop(proxy)
    stop(l2b)

    print("== J4: cache enabled, IdP unreachable at startup ==")
    l3, up = start_listener(9624, "/tmp/jwks_l3.log", cacheJwks="true")   # proxy is down
    time.sleep(3)
    alive = l3.poll() is None
    log = open("/tmp/jwks_l3.log").read()
    first = next((ln for ln in log.splitlines() if ln.strip()), "")
    escapes = "ballerina.a2a.0.Listener:init" in log
    known("startup with a JWKS cache while the IdP is down",
          ("process still running, listener up=" + str(up)) if alive else
          f"process exited with code {l3.returncode}; the error is not returned by a2a:Listener's init, it "
          + ("escapes as an uncaught panic through it" if escapes else "ends the process") + f" ({first[:80]})")
    stop(l3)
finally:
    for p in list(procs):
        stop(p)

print("\nOVERALL:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
