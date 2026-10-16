#!/usr/bin/env python3
"""Raw-HTTP spec probes against an a2a:RestListener (bal-listener). Prints observed behaviour; expectations
are recorded next to each probe with the spec section that justifies them. Usage: probe.py PORT [BASE_PATH]  (BASE_PATH is where the binding is mounted, /rest for a2a:RestListener)"""
import http.client, json, sys, uuid

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9620
BASE = sys.argv[2] if len(sys.argv) > 2 else "/rest"
RESULTS = []


def call(method, path, body=None, headers=None, raw=None, ctype="application/a2a+json", version="1.0", timeout=10):
    h = {}
    if ctype is not None:
        h["Content-Type"] = ctype
    if version is not None:
        h["A2A-Version"] = version
    h.update(headers or {})
    c = http.client.HTTPConnection("localhost", PORT, timeout=timeout)
    data = raw if raw is not None else (json.dumps(body) if body is not None else None)
    try:
        c.request(method, path if path.startswith("/.well-known") else BASE + path, body=data, headers=h)
        r = c.getresponse()
        txt = r.read().decode("utf-8", "replace")
        try:
            js = json.loads(txt)
        except Exception:
            js = None
        return r.status, dict((k.lower(), v) for k, v in r.getheaders()), txt, js
    except Exception as e:
        return -1, {}, f"{type(e).__name__}: {e}", None
    finally:
        c.close()


def msg(text="hello", mid=None, **extra):
    m = {"messageId": mid or str(uuid.uuid4()), "role": "ROLE_USER", "parts": [{"text": text}]}
    m.update(extra)
    return {"message": m}


def reason(js):
    try:
        return js["error"]["details"][0]["reason"]
    except Exception:
        return None


def probe(pid, title, expect, status, note=""):
    RESULTS.append((pid, title, expect, status, note))
    flag = "ok " if note.startswith("OK") else "?? "
    print(f"{flag}{pid:<5}{title}\n       expect: {expect}\n       got:    {status} {note}")


def send(text="hello", **kw):
    return call("POST", "/message:send", msg(text), **kw)


# ---- Versioning (spec 3.6) --------------------------------------------------------------
s, h, t, j = send(version=None)
probe("V1", "no A2A-Version header", "3.6.2: MUST be interpreted as 0.3 -> this 1.0 agent should answer VERSION_NOT_SUPPORTED (400)",
      s, f"reason={reason(j)}")
s, h, t, j = call("POST", "/message:send?A2A-Version=1.0", msg(), version=None)
probe("V2", "A2A-Version as a query parameter (3.6.1 MAY)", "200, version 1.0 honoured", s, t[:120])
s, h, t, j = send(version="1.0.5")
probe("V3", "patch version 1.0.5", "3.6: patch MUST NOT be considered -> 200", s, t[:100])
s, h, t, j = send(version="1.1")
probe("V4", "version 1.1", "VERSION_NOT_SUPPORTED (400)", s, f"reason={reason(j)}")
s, h, t, j = send(version="")
probe("V5", "empty A2A-Version", "3.6.2: empty is 0.3 -> VERSION_NOT_SUPPORTED", s, f"reason={reason(j)}")
s, h, t, j = call("POST", "/message:send", msg(), headers={"a2a-version": "1.0"}, version=None)
probe("V6", "lower-case header name", "200 (HTTP header names are case-insensitive)", s, t[:80])
s, h, t, j = send(version="0.3")
probe("V7", "version 0.3", "VERSION_NOT_SUPPORTED (400) (agent advertises only 1.0)", s, f"reason={reason(j)}")

