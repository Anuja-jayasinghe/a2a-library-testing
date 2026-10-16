// A deterministic (no LLM) A2A agent for the A2A Technology Compatibility
// Kit (TCK), built on ballerina/a2a's RestListener.
//
// The TCK drives a System Under Test through a fixed contract: what the
// agent does depends only on a prefix of the incoming message's messageId
// (the "in-band signal"). The contract lives in the TCK repo's
// scenarios/core_operations.feature and scenarios/streaming.feature, and
// its docs/SUT_REQUIREMENTS.md. The a2a-python reference agent
// (sut/a2a-python/sut_agent.py) implements the same contract.
//
// Not implemented, on purpose: "tck-stream-artifact-chunked". It needs an
// artifact delivered in append/lastChunk pieces, and a2a:TaskUpdater's
// addArtifact has no way to set either flag, so that scenario cannot be
// expressed with this library today. It falls through to the default reply.

import ballerina/a2a;
import ballerina/io;
import ballerina/lang.runtime;
import ballerina/uuid;

configurable int agentPort = 9999;
// Mirrors the TCK's TCK_STREAMING_TIMEOUT (default 2s). The long-running
// resubscribe scenario must stay active for at least twice this.
configurable decimal streamingTimeout = 2;

// The TCK skips requirements that depend on how the agent is configured (a
// capability it does not have, an extended card, a required extension), so
// one build is run in several configurations to cover them:
//   default:                          all of these left alone
//   capabilities withheld:            -Cstreaming=false, -CpushNotifications=false
//   extended card + required ext.:    -CextendedCard=true -CrequiredExtension=true
configurable boolean streaming = true;
configurable boolean pushNotifications = true;
configurable boolean extendedCard = false;
configurable boolean requiredExtension = false;

const string REQUIRED_EXTENSION_URI = "urn:a2a:tck:required-extension";

final a2a:AgentSkill & readonly tckSkill = {
    id: "tck",
    name: "TCK Conformance",
    description: "Handles TCK conformance test messages",
    tags: ["tck"]
};

isolated function buildCard(a2a:AgentSkill[] skills) returns a2a:AgentCard => {
    name: "Ballerina A2A System Under Test (SUT)",
    description: "Deterministic, non-LLM agent for A2A TCK conformance, built on ballerina/a2a",
    version: "1.0.0",
    skills,
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    // The listener derives the streaming / pushNotifications /
    // extendedAgentCard flags and supportedInterfaces itself; extensions it
    // passes through exactly as declared here.
    capabilities: requiredExtension
        ? {extensions: [{uri: REQUIRED_EXTENSION_URI, required: true}]}
        : {},
    supportedInterfaces: []
};

// validateUrl: false so push notifications can reach the TCK's own webhook
// receiver on localhost, which the default SSRF guard would refuse.
final a2a:DefaultHandler tckHandler = new (new TckAgentExecutor(),
    extendedAgentCard = extendedCard
        ? buildCard([tckSkill, {id: "tck-extended", name: "TCK Extended", description: "Only in the extended card", tags: ["tck"]}])
        : (),
    pushSender = new a2a:HttpPushNotificationSender({validateUrl: false})
);

// The extended agent card MUST require authentication (specification section
// 13.3), and a2a:RestListener refuses to serve it without `auth`. The TCK sends
// no credentials, so in the extended configuration it is run against the
// extended-card tests only (see run_tck.sh). A file user store with no users
// is enough: every caller is challenged.
listener a2a:RestListener tckListener = new (agentPort,
    auth = extendedCard ? [{fileUserStoreConfig: {}}] : ()
);

public function main() returns error? {
    if extendedCard {
        check tckListener.attach(new TckExtendedService(tckHandler));
    } else if streaming && pushNotifications {
        check tckListener.attach(new TckFullService(tckHandler));
    } else {
        check tckListener.attach(new TckBaseService(tckHandler));
    }
    check tckListener.'start();
    io:println(string `Ballerina A2A TCK SUT listening on http://localhost:${agentPort}`);
    io:println("Press Ctrl+C to stop.");
}

