// A ballerina/a2a listener protected by a REAL identity provider (Keycloak, ../keycloak),
// used for the identity-provider and AUTH_REQUIRED checks:
//   * tokens are validated against Keycloak's published JWKS (issuer, audience, scope);
//   * `idp-whoami`        answers with the caller identity the library derived (`context.owner`);
//   * `idp-auth-required` pauses the task in TASK_STATE_AUTH_REQUIRED (spec 7.6); any other
//                         message on that task completes it, echoing a credential sent back;
//   * `idp-chain`         is an agent that calls a second agent, as its own service identity.

import ballerina/a2a;
import ballerina/io;

configurable int PORT = 9620;
configurable string issuer = "http://localhost:8180/realms/a2a";
configurable string jwksUrl = "http://localhost:8180/realms/a2a/protocol/openid-connect/certs";
configurable string discoveryUrl = "http://localhost:8180/realms/a2a/.well-known/openid-configuration";
configurable string requiredScope = "a2a:invoke";
// true: cache the JWKS by kid (ballerina/jwt jwksConfig.cacheConfig). Off by default upstream, so the
// IdP is asked for its keys on every request.
configurable boolean cacheJwks = false;
configurable decimal jwksMaxAge = 30;
// idp-chain: the agent to call, and the service credentials to call it with.
configurable string downstreamUrl = "http://localhost:9621";
configurable string tokenUrl = "http://localhost:8180/realms/a2a/protocol/openid-connect/token";
configurable string clientId = "agent-a";
configurable string clientSecret = "agent-a-secret";

isolated function textOfParts(a2a:Part[] parts) returns string {
    string text = "";
    foreach a2a:Part part in parts {
        string? t = part?.text;
        if t is string {
            text += t;
        }
    }
    return text;
}

isolated service class IdpAgent {
    *a2a:Service;
    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        string id = context.message.messageId;
        string text = textOfParts(context.message.parts);
        string owner = context.owner ?: "(none)";

        if id.startsWith("idp-whoami") {
            check updater->working();
            check updater->addArtifact([{text: owner}], name = "owner");
            check updater->complete();
            return;
        }

        // Spec 7.6: the agent needs a further credential mid-task (e.g. a third-party account).
        if id.startsWith("idp-auth-required") {
            check updater->working();
            check updater->requireAuth({
                messageId: "auth-1", role: a2a:ROLE_AGENT,
                parts: [{text: "link your calendar account, then reply with the credential"}]
            });
            return;
        }

        if id.startsWith("idp-chain") {
            check updater->working();
            a2a:HttpClient|a2a:Error downstream = new (downstreamUrl, clientConfig = {
                auth: {tokenUrl, clientId, clientSecret, scopes: ["a2a:invoke"]}
            });
            string seen;
            if downstream is a2a:Error {
                seen = "downstream client failed: " + downstream.message();
            } else {
                a2a:Task|a2a:Message|a2a:Error r = downstream->sendMessage({
                    message: {messageId: "idp-whoami-from-chain", role: a2a:ROLE_USER, parts: [{text: "who am i"}]}
                });
                if r is a2a:Task {
                    a2a:Artifact[] artifacts = r?.artifacts ?: [];
                    seen = artifacts.length() > 0 ? textOfParts(artifacts[0].parts) : "no artifact";
                } else if r is a2a:Error {
                    seen = "downstream error: " + r.message();
                } else {
                    seen = "downstream replied with a message";
                }
            }
            check updater->addArtifact([{text: string `my caller: ${owner}; downstream saw: ${seen}`}], name = "chain");
            check updater->complete();
            return;
        }

        // Default, and the continuation of an AUTH_REQUIRED task: echo what was sent back.
        check updater->working();
        check updater->addArtifact([{text: string `echo: ${text}`}], name = "result");
        check updater->complete();
    }
}

a2a:AgentCard card = {
    name: "Ballerina A2A Agent (Keycloak)",
    description: "Validates Keycloak-issued bearer tokens against the realm's JWKS",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Identity-provider interop checks", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    securitySchemes: {oidc: {'type: "openIdConnect", openIdConnectUrl: discoveryUrl}},
    securityRequirements: [{oidc: [requiredScope]}],
    supportedInterfaces: []
};

listener a2a:Listener l = new (PORT, agentCard = card, auth = [{
    jwtValidatorConfig: {
        issuer,
        audience: "a2a",
        signatureConfig: {jwksConfig: cacheJwks ? {url: jwksUrl, cacheConfig: {capacity: 10, defaultMaxAge: jwksMaxAge}} : {url: jwksUrl}}
    },
    scopes: requiredScope
}]);

public function main() returns error? {
    check l.attach(new IdpAgent());
    io:println(string `Ballerina agent (Keycloak auth) on http://localhost:${PORT}`);
}
