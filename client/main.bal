// Orchestrates the client half of the demo: starts this client's own
// webhook receiver, runs the lifecycle walkthrough against the already-
// running server package, then stops the webhook receiver and forces the
// process to exit -- see process_exit.bal for why the explicit exit is
// needed at all.

import ballerina/io;

public function main() returns error? {
    check webhookListener.'start();

    io:println("A2A lifecycle demo -- three Claude-backed Ballerina agents, one client and two servers");
    io:println(string `Trip Planner:      ${tripPlannerUrl} (run the server package first)`);
    io:println(string `Packing Assistant: ${packingAssistantUrl} (run the server2 package first)`);
    io:println(string `Webhook:           http://localhost:${webhookPort}/webhook/receiver`);

    error? demoResult = runLifecycleDemo();

    check webhookListener.immediateStop();

    if demoResult is error {
        io:println("Demo failed: ", demoResult.message());
        exitProcess(1);
    }
    exitProcess(0);
}
