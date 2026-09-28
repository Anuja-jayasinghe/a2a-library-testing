// The client operations that had never been run against a foreign server:
// sendStreamingMessage, the four push-config operations, getExtendedAgentCard,
// listTasks filters, cancelling a *running* task, and the decoding of typed
// errors that a real server (a2a-sdk 1.1.5) generates. Each check prints one
// PASS/FAIL line so a failure names itself.
//
// Run against python-agent/agent.py on 9700 (default), then again with
// INTEROP_NO_PUSH=1 on 9702 and INTEROP_NO_EXTENDED_CARD=1 on 9703 for the
// typed-error checks (see run_client_ops.sh).

import ballerina/a2a;
import ballerina/io;
import ballerina/lang.runtime;

configurable string agentUrl = "http://localhost:9700";
configurable string noPushUrl = "http://localhost:9702";
configurable string noExtendedUrl = "http://localhost:9703";

int failures = 0;

function expect(string label, boolean ok, string detail = "") {
    io:println(ok ? "PASS: " : "FAIL: ", label, ok || detail == "" ? "" : " -- " + detail);
    if !ok {
        failures += 1;
    }
}

// All of an artifact's text parts, joined: `append` adds parts to one artifact.
function textOf(a2a:Artifact? artifact) returns string {
    string joined = "";
    if artifact is a2a:Artifact {
        foreach a2a:Part p in artifact.parts {
            joined += p?.text ?: "";
        }
    }
    return joined;
}

