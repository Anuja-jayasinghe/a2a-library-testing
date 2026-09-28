// A ballerina/a2a listener with authentication turned on, for the
// cross-SDK auth pairs (X-A1/X-A2 in INTEROP_AND_AUTH_TEST_PLAN.md): does a
// real other-language client's own auth machinery authenticate against it,
// using nothing but the derived card (ListenerConfiguration.auth with no
// securitySchemes declared -- see module-ballerina-a2a commit caf9afc).

import ballerina/a2a;
import ballerina/io;

configurable int PORT = 9612;
// Same shared secret both sides mint/validate with -- this test only
// proves the protocol plumbing (discovery -> scheme name -> credential ->
// header -> validation), not a real identity provider.
configurable string sharedSecret = "interop-auth-shared-secret-0123456789";

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
    name: "Ballerina A2A Interop Listener (authenticated)",
    description: "Requires a bearer credential; its securitySchemes/securityRequirements are derived from auth",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Handles deterministic interop test messages", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

listener a2a:Listener l = new (PORT, agentCard = card,
    auth = [{jwtValidatorConfig: {issuer: "interop", audience: "a2a", signatureConfig: {secret: sharedSecret}}}]
);

public function main() returns error? {
    check l.attach(new InteropAgent());
    io:println(string `Ballerina interop listener (authenticated) on http://localhost:${PORT}`);
}
