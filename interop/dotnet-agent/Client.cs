using A2A;

namespace DotnetInterop;

// Real a2a-dotnet client (A2AClientFactory, HTTP+JSON preferred) -> ballerina/a2a Listener (interop/bal-listener).
// Same scenario set as rust-agent/src/client.rs.
static class InteropClient
{
    static int failures;

    static void Expect(string name, bool ok, object? detail = null)
    {
        if (!ok) failures++;
        Console.WriteLine($"{(ok ? "PASS" : "FAIL")}: {name}{(ok || detail is null ? "" : " -- " + detail)}");
    }

    static SendMessageRequest User(string id, string text, string? taskId = null, string? contextId = null,
                                   SendMessageConfiguration? cfg = null) => new()
    {
        Message = new Message { Role = Role.User, MessageId = id, TaskId = taskId, ContextId = contextId, Parts = [Part.FromText(text)] },
        Configuration = cfg,
    };

    static string ArtText(AgentTask t) => string.Concat((t.Artifacts ?? []).SelectMany(a => a.Parts).Select(p => p.Text ?? ""));

    static async Task<object> Try<T>(Func<Task<T>> f)
    {
        try { return (await f())!; }
        catch (A2AException e) { return e; }
        catch (Exception e) { return e; }
    }

    static string Show(object o) => o is A2AException e ? $"A2AException({e.ErrorCode}): {e.Message}" : o is Exception x ? $"{x.GetType().Name}: {x.Message}" : o.ToString() ?? "";

