// The second server agent in the demo: a Claude-backed Packing Assistant,
// structurally identical to the Trip Planner in server/main.bal. Its only
// purpose is to give the client's generic A2A toolkit a genuine second
// agent to choose between -- discoverAgents/delegateToAgent's agentName
// selection means nothing when there is only ever one agent to pick.

import ballerina/a2a;
import ballerina/ai;
import ballerina/io;
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

listener a2a:Listener packingAgentListener = new (agentPort, agentCard = {
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
}, pushSender = new a2a:HttpPushNotificationSender({validateUrl: false}));
// validateUrl: false -- see server/main.bal's identical note; this demo's
// webhook receiver runs at http://localhost, a loopback address the default
// SSRF guard otherwise rejects.

public function main() returns error? {
    check packingAgentListener.attach(new PackingAssistantAgentService());
    check packingAgentListener.'start();
    io:println(string `Packing Assistant Agent (Claude-backed) listening on http://localhost:${agentPort}`);
    io:println("Run the client package (in a separate terminal) to drive it through the full A2A lifecycle.");
    io:println("Press Ctrl+C to stop.");
}

isolated service class PackingAssistantAgentService {
    *a2a:Service;

    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        check updater->working();

        string userText = extractText(context.message);
        string|error reply = packingAssistant.run(userText, sessionId = updater.getContextId());

        if reply is error {
            string msg = string `packing assistant model call failed: ${reply.message()}`;
            check updater->failed({
                messageId: uuid:createType4AsString(),
                role: a2a:ROLE_AGENT,
                parts: [{text: msg}]
            });
            return error a2a:InternalError(msg, message = msg);
        }

        string trimmed = reply.trim();
        if trimmed.startsWith("NEEDS_INFO:") {
            check updater->requireInput({
                messageId: uuid:createType4AsString(),
                role: a2a:ROLE_AGENT,
                parts: [{text: trimmed.substring("NEEDS_INFO:".length()).trim()}]
            });
            return;
        }

        string packingList = trimmed.startsWith("PACKING_LIST:")
            ? trimmed.substring("PACKING_LIST:".length()).trim()
            : trimmed;
        check updater->addArtifact([{text: packingList}]);
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
