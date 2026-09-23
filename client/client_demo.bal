// The client half of the demo: walks a real a2a:HttpClient through every
// operation this library's Listener implements, against the DemoAgent in
// agent.bal, printing what happens at each step.

import ballerina/a2a;
import ballerina/io;
import ballerina/lang.runtime;

isolated function runLifecycleDemo(string agentUrl, string webhookUrl) returns error? {
    section("1. Agent discovery");
    a2a:AgentCard card = check a2a:resolveAgentCard(agentUrl);
    io:println(string `Discovered "${card.name}": ${card.description}`);
    io:println(string `Capabilities -> streaming: ${card.capabilities.streaming}, `
            + string `pushNotifications: ${card.capabilities.pushNotifications}, `
            + string `extendedAgentCard: ${card.capabilities.extendedAgentCard}`);

    a2a:HttpClient agent = check new (card);

    section("2. sendMessage (blocking, ordinary path)");
    a2a:Task|a2a:Message reply1 = check agent->sendMessage({
        message: {messageId: "m1", role: a2a:ROLE_USER, parts: [{text: "hello there"}]}
    });
    printReply(reply1);

    section("3. sendMessage (direct Message reply, no task at all)");
    a2a:Task|a2a:Message reply2 = check agent->sendMessage({
        message: {messageId: "m2", role: a2a:ROLE_USER, parts: [{text: "ping"}]}
    });
    printReply(reply2);

    section("4. sendStreamingMessage (live events, not replayed)");
    stream<a2a:StreamResponse, a2a:Error?> events = check agent->sendStreamingMessage({
        message: {messageId: "m3", role: a2a:ROLE_USER, parts: [{text: "slow"}]}
    });
    error? streamErr = events.forEach(isolated function(a2a:StreamResponse event) {
        io:println("  live event: ", describeStreamEvent(event));
    });
    if streamErr is error {
        io:println("  stream ended with: ", streamErr.message());
    }
    check events.close();

    section("5. subscribeToTask + cancelTask on a task still in flight");
    a2a:Task started = <a2a:Task>check agent->sendMessage({
        message: {messageId: "m4", role: a2a:ROLE_USER, parts: [{text: "slow"}]},
        configuration: {returnImmediately: true}
    });
    io:println(string `Task ${started.id} created at ${started.status.state}; subscribing live...`);
    stream<a2a:StreamResponse, a2a:Error?> follow = check agent->subscribeToTask({id: started.id});
    record {| a2a:StreamResponse value; |}|a2a:Error? first = follow.next();
    if first is record {| a2a:StreamResponse value; |} {
        io:println("  subscriber saw: ", describeStreamEvent(first.value));
    }
    runtime:sleep(0.5);
    a2a:Task canceled = check agent->cancelTask({id: started.id});
    io:println(string `Canceled -> ${canceled.status.state}`);
    record {| a2a:StreamResponse value; |}|a2a:Error? afterCancel = follow.next();
    if afterCancel is record {| a2a:StreamResponse value; |} {
        io:println("  subscriber stream after cancel: ", describeStreamEvent(afterCancel.value));
    } else {
        io:println("  subscriber stream after cancel: closed, as expected");
    }
    check follow.close();

    section("6. Push notifications: register a webhook, then trigger delivery");
    a2a:Task pushTarget = <a2a:Task>check agent->sendMessage({
        message: {messageId: "m5", role: a2a:ROLE_USER, parts: [{text: "webhook demo"}]},
        configuration: {taskPushNotificationConfig: {url: webhookUrl}}
    });
    io:println(string `Task ${pushTarget.id} completed; webhook should already have fired`);
    map<json>? delivered = waitForWebhookPayload(3);
    io:println("  webhook payload received: ", delivered is map<json> ? "yes" : "no (timed out)");

    section("7. Multi-turn continuation (pause, then answer)");
    a2a:Task paused = <a2a:Task>check agent->sendMessage({
        message: {messageId: "m6", role: a2a:ROLE_USER, parts: [{text: "ask"}]}
    });
    a2a:Message? prompt = paused.status?.message;
    string promptText = prompt is a2a:Message ? (prompt.parts[0]?.text ?: "") : "";
    io:println(string `Task ${paused.id} paused at ${paused.status.state}: "${promptText}"`);
    a2a:Task resumed = <a2a:Task>check agent->sendMessage({
        message: {
            messageId: "m7",
            role: a2a:ROLE_USER,
            taskId: paused.id,
            contextId: paused.contextId,
            parts: [{text: "Colombo"}]
        }
    });
    io:println(string `Continued task ${resumed.id} (same id: ${resumed.id == paused.id}) -> ${resumed.status.state}`);

    section("8. getTask / listTasks");
    a2a:Task fetched = check agent->getTask({id: resumed.id});
    io:println(string `getTask ${fetched.id} -> ${fetched.status.state}`);
    a2a:ListTasksResponse page = check agent->listTasks({pageSize: 10});
    io:println(string `listTasks -> ${page.tasks.length()} task(s) on this page`);

    section("9. getExtendedAgentCard (none configured on this listener)");
    a2a:AgentCard|a2a:Error extended = agent->getExtendedAgentCard();
    io:println("  result: ", extended is a2a:UnsupportedOperationError
            ? "UnsupportedOperationError, as expected -- capabilities.extendedAgentCard is false"
            : "unexpected result");

    io:println("\nLifecycle demo complete.");
}

isolated function section(string title) {
    io:println();
    io:println("== ", title, " ==");
}

isolated function printReply(a2a:Task|a2a:Message reply) {
    // Task and Message are both open records, so the compiler cannot
    // narrow `reply` by elimination -- neither an early return nor an
    // else branch does it. An explicit cast is required for the
    // remaining arm, same as this library's own code does for the
    // identical reason.
    if reply is a2a:Message {
        io:println("Direct Message reply: ", reply.parts[0]?.text ?: "");
    } else {
        a2a:Task task = <a2a:Task>reply;
        a2a:Artifact[] artifacts = task.artifacts ?: [];
        io:println(string `Task ${task.id}: ${task.status.state}`);
        if artifacts.length() > 0 {
            io:println("  artifact: ", artifacts[0].parts[0]?.text ?: "");
        }
    }
}

isolated function describeStreamEvent(a2a:StreamResponse event) returns string {
    if event is a2a:Task {
        return string `Task ${event.id} snapshot (${event.status.state})`;
    }
    if event is a2a:Message {
        return string `Message: ${event.parts[0]?.text ?: ""}`;
    }
    if event is a2a:TaskStatusUpdateEvent {
        return string `status -> ${event.status.state}`;
    }
    // event is now known (by elimination) to be a TaskArtifactUpdateEvent,
    // but StreamResponse's arms are all open records, so the compiler
    // can't prove that from a sequence of early-return `is` checks --
    // an explicit cast is required here, same as elsewhere in this
    // library's own code for the identical reason.
    a2a:TaskArtifactUpdateEvent artifactEvent = <a2a:TaskArtifactUpdateEvent>event;
    return string `artifact -> ${artifactEvent.artifact.parts[0]?.text ?: ""}`;
}
