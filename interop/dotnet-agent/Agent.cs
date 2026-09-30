using System.Collections.Concurrent;
using A2A;
using Anthropic;
using Anthropic.Models.Messages;
using Message = A2A.Message;
using MessageCreateParams = Anthropic.Models.Messages.MessageCreateParams;

namespace DotnetInterop;

static class Llm
{
    static readonly string? Key = Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY") is { Length: > 0 } k ? k : null;
    static readonly string Model = Environment.GetEnvironmentVariable("CLAUDE_MODEL") ?? "claude-haiku-4-5";
    static readonly AnthropicClient? Client = Key is null ? null : new AnthropicClient();
    public static string Mode => Client is null ? "stub" : $"Claude {Model}";

    public static async Task<string> Answer(string prompt)
    {
        if (Client is null) return $"[stub] echo: {prompt}";
        var msg = await Client.Messages.Create(new MessageCreateParams
        {
            Model = Model,
            MaxTokens = 200,
            Messages = [new() { Role = Anthropic.Models.Messages.Role.User, Content = prompt }],
        });
        var text = string.Concat(msg.Content.Select(b => b.TryPickText(out var t) ? t.Text : ""));
        return $"[claude] {text}";
    }
}

sealed class InteropAgent : IAgentHandler
{
    static readonly ConcurrentDictionary<string, bool> Cancelled = new();

    static Message AgentMsg(string text, string taskId, string contextId) => new()
    {
        Role = A2A.Role.Agent, MessageId = Guid.NewGuid().ToString("N"), TaskId = taskId, ContextId = contextId,
        Parts = [Part.FromText(text)],
    };

    public async Task ExecuteAsync(RequestContext context, AgentEventQueue eventQueue, CancellationToken ct)
    {
        string text = string.Concat(context.Message.Parts.Select(p => p.Text ?? ""));
        if (text.StartsWith("msg:"))
        {
            await new MessageResponder(eventQueue, context.ContextId).ReplyAsync(await Llm.Answer(text[4..]), cancellationToken: ct);
            return;
        }
        var updater = new TaskUpdater(eventQueue, context.TaskId, context.ContextId);
        if (!context.IsContinuation) await updater.SubmitAsync(cancellationToken: ct);
        if (text.Contains("need input") && !context.IsContinuation)
        {
            await updater.RequireInputAsync(AgentMsg("Which city?", context.TaskId, context.ContextId), cancellationToken: ct);
            return;
        }
        await updater.StartWorkAsync(AgentMsg("Working", context.TaskId, context.ContextId), cancellationToken: ct);
        if (text.StartsWith("slow"))
        {
            for (int i = 0; i < 16; i++)
            {
                await Task.Delay(500, CancellationToken.None);
                if (ct.IsCancellationRequested || Cancelled.TryRemove(context.TaskId, out _)) return;
            }
        }
        string reply = await Llm.Answer(text);
        await updater.AddArtifactAsync([Part.FromText(reply)], cancellationToken: ct);
        await updater.CompleteAsync(cancellationToken: ct);
    }

    public async Task CancelAsync(RequestContext context, AgentEventQueue eventQueue, CancellationToken ct)
    {
        Cancelled[context.TaskId] = true;
        await new TaskUpdater(eventQueue, context.TaskId, context.ContextId).CancelAsync(cancellationToken: ct);
    }
}
