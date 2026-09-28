import ballerina/a2a;
import ballerina/file;
import ballerina/http;
import ballerina/io;
import ballerina/lang.runtime;

// The receiver runs as its own process (push_receiver.py) -- a module-level
// http:Listener only starts *after* main() returns in this execution model
// (confirmed with a minimal repro), so it can never be reachable during a
// main()-driven test. The receiver writes each delivery here; this file's
// removal before sending is what tells us a later write is this delivery,
// not a stale one from an earlier run.
const string PUSH_RECEIVER_OUT_FILE = "/tmp/push_receiver_last.json";

public function main() returns error? {
    string url = "http://localhost:9700";

    io:println("== I1: resolve card ==");
    a2a:AgentCard card = check a2a:resolveAgentCard(url);
    io:println("name: ", card.name, " | streaming: ", card.capabilities.streaming,
            " | push: ", card.capabilities.pushNotifications);

    a2a:HttpClient c = check new (card);

    io:println("== I2: blocking send -> direct Message ==");
    a2a:Task|a2a:Message|a2a:Error r1 = c->sendMessage({
        message: {messageId: "interop-message-response-1", role: a2a:ROLE_USER, parts: [{text: "hi"}]}
    });
    if r1 is a2a:Message {
        io:println("got Message: ", (<a2a:Part>r1.parts[0])?.text);
    } else {
        io:println("UNEXPECTED: ", (r1 is error) ? r1.message() : "not a Message");
    }

    io:println("== I3: blocking send -> completed Task with artifact ==");
    a2a:Task|a2a:Message|a2a:Error r2 = c->sendMessage({
        message: {messageId: "interop-default-1", role: a2a:ROLE_USER, parts: [{text: "Paris"}]}
    });
    if r2 is a2a:Task {
        io:println("task state: ", r2.status.state, " | artifact: ",
            r2.artifacts is a2a:Artifact[] && (<a2a:Artifact[]>r2.artifacts).length() > 0
                ? (<a2a:Part>(<a2a:Artifact[]>r2.artifacts)[0].parts[0])?.text : "NONE");
    } else {
        io:println("UNEXPECTED: ", (r2 is error) ? r2.message() : "not a Task");
    }

    io:println("== I6: cancel a completed task -> TaskNotCancelableError ==");
    a2a:Task|a2a:Message|a2a:Error r3 = c->sendMessage({
        message: {messageId: "interop-task-immediate-complete-1", role: a2a:ROLE_USER, parts: [{text: "x"}]}
    });
    if r3 is a2a:Task {
        a2a:Task|a2a:Error canceled = c->cancelTask({id: r3.id});
        io:println("cancel result: ", canceled is a2a:TaskNotCancelableError ? "TaskNotCancelableError (correct)" : (canceled is error ? canceled.message() : "unexpectedly succeeded"));
    }

    io:println("== I7: getTask on unknown id -> TaskNotFoundError ==");
    a2a:Task|a2a:Error r4 = c->getTask({id: "no-such-task-ever"});
    io:println(r4 is a2a:TaskNotFoundError ? "TaskNotFoundError (correct)" : (r4 is error ? r4.message() : "unexpectedly succeeded"));

    io:println("== I11: raw bytes part ==");
    a2a:Task|a2a:Message|a2a:Error r5 = c->sendMessage({
        message: {messageId: "interop-raw-1", role: a2a:ROLE_USER, parts: [{raw: "hello-bytes".toBytes()}]}
    });
    if r5 is a2a:Task {
        io:println("artifact: ", (<a2a:Part>(<a2a:Artifact[]>r5.artifacts)[0].parts[0])?.text);
    } else {
        io:println("UNEXPECTED: ", (r5 is error) ? r5.message() : "not a Task");
    }

    io:println("== I4: returnImmediately + poll ==");
    a2a:Task|a2a:Message|a2a:Error r6 = c->sendMessage({
        message: {messageId: "interop-task-paced-1", role: a2a:ROLE_USER, parts: [{text: "poll me"}]},
        configuration: {returnImmediately: true}
    });
    if r6 is a2a:Task {
        io:println("immediate state: ", r6.status.state, " (expect not-yet-COMPLETED)");
        a2a:TaskState polled = r6.status.state;
        foreach int _ in 0 ..< 10 {
            a2a:Task p = check c->getTask({id: r6.id});
            polled = p.status.state;
            if polled == a2a:TASK_STATE_COMPLETED {
                break;
            }
            runtime:sleep(0.3);
        }
        io:println("polled to: ", polled, polled == a2a:TASK_STATE_COMPLETED ? " (correct)" : " (WRONG)");
    } else {
        io:println("UNEXPECTED: ", (r6 is error) ? r6.message() : "not a Task");
    }

    io:println("== I9: subscribe to an already-running task ==");
    a2a:Task|a2a:Message|a2a:Error r7 = c->sendMessage({
        message: {messageId: "interop-task-paced-2", role: a2a:ROLE_USER, parts: [{text: "subscribe me"}]},
        configuration: {returnImmediately: true}
    });
    if r7 is a2a:Task {
        stream<a2a:StreamResponse, a2a:Error?>|a2a:Error sub = c->subscribeToTask({id: r7.id});
        if sub is stream<a2a:StreamResponse, a2a:Error?> {
            boolean sawCompleted = false;
            // Pulled manually, bounded, rather than forEach-to-close: a
            // subscribe stream is not guaranteed to close itself once the
            // task is terminal, and this must not hang the whole run on
            // that assumption.
            foreach int _ in 0 ..< 20 {
                record {|a2a:StreamResponse value;|}|a2a:Error?|error next = sub.next();
                if next is record {|a2a:StreamResponse value;|} {
                    a2a:StreamResponse ev = next.value;
                    if (ev is a2a:Task && ev.status.state == a2a:TASK_STATE_COMPLETED)
                            || (ev is a2a:TaskStatusUpdateEvent && ev.status.state == a2a:TASK_STATE_COMPLETED) {
                        sawCompleted = true;
                        break;
                    }
                } else {
                    break;
                }
            }
            error? closeErr = sub.close();
            io:println(sawCompleted ? "subscribed and saw completion (correct)" : "did not observe completion via subscribe");
        } else {
            io:println("UNEXPECTED: ", sub.message());
        }
    }

    io:println("== I10: multi-turn continuation ==");
    a2a:Task|a2a:Message|a2a:Error r8 = c->sendMessage({
        message: {messageId: "interop-task-input-required-1", role: a2a:ROLE_USER, parts: [{text: "plan a trip"}]}
    });
    if r8 is a2a:Task {
        io:println("first turn state: ", r8.status.state, " (expect INPUT_REQUIRED)");
        a2a:Task|a2a:Message|a2a:Error r9 = c->sendMessage({
            message: {messageId: "interop-continue-1", taskId: r8.id, contextId: r8.contextId,
                role: a2a:ROLE_USER, parts: [{text: "Paris"}]}
        });
        if r9 is a2a:Task {
            io:println("continued to: ", r9.status.state, " on the same task id: ", r9.id == r8.id);
        } else {
            io:println("UNEXPECTED: ", (r9 is error) ? r9.message() : "not a Task");
        }
    } else {
        io:println("UNEXPECTED: ", (r8 is error) ? r8.message() : "not a Task");
    }

    io:println("== I5: ListTasks with pageSize ==");
    a2a:ListTasksResponse|a2a:Error listed = c->listTasks({pageSize: 2});
    if listed is a2a:ListTasksResponse {
        io:println("got ", listed.tasks.length(), " tasks (pageSize 2), totalSize=", listed.totalSize);
    } else {
        io:println("UNEXPECTED: ", listed.message());
    }

    io:println("== I12: push notifications ==");
    // Clear any stale delivery left by an earlier run; "not found" is fine.
    file:Error? removeResult = file:remove(PUSH_RECEIVER_OUT_FILE);
    if removeResult is file:Error {
        io:println("(no stale push_receiver output to clear)");
    }
    a2a:Task|a2a:Message|a2a:Error r10 = c->sendMessage({
        message: {messageId: "interop-task-paced-3", role: a2a:ROLE_USER, parts: [{text: "notify me"}]},
        configuration: {
            returnImmediately: true,
            taskPushNotificationConfig: {url: "http://localhost:19870/hook"}
        }
    });
    if r10 is a2a:Task {
        boolean delivered = false;
        string body = "";
        foreach int _ in 0 ..< 20 {
            string|error content = io:fileReadString(PUSH_RECEIVER_OUT_FILE);
            if content is string {
                delivered = true;
                body = content;
                break;
            }
            runtime:sleep(0.3);
        }
        io:println(delivered ? "webhook delivered (correct): " + body : "webhook NOT delivered");
    } else {
        io:println("UNEXPECTED: ", (r10 is error) ? r10.message() : "not a Task");
    }

    io:println("== I15: malformed body -> 400, not 500 ==");
    http:Client raw = check new (url);
    http:Response badJson = check raw->post("/message:send", "{not json",
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    io:println("malformed JSON status: ", badJson.statusCode, badJson.statusCode == 400 ? " (correct)" : " (WRONG)");

    io:println("== auth-error mapping stays sane against a foreign server: fetch a card at a closed port ==");
    a2a:AgentCard|a2a:Error bad = a2a:resolveAgentCard("http://localhost:1");
    io:println(bad is a2a:Error ? "Error, as expected: " + bad.message() : "UNEXPECTED SUCCESS");
}
