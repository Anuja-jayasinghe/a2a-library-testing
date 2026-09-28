import ballerina/a2a;
import ballerina/io;
import ballerina/jwt;

const string SHARED_SECRET = "interop-auth-shared-secret-0123456789";

function mint(string subject) returns string|error {
    return jwt:issue({
        issuer: "interop", audience: "a2a", username: subject, expTime: 300,
        signatureConfig: {algorithm: jwt:HS256, config: SHARED_SECRET}
    });
}

public function main() returns error? {
    string url = "http://localhost:9701";

    io:println("== X-A3: discover the card, no credential yet ==");
    a2a:AgentCard card = check a2a:resolveAgentCard(url);
    io:println("schemes: ", card.securitySchemes is map<a2a:SecurityScheme> ? (<map<a2a:SecurityScheme>>card.securitySchemes).keys() : []);

    io:println("== X-A3: no credential configured -> rejected ==");
    a2a:HttpClient anon = check new (card);
    a2a:Task|a2a:Message|a2a:Error r1 = anon->sendMessage({
        message: {messageId: "m-anon", role: a2a:ROLE_USER, parts: [{text: "hi"}]}
    });
    io:println(r1 is a2a:AuthenticationError ? "AuthenticationError (correct)" : (r1 is error ? "WRONG TYPE: " + r1.message() : "unexpectedly succeeded"));

    io:println("== X-A3: credential resolved by scheme name, from the card alone ==");
    string token = check mint("alice");
    a2a:InMemoryCredentialStore store = new ({"bearerAuth": token});
    a2a:HttpClient authed = check new (card, credentials = store);
    a2a:Task|a2a:Message|a2a:Error r2 = authed->sendMessage({
        message: {messageId: "m-authed", role: a2a:ROLE_USER, parts: [{text: "hi"}]}
    });
    if r2 is a2a:Task {
        io:println("task state: ", r2.status.state);
    } else {
        io:println("UNEXPECTED: ", (r2 is error) ? r2.message() : "not a Task");
    }
}
