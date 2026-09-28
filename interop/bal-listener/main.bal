import ballerina/a2a;
import ballerina/io;

configurable int PORT = 9611;

isolated service class InteropAgent {
    *a2a:Service;
    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        string text = "";
        foreach a2a:Part part in context.message.parts {
            string? t = part?.text;
            if t is string {
                text += t;
            }
        }
        check updater->working();
        check updater->addArtifact([{text: string `echo: ${text}`}], name = "result");
        check updater->complete();
    }
}

a2a:AgentCard card = {
    name: "Ballerina A2A Interop Listener",
    description: "Deterministic agent on ballerina/a2a's Listener, for interop testing against other SDKs' clients",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Handles deterministic interop test messages", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

listener a2a:Listener l = new (PORT, agentCard = card);

public function main() returns error? {
    check l.attach(new InteropAgent());
    io:println(string `Ballerina interop listener on http://localhost:${PORT}`);
}
