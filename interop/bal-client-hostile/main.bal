// ballerina/a2a HttpClient against a deliberately awkward server (interop/hostile-server/hostile.py).
// Each case prints what the client did: OK (with the decoded state or events), ERR (the typed error and message),
// or PANIC (trapped). The expected outcome, and the rule it comes from, is printed alongside so a reader can judge.
import ballerina/a2a;
import ballerina/io;
import ballerina/time;

configurable string base = "http://localhost:9850";
// Short, so a case that hangs shows up as a timeout instead of stalling the run.
configurable decimal timeoutSeconds = 8;

function mkClient(string c) returns a2a:RestClient|error {
    a2a:AgentCard card = check a2a:resolveAgentCard(string `${base}/${c}`);
    return new (card, clientConfig = {timeout: timeoutSeconds, httpVersion: "1.1"});
}

function req() returns a2a:SendMessageRequest => {message: {messageId: "h-1", role: a2a:ROLE_USER, parts: [{text: "hi"}]}};

function show(string c, string expect, string outcome, decimal secs) {
    io:println(string `${c.padEnd(20)} ${outcome}  [${secs.toString()}s]`);
    io:println(string `${"".padEnd(20)} expected: ${expect}`);
}

function describe(any|error r) returns string {
    if r is a2a:Task {
        return string `OK Task state=${r.status.state} artifacts=${(r.artifacts ?: []).length()}`;
    }
    if r is a2a:Message {
        return "OK Message";
    }
    if r is a2a:ListTasksResponse {
        return string `OK ListTasksResponse tasks=${r.tasks.length()} next=${r.nextPageToken}`;
    }
    if r is error {
        string m = r.message();
        return string `ERR ${(typeof r).toString()}: ${m.length() > 160 ? m.substring(0, 160) + "..." : m}`;
    }
    return "OK " + (typeof r).toString();
}

function unary(string c, string expect) {
    decimal t0 = time:monotonicNow();
    any|error r = trap sendOnce(c);
    show(c, expect, r is error && r.message().startsWith("{ballerina}") ? "PANIC " + r.message() : describe(r), time:monotonicNow() - t0);
}

function sendOnce(string c) returns a2a:Task|a2a:Message|error {
    a2a:RestClient cl = check mkClient(c);
    return cl->sendMessage(req());
}

function list(string c, string expect) {
    decimal t0 = time:monotonicNow();
    any|error r = trap listOnce(c);
    show(c, expect, describe(r), time:monotonicNow() - t0);
}

function listOnce(string c) returns a2a:ListTasksResponse|error {
    a2a:RestClient cl = check mkClient(c);
    return cl->listTasks({});
}

function pushList(string c, string expect) {
    decimal t0 = time:monotonicNow();
    any|error r = trap pushListOnce(c);
    show(c, expect, r is a2a:ListTaskPushNotificationConfigsResponse
        ? string `OK ListTaskPushNotificationConfigsResponse configs=${(r.configs ?: []).length()}` : describe(r), time:monotonicNow() - t0);
}

function pushListOnce(string c) returns a2a:ListTaskPushNotificationConfigsResponse|error {
    a2a:RestClient cl = check mkClient(c);
    return cl->listTaskPushNotificationConfigs({taskId: "t-1"});
}

function streamed(string c, string expect) {
    decimal t0 = time:monotonicNow();
    string|error r = trap streamOnce(c);
    show(c, expect, r is error ? describe(r) : r, time:monotonicNow() - t0);
}

function streamOnce(string c) returns string|error {
    a2a:RestClient cl = check mkClient(c);
    stream<a2a:StreamResponse, a2a:Error?> st = check cl->sendStreamingMessage(req());
    string[] kinds = [];
    int textLen = 0;
    while kinds.length() < 50 {
        record {|a2a:StreamResponse value;|}|a2a:Error? nx = st.next();
        if nx is a2a:Error {
            return string `ERR after [${", ".'join(...kinds)}] ${(typeof nx).toString()}: ${nx.message().length() > 140 ? nx.message().substring(0, 140) : nx.message()}`;
        }
        if nx is () {
            break;
        }
        a2a:StreamResponse e = nx.value;
        if e is a2a:Task {
            kinds.push("task");
        } else if e is a2a:Message {
            kinds.push("message");
        } else if e is a2a:TaskArtifactUpdateEvent {
            kinds.push("artifact");
            foreach a2a:Part p in e.artifact.parts {
                textLen += (p?.text ?: "").length();
            }
        } else if e is a2a:TaskStatusUpdateEvent {
            kinds.push(e.status.state.substring(11));
        }
    }
    return string `OK events=[${", ".'join(...kinds)}] artifactText=${textLen}`;
}

