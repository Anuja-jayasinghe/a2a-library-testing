// The client half of the demo: a real ballerina/ai Agent (backed by
// Anthropic's Claude, its own separate model call from the server's) that
// decides, in its own words, how to pursue each scenario below using the
// A2A tools in toolkit.bal -- genuinely two independent LLM agents
// conversing over the real A2A wire protocol, not a scripted exchange.
//
// Each scenario is still a fixed prompt, not one open-ended agent loop --
// deliberate, so this demo reliably exercises every operation across one
// run instead of depending on the model happening to explore all of them
// on its own.

import ballerina/ai;
import ballerina/io;
import ballerinax/ai.anthropic;

configurable string anthropicApiKey = ?;

isolated function runLifecycleDemo() returns error? {
    anthropic:ModelProvider claudeModel = check new (anthropicApiKey, anthropic:CLAUDE_HAIKU_4_5);
    TripPlannerToolKit toolkit = check new ();
    ai:Agent traveler = check new (
        systemPrompt = {
            role: "Traveler",
            instructions: "You want a short trip planned by the remote Trip Planner agent. You have "
                + "tools that let you send it messages and manage the resulting tasks. Follow the "
                + "specific instruction given to you each turn exactly, using the named tool(s) it "
                + "asks for, then report back plainly what happened -- what you sent, what the agent "
                + "replied, and any task id or state involved. Keep your reports brief."
        },
        model = claudeModel,
        tools = [toolkit]
    );

    section("1. Start a request without a destination (expect a clarifying question)");
    string reply1 = check traveler.run(
        "Use sendToTripPlanner to ask for 'a fun day trip' without naming any city. "
            + "Report exactly what the agent replied.");
    io:println(reply1);

    section("2. Answer with a destination (continuation of the same task)");
    string reply2 = check traveler.run(
        "Use continueTripPlannerTask to tell the agent the destination is Paris. "
            + "Report the itinerary it gives you.");
    io:println(reply2);

    section("3. Check status, then list every known task");
    string reply3 = check traveler.run(
        "Use getTripPlannerTaskStatus to check that task, then use listTripPlannerTasks "
            + "to list everything the agent knows about. Report both results.");
    io:println(reply3);

    section("4. Register a webhook for that task");
    string reply4 = check traveler.run(
        "Use registerTripPlannerWebhook to register our webhook for that task. "
            + "Report whether it succeeded.");
    io:println(reply4);
    map<json>? delivered = waitForWebhookPayload(3);
    io:println(string `  (checked independently of the model: webhook payload actually received -- `
            + string `${delivered is map<json> ? "yes" : "no (timed out)"})`);

    section("5. Start a new task and cancel it before it finishes");
    string reply5 = check traveler.run(
        "Use startTripPlannerTaskWithoutWaiting to ask for a day trip to Tokyo, then immediately "
            + "use cancelTripPlannerTask on that new task before it can finish. Report the "
            + "resulting task state.");
    io:println(reply5);

    section("6. A new request, watched live");
    string reply6 = check traveler.run(
        "Use streamFromTripPlanner to ask for a day trip to Rome, watching the live progress. "
            + "Report the updates you saw and the final itinerary.");
    io:println(reply6);

    io:println("\nLifecycle demo complete.");
}

isolated function section(string title) {
    io:println();
    io:println("== ", title, " ==");
}
