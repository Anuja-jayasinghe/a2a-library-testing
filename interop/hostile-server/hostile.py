#!/usr/bin/env python3
"""A deliberately awkward A2A HTTP+JSON server, for probing ballerina/a2a's *client*.

Raw sockets, not a framework, so every byte (line endings, chunking, truncation, timing) is under control.
Each case is its own base path: the card at /<case>/.well-known/agent-card.json advertises
http://localhost:PORT/<case>, and every A2A operation under that prefix gets that case's response.
Cases are grouped by what the spec or a wire standard says a client should do (see CASES).

    python3 hostile.py [port]
"""
import gzip
import json
import socketserver
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9850


def task(state="TASK_STATE_COMPLETED", **extra):
    t = {"id": "t-1", "contextId": "c-1", "status": {"state": state, "timestamp": "2026-09-30T00:00:00Z"},
         "artifacts": [{"artifactId": "a-1", "parts": [{"text": "hello"}]}]}
    t.update(extra)
    return t


def ev(obj, nl="\n", prefix="data: "):
    return f"{prefix}{json.dumps(obj)}{nl}{nl}"


STREAM_OK = [{"task": task("TASK_STATE_SUBMITTED", artifacts=[])},
             {"statusUpdate": {"taskId": "t-1", "contextId": "c-1", "status": {"state": "TASK_STATE_WORKING"}}},
             {"artifactUpdate": {"taskId": "t-1", "contextId": "c-1", "artifact": {"artifactId": "a-1", "parts": [{"text": "hello"}]}, "lastChunk": True}},
             {"statusUpdate": {"taskId": "t-1", "contextId": "c-1", "status": {"state": "TASK_STATE_COMPLETED"}}}]


def json_resp(body, status="200 OK", ctype="application/a2a+json", extra_headers=""):
    raw = body if isinstance(body, bytes) else json.dumps(body).encode()
    return (f"HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {len(raw)}\r\n{extra_headers}"
            f"Connection: close\r\n\r\n").encode() + raw


def sse_head():
    return b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"


