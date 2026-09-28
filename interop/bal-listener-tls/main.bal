// A ballerina/a2a listener served over HTTPS (and, with -CmutualTls=true, mutual TLS).
// The certificates come from `interop/make_certs.sh`. The point: does the listener
// pass `secureSocket` through, and does the card it serves point clients at https://?

import ballerina/a2a;
import ballerina/http;
import ballerina/io;

configurable int PORT = 9614;
configurable string certDir = "/tmp/interop-certs";
configurable boolean mutualTls = false;
// Non-empty: what a TLS-terminating proxy would tell clients to use (ListenerConfiguration.publicUrl).
configurable string PUBLIC_URL = "";

isolated service class InteropAgent {
    *a2a:Service;
    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        check updater->working();
        check updater->addArtifact([{text: "secure hello"}], name = "result");
        check updater->complete();
    }
}

a2a:AgentCard card = {
    name: "Ballerina A2A Interop Listener (TLS)",
    description: "Served over HTTPS",
    version: "1.0.0",
    skills: [{id: "interop", name: "Interop", description: "Handles deterministic interop test messages", tags: ["interop"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

http:ListenerSecureSocket tlsConfig = mutualTls
    ? {key: {certFile: certDir + "/server.pem", keyFile: certDir + "/server.p8.key"},
       mutualSsl: {verifyClient: http:REQUIRE, cert: certDir + "/ca.pem"}}
    : {key: {certFile: certDir + "/server.pem", keyFile: certDir + "/server.p8.key"}};

listener a2a:Listener l = new (PORT, agentCard = card, secureSocket = tlsConfig,
    publicUrl = PUBLIC_URL == "" ? () : PUBLIC_URL);

public function main() returns error? {
    check l.attach(new InteropAgent());
    io:println(string `Ballerina interop listener (${mutualTls ? "mutual TLS" : "TLS"}) on https://localhost:${PORT}`);
}