    public static async Task<int> Run(string baseUrl)
    {
        Console.WriteLine("== I1: card + negotiation ==");
        var card = await new A2ACardResolver(new Uri(baseUrl)).GetAgentCardAsync();
        Expect("card resolved", card.Name == "Ballerina A2A Interop Listener", card.Name);
        IA2AClient c = A2AClientFactory.Create(card, options: new A2AClientOptions { PreferredBindings = ["HTTP+JSON"] });
        Expect("factory picked the HTTP+JSON client", c is A2AHttpJsonClient, c.GetType().Name);

        Console.WriteLine("== I3: blocking send ==");
        var r1 = await Try(() => c.SendMessageAsync(User("d-1", "what is 2+2?")));
        var task = (r1 as SendMessageResponse)?.Task;
        Expect("completed Task with artifact", task?.Status.State == TaskState.Completed && ArtText(task) == "echo: what is 2+2?", Show(r1));
        if (task is null) return 1;

        Console.WriteLine("== I8: streaming ==");
        var kinds = new List<string>();
        TaskState? last = null;
        try
        {
            await foreach (var ev in c.SendStreamingMessageAsync(User("d-2", "stream me")))
            {
                if (ev.Task is not null) kinds.Add("task");
                else if (ev.Message is not null) kinds.Add("message");
                else if (ev.ArtifactUpdate is not null) kinds.Add("artifact");
                else if (ev.StatusUpdate is not null) { kinds.Add("status"); last = ev.StatusUpdate.Status.State; }
            }
        }
        catch (Exception e) { Expect("stream had no error", false, Show(e)); }
        Expect("stream: Task first, artifact, ends with COMPLETED, then EOF",
               kinds.FirstOrDefault() == "task" && kinds.Contains("artifact") && last == TaskState.Completed, string.Join(",", kinds));

        Console.WriteLine("== I10: multi-turn ==");
        var t1 = (await Try(() => c.SendMessageAsync(User("interop-task-input-required-d1", "plan a trip")))) as SendMessageResponse;
        Expect("first turn INPUT_REQUIRED", t1?.Task?.Status.State == TaskState.InputRequired, t1?.Task?.Status.State);
        if (t1?.Task is { } it)
        {
            var t2 = await Try(() => c.SendMessageAsync(User("interop-continue-d1", "Paris", it.Id, it.ContextId)));
            var tt = (t2 as SendMessageResponse)?.Task;
            Expect("continuation COMPLETED on same task id", tt?.Id == it.Id && tt?.Status.State == TaskState.Completed, Show(t2));
        }

        Console.WriteLine("== I4 + I9: returnImmediately, then subscribe ==");
        var t3 = ((await Try(() => c.SendMessageAsync(User("interop-task-paced-d1", "pace", cfg: new() { ReturnImmediately = true })))) as SendMessageResponse)?.Task;
        Expect("non-terminal immediately", t3 is not null && t3.Status.State != TaskState.Completed, t3?.Status.State);
        bool done = false;
        if (t3 is not null)
        {
            try
            {
                await foreach (var ev in c.SubscribeToTaskAsync(new SubscribeToTaskRequest { Id = t3.Id }))
                    if (ev.StatusUpdate?.Status.State == TaskState.Completed || ev.Task?.Status.State == TaskState.Completed) done = true;
            }
            catch (Exception e) { Console.WriteLine("  subscribe error: " + Show(e)); }
        }
        Expect("subscribe observed COMPLETED and stream ended", done);

        Console.WriteLine("== I6: cancel a RUNNING task ==");
        var t4 = ((await Try(() => c.SendMessageAsync(User("interop-task-paced-d2", "pace", cfg: new() { ReturnImmediately = true })))) as SendMessageResponse)?.Task;
        if (t4 is not null)
        {
            var cx = await Try(() => c.CancelTaskAsync(new CancelTaskRequest { Id = t4.Id }));
            Expect("cancel running task -> CANCELED", (cx as AgentTask)?.Status.State == TaskState.Canceled, Show(cx));
        }

        Console.WriteLine("== I6/I7: typed errors ==");
        var e1 = await Try(() => c.CancelTaskAsync(new CancelTaskRequest { Id = task.Id }));
        Expect("cancel completed -> TaskNotCancelable", (e1 as A2AException)?.ErrorCode == A2AErrorCode.TaskNotCancelable, Show(e1));
        var e2 = await Try(() => c.GetTaskAsync(new GetTaskRequest { Id = "no-such-task" }));
        Expect("unknown task -> TaskNotFound", (e2 as A2AException)?.ErrorCode == A2AErrorCode.TaskNotFound, Show(e2));
        object e3;
        try
        {
            await foreach (var _ in c.SubscribeToTaskAsync(new SubscribeToTaskRequest { Id = task.Id })) { }
            e3 = "stream ended without error";
        }
        catch (Exception e) { e3 = e; }
        Expect("subscribe to finished task -> UnsupportedOperation (spec 3.1.6)", (e3 as A2AException)?.ErrorCode == A2AErrorCode.UnsupportedOperation, Show(e3));

        Console.WriteLine("== getTask / historyLength ==");
        var g = await Try(() => c.GetTaskAsync(new GetTaskRequest { Id = task.Id }));
        Expect("getTask on the real id", (g as AgentTask)?.Id == task.Id, Show(g));
        var g0 = await Try(() => c.GetTaskAsync(new GetTaskRequest { Id = task.Id, HistoryLength = 0 }));
        Expect("getTask historyLength=0 -> no history", g0 is AgentTask gt && (gt.History?.Count ?? 0) == 0, Show(g0));
        var h = ((await Try(() => c.SendMessageAsync(User("d-h0", "hist", cfg: new() { HistoryLength = 0 })))) as SendMessageResponse)?.Task;
        Expect("send historyLength=0 -> no history", h is not null && (h.History?.Count ?? 0) == 0, h?.History?.Count);

        Console.WriteLine("== I5: ListTasks + filters ==");
        var l1 = await Try(() => c.ListTasksAsync(new ListTasksRequest { PageSize = 2 }));
        Expect("pageSize honoured", (l1 as ListTasksResponse)?.Tasks.Count == 2, Show(l1));
        if (l1 is ListTasksResponse p1)
        {
            var l2 = await Try(() => c.ListTasksAsync(new ListTasksRequest { PageSize = 2, PageToken = p1.NextPageToken }));
            Expect("second page via pageToken differs", l2 is ListTasksResponse p2 && p2.Tasks.Count > 0 && p2.Tasks[0].Id != p1.Tasks[0].Id, Show(l2));
        }
        var l3 = await Try(() => c.ListTasksAsync(new ListTasksRequest { HistoryLength = 0 }));
        Expect("historyLength=0 -> no history on any task", l3 is ListTasksResponse r3 && r3.Tasks.Count > 0 && r3.Tasks.All(t => (t.History?.Count ?? 0) == 0), Show(l3));
        var l4 = await Try(() => c.ListTasksAsync(new ListTasksRequest { Status = TaskState.Canceled }));
        Expect("status filter CANCELED", l4 is ListTasksResponse r4 && r4.Tasks.Count > 0 && r4.Tasks.All(t => t.Status.State == TaskState.Canceled), Show(l4));
        var l5 = await Try(() => c.ListTasksAsync(new ListTasksRequest { StatusTimestampAfter = new DateTimeOffset(2999, 1, 1, 0, 0, 0, TimeSpan.Zero) }));
        Expect("statusTimestampAfter (future) -> none", l5 is ListTasksResponse r5 && r5.Tasks.Count == 0, Show(l5) + $" count={(l5 as ListTasksResponse)?.Tasks.Count}");
        var l6 = await Try(() => c.ListTasksAsync(new ListTasksRequest { PageSize = 0 }));
        Expect("pageSize=0 -> InvalidParams", (l6 as A2AException)?.ErrorCode == A2AErrorCode.InvalidParams, Show(l6));

        Console.WriteLine("== I12: push config CRUD ==");
        var pc = await Try(() => c.CreateTaskPushNotificationConfigAsync(new TaskPushNotificationConfig { TaskId = task.Id, Id = "cfg1", Url = "http://localhost:19876/hook", Token = "tok" }));
        Expect("create push config keeps id", (pc as TaskPushNotificationConfig)?.Id == "cfg1", Show(pc));
        var pg = await Try(() => c.GetTaskPushNotificationConfigAsync(new GetTaskPushNotificationConfigRequest { TaskId = task.Id, Id = "cfg1" }));
        Expect("get push config", (pg as TaskPushNotificationConfig)?.Url == "http://localhost:19876/hook", Show(pg));
        var pl = await Try(() => c.ListTaskPushNotificationConfigsAsync(new ListTaskPushNotificationConfigsRequest { TaskId = task.Id }));
        Expect("list push configs", (pl as ListTaskPushNotificationConfigsResponse)?.Configs?.Count == 1, Show(pl));
        var pd = await Try(async () => { await c.DeleteTaskPushNotificationConfigAsync(new DeleteTaskPushNotificationConfigRequest { TaskId = task.Id, Id = "cfg1" }); return "ok"; });
        Expect("delete push config", pd is "ok", Show(pd));

        Console.WriteLine(failures == 0 ? "OVERALL: PASS" : $"OVERALL: FAIL ({failures})");
        return failures == 0 ? 0 : 1;
    }
}
