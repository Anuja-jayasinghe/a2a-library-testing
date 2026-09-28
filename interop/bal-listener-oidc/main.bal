// A ballerina/a2a listener that validates bearer tokens the way production does:
// against an issuer's *published keys* (JWKS), not a shared secret. The tokens come
// from oidc-provider/provider.py, which signs with RS256 and can rotate its key.
//
// `a2a:invoke` is required, so a token that only carries `a2a:read` is a 403.

import ballerina/a2a;
import ballerina/io;

configurable int PORT = 9613;
configurable string providerUrl = "http://localhost:9800";

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
    name: "Ballerina A2A Interop Listener (OIDC/JWKS)",
    description: "Validates RS256 bearer tokens against the issuer's JWKS; requires the a2a:invoke scope",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Handles deterministic interop test messages", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

listener a2a:Listener l = new (PORT, agentCard = card, auth = [{
    jwtValidatorConfig: {
        issuer: providerUrl,
        audience: "a2a",
        signatureConfig: {jwksConfig: {url: providerUrl + "/jwks.json"}}
    },
    scopes: "a2a:invoke"
}]);

public function main() returns error? {
    check l.attach(new InteropAgent());
    io:println(string `Ballerina interop listener (JWKS auth) on http://localhost:${PORT}`);
}
