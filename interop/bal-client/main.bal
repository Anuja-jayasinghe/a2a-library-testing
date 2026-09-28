import ballerina/a2a;
import ballerina/io;

public function main() returns error? {
    string url = "http://localhost:9700";

    io:println("== I1: resolve card ==");
    a2a:AgentCard card = check a2a:resolveAgentCard(url);
    io:println("name: ", card.name, " | streaming: ", card.capabilities.streaming);

    a2a:HttpClient c = check new (card);

    io:println("== I2: blocking send -> direct Message ==");
    a2a:Task|a2a:Message|a2a:Error r1 = c->sendMessage({
        message: {messageId: "interop-message-response-1", role: a2a:ROLE_USER, parts: [{text: "hi"}]}
    });
    if r1 is a2a:Message {
        io:println("got Message: ", (<a2a:Part>r1.parts[0])?.text);
    } else {
        io:println("UNEXPECTED: ", (r1 is error) ? r1.message() : "not a Message");
    }

    io:println("== I3: blocking send -> completed Task with artifact ==");
    a2a:Task|a2a:Message|a2a:Error r2 = c->sendMessage({
        message: {messageId: "interop-default-1", role: a2a:ROLE_USER, parts: [{text: "Paris"}]}
    });
    if r2 is a2a:Task {
        io:println("task state: ", r2.status.state, " | artifact: ",
            r2.artifacts is a2a:Artifact[] && (<a2a:Artifact[]>r2.artifacts).length() > 0
                ? (<a2a:Part>(<a2a:Artifact[]>r2.artifacts)[0].parts[0])?.text : "NONE");
    } else {
        io:println("UNEXPECTED: ", (r2 is error) ? r2.message() : "not a Task");
    }

    io:println("== I6: cancel a completed task -> TaskNotCancelableError ==");
    a2a:Task|a2a:Message|a2a:Error r3 = c->sendMessage({
        message: {messageId: "interop-task-immediate-complete-1", role: a2a:ROLE_USER, parts: [{text: "x"}]}
    });
    if r3 is a2a:Task {
        a2a:Task|a2a:Error canceled = c->cancelTask({id: r3.id});
        io:println("cancel result: ", canceled is a2a:TaskNotCancelableError ? "TaskNotCancelableError (correct)" : (canceled is error ? canceled.message() : "unexpectedly succeeded"));
    }

    io:println("== I7: getTask on unknown id -> TaskNotFoundError ==");
    a2a:Task|a2a:Error r4 = c->getTask({id: "no-such-task-ever"});
    io:println(r4 is a2a:TaskNotFoundError ? "TaskNotFoundError (correct)" : (r4 is error ? r4.message() : "unexpectedly succeeded"));

    io:println("== I11: raw bytes part ==");
    a2a:Task|a2a:Message|a2a:Error r5 = c->sendMessage({
        message: {messageId: "interop-raw-1", role: a2a:ROLE_USER, parts: [{raw: "hello-bytes".toBytes()}]}
    });
    if r5 is a2a:Task {
        io:println("artifact: ", (<a2a:Part>(<a2a:Artifact[]>r5.artifacts)[0].parts[0])?.text);
    } else {
        io:println("UNEXPECTED: ", (r5 is error) ? r5.message() : "not a Task");
    }

    io:println("== auth-error mapping stays sane against a foreign server: fetch a card at a closed port ==");
    a2a:AgentCard|a2a:Error bad = a2a:resolveAgentCard("http://localhost:1");
    io:println(bad is a2a:Error ? "Error, as expected: " + bad.message() : "UNEXPECTED SUCCESS");
}
