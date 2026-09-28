// This client against a TLS listener (9614) and a mutual-TLS listener (9615).
import ballerina/a2a;
import ballerina/http;
import ballerina/io;

configurable string certDir = "/tmp/interop-certs";
int failures = 0;

function expect(string label, boolean ok, string detail = "") {
    io:println(ok ? "PASS: " : "FAIL: ", label, ok || detail == "" ? "" : " -- " + detail);
    if !ok {
        failures += 1;
    }
}

function trusting() returns http:ClientConfiguration => {secureSocket: {cert: certDir + "/ca.pem"}};

function withClientCert() returns http:ClientConfiguration => {secureSocket: {
    cert: certDir + "/ca.pem", key: {certFile: certDir + "/client.pem", keyFile: certDir + "/client.key"}}};

function send(a2a:HttpClient c) returns a2a:Task|a2a:Message|a2a:Error {
    return c->sendMessage({message: {messageId: "tls-1", role: a2a:ROLE_USER, parts: [{text: "hi"}]}});
}

function scheme(a2a:AgentCard card) returns string {
    string u = card.supportedInterfaces.length() > 0 ? card.supportedInterfaces[0].url : "";
    return u.startsWith("https://") ? "https" : u.startsWith("http://") ? "http" : u;
}

public function main() returns error? {
    string tls = "https://localhost:9614";
    io:println("== TLS: the CA is trusted ==");
    a2a:AgentCard|a2a:Error card = a2a:resolveAgentCard(tls, clientConfig = trusting());
    expect("the card is fetched over HTTPS", card is a2a:AgentCard, card is a2a:Error ? card.message() : "");
    if card is a2a:AgentCard {
        expect("the card advertises an https:// interface URL (spec 7.1)", scheme(card) == "https",
                "advertises " + card.supportedInterfaces[0].url);
    }
    a2a:HttpClient|a2a:Error viaUrl = new (tls, clientConfig = trusting());
    if viaUrl is a2a:HttpClient {
        a2a:Task|a2a:Message|a2a:Error r = send(viaUrl);
        expect("a client built from the https URL can send (it follows the card's URL)", r is a2a:Task,
                r is a2a:Error ? r.message().substring(0, 70) : "");
    } else {
        expect("a client can be built from the https URL", false, viaUrl.message());
    }
    if card is a2a:AgentCard {
        // Workaround: correct the scheme ourselves, proving the TLS transport itself is fine.
        card.supportedInterfaces[0].url = tls;
        a2a:HttpClient fixed = check new (card, clientConfig = trusting());
        a2a:Task|a2a:Message|a2a:Error r = send(fixed);
        expect("with the URL corrected by hand, TLS works end to end", r is a2a:Task, r is a2a:Error ? r.message() : "");
    }

    io:println("== TLS: the CA is NOT trusted ==");
    a2a:AgentCard|a2a:Error untrusted = a2a:resolveAgentCard(tls);
    expect("an untrusted certificate is a returned a2a:Error, not a success or a panic", untrusted is a2a:Error);

    io:println("== mutual TLS (9615) ==");
    string mtls = "https://localhost:9615";
    a2a:AgentCard|a2a:Error noCert = a2a:resolveAgentCard(mtls, clientConfig = trusting());
    expect("no client certificate is refused at the TLS layer", noCert is a2a:Error);
    a2a:AgentCard|a2a:Error withCert = a2a:resolveAgentCard(mtls, clientConfig = withClientCert());
    expect("a valid client certificate is accepted", withCert is a2a:AgentCard, withCert is a2a:Error ? withCert.message() : "");
    if withCert is a2a:AgentCard {
        withCert.supportedInterfaces[0].url = mtls;
        a2a:HttpClient m = check new (withCert, clientConfig = withClientCert());
        a2a:Task|a2a:Message|a2a:Error r = send(m);
        expect("a send over mutual TLS works", r is a2a:Task, r is a2a:Error ? r.message() : "");
    }

    io:println(failures == 0 ? "\nOVERALL: PASS" : string `\nOVERALL: FAIL (${failures})`);
}
