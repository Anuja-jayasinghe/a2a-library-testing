// Gives the client-side ai:Agent real A2A operations as tools, built
// against ballerina/a2a's current Client API directly -- no hand-rolled
// HTTP calls to the remote agent or to Anthropic anywhere in this demo.
//
// Scoped to the one remote agent this demo talks to (unlike
// module-ballerina-ai's own A2aToolKit prototype, which is a multi-agent
// registry) and written against this session's current a2a:Client request-
// record shapes.
//
// "Last known task id" is tracked here, not left for the model to
// remember and pass back explicitly -- a model that mistypes or forgets a
// task id is a whole class of failure this demo doesn't need to risk. The
// continuation/status/cancel/webhook tools below all default to it when
// the model omits taskId, so a natural, unprompted "continue that" or
// "check on it" from the model just works.

import ballerina/a2a;
import ballerina/ai;
import ballerina/uuid;

configurable string agentUrl = "http://localhost:9095";

isolated string? lastTaskId = ();

isolated function rememberTaskId(string? taskId) {
    if taskId is string {
        lock {
            lastTaskId = taskId;
        }
    }
}

isolated function lastKnownTaskId() returns string? {
    lock {
        return lastTaskId;
    }
}

# Wraps a2a:HttpClient calls to the Trip Planner agent as tools an
# ai:Agent can call directly.
public isolated class TripPlannerToolKit {
    *ai:BaseToolKit;

    private final a2a:HttpClient agentClient;
    private final ai:ToolConfig[] & readonly tools;

    public isolated function init() returns error? {
        self.agentClient = check new (agentUrl);
        ai:ToolConfig[] configs = [
            {
                name: "sendToTripPlanner",
                description: "Sends a NEW request to the Trip Planner agent, starting a fresh task. "
                    + "Use this to begin a new trip-planning request, never to follow up on one "
                    + "already in progress -- use continueTripPlannerTask for that.",
                parameters: schemaOf({"message": stringParam("The request, in natural language.")}, ["message"]),
                caller: self.sendToTripPlanner
            },
            {
                name: "startTripPlannerTaskWithoutWaiting",
                description: "Like sendToTripPlanner, but returns immediately once the task exists, "
                    + "before the agent has actually finished working on it. Use this specifically "
                    + "when you intend to cancel the task right afterward with cancelTripPlannerTask "
                    + "-- sendToTripPlanner would otherwise already be finished by the time you tried "
                    + "to cancel it.",
                parameters: schemaOf({"message": stringParam("The request, in natural language.")}, ["message"]),
                caller: self.startTripPlannerTaskWithoutWaiting
            },
            {
                name: "continueTripPlannerTask",
                description: "Sends a follow-up message that continues the most recent trip-planning "
                    + "task -- for example, answering a question the agent just asked. Do not pass a "
                    + "task id; the most recent task is used automatically.",
                parameters: schemaOf({"message": stringParam("The follow-up, in natural language.")}, ["message"]),
                caller: self.continueTripPlannerTask
            },
            {
                name: "streamFromTripPlanner",
                description: "Like sendToTripPlanner, but returns the agent's live progress updates as "
                    + "well as its final answer. Prefer this when you want to observe the agent working, "
                    + "not just its final reply.",
                parameters: schemaOf({"message": stringParam("The request, in natural language.")}, ["message"]),
                caller: self.streamFromTripPlanner
            },
            {
                name: "getTripPlannerTaskStatus",
                description: "Fetches the current state of the most recent trip-planning task. Always "
                    + "call this fresh when asked about a task's status -- never answer from memory.",
                parameters: (),
                caller: self.getTripPlannerTaskStatus
            },
            {
                name: "cancelTripPlannerTask",
                description: "Cancels the most recent trip-planning task, if it is still in progress.",
                parameters: (),
                caller: self.cancelTripPlannerTask
            },
            {
                name: "listTripPlannerTasks",
                description: "Lists every task the Trip Planner agent currently knows about.",
                parameters: (),
                caller: self.listTripPlannerTasks
            },
            {
                name: "registerTripPlannerWebhook",
                description: "Registers this client's own local webhook to be notified when the most "
                    + "recent trip-planning task changes state.",
                parameters: (),
                caller: self.registerTripPlannerWebhook
            }
        ];
        self.tools = configs.cloneReadOnly();
    }

    public isolated function getTools() returns ai:ToolConfig[] => self.tools;

    private isolated function sendToTripPlanner(string message) returns string|error {
        a2a:Task|a2a:Message result = check self.agentClient->sendMessage({
            message: {messageId: newMessageId(), role: a2a:ROLE_USER, parts: [{text: message}]}
        });
        return self.describeResult(result);
    }

    private isolated function startTripPlannerTaskWithoutWaiting(string message) returns string|error {
        a2a:Task|a2a:Message result = check self.agentClient->sendMessage({
            message: {messageId: newMessageId(), role: a2a:ROLE_USER, parts: [{text: message}]},
            configuration: {returnImmediately: true}
        });
        return self.describeResult(result);
    }

    private isolated function continueTripPlannerTask(string message) returns string|error {
        string? taskId = lastKnownTaskId();
        if taskId is () {
            return "There is no task to continue yet -- call sendToTripPlanner first.";
        }
        a2a:Task|a2a:Message result = check self.agentClient->sendMessage({
            message: {messageId: newMessageId(), role: a2a:ROLE_USER, taskId, parts: [{text: message}]}
        });
        return self.describeResult(result);
    }

    private isolated function streamFromTripPlanner(string message) returns string|error {
        stream<a2a:StreamResponse, a2a:Error?> events = check self.agentClient->sendStreamingMessage({
            message: {messageId: newMessageId(), role: a2a:ROLE_USER, parts: [{text: message}]}
        });
        return collectStream(events);
    }

    private isolated function getTripPlannerTaskStatus() returns string|error {
        string? taskId = lastKnownTaskId();
        if taskId is () {
            return "There is no task yet -- call sendToTripPlanner first.";
        }
        a2a:Task task = check self.agentClient->getTask({id: taskId});
        return summarize(task);
    }

    private isolated function cancelTripPlannerTask() returns string|error {
        string? taskId = lastKnownTaskId();
        if taskId is () {
            return "There is no task yet -- call sendToTripPlanner first.";
        }
        a2a:Task task = check self.agentClient->cancelTask({id: taskId});
        return summarize(task);
    }

    private isolated function listTripPlannerTasks() returns string|error {
        a2a:ListTasksResponse result = check self.agentClient->listTasks();
        if result.tasks.length() == 0 {
            return "No tasks found.";
        }
        string[] lines = from a2a:Task task in result.tasks select summarize(task);
        return string:'join("\n", ...lines);
    }

    private isolated function registerTripPlannerWebhook() returns string|error {
        string? taskId = lastKnownTaskId();
        if taskId is () {
            return "There is no task yet -- call sendToTripPlanner first.";
        }
        string webhookUrl = string `http://localhost:${webhookPort}/webhook/receiver`;
        a2a:TaskPushNotificationConfig created =
            check self.agentClient->createTaskPushNotificationConfig({taskId, url: webhookUrl});
        string configId = created?.id ?: "(no id)";
        return string `Registered push notification config ${configId} for task ${taskId}.`;
    }

    private isolated function describeResult(a2a:Task|a2a:Message result) returns string {
        // Task and Message are both open records, so the compiler cannot
        // narrow `result` by elimination -- an explicit cast is required
        // for the Task arm, same as ballerina/a2a's own code does for the
        // identical reason.
        if result is a2a:Message {
            rememberTaskId(());
            return string `Direct reply (no task created): ${partsText(result.parts)}`;
        }
        a2a:Task task = <a2a:Task>result;
        rememberTaskId(task.id);
        return summarize(task);
    }
}

