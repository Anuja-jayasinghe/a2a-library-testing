// A minimal webhook receiver standing in for "the client's own server" --
// in a real deployment this would be a separate service entirely; here
// it's just enough to prove push-notification delivery actually happens.

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/log;

configurable int webhookPort = 9096;

// map<json>?, not json? -- json itself already includes `()` as one of
// its members, so json? can never distinguish "no payload received yet"
// from "received a literal JSON null"; map<json>? can, since a JSON
// object is never nil.
isolated map<json>? lastWebhookPayload = ();

listener http:Listener webhookListener = new (webhookPort);

service /webhook on webhookListener {
    isolated resource function post receiver(http:Caller caller, http:Request req) returns error? {
        json payload = check req.getJsonPayload();
        map<json> asMap = check payload.ensureType();
        lock {
            lastWebhookPayload = asMap.clone();
        }
        log:printInfo("webhook received a push notification", payload = payload);
        json response = {};
        check caller->respond(response);
    }
}

isolated function takeLastWebhookPayload() returns map<json>? {
    map<json>? result;
    lock {
        result = lastWebhookPayload.clone();
        lastWebhookPayload = ();
    }
    return result;
}

isolated function waitForWebhookPayload(decimal timeoutSeconds) returns map<json>? {
    decimal waited = 0;
    while waited < timeoutSeconds {
        map<json>? payload = takeLastWebhookPayload();
        if payload is map<json> {
            return payload;
        }
        runtime:sleep(0.2);
        waited += 0.2d;
    }
    return ();
}