# --- unary cases (message:send / tasks list) -------------------------------------------------------------------
def u(case, sock):
    if case == "u_huge":  # the s_huge artifact as a unary reply, to separate SSE parsing cost from JSON decoding
        t = task(); t["artifacts"][0]["parts"][0]["text"] = "x" * 2_000_000
        return sock.sendall(json_resp({"task": t}))
    if case == "u_ok":
        return sock.sendall(json_resp({"task": task()}))
    if case == "u_unknown_fields":  # spec 5.7: SHOULD ignore unrecognized fields
        t = task(futureField={"x": 1})
        t["status"]["futureStatusField"] = True
        t["artifacts"][0]["parts"][0]["futurePartField"] = "y"
        return sock.sendall(json_resp({"task": t, "futureTopLevel": 1}))
    if case == "u_enum_unknown":  # a state value from a newer revision
        return sock.sendall(json_resp({"task": task("TASK_STATE_FROBNICATED")}))
    if case == "u_enum_int":  # ProtoJSON: parsers accept the enum's integer value too
        return sock.sendall(json_resp({"task": task(3)}))
    if case == "u_snake_names":  # ProtoJSON: parsers accept the original proto field name as well as lowerCamelCase
        t = task()
        t["context_id"] = t.pop("contextId")
        return sock.sendall(json_resp({"task": t}))
    if case == "u_null_fields":  # ProtoJSON: null means the field's default
        return sock.sendall(json_resp({"task": task(history=None, metadata=None)}))
    if case == "u_both_arms":  # oneof with two arms set
        return sock.sendall(json_resp({"task": task(), "message": {"messageId": "m", "role": "ROLE_AGENT", "parts": [{"text": "x"}]}}))
    if case == "u_html_200":
        return sock.sendall(json_resp(b"<html><body>proxy login</body></html>", ctype="text/html"))
    if case == "u_500_text":
        return sock.sendall(json_resp(b"boom", status="500 Internal Server Error", ctype="text/plain"))
    if case == "u_503_retry_after":
        return sock.sendall(json_resp(b"", status="503 Service Unavailable", ctype="text/plain", extra_headers="Retry-After: 1\r\n"))
    if case == "u_truncated":  # Content-Length promises more than is sent, then the connection closes
        raw = json.dumps({"task": task()}).encode()
        sock.sendall(f"HTTP/1.1 200 OK\r\nContent-Type: application/a2a+json\r\nContent-Length: {len(raw) + 500}\r\n\r\n".encode() + raw[:40])
        return
    if case == "u_gzip":
        raw = gzip.compress(json.dumps({"task": task()}).encode())
        return sock.sendall(json_resp(raw, extra_headers="Content-Encoding: gzip\r\n"))
    if case == "u_chunked":
        raw = json.dumps({"task": task()}).encode()
        sock.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/a2a+json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
        for i in range(0, len(raw), 7):
            c = raw[i:i + 7]
            sock.sendall(f"{len(c):x}\r\n".encode() + c + b"\r\n")
            time.sleep(0.01)
        return sock.sendall(b"0\r\n\r\n")
    if case == "u_bom":
        return sock.sendall(json_resp(b"\xef\xbb\xbf" + json.dumps({"task": task()}).encode()))
    if case == "u_redirect":  # 307 keeps method and body
        return sock.sendall(f"HTTP/1.1 307 Temporary Redirect\r\nLocation: http://localhost:{PORT}/u_ok/message:send\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
    if case == "u_hang":  # accepts, never answers
        time.sleep(200)
        return
    if case == "u_problem_json":  # an error body as application/problem+json (what a2a-rs sends)
        return sock.sendall(json_resp({"error": {"code": 404, "status": "NOT_FOUND", "message": "nope",
            "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND", "domain": "a2a-protocol.org"}]}},
            status="404 Not Found", ctype="application/problem+json"))
    if case == "u_rfc9457":  # an RFC 9457 problem document instead of google.rpc.Status (what a2a-dotnet sends for bad query params)
        return sock.sendall(json_resp({"type": "about:blank", "title": "Bad Request", "status": 400, "detail": "bad filter"},
            status="400 Bad Request", ctype="application/problem+json"))
    if case == "p_truncated":  # a push-config list whose 200 body is cut off mid-JSON
        raw = json.dumps({"configs": [{"id": "cfg1", "taskId": "t-1", "url": "http://example.com/hook"}]}).encode()
        sock.sendall(f"HTTP/1.1 200 OK\r\nContent-Type: application/a2a+json\r\nContent-Length: {len(raw) + 500}\r\n\r\n".encode() + raw[:25])
        return
    if case == "p_html":  # a proxy's HTML page with a 200
        return sock.sendall(json_resp(b"<html><body>captive portal</body></html>", ctype="text/html"))
    if case == "l_omitted_defaults":  # ProtoJSON omits "" and 0; a2a-rs does this on a last page
        return sock.sendall(json_resp({"tasks": [task()], "pageSize": 50, "totalSize": 1}))
    if case == "l_empty_object":  # the canonical ProtoJSON rendering of an empty page: every field is a default
        return sock.sendall(json_resp({}))
    sock.sendall(json_resp({"error": {"code": 404, "message": f"unknown case {case}"}}, status="404 Not Found"))


