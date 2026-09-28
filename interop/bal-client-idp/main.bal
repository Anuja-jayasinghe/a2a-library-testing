// ballerina/a2a's client against a REAL identity provider (Keycloak, ../keycloak):
//   K2  our client -> a foreign (Python) agent that validates Keycloak RS256 tokens via JWKS
//   K3  a user's token, refreshed by ballerina/oauth2's refresh-token grant (the tail of an
//       authorization-code login), against our own listener
//   B2  AUTH_REQUIRED, seen from the client side: from our listener, and from the Python SDK's agent
//   C1  identity through an agent chain: user -> agent A -> agent B
// The client's token handling is ballerina/http + ballerina/oauth2 (clientConfig.auth); nothing here
// mints or attaches a token by hand.

import ballerina/a2a;
import ballerina/io;
import ballerina/lang.runtime;

configurable string ourAgent = "http://localhost:9620";
configurable string pyAgent = "http://localhost:9702";
configurable string tokenUrl = "http://localhost:8180/realms/a2a/protocol/openid-connect/token";
// From the authorization-code login the runner performed for alice (see run_idp_checks.sh).
configurable string aliceRefreshToken = "";
configurable string aliceSub = "";

int failures = 0;

function expect(string label, boolean ok, string detail = "") {
    io:println(ok ? "PASS: " : "FAIL: ", label, ok || detail == "" ? "" : " -- " + detail);
    if !ok {
        failures += 1;
    }
}

function textOfParts(a2a:Part[] parts) returns string {
    string text = "";
    foreach a2a:Part p in parts {
        text += p?.text ?: "";
    }
    return text;
}

function show(a2a:Task|a2a:Message|a2a:Error r) returns string {
    return r is a2a:Error ? r.message() : r.toString();
}

function artifactText(a2a:Task t) returns string {
    string text = "";
    foreach a2a:Artifact a in t?.artifacts ?: [] {
        text += textOfParts(a.parts);
    }
    return text;
}

function serviceClient(string url, string id, string secret, string scope) returns a2a:HttpClient|a2a:Error {
    return new (url, clientConfig = {auth: {tokenUrl, clientId: id, clientSecret: secret, scopes: [scope]}});
}

function userClient(string url) returns a2a:HttpClient|a2a:Error {
    return new (url, clientConfig = {auth: {
        refreshUrl: tokenUrl, refreshToken: aliceRefreshToken, clientId: "a2a-webapp", clientSecret: "webapp-secret"
    }});
}

function send(a2a:HttpClient c, string id, string text = "hi", string? taskId = ())
        returns a2a:Task|a2a:Message|a2a:Error {
    return c->sendMessage({message: {messageId: id, role: a2a:ROLE_USER, parts: [{text}], taskId}});
}

