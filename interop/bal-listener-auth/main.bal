// A ballerina/a2a listener with authentication turned on, for the
// cross-SDK auth pairs (X-A1/X-A2 in INTEROP_AND_AUTH_TEST_PLAN.md): does a
// real other-language client's own auth machinery authenticate against it,
// using nothing but the derived card (ListenerConfiguration.auth with no
// securitySchemes declared -- see module-ballerina-a2a commit caf9afc).

import ballerina/a2a;
import ballerina/io;

configurable int PORT = 9612;
// Same shared secret both sides mint/validate with -- this test only
// proves the protocol plumbing (discovery -> scheme name -> credential ->
// header -> validation), not a real identity provider.
configurable string sharedSecret = "interop-auth-shared-secret-0123456789";

isolated class InteropAgent {
    *a2a:AgentExecutor;
    public isolated function execute(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        string text = "";
        foreach a2a:Part part in context.message.parts {
            string? t = part?.text;
            if t is string {
                text += t;
            }
        }
        check updater.working();
        check updater.addArtifact([{text: string `echo: ${text}`}], name = "result");
        check updater.complete();
        return;
    }
}

a2a:AgentCard card = {
    name: "Ballerina A2A Interop Listener (authenticated)",
    description: "Requires a bearer credential; its securitySchemes/securityRequirements are derived from auth",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Handles deterministic interop test messages", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

final a2a:DefaultHandler handler = new (new InteropAgent());

listener a2a:RestListener l = new (PORT, auth = [{jwtValidatorConfig: {issuer: "interop", audience: "a2a", signatureConfig: {secret: sharedSecret}}}]);

public function main() returns error? {
    check l.attach(new AgentOperations(handler, card));
    io:println(string `Ballerina interop listener (authenticated) on http://localhost:${PORT}`);
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
        return self.handler.handleSendMessage(context, request);
    }

    isolated resource function post message\:stream(a2a:Context context, a2a:SendMessageRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.handleSendStreamingMessage(context, request);
    }

    isolated resource function get tasks/[string id]/subscribe(a2a:Context context, a2a:SubscribeToTaskRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.handleSubscribeToTask(context, request);
    }

    isolated resource function get tasks/[string id](a2a:Context context, a2a:GetTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.handleGetTask(context, request);
    }

    isolated resource function get tasks(a2a:Context context, a2a:ListTasksRequest request)
            returns a2a:ListTasksResponse|a2a:Error {
        return self.handler.handleListTasks(context, request);
    }

    isolated resource function post tasks/[string id]/cancel(a2a:Context context, a2a:CancelTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.handleCancelTask(context, request);
    }

    isolated resource function post tasks/[string id]/pushNotificationConfigs(a2a:Context context, a2a:TaskPushNotificationConfig request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.handleCreateTaskPushNotificationConfig(context, request);
    }

    isolated resource function get tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context, a2a:GetTaskPushNotificationConfigRequest request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.handleGetTaskPushNotificationConfig(context, request);
    }

    isolated resource function get tasks/[string id]/pushNotificationConfigs(a2a:Context context, a2a:ListTaskPushNotificationConfigsRequest request)
            returns a2a:ListTaskPushNotificationConfigsResponse|a2a:Error {
        return self.handler.handleListTaskPushNotificationConfigs(context, request);
    }

    isolated resource function delete tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context, a2a:DeleteTaskPushNotificationConfigRequest request)
            returns a2a:Error? {
        return self.handler.handleDeleteTaskPushNotificationConfig(context, request);
    }
}
