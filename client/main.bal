// Orchestrates the client half of the demo: starts this client's own
// webhook receiver, runs the lifecycle walkthrough against the already-
// running server package, then stops the webhook receiver and forces the
// process to exit -- see process_exit.bal for why the explicit exit is
// needed at all.

import ballerina/io;

configurable int agentPort = 9095;

public function main() returns error? {
    check webhookListener.'start();

    string agentUrl = string `http://localhost:${agentPort}`;
    string webhookUrl = string `http://localhost:${webhookPort}/webhook/receiver`;

    io:println("A2A lifecycle demo -- Ballerina client driving a Ballerina listener");
    io:println(string `Agent:   ${agentUrl} (run the server package first)`);
    io:println(string `Webhook: ${webhookUrl}`);

    error? demoResult = runLifecycleDemo(agentUrl, webhookUrl);

    check webhookListener.immediateStop();

    if demoResult is error {
        io:println("Demo failed: ", demoResult.message());
        exitProcess(1);
    }
    exitProcess(0);
}
