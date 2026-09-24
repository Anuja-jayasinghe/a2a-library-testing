// Exercises ballerina/a2a's CLIENT against genuinely long-running tasks (the
// slow-agent package: over a minute per task) and prints a timestamped
// account of what the library did. One scenario per run:
//
//   stream          sendStreamingMessage on a task that reports progress
//   stream-silent   sendStreamingMessage on a task silent for ~70s
//   push            push notifications: webhook registered on a paused task,
//                   and another registered inline on the send request
//   subscribe       subscribeToTask on a task already running, twice
//   cancel          a second message to a busy task, then cancelTask mid-run
//
// bal run -- -Cscenario=push

import ballerina/a2a;
import ballerina/ai;
import ballerina/lang.'function as fn;
import ballerina/http;
import ballerina/io;
import ballerina/lang.runtime;
import ballerina/time;
import ballerina/uuid;

configurable string scenario = "stream";
configurable string agentUrl = "http://localhost:9098";
configurable int webhookPort = 9198;
// The HTTP client's own timeout in seconds (Ballerina's default is 30).
configurable decimal clientTimeout = 30;
configurable string taskId = "";

final time:Utc startedAt = time:utcNow();

isolated function elapsed() returns string {
    decimal secs = time:utcDiffSeconds(time:utcNow(), startedAt);
    return string `+${secs.round(1)}s`;
}

isolated function say(string line) {
    io:println(elapsed(), "  ", line);
}

// ---- webhook receiver ---------------------------------------------------

type Delivery record {|string at; string keys; string state; string taskId; string token;|};

isolated Delivery[] deliveries = [];

listener http:Listener webhookListener = new (webhookPort);

service /hook on webhookListener {
    isolated resource function post [string tag](http:Request req) returns http:Ok|error {
        json payload = check req.getJsonPayload();
        map<json> body = check payload.ensureType();
        string state = "?";
        string taskId = "?";
        json|error task = body["task"];
        json root = task is json && task !is () ? task : payload;
        if root is map<json> {
            json id = root["id"];
            taskId = id is string ? id : "?";
            json st = root["status"];
            if st is map<json> {
                json s = st["state"];
                state = s is string ? s : "?";
            }
        }
        string token = req.getHeader("X-A2A-Notification-Token") is string
            ? check req.getHeader("X-A2A-Notification-Token") : "(none)";
        string keys = string:'join(",", ...body.keys());
        string at = elapsed();
        string tagged = token + " tag=" + tag;
        lock {
            deliveries.push({at, keys, state, taskId, token: tagged});
        }
        say(string `WEBHOOK delivered: tag=${tag} top-level keys=[${keys}] task=${taskId} state=${state} token=${token}`);
        return http:OK;
    }
}

// ---- helpers ------------------------------------------------------------

isolated function userMessage(string text, string? taskId = ()) returns a2a:Message {
    a2a:Message m = {messageId: uuid:createType4AsString(), role: a2a:ROLE_USER, parts: [{text}]};
    if taskId is string {
        m.taskId = taskId;
    }
    return m;
}

isolated function errKind(a2a:Error e) returns string {
    if e is a2a:TaskNotFoundError {
        return "TaskNotFoundError";
    }
    if e is a2a:TaskNotCancelableError {
        return "TaskNotCancelableError";
    }
    if e is a2a:UnsupportedOperationError {
        return "UnsupportedOperationError";
    }
    if e is a2a:InvalidAgentResponseError {
        return "InvalidAgentResponseError";
    }
    if e is a2a:InternalError {
        return "InternalError";
    }
    return "Error";
}

isolated function describeEvent(a2a:StreamResponse ev) returns string {
    if ev is a2a:Task {
        return string `Task ${ev.id} state=${ev.status.state}`;
    }
    if ev is a2a:Message {
        return "Message";
    }
    if ev is a2a:TaskStatusUpdateEvent {
        a2a:Message? m = ev.status?.message;
        string note = m is a2a:Message ? (m.parts[0]?.text ?: "") : "";
        return string `statusUpdate state=${ev.status.state} "${note}"`;
    }
    return "artifactUpdate";
}

