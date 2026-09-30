// Sixth-language interop rig: the official a2a-dotnet SDK (A2A / A2A.AspNetCore built from main 76de7f3, A2A v1.0), HTTP+JSON only.
//   dotnet DotnetInterop.dll agent  [port]         -> Claude-backed agent (stub if ANTHROPIC_API_KEY is unset)
//   dotnet DotnetInterop.dll client [listener-url] -> drives ballerina/a2a's Listener (interop/bal-listener)
// Agent contract is the same as node-agent/agent.mjs: "slow" / "need input" / "msg:" / anything else.
using A2A;
using A2A.AspNetCore;
using DotnetInterop;

if (args.Length > 0 && args[0] == "client")
{
    return await InteropClient.Run(args.Length > 1 ? args[1] : "http://localhost:9611");
}

int port = args.Length > 1 ? int.Parse(args[1]) : 9806;
string host = Environment.GetEnvironmentVariable("PUBLIC_HOST") ?? "localhost";
var builder = WebApplication.CreateBuilder();
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");
builder.Logging.SetMinimumLevel(LogLevel.Warning);
var card = new AgentCard
{
    Name = ".NET A2A Interop Agent",
    Description = $"a2a-dotnet agent (HTTP+JSON only), {Llm.Mode}",
    Version = "1.0.0",
    SupportedInterfaces = [new AgentInterface { Url = $"http://{host}:{port}", ProtocolBinding = "HTTP+JSON", ProtocolVersion = "1.0" }],
    DefaultInputModes = ["text/plain"],
    DefaultOutputModes = ["text/plain"],
    Capabilities = new AgentCapabilities { Streaming = true, PushNotifications = false },
    Skills = [new AgentSkill { Id = "chat", Name = "Chat", Description = "Answers questions", Tags = ["chat"] }],
};
builder.Services.AddA2AAgent<InteropAgent>(card);
var app = builder.Build();
app.MapHttpA2A(app.Services.GetRequiredService<IA2ARequestHandler>(), "");
app.MapWellKnownAgentCard(card);
Console.WriteLine($"dotnet agent on http://{host}:{port} ({Llm.Mode})");
await app.RunAsync();
return 0;