// The listener derives the advertised capabilities from the resources a
// service defines, so each configuration is its own service class.
isolated service class TckBaseService {
    *a2a:Service;
    private final a2a:DefaultHandler handler;

    isolated function init(a2a:DefaultHandler handler) {
        self.handler = handler;
    }

    isolated resource function get agentCard() returns a2a:AgentCard|a2a:Error => buildCard([tckSkill]);

    isolated resource function post message\:send(a2a:Context context, a2a:SendMessageRequest request)
            returns a2a:Task|a2a:Message|a2a:Error => self.handler.sendMessage(context, request);

    isolated resource function get tasks/[string id](a2a:Context context, a2a:GetTaskRequest request)
            returns a2a:Task|a2a:Error => self.handler.getTask(context, request);

    isolated resource function get tasks(a2a:Context context, a2a:ListTasksRequest request)
            returns a2a:ListTasksResponse|a2a:Error => self.handler.listTasks(context, request);

    isolated resource function post tasks/[string id]/cancel(a2a:Context context, a2a:CancelTaskRequest request)
            returns a2a:Task|a2a:Error => self.handler.cancelTask(context, request);
}

isolated service class TckFullService {
    *a2a:Service;
    private final a2a:DefaultHandler handler;

    isolated function init(a2a:DefaultHandler handler) {
        self.handler = handler;
    }

    isolated resource function get agentCard() returns a2a:AgentCard|a2a:Error => buildCard([tckSkill]);

    isolated resource function post message\:send(a2a:Context context, a2a:SendMessageRequest request)
            returns a2a:Task|a2a:Message|a2a:Error => self.handler.sendMessage(context, request);

    isolated resource function post message\:stream(a2a:Context context, a2a:SendMessageRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error => self.handler.sendStreamingMessage(context, request);

    isolated resource function get tasks/[string id]/subscribe(a2a:Context context, a2a:SubscribeToTaskRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error => self.handler.subscribeToTask(context, request);

    isolated resource function get tasks/[string id](a2a:Context context, a2a:GetTaskRequest request)
            returns a2a:Task|a2a:Error => self.handler.getTask(context, request);

    isolated resource function get tasks(a2a:Context context, a2a:ListTasksRequest request)
            returns a2a:ListTasksResponse|a2a:Error => self.handler.listTasks(context, request);

    isolated resource function post tasks/[string id]/cancel(a2a:Context context, a2a:CancelTaskRequest request)
            returns a2a:Task|a2a:Error => self.handler.cancelTask(context, request);

    isolated resource function post tasks/[string id]/pushNotificationConfigs(a2a:Context context,
            a2a:TaskPushNotificationConfig request) returns a2a:TaskPushNotificationConfig|a2a:Error =>
        self.handler.createTaskPushNotificationConfig(context, request);

    isolated resource function get tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context,
            a2a:GetTaskPushNotificationConfigRequest request) returns a2a:TaskPushNotificationConfig|a2a:Error =>
        self.handler.getTaskPushNotificationConfig(context, request);

    isolated resource function get tasks/[string id]/pushNotificationConfigs(a2a:Context context,
            a2a:ListTaskPushNotificationConfigsRequest request) returns a2a:ListTaskPushNotificationConfigsResponse|a2a:Error =>
        self.handler.listTaskPushNotificationConfigs(context, request);

    isolated resource function delete tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context,
            a2a:DeleteTaskPushNotificationConfigRequest request) returns a2a:Error? =>
        self.handler.deleteTaskPushNotificationConfig(context, request);
}