# Drains a stream, printing each event as it arrives. Returns the number of events.
isolated function drain(string label, stream<a2a:StreamResponse, a2a:Error?> events) returns int {
    int n = 0;
    while true {
        record {|a2a:StreamResponse value;|}|a2a:Error? next = events.next();
        if next is () {
            say(string `${label}: stream closed cleanly after ${n} events`);
            break;
        }
        if next is a2a:Error {
            say(string `${label}: stream ended WITH ERROR after ${n} events: ${errKind(next)}: ${next.message()}`);
            break;
        }
        n += 1;
        say(string `${label}: event ${n}: ${describeEvent(next.value)}`);
    }
    a2a:Error? closeResult = events.close();
    if closeResult is a2a:Error {
        say(string `${label}: close() reported ${closeResult.message()}`);
    }
    return n;
}

isolated function isTerminal(a2a:TaskState s) returns boolean =>
    s == a2a:TASK_STATE_COMPLETED || s == a2a:TASK_STATE_FAILED
    || s == a2a:TASK_STATE_CANCELED || s == a2a:TASK_STATE_REJECTED;

isolated function stateOf(a2a:HttpClient c, string id) returns string {
    a2a:Task|a2a:Error t = c->getTask({id});
    return t is a2a:Task ? t.status.state.toString() : "getTask failed: " + t.message();
}

// ---- scenarios ----------------------------------------------------------

isolated function runStream(a2a:HttpClient c, string text) returns error? {
    say(string `sendStreamingMessage("${text}")`);
    stream<a2a:StreamResponse, a2a:Error?>|a2a:Error s = c->sendStreamingMessage({message: userMessage(text)});
    if s is a2a:Error {
        say("could not open the stream: " + errKind(s) + ": " + s.message());
        return;
    }
    _ = drain("stream", s);
}

isolated function runPush(a2a:HttpClient c) returns error? {
    string hook = string `http://localhost:${webhookPort}/hook`;

    say("A: send \"input please\" -> expect a task paused at INPUT_REQUIRED");
    a2a:Task|a2a:Message r = check c->sendMessage({message: userMessage("input please")});
    a2a:Task paused = <a2a:Task>r;
    say(string `A: task ${paused.id} state=${paused.status.state}`);

    a2a:TaskPushNotificationConfig cfg = check c->createTaskPushNotificationConfig(
            {taskId: paused.id, url: hook + "/registered", token: "tok-registered"});
    say(string `A: webhook registered on the paused task, config id=${cfg?.id ?: "?"}`);

    say("A: continue with \"go\" (returnImmediately) -> the 70s job starts");
    a2a:Task|a2a:Message go = check c->sendMessage({
        message: userMessage("go", paused.id),
        configuration: {returnImmediately: true}
    });
    a2a:Task goTask = <a2a:Task>go;
    say(string `A: returned at once with state=${goTask.status.state}`);

    say("B: fresh long task with the webhook registered INLINE on the send request");
    a2a:Task|a2a:Message inl = check c->sendMessage({
        message: userMessage("steady work"),
        configuration: {
            returnImmediately: true,
            taskPushNotificationConfig: {url: hook + "/inline", token: "tok-inline"}
        }
    });
    a2a:Task inlTask = <a2a:Task>inl;
    say(string `B: task ${inlTask.id} state=${inlTask.status.state}`);

    decimal waited = 0;
    while waited < 110d {
        runtime:sleep(10);
        waited += 10d;
        string sa = stateOf(c, paused.id);
        string sb = stateOf(c, inlTask.id);
        say(string `poll: A=${sa}  B=${sb}`);
        if sa == "TASK_STATE_COMPLETED" && sb == "TASK_STATE_COMPLETED" {
            break;
        }
    }
    say("waiting 5s for any late webhook deliveries");
    runtime:sleep(5);
    lock {
        say(string `summary: ${deliveries.length()} webhook deliveries in total`);
        foreach Delivery d in deliveries {
            say(string `  at ${d.at}: keys=[${d.keys}] state=${d.state} task=${d.taskId} ${d.token}`);
        }
    }
}

isolated function runSubscribe(a2a:HttpClient c) returns error? {
    a2a:Task|a2a:Message r = check c->sendMessage({
        message: userMessage("steady work"),
        configuration: {returnImmediately: true}
    });
    a2a:Task t = <a2a:Task>r;
    say(string `started task ${t.id} state=${t.status.state}`);
    runtime:sleep(20);
    say("20s in: two subscribers attach to the running task");
    future<int> f1 = start subscribeAndDrain(c, t.id, "viewer1");
    runtime:sleep(10);
    future<int> f2 = start subscribeAndDrain(c, t.id, "viewer2");
    int n1 = check wait f1;
    int n2 = check wait f2;
    say(string `viewer1 saw ${n1} events, viewer2 saw ${n2} events`);
    say("subscribing again now that the task is finished -> expect UnsupportedOperationError");
    stream<a2a:StreamResponse, a2a:Error?>|a2a:Error late = c->subscribeToTask({id: t.id});
    if late is a2a:Error {
        say("late subscribe refused: " + errKind(late) + ": " + late.message());
    } else {
        say("late subscribe was ACCEPTED (unexpected)");
        _ = drain("late", late);
    }
}

