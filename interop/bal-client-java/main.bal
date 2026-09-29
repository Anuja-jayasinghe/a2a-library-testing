import ballerina/a2a;
import ballerina/io;

public function main() returns error? {
    string url = "http://localhost:9999";

    io:println("== I1: resolve card (real a2a-java reference server) ==");
    a2a:AgentCard card = check a2a:resolveAgentCard(url, clientConfig = {httpVersion: "1.1"});
    io:println("name: ", card.name, " | streaming: ", card.capabilities.streaming);

    a2a:HttpClient c = check new (card, clientConfig = {httpVersion: "1.1"});

    io:println("== I2/I3: blocking send ==");
    a2a:Task|a2a:Message|a2a:Error r1 = c->sendMessage({
        message: {messageId: "m1", role: a2a:ROLE_USER, parts: [{text: "hi"}]}
    });
    if r1 is a2a:Task {
        io:println("task state: ", r1.status.state);
        if r1.artifacts is a2a:Artifact[] {
            foreach a2a:Artifact a in <a2a:Artifact[]>r1.artifacts {
                foreach a2a:Part p in a.parts {
                    io:println("  artifact part: ", p?.text);
                }
            }
        }
    } else if r1 is a2a:Message {
        io:println("got Message: ", (<a2a:Part>r1.parts[0])?.text);
    } else {
        io:println("ERROR: ", (r1 is error) ? r1.message() : "??");
    }

    io:println("== I7: getTask on unknown id ==");
    a2a:Task|a2a:Error r2 = c->getTask({id: "no-such-task-ever"});
    io:println(r2 is a2a:TaskNotFoundError ? "TaskNotFoundError (correct)" : (r2 is error ? r2.message() : "unexpectedly succeeded"));
}
