// The second server agent in the demo: a Claude-backed Packing Assistant,
// structurally identical to the Trip Planner in server/main.bal. Its only
// purpose is to give the client's generic A2A toolkit a genuine second
// agent to choose between -- discoverAgents/delegateToAgent's agentName
// selection means nothing when there is only ever one agent to pick.

import ballerina/a2a;
import ballerina/ai;
import ballerina/io;
import ballerina/log;
import ballerina/uuid;
import ballerinax/ai.anthropic;

configurable int agentPort = 9097;
configurable string anthropicApiKey = ?;

final anthropic:ModelProvider claudeModel = check new (anthropicApiKey, anthropic:CLAUDE_HAIKU_4_5);

final ai:Agent packingAssistant = check new (
    systemPrompt = {
        role: "Packing Assistant",
        instructions: string `You suggest a short packing list for a trip.

If the user's message does not mention a destination or trip type (e.g.
beach, hiking, winter city break), respond with exactly this format and
nothing else:
NEEDS_INFO: <a short, friendly question asking about the destination or trip type>

Once you know enough (from this message or an earlier one in this
conversation), respond with exactly this format and nothing else:
PACKING_LIST: <5 to 6 packing items, one short phrase each, comma-separated>

Never respond in any other format, and never ask more than one clarifying
question before producing a packing list once you know enough.`
    },
    model = claudeModel
);

final a2a:AgentCard packingAgentHandlerCard = {
    name: "Packing Assistant Agent",
    description: "A Claude-backed agent that suggests a short packing list for a trip",
    version: "1.0.0",
    skills: [
        {
            id: "suggest-packing-list",
            name: "Suggest a Packing List",
            description: "Suggests a short packing list for a named destination or trip type",
            tags: ["travel", "packing"],
            examples: ["What should I pack for Kyoto in winter?", "Packing list for a beach trip"]
        }
    ],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

final a2a:DefaultHandler packingAgentHandler = new (new PackingAssistantAgentExecutor(), pushSender = new a2a:HttpPushNotificationSender({validateUrl: false}));

listener a2a:RestListener packingAgentListener = new (agentPort);
// validateUrl: false -- see server/main.bal's identical note; this demo's
// webhook receiver runs at http://localhost, a loopback address the default
// SSRF guard otherwise rejects.

public function main() returns error? {
    check packingAgentListener.attach(new AgentOperations(packingAgentHandler, packingAgentHandlerCard));
    check packingAgentListener.'start();
    io:println(string `Packing Assistant Agent (Claude-backed) listening on http://localhost:${agentPort}`);
    io:println("Run the client package (in a separate terminal) to drive it through the full A2A lifecycle.");
    io:println("Press Ctrl+C to stop.");
}

isolated class PackingAssistantAgentExecutor {
    *a2a:AgentExecutor;

    public isolated function execute(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        check updater.working();

        string userText = extractText(context.message);
        string taskId = updater.getTaskId();
        boolean isContinuation = context.message.taskId is string;
        log:printInfo("Packing Assistant: task received", taskId = taskId, contextId = updater.getContextId(),
                continuation = isContinuation, request = userText);
        log:printInfo("Packing Assistant: asking Claude", taskId = taskId);
        string|error reply = packingAssistant.run(userText, sessionId = updater.getContextId());

        if reply is error {
            log:printError("Packing Assistant: task failed", taskId = taskId, reason = reply.message());
            string msg = string `packing assistant model call failed: ${reply.message()}`;
            check updater.failed({
                messageId: uuid:createType4AsString(),
                role: a2a:ROLE_AGENT,
                parts: [{text: msg}]
            });
            return error a2a:InternalError(msg, message = msg);
        }

        string trimmed = reply.trim();
        log:printInfo("Packing Assistant: Claude replied", taskId = taskId, reply = trimmed);
        if trimmed.startsWith("NEEDS_INFO:") {
            log:printInfo("Packing Assistant: task needs input (INPUT_REQUIRED)", taskId = taskId);
            check updater.requireInput({
                messageId: uuid:createType4AsString(),
                role: a2a:ROLE_AGENT,
                parts: [{text: trimmed.substring("NEEDS_INFO:".length()).trim()}]
            });
            return;
        }

        string packingList = trimmed.startsWith("PACKING_LIST:")
            ? trimmed.substring("PACKING_LIST:".length()).trim()
            : trimmed;
        check updater.addArtifact([{text: packingList}]);
        check updater.complete();
        log:printInfo("Packing Assistant: task completed (COMPLETED)", taskId = taskId);
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