isolated function subscribeAndDrain(a2a:HttpClient c, string id, string label) returns int {
    stream<a2a:StreamResponse, a2a:Error?>|a2a:Error s = c->subscribeToTask({id});
    if s is a2a:Error {
        say(string `${label}: subscribe failed: ${errKind(s)}: ${s.message()}`);
        return 0;
    }
    return drain(label, s);
}

isolated function runCancel(a2a:HttpClient c) returns error? {
    string hook = string `http://localhost:${webhookPort}/hook`;
    a2a:Task|a2a:Message r = check c->sendMessage({
        message: userMessage("steady work"),
        configuration: {
            returnImmediately: true,
            taskPushNotificationConfig: {url: hook + "/cancel-test", token: "tok-cancel"}
        }
    });
    a2a:Task t = <a2a:Task>r;
    say(string `started task ${t.id} state=${t.status.state} (webhook registered inline)`);

    runtime:sleep(5);
    say("5s in: send a second message to the SAME running task");
    a2a:Task|a2a:Message|a2a:Error second = c->sendMessage({message: userMessage("more", t.id)});
    if second is a2a:Error {
        say("second message refused: " + errKind(second) + ": " + second.message());
    } else {
        say("second message was ACCEPTED (unexpected while the task is running)");
    }

    runtime:sleep(15);
    say(string `20s in: state=${stateOf(c, t.id)}; cancelling now`);
    a2a:Task|a2a:Error canceled = c->cancelTask({id: t.id});
    if canceled is a2a:Task {
        say(string `cancelTask returned state=${canceled.status.state}`);
    } else {
        say("cancelTask failed: " + errKind(canceled) + ": " + canceled.message());
    }
    a2a:Task|a2a:Error again = c->cancelTask({id: t.id});
    say(again is a2a:Error ? "cancelling again refused: " + errKind(again) + ": " + again.message()
            : "cancelling again ACCEPTED, state=" + again.status.state.toString());

    say("waiting past the moment the 70s job would have finished, watching the stored state");
    foreach int i in 1 ... 6 {
        runtime:sleep(10);
        say(string `state=${stateOf(c, t.id)}`);
    }
    lock {
        say(string `summary: ${deliveries.length()} webhook deliveries`);
        foreach Delivery d in deliveries {
            say(string `  at ${d.at}: keys=[${d.keys}] state=${d.state} ${d.token}`);
        }
    }
}


// Calls ai:A2aToolKit's delegateToAgent tool function directly, the way the
// model's tool call would, and prints exactly the text the model receives.
isolated function runToolkitContinue() returns error? {
    ai:A2aToolKit kit = check new (agents = [{agent: agentUrl}]);
    ai:ToolConfig[] tools = kit.getTools();
    foreach ai:ToolConfig t in tools {
        if t.name == "delegateToAgent" {
            say(string `calling delegateToAgent(agentName, "Paris", taskId=${taskId}) on a task paused at INPUT_REQUIRED`);
            any|error result = fn:call(t.caller, "Trip Planner Agent", "Paris", taskId);
            say("the model would receive: " + (result is error ? "ERROR " + result.message() : result.toString()));
            runtime:sleep(4);
            a2a:HttpClient c = check new (agentUrl);
            say("4s later the task's real state is: " + stateOf(c, taskId));
        }
    }
}

public function main() returns error? {
    check webhookListener.'start();
    a2a:HttpClient c = check new (agentUrl, clientConfig = {timeout: clientTimeout});
    say(string `scenario=${scenario} agent=${agentUrl}`);
    match scenario {
        "stream" => {
            check runStream(c, "steady work");
        }
        "stream-silent" => {
            check runStream(c, "silent work");
        }
        "push" => {
            check runPush(c);
        }
        "subscribe" => {
            check runSubscribe(c);
        }
        "cancel" => {
            check runCancel(c);
        }
        "toolkit-continue" => {
            check runToolkitContinue();
        }
        _ => {
            say("unknown scenario");
        }
    }
    say("done");
    exitProcess(0);
}