# ---- Content type / method handling -----------------------------------------------------
s, h, t, j = send(ctype="application/json")
probe("C1", "Content-Type application/json", "11.1 says application/json is the REST type -> 200", s, t[:80])
s, h, t, j = send(ctype=None)
probe("C2", "no Content-Type", "accept or 415; never 5xx", s, t[:100])
s, h, t, j = send(ctype="text/plain")
probe("C3", "Content-Type text/plain", "415 / 400, never 5xx", s, t[:100])
s, h, t, j = call("GET", "/message:send")
probe("C4", "GET on POST-only path", "405 (or 404)", s, t[:100])
s, h, t, j = call("POST", "/tasks")
probe("C5", "POST /tasks (list is GET)", "405 or 404", s, t[:100])
s, h, t, j = call("POST", "/nope", {})
probe("C6", "unknown path", "404", s, t[:100])
s, h, t, j = call("OPTIONS", "/message:send")
probe("C7", "OPTIONS", "no 5xx", s, t[:100])

# ---- Request validation (proto required fields, 5.x) ------------------------------------
cases = [
    ("R1", "missing messageId", {"message": {"role": "ROLE_USER", "parts": [{"text": "x"}]}}),
    ("R2", "missing role", {"message": {"messageId": "a", "parts": [{"text": "x"}]}}),
    ("R3", "ROLE_UNSPECIFIED", {"message": {"messageId": "a", "role": "ROLE_UNSPECIFIED", "parts": [{"text": "x"}]}}),
    ("R4", "empty parts", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": []}}),
    ("R5", "part with two oneof members", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": [{"text": "x", "data": {"a": 1}}]}}),
    ("R6", "part with none", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": [{}]}}),
    ("R7", "no message field", {}),
    ("R8", "message is a string", {"message": "hi"}),
    ("R9", "role as integer 1", {"message": {"messageId": "a", "role": 1, "parts": [{"text": "x"}]}}),
    ("R10", "unknown role string", {"message": {"messageId": "a", "role": "ROLE_ALIEN", "parts": [{"text": "x"}]}}),
    ("R11", "unknown top-level field", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": [{"text": "x"}]}, "bogus": 1}),
    ("R12", "unknown message field", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": [{"text": "x"}], "bogus": 1}}),
    ("R13", "messageId is a number", {"message": {"messageId": 5, "role": "ROLE_USER", "parts": [{"text": "x"}]}}),
    ("R14", "snake_case field names", {"message": {"message_id": "a", "role": "ROLE_USER", "parts": [{"text": "x"}]}}),
    ("R15", "role as short name USER", {"message": {"messageId": "a", "role": "USER", "parts": [{"text": "x"}]}}),
    ("R16", "text part with mediaType+filename", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": [{"text": "x", "mediaType": "text/plain", "filename": "a.txt"}]}}),
    ("R17", "url part", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": [{"url": "https://example.com/a.png", "mediaType": "image/png"}]}}),
    ("R18", "raw part not base64", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": [{"raw": "!!!not base64!!!"}]}}),
    ("R19", "data part scalar", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": [{"data": 42}]}}),
    ("R20", "metadata not an object", {"message": {"messageId": "a", "role": "ROLE_USER", "parts": [{"text": "x"}], "metadata": [1]}}),
    ("R21", "configuration.historyLength negative", {**msg(), "configuration": {"historyLength": -1}}),
    ("R22", "configuration wrong type", {**msg(), "configuration": "x"}),
    ("R23", "taskId names nonexistent task", {"message": {"messageId": "a", "role": "ROLE_USER", "taskId": "no-such-task", "parts": [{"text": "x"}]}}),
    ("R24", "empty-string messageId", {"message": {"messageId": "", "role": "ROLE_USER", "parts": [{"text": "x"}]}}),
]
for pid, title, body in cases:
    s, h, t, j = call("POST", "/message:send", body)
    probe(pid, title, "4xx with an error body, never 5xx/hang", s, f"reason={reason(j)} {t[:110] if s >= 500 or s == 200 else ''}")

s, h, t, j = call("POST", "/message:send", raw="{not json")
probe("R25", "malformed JSON", "400", s, f"reason={reason(j)}")
s, h, t, j = call("POST", "/message:send", raw="")
probe("R26", "empty body", "400", s, f"reason={reason(j)}")
s, h, t, j = call("POST", "/message:send", raw="[]")
probe("R27", "body is a JSON array", "400", s, f"reason={reason(j)}")
s, h, t, j = call("POST", "/message:send", raw=b"\xff\xfe\x00".decode("latin1"))
probe("R28", "non-UTF8 bytes", "400, never 5xx", s, f"reason={reason(j)}")
big = "x" * (5 * 1024 * 1024)
s, h, t, j = call("POST", "/message:send", msg(big), timeout=30)
probe("R29", "5 MB text part", "accepted or a clean 413/400, never a crash", s, t[:80])

# ---- Task lifecycle / listing (proto + 6.5) ---------------------------------------------
s, h, t, j = send("seed")
tid = j["task"]["id"] if j and "task" in j else None
probe("T0", "seed task", "200 + completed Task", s, f"task={tid} state={j and j.get('task', {}).get('status', {}).get('state')}")
for pid, q, exp in [
    ("L1", "pageSize=0", "proto: page_size 0 = default OR 400"),
    ("L2", "pageSize=-1", "400"),
    ("L3", "pageSize=101", "6.5 example: 400 (1..100 inclusive) OR clamp to 100"),
    ("L4", "pageSize=1000000", "400 or clamp"),
    ("L5", "pageSize=abc", "400"),
    ("L6", "pageToken=garbage", "400 (invalid token) not 5xx"),
    ("L7", "status=TASK_STATE_COMPLETED", "200, only completed"),
    ("L8", "status=working", "400 (invalid enum) per 6.5 example"),
    ("L9", "historyLength=-5", "400 per 6.5 example"),
    ("L10", "historyLength=0", "200, history omitted"),
    ("L11", "contextId=nonexistent", "200, empty tasks, totalSize 0"),
    ("L12", "statusTimestampAfter=notadate", "400"),
    ("L13", "statusTimestampAfter=2000-01-01T00:00:00Z", "200"),
    ("L14", "includeArtifacts=maybe", "400"),
    ("L15", "unknownParam=1", "200 (ignore) or 400; not 5xx"),
]:
    s, h, t, j = call("GET", "/tasks?" + q)
    extra = ""
    if s == 200 and j is not None:
        extra = f"tasks={len(j.get('tasks', []))} pageSize={j.get('pageSize')} totalSize={j.get('totalSize')} next={j.get('nextPageToken')!r}"
    else:
        extra = f"reason={reason(j)} {t[:100]}"
    probe(pid, f"GET /tasks?{q}", exp, s, extra)

# pagination walk: create 5 tasks in one context then page by 2
ctx = str(uuid.uuid4())
for i in range(5):
    call("POST", "/message:send", msg(f"t{i}", contextId=ctx))
seen, tok, pages = [], None, 0
while pages < 10:
    q = f"/tasks?contextId={ctx}&pageSize=2" + (f"&pageToken={tok}" if tok else "")
    s, h, t, j = call("GET", q)
    if s != 200:
        break
    seen += [x["id"] for x in j.get("tasks", [])]
    tok = j.get("nextPageToken") or None
    pages += 1
    if not tok:
        break
probe("L16", "pagination walk 5 tasks / pageSize 2", "3 pages, 5 distinct ids, totalSize 5, no dupes",
      s, f"pages={pages} ids={len(seen)} distinct={len(set(seen))}")
s, h, t, j = call("GET", f"/tasks?contextId={ctx}")
tasks = j.get("tasks", []) if j else []
ts = [x["status"].get("timestamp") for x in tasks]
probe("L17", "list ordering", "spec: most recently updated first", s, f"desc={ts == sorted(ts, reverse=True)} n={len(ts)}")

s, h, t, j = call("GET", f"/tasks/{tid}")
probe("T1", "GET task", "200", s, f"state={j and j.get('status', {}).get('state')}")
s, h, t, j = call("GET", f"/tasks/{tid}?historyLength=0")
probe("T2", "GET task historyLength=0", "history absent/empty", s, f"history={j and j.get('history')}")
s, h, t, j = call("GET", f"/tasks/{tid}?historyLength=1")
probe("T3", "GET task historyLength=1", "at most 1 history entry", s, f"n={len(j.get('history', [])) if j else None}")
s, h, t, j = call("GET", f"/tasks/{tid}?historyLength=-1")
probe("T4", "GET task historyLength=-1", "400", s, f"reason={reason(j)}")
s, h, t, j = call("GET", f"/tasks/{tid}%3Acancel")
probe("T5", "GET tasks/{id}%3Acancel (encoded colon)", "not a 5xx", s, f"reason={reason(j)}")
s, h, t, j = call("POST", f"/tasks/{tid}%3Acancel", {})
probe("T6", "POST tasks/{id}%3Acancel", "same as literal colon: TASK_NOT_CANCELABLE", s, f"reason={reason(j)}")
s, h, t, j = call("POST", f"/tasks/{tid}:cancel", {})
probe("T7", "POST tasks/{id}:cancel on completed", "TASK_NOT_CANCELABLE", s, f"reason={reason(j)}")
s, h, t, j = call("POST", f"/tasks/{tid}:cancel", raw="")
probe("T8", "cancel with empty body", "accepted", s, f"reason={reason(j)}")
s, h, t, j = call("POST", "/tasks/no-such:cancel", {})
probe("T9", "cancel unknown", "404 TASK_NOT_FOUND", s, f"reason={reason(j)}")
s, h, t, j = call("GET", "/tasks/" + "a" * 5000)
probe("T10", "5000-char task id", "404, not 5xx", s, f"reason={reason(j)}")
s, h, t, j = call("GET", "/tasks/../etc/passwd")
probe("T11", "path traversal in task id", "404/400, not 5xx", s, f"reason={reason(j)}")
s, h, t, j = call("GET", "/tasks/%00")
probe("T12", "NUL in task id", "404/400, not 5xx", s, f"reason={reason(j)}")
s, h, t, j = call("GET", "/tasks/é")
probe("T13", "non-ASCII path", "404/400", s, f"reason={reason(j)}")

# message to a terminal task
s, h, t, j = call("POST", "/message:send", {"message": {"messageId": str(uuid.uuid4()), "role": "ROLE_USER", "taskId": tid, "parts": [{"text": "again"}]}})
probe("T14", "message:send continuing a COMPLETED task", "spec 3.4.x: terminal tasks accept no more messages -> error (UNSUPPORTED_OPERATION / TASK_NOT_FOUND-ish), not a fresh 200",
      s, f"reason={reason(j)} {t[:120] if s == 200 else ''}")
s, h, t, j = call("POST", "/message:send", {"message": {"messageId": str(uuid.uuid4()), "role": "ROLE_USER", "taskId": tid, "contextId": "some-other-context", "parts": [{"text": "again"}]}})
probe("T15", "taskId with mismatched contextId", "error (INVALID_PARAMS)", s, f"reason={reason(j)}")

# streaming edge cases
def sse(path, body, method="POST", **kw):
    return call(method, path, body, headers={"Accept": "text/event-stream"}, **kw)

s, h, t, j = sse(f"/tasks/{tid}:subscribe", None)
probe("S1", "subscribe to a terminal task", "spec 3.1.6: UNSUPPORTED_OPERATION (400)", s, f"reason={reason(j)} {t[:100] if s == 200 else ''}")
s, h, t, j = sse("/tasks/no-such:subscribe", None)
probe("S2", "subscribe to unknown task", "404 TASK_NOT_FOUND as a normal HTTP error, not an SSE stream", s, f"reason={reason(j)} ct={h.get('content-type')}")
s, h, t, j = call("POST", "/message:stream", {"message": {"role": "ROLE_USER", "parts": [{"text": "x"}]}})
probe("S3", "message:stream with an invalid body", "400 as a normal HTTP error before any stream starts", s, f"reason={reason(j)} ct={h.get('content-type')}")
s, h, t, j = call("POST", "/message:stream", msg("stream"))
probe("S4", "message:stream response headers", "text/event-stream, Cache-Control: no-cache", s, f"ct={h.get('content-type')} cc={h.get('cache-control')} x-accel={h.get('x-accel-buffering')}")

# push notification config
def push(tid_, body, method="POST", extra=""):
    return call(method, f"/tasks/{tid_}/pushNotificationConfigs{extra}", body)

for pid, url, exp in [
    ("P1", "https://example.com/hook", "200 (valid)"),
    ("P2", "http://127.0.0.1:1/hook", "loopback: SSRF risk -> refuse or at least document"),
    ("P3", "http://169.254.169.254/latest/meta-data/", "link-local metadata address -> refuse (14.1.1 SSRF)"),
    ("P4", "file:///etc/passwd", "refuse (400)"),
    ("P5", "not a url", "400"),
    ("P6", "", "400"),
    ("P7", "http://[::1]/hook", "loopback v6 -> refuse"),
    ("P8", "http://10.0.0.5/hook", "private range -> refuse or document"),
    ("P9", "gopher://example.com/", "refuse"),
    ("P10", "http://localhost@evil.example/", "userinfo trick"),
]:
    s, h, t, j = push(tid, {"config": {"url": url}} if False else {"url": url})
    probe(pid, f"push config url={url!r}", exp, s, f"reason={reason(j)} {t[:120] if s == 200 else ''}")
s, h, t, j = push("no-such", {"url": "https://example.com/hook"})
probe("P11", "push config on unknown task", "404 TASK_NOT_FOUND", s, f"reason={reason(j)}")
s, h, t, j = push(tid, None, method="GET")
probe("P12", "list push configs", "200", s, t[:140])
s, h, t, j = push(tid, None, method="GET", extra="?pageSize=0")
probe("P13", "list push configs pageSize=0", "200 or 400", s, t[:100])
s, h, t, j = push(tid, None, method="GET", extra="/does-not-exist")
probe("P14", "get unknown push config id", "404 TASK_NOT_FOUND", s, f"reason={reason(j)}")
s, h, t, j = push(tid, None, method="DELETE", extra="/does-not-exist")
probe("P15", "delete unknown push config id", "404 or 200 idempotent (spec: empty)", s, f"reason={reason(j)}")

# card / discovery
s, h, t, j = call("GET", "/.well-known/agent-card.json", ctype=None, version=None)
probe("D1", "card without A2A-Version", "200 (discovery is not versioned)", s, "")
s, h, t, j = call("GET", "/.well-known/agent-card.json", ctype=None, headers={"If-None-Match": h.get("etag", "")})
probe("D2", "card conditional GET with ETag", "304 (8.x SHOULD support caching)", s, f"etag={h.get('etag')}")
s, h, t, j = call("HEAD", "/.well-known/agent-card.json", ctype=None)
probe("D3", "HEAD card", "200 or 405, not 5xx", s, "")
s, h, t, j = call("GET", "/extendedAgentCard")
probe("D4", "GET /extendedAgentCard when not configured", "400 EXTENDED_AGENT_CARD_NOT_CONFIGURED", s, f"reason={reason(j)}")
s, h, t, j = call("GET", "/nosuchtenant/extendedAgentCard")
probe("D5", "tenant-prefixed extended card", "clean 4xx", s, f"reason={reason(j)}")
s, h, t, j = call("GET", "/.well-known/agent.json", ctype=None)
probe("D6", "legacy card path /.well-known/agent.json", "404 acceptable (0.3 path); a 200 would be a v0.3 shape", s, "")

# concurrency: 40 parallel sends
import concurrent.futures as cf
def one(i):
    s, h, t, j = call("POST", "/message:send", msg(f"c{i}"))
    return s, (j or {}).get("task", {}).get("status", {}).get("state")
with cf.ThreadPoolExecutor(40) as ex:
    rs = list(ex.map(one, range(40)))
bad = [r for r in rs if r != (200, "TASK_STATE_COMPLETED")]
probe("K1", "40 concurrent blocking sends", "all 200 COMPLETED", 200 if not bad else -2, f"bad={bad[:3]}")

print("\nSUMMARY (lines starting with '??' need a human look against the spec):")
for r in RESULTS:
    pass