# --- streaming cases (message:stream) --------------------------------------------------------------------------
def s(case, sock):
    sock.sendall(sse_head())
    if case == "s_ok":
        return sock.sendall("".join(ev(e) for e in STREAM_OK).encode())
    if case == "s_crlf":  # WHATWG SSE: CRLF, LF and CR are all line terminators
        return sock.sendall("".join(ev(e, nl="\r\n") for e in STREAM_OK).encode())
    if case == "s_cr":
        return sock.sendall("".join(ev(e, nl="\r") for e in STREAM_OK).encode())
    if case == "s_nospace":  # "data:" with no space is valid; the space is optional
        return sock.sendall("".join(ev(e, prefix="data:") for e in STREAM_OK).encode())
    if case == "s_multiline":  # one event over several data: lines, joined with "\n" by the parser
        out = ""
        for e in STREAM_OK:
            j = json.dumps(e, indent=1)
            out += "".join(f"data: {line}\n" for line in j.split("\n")) + "\n"
        return sock.sendall(out.encode())
    if case == "s_split":  # an event's bytes split across writes, mid-JSON and mid-line-terminator
        raw = "".join(ev(e) for e in STREAM_OK).encode()
        for i in range(0, len(raw), 13):
            sock.sendall(raw[i:i + 13])
            time.sleep(0.02)
        return
    if case == "s_fields":  # id, event, retry fields and comments interleaved
        out = ": hello\n\nretry: 1000\n\n"
        for i, e in enumerate(STREAM_OK):
            out += f": keep-alive\nid: {i}\nevent: message\n{ev(e)}"
        return sock.sendall(out.encode())
    if case == "s_bom":  # WHATWG SSE: a leading U+FEFF is stripped
        return sock.sendall(b"\xef\xbb\xbf" + "".join(ev(e) for e in STREAM_OK).encode())
    if case == "s_huge":  # a 2 MB artifact in one event
        big = [STREAM_OK[0], STREAM_OK[1],
               {"artifactUpdate": {"taskId": "t-1", "contextId": "c-1", "artifact": {"artifactId": "a-1", "parts": [{"text": "x" * 2_000_000}]}, "lastChunk": True}},
               STREAM_OK[3]]
        return sock.sendall("".join(ev(e) for e in big).encode())
    if case == "s_eof_midtask":  # the connection drops before any terminal state
        sock.sendall("".join(ev(e) for e in STREAM_OK[:2]).encode())
        return
    if case == "s_bad_json":
        return sock.sendall(ev(STREAM_OK[0]).encode() + b"data: {not json\n\n")
    if case == "s_error_frame":  # a mid-stream error as a named "error" event
        return sock.sendall(ev(STREAM_OK[0]).encode() + b'event: error\ndata: {"error":{"code":500,"message":"agent crashed","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"INTERNAL_ERROR","domain":"a2a-protocol.org"}]}}\n\n')
    if case == "s_unknown_arm":  # a StreamResponse arm from a newer revision, between known ones
        return sock.sendall((ev(STREAM_OK[0]) + ev({"futureArm": {"x": 1}}) + "".join(ev(e) for e in STREAM_OK[1:])).encode())
    if case == "s_no_task_first":  # spec 3.1.2 violation (a2a-rs does this): status update first, no Task event
        return sock.sendall("".join(ev(e) for e in STREAM_OK[1:]).encode())
    if case == "s_after_terminal":  # extra events after the terminal state
        return sock.sendall(("".join(ev(e) for e in STREAM_OK) + ev(STREAM_OK[1])).encode())
    if case == "s_stall":  # opens the stream, sends the Task, then nothing (no keep-alives) for 200s
        sock.sendall(ev(STREAM_OK[0]).encode())
        time.sleep(200)
        return
    sock.sendall(b"data: {}\n\n")


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.request.recv(65536)
            if not chunk:
                return
            data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        method, path, _ = lines[0].split(" ", 2)
        headers = {k.lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:] if ":" in l)}
        want = int(headers.get("content-length", "0"))
        while len(body) < want:
            body += self.request.recv(65536)
        parts = path.lstrip("/").split("/", 1)
        case, rest = parts[0], ("/" + parts[1] if len(parts) > 1 else "/")
        print(f"{method} {path} accept={headers.get('accept', '')} ae={headers.get('accept-encoding', '')}", flush=True)
        try:
            if rest.startswith("/.well-known/agent-card.json"):
                card = {"name": f"hostile {case}", "description": "hostile test server", "version": "1",
                        "supportedInterfaces": [{"url": f"http://localhost:{PORT}/{case}", "protocolBinding": "HTTP+JSON", "protocolVersion": "1.0"}],
                        "capabilities": {"streaming": True, "pushNotifications": case.startswith("p_")},
                        "defaultInputModes": ["text/plain"], "defaultOutputModes": ["text/plain"],
                        "skills": [{"id": "s", "name": "s", "description": "s", "tags": ["t"]}]}
                self.request.sendall(json_resp(card, ctype="application/json"))
            elif case.startswith("s_"):
                s(case, self.request)
            else:
                u(case, self.request)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    print(f"hostile server on http://localhost:{PORT}", flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