public function main() returns error? {
    io:println("== K2: our client -> a foreign agent that validates Keycloak tokens against the realm JWKS ==");
    a2a:HttpClient toPy = check serviceClient(pyAgent, "agent-a", "agent-a-secret", "a2a:invoke");
    a2a:Task|a2a:Message|a2a:Error r1 = send(toPy, "k2-1");
    expect("a Keycloak client_credentials token, obtained by the client itself, is accepted by the Python agent",
            r1 is a2a:Task && r1.status.state == a2a:TASK_STATE_COMPLETED, r1 is a2a:Error ? r1.message() : "");

    a2a:HttpClient reader = check serviceClient(pyAgent, "reader", "reader-secret", "a2a:read");
    a2a:Task|a2a:Message|a2a:Error r2 = send(reader, "k2-2");
    expect("a valid token without the required scope is an AuthorizationError (403)", r2 is a2a:AuthorizationError,
            r2 is a2a:Error ? r2.message() : "succeeded");

    a2a:HttpClient anon = check new (pyAgent);
    a2a:Task|a2a:Message|a2a:Error r3 = send(anon, "k2-3");
    expect("no credential is an AuthenticationError (401)", r3 is a2a:AuthenticationError,
            r3 is a2a:Error ? r3.message() : "succeeded");

    a2a:AgentCard pyCard = check a2a:resolveAgentCard(pyAgent);
    map<a2a:SecurityScheme> schemes = pyCard.securitySchemes ?: {};
    a2a:SecurityScheme? oidc = schemes["oidc"];
    expect("the foreign card's openIdConnect scheme is decoded by our client",
            oidc is a2a:OpenIdConnectSecurityScheme && oidc.openIdConnectUrl.endsWith("/.well-known/openid-configuration"),
            oidc is () ? "scheme missing" : oidc.toString());
    a2a:SecurityRequirement[] reqs = pyCard.securityRequirements ?: [];
    expect("and so is the requirement, with its scope", reqs.length() == 1 && reqs[0]["oidc"] == ["a2a:invoke"],
            reqs.toString());

    io:println("== K3: a user's credential, kept alive by the refresh-token grant ==");
    a2a:HttpClient alice = check userClient(ourAgent);
    a2a:Task|a2a:Message|a2a:Error w1 = send(alice, "idp-whoami-1");
    expect("the agent sees the user (the sub of the login), not a service", w1 is a2a:Task && artifactText(w1) == aliceSub,
            w1 is a2a:Task ? artifactText(w1) + " vs " + aliceSub : show(w1));
    io:println("  (alice's access token lives 6s; sleeping 8s)");
    runtime:sleep(8);
    a2a:Task|a2a:Message|a2a:Error w2 = send(alice, "idp-whoami-2");
    expect("after the access token expired the client refreshed it and the call still succeeds, as the same user",
            w2 is a2a:Task && artifactText(w2) == aliceSub, w2 is a2a:Error ? w2.message() : "");

    io:println("== B2: AUTH_REQUIRED from our listener ==");
    a2a:Task|a2a:Message|a2a:Error p1 = send(alice, "idp-auth-required-1", "book me a meeting");
    expect("the blocking call returns at AUTH_REQUIRED (an interrupted state), not at a timeout",
            p1 is a2a:Task && p1.status.state == a2a:TASK_STATE_AUTH_REQUIRED,
            p1 is a2a:Task ? p1.status.state.toString() : show(p1));
    if p1 is a2a:Task {
        a2a:Message? ask = p1.status?.message;
        expect("the status message says what to do", ask is a2a:Message && textOfParts(ask.parts).includes("link your calendar"));
        a2a:Task|a2a:Error polled = alice->getTask({id: p1.id});
        expect("getTask reports the paused state", polled is a2a:Task && polled.status.state == a2a:TASK_STATE_AUTH_REQUIRED);
        a2a:Task|a2a:Message|a2a:Error p2 = send(alice, "idp-continue-1", "credential=cal-token-123", p1.id);
        expect("the credential, sent on the same task, completes it", p2 is a2a:Task && p2.id == p1.id
                && p2.status.state == a2a:TASK_STATE_COMPLETED && artifactText(p2).includes("cal-token-123"),
                p2 is a2a:Task ? p2.status.state.toString() + " " + artifactText(p2) : show(p2));
    }

    io:println("== B2: AUTH_REQUIRED from the Python SDK's agent ==");
    a2a:Task|a2a:Message|a2a:Error f1 = send(toPy, "interop-task-auth-required-1", "book me a meeting");
    expect("a foreign server's AUTH_REQUIRED is surfaced as a Task in that state",
            f1 is a2a:Task && f1.status.state == a2a:TASK_STATE_AUTH_REQUIRED,
            f1 is a2a:Task ? f1.status.state.toString() : show(f1));
    if f1 is a2a:Task {
        a2a:Message? ask = f1.status?.message;
        expect("its status message survives decoding", ask is a2a:Message && textOfParts(ask.parts).includes("link your calendar"));
        a2a:Task|a2a:Message|a2a:Error f2 = send(toPy, "interop-continue-1", "credential=cal-token-456", f1.id);
        expect("continuing on the same task completes it", f2 is a2a:Task && f2.id == f1.id
                && f2.status.state == a2a:TASK_STATE_COMPLETED && artifactText(f2).includes("cal-token-456"),
                f2 is a2a:Task ? f2.status.state.toString() + " " + artifactText(f2) : show(f2));
    }
    a2a:Task|a2a:Message|a2a:Error f3 = send(toPy, "interop-task-auth-required-2", "cancel me");
    if f3 is a2a:Task {
        a2a:Task|a2a:Error canceled = toPy->cancelTask({id: f3.id});
        expect("a foreign task paused in AUTH_REQUIRED can be canceled", canceled is a2a:Task
                && canceled.status.state == a2a:TASK_STATE_CANCELED, canceled is a2a:Error ? canceled.message() : "");
    } else {
        expect("a foreign task paused in AUTH_REQUIRED can be canceled", false, show(f3));
    }

    io:println("== B2: the same, over the streaming operation ==");
    stream<a2a:StreamResponse, a2a:Error?>|a2a:Error st = toPy->sendStreamingMessage({
        message: {messageId: "interop-task-auth-required-3", role: a2a:ROLE_USER, parts: [{text: "stream"}]}
    });
    if st is stream<a2a:StreamResponse, a2a:Error?> {
        boolean sawAuth = false;
        int guard = 0;
        while guard < 10 && !sawAuth {
            guard += 1;
            record {|a2a:StreamResponse value;|}|a2a:Error? n = st.next();
            if n is record {|a2a:StreamResponse value;|} {
                a2a:StreamResponse ev = n.value;
                if ev is a2a:TaskStatusUpdateEvent && ev.status.state == a2a:TASK_STATE_AUTH_REQUIRED {
                    sawAuth = true;
                } else if ev is a2a:Task && ev.status.state == a2a:TASK_STATE_AUTH_REQUIRED {
                    sawAuth = true;
                }
            } else {
                break;
            }
        }
        expect("the AUTH_REQUIRED transition arrives as a stream event", sawAuth);
        check st.close();
    } else {
        expect("the AUTH_REQUIRED transition arrives as a stream event", false, st.message());
    }

    io:println("== C1: identity through an agent chain (user -> A -> B) ==");
    a2a:Task|a2a:Message|a2a:Error ch = send(alice, "idp-chain-1");
    if ch is a2a:Task {
        string text = artifactText(ch);
        io:println("  " + text);
        expect("A knows who called it (the user)", text.includes("my caller: " + aliceSub));
        // Not a pass/fail on the library alone: this records what a developer gets today.
        boolean userReachedB = text.includes("downstream saw: " + aliceSub);
        io:println(userReachedB ? "INFO: the user's identity reached agent B"
                : "INFO: agent B saw agent A's own service identity, NOT the user (no delegation)");
    } else {
        expect("the chained call completes", false, show(ch));
    }

    io:println(failures == 0 ? "\nOVERALL: PASS" : string `\nOVERALL: FAIL (${failures})`);
}