isolated function newMessageId() returns string {
    return uuid:createType4AsString();
}

# Collects a live stream to completion. A tool call returns once, so the
# value of streaming here is capturing intermediate progress rather than
# only the final state.
#
# + events - The live stream to drain
# + return - Every event, one per line, or an error if the stream itself failed
isolated function collectStream(stream<a2a:StreamResponse, a2a:Error?> events) returns string|error {
    string[] lines = [];
    while true {
        record {|a2a:StreamResponse value;|}|a2a:Error? next = events.next();
        if next is () {
            break;
        }
        if next is a2a:Error {
            lines.push(string `(stream ended with an error: ${next.message()})`);
            break;
        }
        a2a:StreamResponse event = next.value;
        if event is a2a:Task {
            rememberTaskId(event.id);
            lines.push(summarize(event));
        } else if event is a2a:Message {
            lines.push(partsText(event.parts));
        } else if event is a2a:TaskStatusUpdateEvent {
            lines.push(string `[${event.status.state}]`);
        } else {
            // event is now known (by elimination) to be a
            // TaskArtifactUpdateEvent, but StreamResponse's arms are all
            // open records, so the compiler can't prove that from a
            // sequence of `is` checks -- an explicit cast is required.
            a2a:TaskArtifactUpdateEvent artifactEvent = <a2a:TaskArtifactUpdateEvent>event;
            lines.push(string `artifact: ${partsText(artifactEvent.artifact.parts)}`);
        }
    }
    check events.close();
    return lines.length() == 0 ? "(no events received)" : string:'join("\n", ...lines);
}

isolated function partsText(a2a:Part[] parts) returns string {
    string[] texts = [];
    foreach a2a:Part part in parts {
        string? text = part?.text;
        if text is string {
            texts.push(text);
        }
    }
    return string:'join(" ", ...texts);
}

isolated function taskText(a2a:Task task) returns string {
    a2a:Artifact[] artifacts = task.artifacts ?: [];
    if artifacts.length() > 0 {
        return partsText(artifacts[artifacts.length() - 1].parts);
    }
    a2a:Message? statusMessage = task.status?.message;
    if statusMessage is a2a:Message {
        return partsText(statusMessage.parts);
    }
    return string `(no textual response -- task state: ${task.status.state})`;
}

isolated function summarize(a2a:Task task) returns string =>
    string `[${task.status.state}] ${taskText(task)} (task id: ${task.id})`;

isolated function schemaOf(map<json> properties, string[] required) returns map<json> =>
    {"type": "object", "properties": properties, "required": required};

isolated function stringParam(string description) returns map<json> =>
    {"type": "string", "description": description};