public function main() returns error? {
    a2a:HttpClient c = check new (agentUrl);

    io:println("== sendStreamingMessage (client) against a real server ==");
    stream<a2a:StreamResponse, a2a:Error?>|a2a:Error st = c->sendStreamingMessage({
        message: {messageId: "interop-task-paced-stream", role: a2a:ROLE_USER, parts: [{text: "stream me"}]}
    });
    if st is stream<a2a:StreamResponse, a2a:Error?> {
        int events = 0;
        boolean sawTask = false;
        boolean sawArtifact = false;
        boolean sawCompleted = false;
        while true {
            record {|a2a:StreamResponse value;|}|a2a:Error? n = st.next();
            if n is record {|a2a:StreamResponse value;|} {
                events += 1;
                a2a:StreamResponse ev = n.value;
                if ev is a2a:Task {
                    sawTask = true;
                } else if ev is a2a:TaskArtifactUpdateEvent {
                    sawArtifact = true;
                } else if ev is a2a:TaskStatusUpdateEvent && ev.status.state == a2a:TASK_STATE_COMPLETED {
                    sawCompleted = true;
                }
            } else {
                break;
            }
            if events > 20 {
                break;
            }
        }
        expect("streaming: initial Task event", sawTask);
        expect("streaming: artifact event", sawArtifact);
        expect("streaming: COMPLETED status, and the stream then ends", sawCompleted && events <= 20,
                string `events=${events}`);
    } else {
        expect("streaming: opened", false, st.message());
    }

    io:println("== push-config CRUD through the client ==");
    a2a:Task|a2a:Message|a2a:Error held = c->sendMessage({
        message: {messageId: "interop-task-cancelable-pc", role: a2a:ROLE_USER, parts: [{text: "hold"}]},
        configuration: {returnImmediately: true}
    });
    if held is a2a:Task {
        string taskId = held.id;
        a2a:TaskPushNotificationConfig|a2a:Error created = c->createTaskPushNotificationConfig(
                {taskId, id: "cfg-1", url: "http://localhost:19870/hook", token: "secret-token"});
        expect("create returns the caller's id", created is a2a:TaskPushNotificationConfig && created?.id == "cfg-1",
                created is a2a:Error ? created.message() : "");
        a2a:TaskPushNotificationConfig|a2a:Error got = c->getTaskPushNotificationConfig({taskId, id: "cfg-1"});
        expect("get returns the same config", got is a2a:TaskPushNotificationConfig && got.url == "http://localhost:19870/hook",
                got is a2a:Error ? got.message() : "");
        a2a:ListTaskPushNotificationConfigsResponse|a2a:Error listed = c->listTaskPushNotificationConfigs({taskId});
        expect("list contains it", listed is a2a:ListTaskPushNotificationConfigsResponse
                && (listed?.configs ?: []).length() == 1, listed is a2a:Error ? listed.message() : "");
        a2a:Error? deleted = c->deleteTaskPushNotificationConfig({taskId, id: "cfg-1"});
        expect("delete succeeds", deleted is (), deleted is a2a:Error ? deleted.message() : "");
        a2a:TaskPushNotificationConfig|a2a:Error gone = c->getTaskPushNotificationConfig({taskId, id: "cfg-1"});
        expect("get after delete is an error", gone is a2a:Error);

        io:println("== cancel a RUNNING task ==");
        a2a:Task|a2a:Error canceled = c->cancelTask({id: taskId});
        expect("cancel of a running task reaches CANCELED", canceled is a2a:Task
                && canceled.status.state == a2a:TASK_STATE_CANCELED,
                canceled is a2a:Error ? canceled.message() : canceled.status.state);
    } else {
        expect("create a task to hold", false);
    }

    io:println("== getExtendedAgentCard ==");
    a2a:AgentCard|a2a:Error ext = c->getExtendedAgentCard();
    expect("extended card fetched, with the extra skill", ext is a2a:AgentCard && ext.skills.length() == 2,
            ext is a2a:Error ? ext.message() : "skills=" + ext.skills.length().toString());

    io:println("== listTasks filters ==");
    a2a:Task|a2a:Message|a2a:Error a = c->sendMessage({
        message: {messageId: "interop-default-ctx-a", role: a2a:ROLE_USER, parts: [{text: "a"}]}
    });
    if a is a2a:Task {
        string ctx = a.contextId ?: ""; // captured: type narrowing does not carry into the lambdas below
        a2a:ListTasksResponse|a2a:Error byCtx = c->listTasks({contextId: ctx});
        expect("contextId filter returns only that context", byCtx is a2a:ListTasksResponse
                && byCtx.tasks.length() >= 1 && byCtx.tasks.every(t => t.contextId == ctx),
                byCtx is a2a:Error ? byCtx.message() : "");
        a2a:ListTasksResponse|a2a:Error done = c->listTasks({status: a2a:TASK_STATE_COMPLETED, pageSize: 50});
        expect("status filter returns only COMPLETED", done is a2a:ListTasksResponse
                && done.tasks.length() >= 1 && done.tasks.every(t => t.status.state == a2a:TASK_STATE_COMPLETED),
                done is a2a:Error ? done.message() : "");
        a2a:ListTasksResponse|a2a:Error page1 = c->listTasks({pageSize: 2});
        if page1 is a2a:ListTasksResponse && page1.nextPageToken != "" {
            a2a:ListTasksResponse|a2a:Error page2 = c->listTasks({pageSize: 2, pageToken: page1.nextPageToken});
            expect("pageToken advances to a different page", page2 is a2a:ListTasksResponse
                    && page2.tasks.length() > 0 && page2.tasks[0].id != page1.tasks[0].id,
                    page2 is a2a:Error ? page2.message() : "");
        } else {
            expect("pageToken advances to a different page", false, "no nextPageToken on the first page");
        }
        a2a:ListTasksResponse|a2a:Error noArtifacts = c->listTasks({contextId: ctx, includeArtifacts: false});
        expect("includeArtifacts=false omits artifacts", noArtifacts is a2a:ListTasksResponse
                && noArtifacts.tasks.length() >= 1 && noArtifacts.tasks.every(t => (t?.artifacts ?: []).length() == 0),
                noArtifacts is a2a:Error ? noArtifacts.message() : "");
    }

    io:println("== an artifact streamed in chunks (append / lastChunk) by a foreign server ==");
    stream<a2a:StreamResponse, a2a:Error?>|a2a:Error ch = c->sendStreamingMessage({
        message: {messageId: "interop-task-chunked-1", role: a2a:ROLE_USER, parts: [{text: "chunks"}]}
    });
    if ch is stream<a2a:StreamResponse, a2a:Error?> {
        string joined = "";
        int chunkEvents = 0;
        boolean lastSeen = false;
        boolean appendSeen = false;
        int guard = 0;
        while guard < 20 {
            guard += 1;
            record {|a2a:StreamResponse value;|}|a2a:Error? n = ch.next();
            if n is record {|a2a:StreamResponse value;|} {
                a2a:StreamResponse ev = n.value;
                if ev is a2a:TaskArtifactUpdateEvent {
                    chunkEvents += 1;
                    joined += textOf(ev.artifact);
                    appendSeen = appendSeen || ev.append == true;
                    lastSeen = lastSeen || ev.lastChunk == true;
                }
            } else {
                break;
            }
        }
        expect("chunked artifact: three chunk events arrive in order", chunkEvents == 3 && joined == "one two three",
                string `events=${chunkEvents} joined="${joined}"`);
        expect("chunked artifact: the append and lastChunk flags survive decoding", appendSeen && lastSeen);
    } else {
        expect("chunked artifact: stream opened", false, ch.message());
    }
    a2a:Task|a2a:Message|a2a:Error chBlocking = c->sendMessage({
        message: {messageId: "interop-task-chunked-2", role: a2a:ROLE_USER, parts: [{text: "chunks"}]}
    });
    expect("chunked artifact: a blocking send returns the merged text", chBlocking is a2a:Task
            && (chBlocking?.artifacts ?: []).length() == 1 && textOf((<a2a:Artifact[]>chBlocking?.artifacts)[0]) == "one two three",
            chBlocking is a2a:Task ? textOf((chBlocking?.artifacts ?: [])[0]) : "not a task");

    io:println("== typed errors decoded from a REAL server's bodies ==");
    // The client refuses locally when the card says a capability is absent, so
    // to see the *server's* error we make the client believe the capability
    // exists (edit the resolved card), then let the real server say no.
    a2a:AgentCard noPushCard = check a2a:resolveAgentCard(noPushUrl);
    expect("server withholds push (card says so)", !noPushCard.capabilities.pushNotifications);
    noPushCard.capabilities.pushNotifications = true;
    a2a:HttpClient liar = check new (noPushCard);
    a2a:Task|a2a:Message|a2a:Error t = liar->sendMessage({
        message: {messageId: "interop-task-cancelable-np", role: a2a:ROLE_USER, parts: [{text: "x"}]},
        configuration: {returnImmediately: true}
    });
    if t is a2a:Task {
        a2a:TaskPushNotificationConfig|a2a:Error pn = liar->createTaskPushNotificationConfig(
                {taskId: t.id, url: "http://localhost:19870/hook"});
        expect("PushNotificationNotSupportedError from a real 400 + PUSH_NOTIFICATION_NOT_SUPPORTED",
                pn is a2a:PushNotificationNotSupportedError, pn is a2a:Error ? pn.message() : "unexpectedly succeeded");
    }

    a2a:AgentCard noExtCard = check a2a:resolveAgentCard(noExtendedUrl);
    expect("server claims an extended card (card says so)", noExtCard.capabilities.extendedAgentCard);
    a2a:HttpClient c3 = check new (noExtCard);
    a2a:AgentCard|a2a:Error ne = c3->getExtendedAgentCard();
    expect("ExtendedAgentCardNotConfiguredError from a real 400 + EXTENDED_AGENT_CARD_NOT_CONFIGURED",
            ne is a2a:ExtendedAgentCardNotConfiguredError, ne is a2a:Error ? ne.message() : "unexpectedly succeeded");

    io:println(failures == 0 ? "\nOVERALL: PASS" : string `\nOVERALL: FAIL (${failures})`);
    runtime:sleep(0.1);
}
