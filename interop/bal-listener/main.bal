import ballerina/a2a;
import ballerina/io;
import ballerina/lang.runtime;

configurable int PORT = 9611;
// I13: how often the listener sends SSE keep-alive comments, and how long the
// "paced" task stays silent -- set PACE_SECONDS well above KEEPALIVE_SECONDS to
// make a real other-SDK SSE parser sit through several comment-only frames.
configurable decimal KEEPALIVE_SECONDS = 15;
configurable decimal PACE_SECONDS = 1.5;

isolated service class InteropAgent {
    *a2a:Service;
    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        string id = context.message.messageId;
        string text = "";
        foreach a2a:Part part in context.message.parts {
            string? t = part?.text;
            if t is string {
                text += t;
            }
        }

        // I10: pause for more input; a follow-up on the same taskId is
        // handled by the else-branch below (any prefix), matching
        // tck-sut/python-agent's contract.
        if id.startsWith("interop-task-input-required") {
            check updater->working();
            check updater->requireInput({
                messageId: "ask-1", role: a2a:ROLE_AGENT, parts: [{text: "which city?"}]
            });
            return;
        }

        // I4/I9/I13: a short, real delay before completing -- long enough to
        // poll or subscribe mid-flight.
        if id.startsWith("interop-task-paced") {
            check updater->working();
            runtime:sleep(PACE_SECONDS);
            check updater->addArtifact([{text: string `echo: ${text}`}], name = "result");
            check updater->complete();
            return;
        }

        if id.startsWith("interop-task-fail") {
            check updater->working();
            check updater->failed({
                messageId: "fail-1", role: a2a:ROLE_AGENT, parts: [{text: "deliberate interop failure"}]
            });
            return;
        }

        // Default: I3, and also the continuation reply for I10 (any
        // messageId, once context.message.taskId names an existing task).
        check updater->working();
        check updater->addArtifact([{text: string `echo: ${text}`}], name = "result");
        check updater->complete();
    }
}

a2a:AgentCard card = {
    name: "Ballerina A2A Interop Listener",
    description: "Deterministic agent on ballerina/a2a's Listener, for interop testing against other SDKs' clients",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Handles deterministic interop test messages", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

listener a2a:Listener l = new (PORT, agentCard = card, keepAliveInterval = KEEPALIVE_SECONDS,
    pushSender = new a2a:HttpPushNotificationSender({validateUrl: false}));
// validateUrl: false because the interop push receiver runs on localhost,
// which the default SSRF guard (specification section 13.2) rejects; a real
// deployment leaves that guard on.

public function main() returns error? {
    check l.attach(new InteropAgent());
    io:println(string `Ballerina interop listener on http://localhost:${PORT}`);
}
