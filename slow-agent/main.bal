// A deterministic (no LLM) agent whose tasks genuinely run for over a minute,
// for exercising streaming, subscribe, push notifications and cancellation on
// long-running work. The Claude-backed agents answer in a second or two, so
// they cannot show any of that.
//
// What a task does depends on the request text:
//   contains "silent"  a long silent stretch: one "working" update, then
//                      nothing for silentSeconds, then the result. Probes
//                      idle timeouts on a live stream.
//   contains "input"   first message: pauses at INPUT_REQUIRED. The
//                      continuation then runs the steady job below.
//   anything else      steady progress: a "working" update every stepSeconds
//                      for `steps` steps (default 7 x 10s = 70s), then the
//                      result.

import ballerina/a2a;
import ballerina/http;
import ballerina/io;
import ballerina/lang.runtime;
import ballerina/log;
import ballerina/uuid;

configurable int agentPort = 9098;
configurable int steps = 7;
configurable decimal stepSeconds = 10;
configurable decimal silentSeconds = 70;
// The HTTP listener's own idle timeout (Ballerina's default is 60s). It only
// takes effect through a pre-built http:Listener: a2a:Listener ignores the
// http:ListenerConfiguration fields when given a bare port.
configurable decimal listenerTimeout = 60;

final http:Listener slowHttp = check new (agentPort, timeout = listenerTimeout);

listener a2a:Listener slowListener = new (slowHttp, agentCard = {
    name: "Slow Worker",
    description: "Deterministic agent whose tasks run for over a minute",
    version: "1.0.0",
    skills: [
        {
            id: "slow-work",
            name: "Slow work",
            description: "Runs for over a minute, reporting progress",
            tags: ["test"],
            examples: ["steady", "silent", "input"]
        }
    ],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
}, pushSender = new a2a:HttpPushNotificationSender({validateUrl: false}));

public function main() returns error? {
    check slowListener.attach(new SlowWorkerService());
    check slowListener.'start();
    io:println(string `Slow Worker listening on http://localhost:${agentPort}`);
}

isolated service class SlowWorkerService {
    *a2a:Service;

    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        string text = extractText(context.message);
        string taskId = updater.getTaskId();
        boolean continuation = context.message.taskId is string;
        log:printInfo("slow-agent: received", taskId = taskId, continuation = continuation, request = text);

        if !continuation && text.includes("input") {
            check updater->requireInput(agentMessage("Say go to start the long job."));
            log:printInfo("slow-agent: paused for input", taskId = taskId);
            return;
        }

        check updater->working(agentMessage("starting"));
        if text.includes("silent") {
            runtime:sleep(silentSeconds);
        } else {
            foreach int i in 1 ... steps {
                runtime:sleep(stepSeconds);
                a2a:Error? progress = updater->working(agentMessage(string `step ${i} of ${steps}`));
                if progress is a2a:Error {
                    log:printInfo("slow-agent: stopping, the task is no longer running",
                            taskId = taskId, reason = progress.message());
                    return;
                }
            }
        }

        a2a:Error? done = updater->addArtifact([{text: "long job finished"}]);
        if done is a2a:Error {
            log:printInfo("slow-agent: finished but the task was already closed",
                    taskId = taskId, reason = done.message());
            return;
        }
        check updater->complete();
        log:printInfo("slow-agent: completed", taskId = taskId);
        return;
    }
}

isolated function extractText(a2a:Message message) returns string {
    string text = "";
    foreach a2a:Part part in message.parts {
        string? t = part?.text;
        if t is string {
            text += t;
        }
    }
    return text;
}

isolated function agentMessage(string text) returns a2a:Message => {
    messageId: uuid:createType4AsString(),
    role: a2a:ROLE_AGENT,
    parts: [{text}]
};