public function main() {
    io:println("=== unary: send ===");
    unary("u_ok", "OK Task COMPLETED (control)");
    unary("u_huge", "OK, fast (a 2 MB artifact in a unary reply; compare s_huge)");
    unary("u_unknown_fields", "OK (spec 5.7: SHOULD ignore unrecognized fields)");
    unary("u_enum_unknown", "a typed error, not a panic or a mis-decoded state");
    unary("u_enum_int", "OK COMPLETED (ProtoJSON parsers accept an enum's integer value; spec 5.5 serialises names)");
    unary("u_snake_names", "OK (ProtoJSON parsers accept original proto names), or a typed error (A2A mandates camelCase)");
    unary("u_null_fields", "OK (ProtoJSON: null is the field default)");
    unary("u_both_arms", "a typed error: a oneof must carry exactly one arm");
    unary("u_html_200", "a typed error (InvalidAgentResponse), not a hang or panic");
    unary("u_500_text", "a typed error carrying the 500");
    unary("u_503_retry_after", "a typed error (no retry configured)");
    unary("u_truncated", "a typed error, promptly (not a hang until timeout)");
    unary("u_gzip", "OK (Content-Encoding: gzip decoded)");
    unary("u_chunked", "OK (chunked transfer)");
    unary("u_bom", "OK or a typed error (RFC 8259 8.1: parsers MAY ignore a BOM)");
    unary("u_redirect", "OK via the redirect, or a typed error; never a panic");
    unary("u_hang", string `a typed timeout after ~${timeoutSeconds}s`);
    unary("u_problem_json", "TaskNotFoundError (same google.rpc.Status body, served as application/problem+json)");
    unary("u_rfc9457", "a typed error (an RFC 9457 body is not google.rpc.Status)");

    io:println("=== unary: list ===");
    list("l_omitted_defaults", "OK tasks=1 next= (ProtoJSON omits the empty nextPageToken)");
    list("l_empty_object", "OK tasks=0 (ProtoJSON renders an empty page as {})");

    io:println("=== unary: list push configs ===");
    pushList("p_truncated", "a typed error: the 200 body is truncated JSON");
    pushList("p_html", "a typed error: the 200 body is not JSON at all");

    io:println("=== streaming ===");
    streamed("s_ok", "OK [task, WORKING, artifact, COMPLETED] (control)");
    streamed("s_crlf", "OK, same four events (WHATWG SSE: CRLF is a line terminator)");
    streamed("s_cr", "OK, same four events (WHATWG SSE: bare CR is a line terminator)");
    streamed("s_nospace", "OK, same four events (the space after 'data:' is optional)");
    streamed("s_multiline", "OK, same four events (multiple data: lines join with \\n)");
    streamed("s_split", "OK, same four events (frames split across TCP writes)");
    streamed("s_fields", "OK, same four events (id/event/retry fields and comments ignored)");
    streamed("s_bom", "OK, same four events (WHATWG SSE: a leading BOM is stripped)");
    streamed("s_huge", "OK, artifactText=2000000");
    streamed("s_huge", "OK, artifactText=2000000 (second run, JIT warm)");
    streamed("s_eof_midtask", "events [task, WORKING] then an error or end; the caller must be able to tell it never finished");
    streamed("s_bad_json", "ERR after [task] InvalidAgentResponse");
    streamed("s_error_frame", "ERR after [task] carrying 'agent crashed'");
    streamed("s_unknown_arm", "OK, four known events, the unknown arm skipped (spec 5.7)");
    streamed("s_no_task_first", "OK [WORKING, artifact, COMPLETED] tolerated, or a typed error (spec 3.1.2 MUST begin with Task)");
    streamed("s_after_terminal", "OK, stops at COMPLETED (events after the terminal state are not delivered)");
    streamed("s_stall", string `a typed timeout after ~${timeoutSeconds}s (no bytes at all), not an indefinite hang`);
}
