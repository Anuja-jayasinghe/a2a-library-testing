// The server half of the demo: a real ballerina/ai Agent (backed by
// Anthropic's Claude via ballerinax/ai.anthropic) wrapped as an a2a:Service.
// This is a genuine LLM-backed A2A agent, not a scripted one -- every
// reply comes from an actual model call.
//
// Persona: a trip-planning assistant. If the caller's message doesn't name
// a destination, it asks for one (TASK_STATE_INPUT_REQUIRED); once it knows
// the destination, it produces a short itinerary and completes. The A2A
// contextId is used as the ai:Agent session id, so a continuation
// (message.taskId set) naturally continues the same LLM conversation --
// the model remembers it already asked for a destination.

import ballerina/a2a;
import ballerina/ai;
import ballerina/io;
import ballerina/uuid;
import ballerinax/ai.anthropic;

configurable int agentPort = 9095;
configurable string anthropicApiKey = ?;

final anthropic:ModelProvider claudeModel = check new (anthropicApiKey, anthropic:CLAUDE_HAIKU_4_5);

final ai:Agent tripPlanner = check new (
    systemPrompt = {
        role: "Trip Planner",
        instructions: string `You help plan a short, one-day trip itinerary.

If the user's message does not name a specific destination city, respond
with exactly this format and nothing else:
NEEDS_INFO: <a short, friendly question asking which city they want to visit>

Once you know the destination (from this message or an earlier one in this
conversation), respond with exactly this format and nothing else:
ITINERARY: <a short, concrete one-day itinerary for that city -- 3 to 4
activities, each one sentence>

Never respond in any other format, and never ask more than one clarifying
question before producing an itinerary once a destination is known.`
    },
    model = claudeModel
);

listener a2a:Listener demoAgentListener = new (agentPort, agentCard = {
    name: "Trip Planner Agent",
    description: "A Claude-backed agent that plans short, one-day trip itineraries",
    version: "1.0.0",
    skills: [
        {
            id: "plan-day-trip",
            name: "Plan a Day Trip",
            description: "Plans a short, one-day itinerary for a named destination city",
            tags: ["travel", "itinerary"],
            examples: ["Plan me a day trip to Paris", "What should I do in Kyoto for a day?"]
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
    check demoAgentListener.attach(new TripPlannerAgentService());
    check demoAgentListener.'start();
    io:println(string `Trip Planner Agent (Claude-backed) listening on http://localhost:${agentPort}`);
    io:println("Run the client package (in a separate terminal) to drive it through the full A2A lifecycle.");
    io:println("Press Ctrl+C to stop.");
}

isolated service class TripPlannerAgentService {
    *a2a:Service;

    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        check updater->working();

        string userText = extractText(context.message);
        // The A2A contextId as the ai:Agent session id: a continuation
        // (same task, same context) reuses the same LLM conversation, so
        // the model remembers it already asked for a destination rather
        // than this code having to reconstruct that history itself.
        string|error reply = tripPlanner.run(userText, sessionId = updater.getContextId());

        if reply is error {
            string msg = string `trip planner model call failed: ${reply.message()}`;
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

        // ITINERARY: prefix expected, but anything else is still treated
        // as the answer -- a model that drifts from the exact format
        // asked for still deserves a real reply, not a hard failure.
        string itinerary = trimmed.startsWith("ITINERARY:")
            ? trimmed.substring("ITINERARY:".length()).trim()
            : trimmed;
        check updater->addArtifact([{text: itinerary}]);
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
