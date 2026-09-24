// The client half of the demo: a real ballerina/ai Agent (backed by
// Anthropic's Claude, its own separate model call from either server's)
// that decides, in its own words, how to pursue each scenario below using
// ai:A2aToolKit -- ballerina/ai's generic, multi-agent A2A toolkit.
//
// Unlike a bespoke per-agent toolkit (one named tool per remote agent),
// this is the toolkit a real user would reach for: a registry of agents
// (resolved from their Agent Cards), with a small set of generic,
// agentName-parameterized tools -- discoverAgents, delegateToAgent,
// getAgentTaskStatus, cancelAgentTask, listAgentTasks, streamFromAgent,
// createAgentPushNotificationConfig. Adding an agent is a config line, not
// a new tool the model has to relearn.
//
// Each scenario is still a fixed prompt, not one open-ended agent loop --
// deliberate, so this demo reliably exercises every operation across one
// run instead of depending on the model happening to explore all of them
// on its own.

import ballerina/ai;
import ballerina/io;
import ballerinax/ai.anthropic;

configurable string anthropicApiKey = ?;
configurable string tripPlannerUrl = "http://localhost:9095";
configurable string packingAssistantUrl = "http://localhost:9097";

isolated function runLifecycleDemo() returns error? {
    anthropic:ModelProvider claudeModel = check new (anthropicApiKey, anthropic:CLAUDE_HAIKU_4_5);
    ai:A2aToolKit a2a = check new (
        agents = [{agent: tripPlannerUrl}, {agent: packingAssistantUrl}],
        toolSet = {streaming: true, pushNotifications: true}
    );
    ai:Agent traveler = check new (
        systemPrompt = {
            role: "Traveler",
            instructions: "You want a short trip planned, and to know what to pack for it. Two "
                + "agents are available to help -- discover them before delegating. Follow the "
                + "specific instruction given to you each turn exactly, using the named tool(s) it "
                + "asks for, then report back plainly what happened -- what you sent, which agent "
                + "replied, what it said, and any task id involved. Keep your reports brief."
        },
        model = claudeModel,
        tools = [a2a]
    );

    section("1. Discover the agents, then ask the Trip Planner for a trip (no destination)");
    string reply1 = check traveler.run(
        "Use discoverAgents to see what's available. Then use delegateToAgent to ask the Trip "
            + "Planner agent for 'a fun day trip' without naming any city. Report exactly what "
            + "the agent replied, and the task id.");
    io:println(reply1);

    section("2. Continue that same task with a destination");
    string reply2 = check traveler.run(
        "Use delegateToAgent again, to the same Trip Planner agent, passing the taskId from "
            + "before and the message 'Paris'. Report the itinerary it gives you.");
    io:println(reply2);

    section("3. Check status, then list every task the Trip Planner knows about");
    string reply3 = check traveler.run(
        "Use getAgentTaskStatus to check that same task, then use listAgentTasks to list "
            + "everything the Trip Planner agent knows about. Report both results.");
    io:println(reply3);

    section("4. Delegate a different request to the Packing Assistant");
    string reply4 = check traveler.run(
        "Use delegateToAgent to ask the Packing Assistant agent what to pack for the Paris day "
            + "trip. This is a fresh task with a different agent, not a continuation. Report the "
            + "packing list and its task id.");
    io:println(reply4);

    section("5. Register a webhook for the Packing Assistant's task");
    string reply5 = check traveler.run(string `Use createAgentPushNotificationConfig to register `
            + string `the webhook URL http://localhost:${webhookPort}/webhook/receiver for the `
            + string `Packing Assistant task from the previous step. Report whether it succeeded.`);
    io:println(reply5);
    map<json>? delivered = waitForWebhookPayload(3);
    io:println(string `  (checked independently of the model: webhook payload actually received -- `
            + string `${delivered is map<json> ? "yes" : "no (timed out)"})`);

    section("6. Start a new Trip Planner task and try to cancel it");
    string reply6 = check traveler.run(
        "Use delegateToAgent to ask the Trip Planner agent for a day trip to Tokyo, then "
            + "immediately use cancelAgentTask on that new task. Report the resulting task "
            + "state, whether it was still running or had already finished.");
    io:println(reply6);

    section("7. A new request, watched live");
    string reply7 = check traveler.run(
        "Use streamFromAgent to ask the Trip Planner agent for a day trip to Rome, watching the "
            + "live progress. Report the updates you saw and the final itinerary.");
    io:println(reply7);

    io:println("\nLifecycle demo complete.");
}

isolated function section(string title) {
    io:println();
    io:println("== ", title, " ==");
}
