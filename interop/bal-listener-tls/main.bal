// A ballerina/a2a listener served over HTTPS (and, with -CmutualTls=true, mutual TLS).
// The certificates come from `interop/make_certs.sh`. The point: does the listener
// pass `secureSocket` through, and does the card it serves point clients at https://?

import ballerina/a2a;
import ballerina/http;
import ballerina/io;

configurable int PORT = 9614;
configurable string certDir = "/tmp/interop-certs";
configurable boolean mutualTls = false;
// Non-empty: what a TLS-terminating proxy would tell clients to use (ListenerConfiguration.publicUrl).
configurable string PUBLIC_URL = "";

isolated class InteropAgent {
    *a2a:AgentExecutor;
    public isolated function execute(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        check updater.working();
        check updater.addArtifact([{text: "secure hello"}], name = "result");
        check updater.complete();
        return;
    }
}

a2a:AgentCard card = {
    name: "Ballerina A2A Interop Listener (TLS)",
    description: "Served over HTTPS",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Handles deterministic interop test messages", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

http:ListenerSecureSocket tlsConfig = mutualTls
    ? {key: {certFile: certDir + "/server.pem", keyFile: certDir + "/server.p8.key"},
       mutualSsl: {verifyClient: http:REQUIRE, cert: certDir + "/ca.pem"}}
    : {key: {certFile: certDir + "/server.pem", keyFile: certDir + "/server.p8.key"}};

final a2a:DefaultHandler handler = new (new InteropAgent());

listener a2a:RestListener l = new (PORT, secureSocket = tlsConfig, publicUrl = PUBLIC_URL == "" ? () : PUBLIC_URL);

public function main() returns error? {
    check l.attach(new AgentOperations(handler, card));
    io:println(string `Ballerina interop listener (${mutualTls ? "mutual TLS" : "TLS"}) on https://localhost:${PORT}`);
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
        return self.handler.onSendMessage(context, request);
    }

    isolated resource function post message\:stream(a2a:Context context, a2a:SendMessageRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.onSendStreamingMessage(context, request);
    }

    isolated resource function get tasks/[string id]/subscribe(a2a:Context context, a2a:SubscribeToTaskRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.onSubscribeToTask(context, request);
    }

    isolated resource function get tasks/[string id](a2a:Context context, a2a:GetTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.onGetTask(context, request);
    }

    isolated resource function get tasks(a2a:Context context, a2a:ListTasksRequest request)
            returns a2a:ListTasksResponse|a2a:Error {
        return self.handler.onListTasks(context, request);
    }

    isolated resource function post tasks/[string id]/cancel(a2a:Context context, a2a:CancelTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.onCancelTask(context, request);
    }

    isolated resource function post tasks/[string id]/pushNotificationConfigs(a2a:Context context, a2a:TaskPushNotificationConfig request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.onCreateTaskPushNotificationConfig(context, request);
    }

    isolated resource function get tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context, a2a:GetTaskPushNotificationConfigRequest request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.onGetTaskPushNotificationConfig(context, request);
    }

    isolated resource function get tasks/[string id]/pushNotificationConfigs(a2a:Context context, a2a:ListTaskPushNotificationConfigsRequest request)
            returns a2a:ListTaskPushNotificationConfigsResponse|a2a:Error {
        return self.handler.onListTaskPushNotificationConfigs(context, request);
    }

    isolated resource function delete tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context, a2a:DeleteTaskPushNotificationConfigRequest request)
            returns a2a:Error? {
        return self.handler.onDeleteTaskPushNotificationConfig(context, request);
    }
}
