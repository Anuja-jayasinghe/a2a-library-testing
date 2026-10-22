// A ballerina/a2a listener that validates bearer tokens the way production does:
// against an issuer's *published keys* (JWKS), not a shared secret. The tokens come
// from oidc-provider/provider.py, which signs with RS256 and can rotate its key.
//
// `a2a:invoke` is required, so a token that only carries `a2a:read` is a 403.

import ballerina/a2a;
import ballerina/io;

configurable int PORT = 9613;
configurable string providerUrl = "http://localhost:9800";

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
    name: "Ballerina A2A Interop Listener (OIDC/JWKS)",
    description: "Validates RS256 bearer tokens against the issuer's JWKS; requires the a2a:invoke scope",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Handles deterministic interop test messages", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

final a2a:DefaultHandler handler = new (new InteropAgent());

listener a2a:RestListener l = new (PORT, auth = [{
    jwtValidatorConfig: {
        issuer: providerUrl,
        audience: "a2a",
        signatureConfig: {jwksConfig: {url: providerUrl + "/jwks.json"}}
    },
    scopes: "a2a:invoke"
}]);

public function main() returns error? {
    check l.attach(new AgentOperations(handler, card));
    io:println(string `Ballerina interop listener (JWKS auth) on http://localhost:${PORT}`);
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
