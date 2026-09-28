// Opt-in stream reconnection (HttpClientConfiguration.maxReconnectAttempts), against a real server
// whose stream is cut mid-flight by flaky_proxy.py (9705 -> Python agent 9700, cut after 3s).
// The task ticks for ~6s, so the cut lands in the middle of it.

import ballerina/a2a;
import ballerina/http;
import ballerina/io;

configurable string proxyUrl = "http://localhost:9705";

int failures = 0;

function expect(string label, boolean ok, string detail = "") {
    io:println(ok ? "PASS: " : "FAIL: ", label, ok || detail == "" ? "" : " -- " + detail);
    if !ok {
        failures += 1;
    }
}

// Reads a stream to its end (or a bound) and reports what it saw.
function drain(stream<a2a:StreamResponse, a2a:Error?> s) returns [boolean, int, string] {
    boolean completed = false;
    int events = 0;
    string ending = "stream ended";
    int guard = 0;
    while guard < 60 {
        guard += 1;
        record {|a2a:StreamResponse value;|}|a2a:Error? n = s.next();
        if n is record {|a2a:StreamResponse value;|} {
            events += 1;
            a2a:StreamResponse ev = n.value;
            if (ev is a2a:TaskStatusUpdateEvent && ev.status.state == a2a:TASK_STATE_COMPLETED)
                    || (ev is a2a:Task && ev.status.state == a2a:TASK_STATE_COMPLETED) {
                completed = true;
            }
        } else if n is a2a:Error {
            ending = "ended with error: " + n.message();
            break;
        } else {
            break;
        }
    }
    return [completed, events, ending];
}

function run(int attempts, string id) returns [boolean, int, string]|a2a:Error|error {
    // HTTP/1.1 only so the byte-level proxy can read the request line; the client's default HTTP/2 would hide it.
    // The agent's card advertises its own address (9700), so a client that trusted it would bypass the
    // proxy after the card fetch. Point the card's interface at the proxy instead.
    a2a:AgentCard card = check a2a:resolveAgentCard(proxyUrl, clientConfig = {httpVersion: http:HTTP_1_1});
    card.supportedInterfaces[0].url = proxyUrl;
    a2a:HttpClient c = check new (card, maxReconnectAttempts = attempts, clientConfig = {httpVersion: http:HTTP_1_1});
    stream<a2a:StreamResponse, a2a:Error?> s = check c->sendStreamingMessage({
        message: {messageId: id, role: a2a:ROLE_USER, parts: [{text: "tick"}]}
    });
    return drain(s);
}

configurable int attempts = 0;

public function main() returns error? {
    // The proxy cuts only the FIRST streaming connection it sees, so each run gets a fresh proxy.
    io:println("== maxReconnectAttempts = ", attempts, ", stream cut after 3s of a ~6s task ==");
    [boolean, int, string]|a2a:Error|error r = run(attempts, string `interop-task-slowstream-${attempts}`);
    if r is [boolean, int, string] {
        string detail = string `completed=${r[0]} events=${r[1]} (${r[2]})`;
        if attempts == 0 {
            expect("without reconnection the cut stream does NOT reach COMPLETED", !r[0], detail);
        } else {
            expect("with reconnection the client resubscribes and reaches COMPLETED", r[0], detail);
        }
    } else {
        expect("the run produced a result", false, r is error ? r.message() : "");
    }
    io:println(failures == 0 ? "\nOVERALL: PASS" : string `\nOVERALL: FAIL (${failures})`);
}
