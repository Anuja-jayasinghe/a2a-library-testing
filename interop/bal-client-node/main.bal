// ballerina/a2a HttpClient -> a real @a2a-js/sdk 1.2.1 agent (interop/node-agent, HTTP+JSON, A2A v1.0).
// Assertions are on protocol behaviour, never on reply wording.
import ballerina/a2a;
import ballerina/io;
import ballerina/lang.runtime;

int failures = 0;

function expect(string name, boolean ok, string detail = "") {
    io:println(ok ? "PASS: " : "FAIL: ", name, detail == "" ? "" : " -- " + detail);
    if !ok {
        failures += 1;
    }
}

function textOf(a2a:Part[] parts) returns string {
    string s = "";
    foreach a2a:Part p in parts {
        s += p?.text ?: "";
    }
    return s;
}

function user(string id, string text, string? taskId = (), string? contextId = ()) returns a2a:SendMessageRequest {
    a2a:Message m = {messageId: id, role: a2a:ROLE_USER, parts: [{text}]};
    if taskId is string {
        m.taskId = taskId;
    }
    if contextId is string {
        m.contextId = contextId;
    }
    return {message: m};
}

public function main(string url = "http://localhost:9800") returns error? {
    io:println("== I1: card ==");
    a2a:AgentCard card = check a2a:resolveAgentCard(url);
    expect("card resolved", card.name.length() > 0, card.name);
    expect("card declares streaming", card.capabilities.streaming == true);
    a2a:HttpClient c = check new (card);

    io:println("== I3: blocking send -> completed Task + artifact ==");
    a2a:Task|a2a:Message|a2a:Error r = c->sendMessage(user("n-1", "what is 2+2?"));
    string answerText = "";
    if r is a2a:Task {
        expect("state COMPLETED", r.status.state == a2a:TASK_STATE_COMPLETED, r.status.state);
        a2a:Artifact[] arts = r.artifacts ?: [];
        expect("one artifact", arts.length() == 1);
        if arts.length() > 0 {
            answerText = textOf(arts[0].parts);
            io:println("  artifact: ", answerText);
        }
    } else {
        expect("blocking send returned a Task", false, r is error ? r.message() : "Message");
    }

    io:println("== I2: direct Message reply ==");
    a2a:Task|a2a:Message|a2a:Error rm = c->sendMessage(user("n-2", "msg: say hello"));
    expect("got a Message, not a Task", rm is a2a:Message);

    io:println("== I8: streaming send ==");
    stream<a2a:StreamResponse, a2a:Error?>|a2a:Error st = c->sendStreamingMessage(user("n-3", "stream me"));
    if st is stream<a2a:StreamResponse, a2a:Error?> {
        int n = 0;
        boolean sawTask = false;
        boolean sawArtifact = false;
        boolean sawCompleted = false;
        while n < 30 {
            record {|a2a:StreamResponse value;|}|a2a:Error? nx = st.next();
            if nx is record {|a2a:StreamResponse value;|} {
                n += 1;
                a2a:StreamResponse ev = nx.value;
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
        }
        expect("stream: Task first, artifact, COMPLETED, then EOF", sawTask && sawArtifact && sawCompleted && n < 30, string `events=${n}`);
    } else {
        expect("stream opened", false, st.message());
    }

    io:println("== I10: multi-turn (INPUT_REQUIRED -> same task id -> COMPLETED) ==");
    a2a:Task|a2a:Message|a2a:Error t1 = c->sendMessage(user("n-4", "need input please"));
    if t1 is a2a:Task {
        expect("first turn INPUT_REQUIRED", t1.status.state == a2a:TASK_STATE_INPUT_REQUIRED, t1.status.state);
        a2a:Task|a2a:Message|a2a:Error t2 = c->sendMessage(user("n-5", "Paris", t1.id, t1.contextId));
        expect("continuation COMPLETED on the same task", t2 is a2a:Task && t2.id == t1.id && t2.status.state == a2a:TASK_STATE_COMPLETED,
                t2 is a2a:Task ? t2.status.state : "not a task");
    } else {
        expect("first turn is a Task", false);
    }

    io:println("== I4/I6: returnImmediately, then cancel a RUNNING task ==");
    a2a:Task|a2a:Message|a2a:Error s1 = c->sendMessage({
        message: {messageId: "n-6", role: a2a:ROLE_USER, parts: [{text: "slow please"}]},
        configuration: {returnImmediately: true}
    });
    if s1 is a2a:Task {
        expect("returnImmediately gives a non-terminal task", s1.status.state != a2a:TASK_STATE_COMPLETED, s1.status.state);
        runtime:sleep(1);
        a2a:Task|a2a:Error cx = c->cancelTask({id: s1.id});
        expect("cancel of a running task -> CANCELED", cx is a2a:Task && cx.status.state == a2a:TASK_STATE_CANCELED,
                cx is a2a:Task ? cx.status.state : cx.message());
    } else {
        expect("returnImmediately returned a Task", false);
    }

    io:println("== I6b: cancel a completed task ==");
    if r is a2a:Task {
        a2a:Task|a2a:Error cx2 = c->cancelTask({id: r.id});
        expect("TaskNotCancelableError decoded from the JS server's body", cx2 is a2a:TaskNotCancelableError, cx2 is error ? cx2.message() : "succeeded");
    }

    io:println("== I7: getTask unknown id ==");
    a2a:Task|a2a:Error g = c->getTask({id: "no-such-task"});
    expect("TaskNotFoundError", g is a2a:TaskNotFoundError, g is error ? g.message() : "succeeded");

    io:println("== getTask historyLength ==");
    if r is a2a:Task {
        a2a:Task|a2a:Error h0 = c->getTask({id: r.id, historyLength: 0});
        a2a:Task|a2a:Error h1 = c->getTask({id: r.id, historyLength: 1});
        expect("historyLength=0 -> no history", h0 is a2a:Task && (h0.history ?: []).length() == 0, h0 is a2a:Task ? (h0.history ?: []).length().toString() : h0.message());
        expect("historyLength=1 -> at most 1 message", h1 is a2a:Task && (h1.history ?: []).length() <= 1);
    }

    io:println("== I5: ListTasks (pageSize, status, historyLength, statusTimestampAfter) ==");
    a2a:ListTasksResponse|a2a:Error l1 = c->listTasks({pageSize: 2});
    expect("pageSize honoured", l1 is a2a:ListTasksResponse && l1.tasks.length() == 2, l1 is a2a:ListTasksResponse ? l1.tasks.length().toString() : l1.message());
    if l1 is a2a:ListTasksResponse && l1.nextPageToken is string && l1.nextPageToken != "" {
        a2a:ListTasksResponse|a2a:Error l2 = c->listTasks({pageSize: 2, pageToken: l1.nextPageToken});
        expect("second page differs", l2 is a2a:ListTasksResponse && l2.tasks.length() > 0 && l2.tasks[0].id != l1.tasks[0].id);
    }
    a2a:ListTasksResponse|a2a:Error l3 = c->listTasks({status: a2a:TASK_STATE_CANCELED});
    expect("status filter", l3 is a2a:ListTasksResponse && l3.tasks.length() >= 1 && l3.tasks.every(t => t.status.state == a2a:TASK_STATE_CANCELED));
    a2a:ListTasksResponse|a2a:Error l4 = c->listTasks({historyLength: 0});
    expect("historyLength=0 on list", l4 is a2a:ListTasksResponse && l4.tasks.every(t => (t.history ?: []).length() == 0));
    a2a:ListTasksResponse|a2a:Error l5 = c->listTasks({statusTimestampAfter: "2999-01-01T00:00:00Z"});
    expect("statusTimestampAfter in the future -> none", l5 is a2a:ListTasksResponse && l5.tasks.length() == 0, l5 is a2a:ListTasksResponse ? l5.tasks.length().toString() : l5.message());
    a2a:ListTasksResponse|a2a:Error l6 = c->listTasks({statusTimestampAfter: "2000-01-01T00:00:00Z"});
    expect("statusTimestampAfter in the past -> all", l6 is a2a:ListTasksResponse && l6.tasks.length() > 0);

    io:println("== I12: push-notification config CRUD ==");
    if r is a2a:Task {
        a2a:TaskPushNotificationConfig|a2a:Error pc = c->createTaskPushNotificationConfig({url: "http://localhost:19871/hook", taskId: r.id, id: "cfg1", token: "tok"});
        expect("create push config", pc is a2a:TaskPushNotificationConfig, pc is error ? pc.message() : "");
        a2a:ListTaskPushNotificationConfigsResponse|a2a:Error pl = c->listTaskPushNotificationConfigs({taskId: r.id});
        expect("list push configs", pl is a2a:ListTaskPushNotificationConfigsResponse && (pl.configs ?: []).length() == 1, pl is error ? pl.message() : "");
        a2a:Error? pd = c->deleteTaskPushNotificationConfig({taskId: r.id, id: "cfg1"});
        expect("delete push config", pd is (), pd is error ? pd.message() : "");
    }

    io:println(failures == 0 ? "OVERALL: PASS" : string `OVERALL: FAIL (${failures})`);
}
