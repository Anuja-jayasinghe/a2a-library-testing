// The Traveler agent: a real ballerina/ai Agent (backed by Anthropic's
// Claude) given A2A operations against both server agents as tools via
// ai:A2aToolKit -- ballerina/ai's generic, multi-agent A2A toolkit. Built
// once here and driven interactively from main.bal, one typed message at
// a time, so a real person can exercise it by hand instead of a fixed
// script.

import ballerina/ai;
import ballerinax/ai.anthropic;

configurable string anthropicApiKey = ?;
configurable string tripPlannerUrl = "http://localhost:9095";
configurable string packingAssistantUrl = "http://localhost:9097";

isolated function buildTraveler() returns ai:Agent|error {
    anthropic:ModelProvider claudeModel = check new (anthropicApiKey, anthropic:CLAUDE_HAIKU_4_5);
    ai:A2aToolKit a2a = check new (
        agents = [{agent: tripPlannerUrl}, {agent: packingAssistantUrl}],
        toolSet = {streaming: true, pushNotifications: true}
    );
    return new (
        systemPrompt = {
            role: "Traveler",
            instructions: "You want a short trip planned, and to know what to pack for it. Two "
                + "agents are available to help -- discover them before delegating. Remember "
                + "task ids and which agent they belong to from earlier in the conversation, so "
                + "you can check on, continue, or cancel them later without asking the user to "
                + "repeat them. Report back plainly what happened -- what you sent, which agent "
                + "replied, what it said, and any task id involved."
        },
        model = claudeModel,
        tools = [a2a]
    );
}
