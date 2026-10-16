import ballerina/a2a;
import ballerina/io;
import ballerina/lang.runtime;

configurable int PORT = 9611;
// I13: how often the listener sends SSE keep-alive comments, and how long the
// "paced" task stays silent -- set PACE_SECONDS well above KEEPALIVE_SECONDS to
// make a real other-SDK SSE parser sit through several comment-only frames.
configurable decimal KEEPALIVE_SECONDS = 15;
configurable decimal PACE_SECONDS = 1.5;
// Non-empty: the card declares this extension as REQUIRED, so a request that does not name it
// in A2A-Extensions is refused with ExtensionSupportRequiredError (spec 3.3.4).
configurable string REQUIRED_EXTENSION = "";

isolated class InteropAgent {
    *a2a:AgentExecutor;
    public isolated function execute(a2a:RequestContext context, a2a:TaskUpdater updater)
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
        return;
    }
}

a2a:AgentCard card = {
    name: "Ballerina A2A Interop Listener",
    description: "Deterministic agent on ballerina/a2a's Listener, for interop testing against other SDKs' clients",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Handles deterministic interop test messages", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: REQUIRED_EXTENSION == "" ? {} : {extensions: [{uri: REQUIRED_EXTENSION, required: true}]},
    supportedInterfaces: []
};

final a2a:DefaultHandler handler = new (new InteropAgent(), pushSender = new a2a:HttpPushNotificationSender({validateUrl: false}));

listener a2a:RestListener l = new (PORT, keepAliveInterval = KEEPALIVE_SECONDS);
// validateUrl: false because the interop push receiver runs on localhost,
// which the default SSRF guard (specification section 13.2) rejects; a real
// deployment leaves that guard on.

public function main() returns error? {
    check l.attach(new AgentOperations(handler, card));
    io:println(string `Ballerina interop listener on http://localhost:${PORT}`);
}

isolated service class AgentOperations {
    *a2a:Service;

    private final a2a:DefaultHandler handler;
    private final a2a:AgentCard & readonly card;

    isolated function init(a2a:DefaultHandler handler, a2a:AgentCard card) {
        self.handler = handler;
        self.card = card.cloneReadOnly();
    }

    isolated resource function get agentCard() returns a2a:AgentCard|a2a:Error {
        return self.card;
    }

    isolated resource function post message\:send(a2a:Context context, a2a:SendMessageRequest request)
            returns a2a:Task|a2a:Message|a2a:Error {
        return self.handler.sendMessage(context, request);
    }

    isolated resource function post message\:stream(a2a:Context context, a2a:SendMessageRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.sendStreamingMessage(context, request);
    }

    isolated resource function get tasks/[string id]/subscribe(a2a:Context context, a2a:SubscribeToTaskRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.subscribeToTask(context, request);
    }

    isolated resource function get tasks/[string id](a2a:Context context, a2a:GetTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.getTask(context, request);
    }

    isolated resource function get tasks(a2a:Context context, a2a:ListTasksRequest request)
            returns a2a:ListTasksResponse|a2a:Error {
        return self.handler.listTasks(context, request);
    }

    isolated resource function post tasks/[string id]/cancel(a2a:Context context, a2a:CancelTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.cancelTask(context, request);
    }

    isolated resource function post tasks/[string id]/pushNotificationConfigs(a2a:Context context, a2a:TaskPushNotificationConfig request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.createTaskPushNotificationConfig(context, request);
    }

    isolated resource function get tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context, a2a:GetTaskPushNotificationConfigRequest request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.getTaskPushNotificationConfig(context, request);
    }

    isolated resource function get tasks/[string id]/pushNotificationConfigs(a2a:Context context, a2a:ListTaskPushNotificationConfigsRequest request)
            returns a2a:ListTaskPushNotificationConfigsResponse|a2a:Error {
        return self.handler.listTaskPushNotificationConfigs(context, request);
    }

    isolated resource function delete tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context, a2a:DeleteTaskPushNotificationConfigRequest request)
            returns a2a:Error? {
        return self.handler.deleteTaskPushNotificationConfig(context, request);
    }
}
