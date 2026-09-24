// Orchestrates the client half of the demo: starts this client's own
// webhook receiver, builds the Traveler agent (traveler.bal), then hands
// control to an interactive prompt so a real person can type messages to
// it directly, instead of a fixed script driving it -- see
// process_exit.bal for why the explicit exit at the end is needed.

import ballerina/ai;
import ballerina/io;

public function main() returns error? {
    check webhookListener.'start();

    io:println("A2A demo -- three Claude-backed Ballerina agents, one client and two servers");
    io:println(string `Trip Planner:      ${tripPlannerUrl} (run the server package first)`);
    io:println(string `Packing Assistant: ${packingAssistantUrl} (run the server2 package first)`);
    io:println(string `Webhook:           http://localhost:${webhookPort}/webhook/receiver`);
    io:println();

    ai:Agent|error traveler = buildTraveler();
    if traveler is error {
        check webhookListener.immediateStop();
        io:println("Could not start the Traveler agent: ", traveler.message());
        exitProcess(1);
        return;
    }

    io:println("Type a message for the Traveler agent -- it can discover, message, check on, "
            + "cancel, or stream from either server agent. Type 'exit' to quit.");
    interactiveLoop(traveler);

    check webhookListener.immediateStop();
    exitProcess(0);
}

function interactiveLoop(ai:Agent traveler) {
    while true {
        string input = io:readln("\nYou: ").trim();
        if input == "" {
            continue;
        }
        if input == "exit" || input == "quit" {
            return;
        }
        string|error reply = traveler.run(input);
        if reply is error {
            io:println("Traveler hit an error: ", reply.message());
        } else {
            io:println("Traveler: ", reply);
        }
    }
}
