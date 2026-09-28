// The production-shaped auth flow, end to end, from this library's client:
//   client -> issuer's /token (OAuth2 client_credentials) -> RS256 JWT
//   client -> listener with `Authorization: Bearer <jwt>`
//   listener -> issuer's /jwks.json, validates signature/iss/aud/exp/scope
// The client's token handling is ballerina/http + ballerina/oauth2 (clientConfig.auth);
// nothing here mints or attaches a token by hand.

import ballerina/a2a;
import ballerina/http;
import ballerina/io;
import ballerina/lang.runtime;

configurable string providerUrl = "http://localhost:9800";
configurable string agentUrl = "http://localhost:9613";

int failures = 0;

function expect(string label, boolean ok, string detail = "") {
    io:println(ok ? "PASS: " : "FAIL: ", label, ok || detail == "" ? "" : " -- " + detail);
    if !ok {
        failures += 1;
    }
}

function issued() returns int|error {
    http:Client p = check new (providerUrl, httpVersion = http:HTTP_1_1);
    json stats = check p->get("/admin/stats");
    return check (check stats.issued).ensureType(int);
}

function clientFor(string id, string secret, string scope) returns a2a:HttpClient|error {
    // Nothing but the documented OAuth2 grant config: the client obtains, caches and
    // refreshes the token itself (ballerina/http + ballerina/oauth2).
    return new (agentUrl, clientConfig = {
        auth: {tokenUrl: providerUrl + "/token", clientId: id, clientSecret: secret, scopes: [scope]}
    });
}

function send(a2a:HttpClient c, string id) returns a2a:Task|a2a:Message|a2a:Error {
    return c->sendMessage({message: {messageId: id, role: a2a:ROLE_USER, parts: [{text: "hi"}]}});
}

public function main() returns error? {
    io:println("== token acquired by the client itself (OAuth2 client_credentials), validated via JWKS ==");
    int before = check issued();
    a2a:HttpClient c = check clientFor("agent-a", "agent-a-secret", "a2a:invoke");
    // Constructing the client already fetched a token: ballerina/oauth2 acquires eagerly at init.
    int afterConstruct = check issued();
    expect("constructing the client fetched a token from the issuer up front", afterConstruct > before,
            string `before=${before} after=${afterConstruct}`);
    a2a:Task|a2a:Message|a2a:Error r1 = send(c, "oidc-1");
    expect("authenticated send succeeds with a token the client obtained", r1 is a2a:Task
            && r1.status.state == a2a:TASK_STATE_COMPLETED, r1 is a2a:Error ? r1.message() : "");
    int afterFirst = check issued();
    expect("the first call needed no further token", afterFirst == afterConstruct,
            string `issued ${afterConstruct} -> ${afterFirst}`);

    a2a:Task|a2a:Message|a2a:Error r2 = send(c, "oidc-2");
    int afterSecond = check issued();
    expect("a second call reuses the cached token (no new token issued)", r2 is a2a:Task && afterSecond == afterFirst,
            string `issued ${afterFirst} -> ${afterSecond}`);

    io:println("== expiry: the provider's tokens live 4 seconds ==");
    runtime:sleep(5.5);
    a2a:Task|a2a:Message|a2a:Error r3 = send(c, "oidc-3");
    int afterExpiry = check issued();
    expect("after expiry the client fetches a fresh token and the call still succeeds", r3 is a2a:Task
            && afterExpiry > afterSecond, r3 is a2a:Error ? r3.message() : string `issued ${afterSecond} -> ${afterExpiry}`);

    io:println("== scope: a token with only a2a:read against a listener that requires a2a:invoke ==");
    a2a:HttpClient reader = check clientFor("reader", "reader-secret", "a2a:read");
    a2a:Task|a2a:Message|a2a:Error r4 = send(reader, "oidc-4");
    expect("insufficient scope is an AuthorizationError (403)", r4 is a2a:AuthorizationError,
            r4 is a2a:Error ? r4.message() : "unexpectedly succeeded");

    io:println("== wrong client secret: the issuer refuses the token request ==");
    // ballerina/oauth2 fetches the first token while the client is being constructed. `trap`
    // is only here so a panic cannot end this run; the assertion is the documented contract:
    // a2a:HttpClient's init returns a typed a2a:Error, it does not panic.
    a2a:HttpClient|error bad = trap clientFor("agent-a", "not-the-secret", "a2a:invoke");
    expect("a refused token request is a returned a2a:Error (HttpClient's documented contract)", bad is a2a:Error,
            bad is error ? "it escaped as a PANIC: " + bad.message().substring(0, 50) : "constructed successfully");
    a2a:HttpClient|error unreachable = trap new (agentUrl, clientConfig = {
        auth: {tokenUrl: "http://localhost:1/token", clientId: "agent-a", clientSecret: "x"}});
    expect("an unreachable token endpoint is a returned a2a:Error too", unreachable is a2a:Error,
            unreachable is error ? "it escaped as a PANIC" : "constructed successfully");

    io:println("== no credential at all ==");
    a2a:HttpClient anon = check new (agentUrl);
    a2a:Task|a2a:Message|a2a:Error r6 = send(anon, "oidc-6");
    expect("AuthenticationError (401)", r6 is a2a:AuthenticationError, r6 is a2a:Error ? r6.message() : "succeeded");

    io:println("== key rotation: the issuer starts signing with a new key ==");
    http:Client admin = check new (providerUrl, httpVersion = http:HTTP_1_1);
    json rotated = check admin->post("/admin/rotate", {});
    io:println("  issuer now signs with ", (check rotated.kid).toString());
    runtime:sleep(5.5); // let the client's old (old-key) token expire so a new one is needed
    a2a:Task|a2a:Message|a2a:Error r7 = send(c, "oidc-7");
    expect("a token signed with the NEW key is accepted (the listener picks up the rotated JWKS)", r7 is a2a:Task,
            r7 is a2a:Error ? r7.message() : "");

    io:println(failures == 0 ? "\nOVERALL: PASS" : string `\nOVERALL: FAIL (${failures})`);
}