isolated service class TckExtendedService {
    *a2a:Service;
    private final a2a:DefaultHandler handler;

    isolated function init(a2a:DefaultHandler handler) {
        self.handler = handler;
    }

    isolated resource function get agentCard() returns a2a:AgentCard|a2a:Error => buildCard([tckSkill]);

    isolated resource function post message\:send(a2a:Context context, a2a:SendMessageRequest request)
            returns a2a:Task|a2a:Message|a2a:Error => self.handler.sendMessage(context, request);

    isolated resource function post message\:stream(a2a:Context context, a2a:SendMessageRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error => self.handler.sendStreamingMessage(context, request);

    isolated resource function get tasks/[string id]/subscribe(a2a:Context context, a2a:SubscribeToTaskRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error => self.handler.subscribeToTask(context, request);

    isolated resource function get tasks/[string id](a2a:Context context, a2a:GetTaskRequest request)
            returns a2a:Task|a2a:Error => self.handler.getTask(context, request);

    isolated resource function get tasks(a2a:Context context, a2a:ListTasksRequest request)
            returns a2a:ListTasksResponse|a2a:Error => self.handler.listTasks(context, request);

    isolated resource function post tasks/[string id]/cancel(a2a:Context context, a2a:CancelTaskRequest request)
            returns a2a:Task|a2a:Error => self.handler.cancelTask(context, request);

    isolated resource function post tasks/[string id]/pushNotificationConfigs(a2a:Context context,
            a2a:TaskPushNotificationConfig request) returns a2a:TaskPushNotificationConfig|a2a:Error =>
        self.handler.createTaskPushNotificationConfig(context, request);

    isolated resource function get tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context,
            a2a:GetTaskPushNotificationConfigRequest request) returns a2a:TaskPushNotificationConfig|a2a:Error =>
        self.handler.getTaskPushNotificationConfig(context, request);

    isolated resource function get tasks/[string id]/pushNotificationConfigs(a2a:Context context,
            a2a:ListTaskPushNotificationConfigsRequest request) returns a2a:ListTaskPushNotificationConfigsResponse|a2a:Error =>
        self.handler.listTaskPushNotificationConfigs(context, request);

    isolated resource function delete tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context,
            a2a:DeleteTaskPushNotificationConfigRequest request) returns a2a:Error? =>
        self.handler.deleteTaskPushNotificationConfig(context, request);

    isolated resource function get extendedAgentCard(a2a:Context context, a2a:GetExtendedAgentCardRequest request)
            returns a2a:AgentCard|a2a:Error => self.handler.getExtendedAgentCard(context, request);
}

isolated class TckAgentExecutor {
    *a2a:AgentExecutor;

    public isolated function execute(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        string id = context.message.messageId;

        // Longer prefixes are tested before the shorter ones they extend.
        if id.startsWith("tck-message-response") {
            return agentMessage("Direct message response");
        }
        if id.startsWith("tck-input-required") {
            check updater->requireInput(agentMessage("Input required"));
            return;
        }
        if id.startsWith("tck-reject-task") {
            check updater->reject(agentMessage("rejected"));
            return;
        }
        if id.startsWith("tck-complete-task") {
            check updater->complete(agentMessage("Hello from TCK"));
            return;
        }
        if id.startsWith("tck-artifact-file-url") {
            check updater->addArtifact([{url: "https://example.com/output.txt",
                mediaType: "text/plain", filename: "output.txt"}]);
            check updater->complete();
            return;
        }
        if id.startsWith("tck-artifact-file") {
            check updater->addArtifact([{raw: "tck".toBytes(), mediaType: "text/plain", filename: "output.txt"}]);
            check updater->complete();
            return;
        }
        if id.startsWith("tck-artifact-data") {
            check updater->addArtifact([{data: {"key": "value", "count": 42}}]);
            check updater->complete();
            return;
        }
        if id.startsWith("tck-artifact-text") {
            check updater->addArtifact([{text: "Generated text content"}]);
            check updater->complete();
            return;
        }

        // Streaming scenarios: a "working" update, an artifact, "completed".
        if id.startsWith("test-resubscribe-message-id") {
            check updater->working();
            runtime:sleep(2 * streamingTimeout);
            check updater->complete();
            return;
        }
        if id.startsWith("tck-stream-002") {
            check updater->complete();
            return;
        }
        if id.startsWith("tck-stream-artifact-file") {
            check updater->working();
            check updater->addArtifact([{raw: "tck".toBytes(), mediaType: "text/plain", filename: "output.txt"}]);
            check updater->complete();
            return;
        }
        string? streamText = streamArtifactText(id);
        if streamText is string {
            check updater->working();
            check updater->addArtifact([{text: streamText}]);
            check updater->complete();
            return;
        }

        // Default: complete with an echo. The TCK's own setup messages
        // (for example "tck-send-001") rely on this.
        check updater->complete(agentMessage("Unhandled messageId prefix: " + id));
        return;
    }
}

isolated function streamArtifactText(string id) returns string? {
    if id.startsWith("tck-stream-001") {
        return "Stream hello from TCK";
    }
    if id.startsWith("tck-stream-003") {
        return "Stream task lifecycle";
    }
    if id.startsWith("tck-stream-ordering-001") {
        return "Ordered output";
    }
    if id.startsWith("tck-stream-artifact-text") {
        return "Streamed text content";
    }
    return ();
}

isolated function agentMessage(string text) returns a2a:Message => {
    messageId: uuid:createType4AsString(),
    role: a2a:ROLE_AGENT,
    parts: [{text}]
};
