// The server half of the demo: an a2a:Listener serving a small agent that
// exercises every task state this library supports, so the client half can
// walk through the full A2A lifecycle against it.
//
// Trigger texts (matched on the inbound message's own text):
// - "ping"        -> a direct Message reply, no task at all.
// - "ask"         -> pauses at TASK_STATE_INPUT_REQUIRED, for the
//                    continuation (multi-turn) part of the demo.
// - "slow"        -> takes a few seconds to complete, so the client demo
//                    has time to open a live subscribeToTask stream and
//                    cancel it mid-flight.
// - anything else -> working -> one artifact -> complete, the ordinary path.

import ballerina/a2a;
import ballerina/io;
import ballerina/lang.runtime;
import ballerina/uuid;

configurable int agentPort = 9095;

listener a2a:Listener demoAgentListener = new (agentPort, agentCard = {
    name: "Demo Lifecycle Agent",
    description: "Echoes text back as a completed task; demonstrates every A2A task state",
    version: "1.0.0",
    skills: [
        {
            id: "echo",
            name: "Echo",
            description: "Echoes the caller's text back as a task artifact",
            tags: ["demo", "echo"]
        }
    ],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    // Placeholders -- the listener derives supportedInterfaces and the
    // streaming/pushNotifications/extendedAgentCard capability flags
    // itself. See ListenerConfiguration.streamingCapability/
    // pushNotificationsCapability to withhold either deliberately.
    capabilities: {},
    supportedInterfaces: []
}, pushSender = new a2a:HttpPushNotificationSender({validateUrl: false}));
// validateUrl: false is because this demo's client-side webhook receiver
// runs at http://localhost -- a loopback address the default SSRF guard
// (specification section 13.2) otherwise rejects before ever connecting.
// A real deployment leaves the default on and points webhooks at real,
// public hosts.

public function main() returns error? {
    check demoAgentListener.attach(new DemoAgent());
    check demoAgentListener.'start();
    io:println(string `Demo Lifecycle Agent listening on http://localhost:${agentPort}`);
    io:println("Run the client package (in a separate terminal) to drive it through the full A2A lifecycle.");
    io:println("Press Ctrl+C to stop.");
}

isolated service class DemoAgent {
    *a2a:Service;

    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        string text = extractText(context.message);

        if text == "ping" {
            return {messageId: uuid:createType4AsString(), role: a2a:ROLE_AGENT, parts: [{text: "pong"}]};
        }

        if text == "ask" {
            check updater->working();
            check updater->requireInput({
                messageId: uuid:createType4AsString(),
                role: a2a:ROLE_AGENT,
                parts: [{text: "What city should I search near?"}]
            });
            return;
        }

        if text == "slow" {
            check updater->working();
            // A few visible steps, each with a real pause, so a client
            // watching live has something to actually observe.
            check updater->addArtifact([{text: "step 1/3: starting"}]);
            runtime:sleep(1.5);
            check updater->addArtifact([{text: "step 2/3: working"}]);
            runtime:sleep(1.5);
            check updater->addArtifact([{text: "step 3/3: finishing"}]);
            runtime:sleep(1.5);
            check updater->complete();
            return;
        }

        // The ordinary path: a continuation (message.taskId set) lands
        // here too once the caller has already answered "ask"'s prompt.
        check updater->working();
        check updater->addArtifact([{text: string `echo: ${text}`}]);
        check updater->complete();
        return;
    }
}

isolated function extractText(a2a:Message message) returns string {
    string text = "";
    foreach a2a:Part part in message.parts {
        string? t = part?.text;
        if t is string {
            text += t;
        }
    }
    return text;
}
