# A2A SDK signatures at a glance

Each pair shows the **user-facing client call** and **server callback** for one
plain text exchange. The snippets focus on the API shape; the linked interop
programs and upstream SDK samples show the complete imports, dependency setup,
agent cards, HTTP hosting, and error handling. All cards used here advertise A2A v1.0. The
interop examples use the HTTP+JSON binding so the languages can talk to one
another. A reply can be a direct `Message` or a `Task`; these servers choose a
direct `Message` to keep the examples small.

| Language | SDK checked here | Full client | Full server |
| --- | --- | --- | --- |
| JavaScript | `@a2a-js/sdk` 1.2.1 | [client.mjs](../interop/node-agent/client.mjs) | [agent.mjs](../interop/node-agent/agent.mjs) |
| Python | `a2a-sdk` 1.1.5 | [driver.py](../interop/python-client/driver.py) | [agent.py](../interop/python-agent/agent.py) |
| Java | `a2a-java` 1.4.1.Final-SNAPSHOT (local checkout) | [StreamDriver.java](../interop/java-client-stream/StreamDriver.java) | [AgentExecutorProducer.java](https://github.com/a2aproject/a2a-java/blob/main/examples/helloworld/server/src/main/java/org/a2aproject/sdk/examples/helloworld/server/AgentExecutorProducer.java) |
| Rust | `a2a-client-lf` 0.2.5 / `a2a-server-lf` 0.4.4 | [client.rs](https://github.com/a2aproject/a2a-rs/blob/main/examples/src/helloworld/client.rs) | [server.rs](https://github.com/a2aproject/a2a-rs/blob/main/examples/src/helloworld/server.rs) |
| Go | `a2a-go/v2` 2.6.0 | [client/main.go](../interop/go-agent/client/main.go) | [agent/main.go](../interop/go-agent/agent/main.go) |
| .NET | `a2a-dotnet` source at `76de7f3` | [MessageBasedCommunicationSample.cs](https://github.com/a2aproject/a2a-dotnet/blob/main/samples/AgentClient/Samples/MessageBasedCommunicationSample.cs) | [EchoAgent.cs](https://github.com/a2aproject/a2a-dotnet/blob/main/samples/AgentServer/EchoAgent.cs) |
| Ballerina | `ballerina/a2a` local 0.1.0 | [bal-client/main.bal](../interop/bal-client/main.bal) | [bal-listener/main.bal](../interop/bal-listener/main.bal) |

`http://localhost:PORT` below means the base URL of a running agent. For a
direct message, print its text parts; a task-producing agent instead returns
a task or task events.

## JavaScript

**Client** — discover the card, then send a user message:

```js
import { randomUUID } from 'node:crypto';
import { Role } from '@a2a-js/sdk';
import { ClientFactory, ClientFactoryOptions, RestTransportFactory } from '@a2a-js/sdk/client';

const options = ClientFactoryOptions.createFrom(ClientFactoryOptions.default, {
  transports: [new RestTransportFactory()], preferredTransports: ['HTTP+JSON'],
});
const client = await new ClientFactory(options).createFromUrl('http://localhost:9800');
const reply = await client.sendMessage({
  message: {
    messageId: randomUUID(), contextId: '', taskId: '', role: Role.ROLE_USER,
    parts: [{ content: { $case: 'text', value: 'Hello' }, metadata: undefined,
      filename: '', mediaType: 'text/plain' }],
    metadata: {}, extensions: [], referenceTaskIds: [],
  },
  tenant: '', configuration: undefined, metadata: {},
});
console.log(reply);
```

**Server** — implement `execute(context, eventBus)` and mount a request handler:

```js
import express from 'express';
import { randomUUID } from 'node:crypto';
import { AGENT_CARD_PATH, Role } from '@a2a-js/sdk';
import { AgentEvent, DefaultRequestHandler, InMemoryTaskStore } from '@a2a-js/sdk/server';
import { agentCardHandler, restHandler, UserBuilder } from '@a2a-js/sdk/server/express';

class HelloExecutor {
  async execute(context, eventBus) {
    eventBus.publish(AgentEvent.message({
      messageId: randomUUID(), contextId: context.contextId, taskId: '',
      role: Role.ROLE_AGENT,
      parts: [{ content: { $case: 'text', value: 'Hello from JS' },
        metadata: undefined, filename: '', mediaType: 'text/plain' }],
      metadata: {}, extensions: [], referenceTaskIds: [],
    }));
  }
  async cancelTask() {}
}

// `card` is an AgentCard advertising http://localhost:9800 as HTTP+JSON.
const handler = new DefaultRequestHandler(card, new InMemoryTaskStore(), new HelloExecutor());
const app = express();
app.use(`/${AGENT_CARD_PATH}`, agentCardHandler({ agentCardProvider: handler }));
app.use('/', restHandler({ requestHandler: handler, userBuilder: UserBuilder.noAuthentication }));
app.listen(9800);
```

## Python

**Client** — configure the binding explicitly; `send_message` yields response
events even for a regular send:

```python
import uuid
import httpx
from a2a.client.card_resolver import A2ACardResolver
from a2a.client.client import ClientConfig
from a2a.client.client_factory import ClientFactory
from a2a.types import Message, Part, Role, SendMessageRequest
from a2a.utils.constants import TransportProtocol

async with httpx.AsyncClient() as http:
    card = await A2ACardResolver(http, "http://localhost:9700").get_agent_card()
    client = ClientFactory(ClientConfig(
        httpx_client=http,
        supported_protocol_bindings=[TransportProtocol.HTTP_JSON],
    )).create(card)
    request = SendMessageRequest(message=Message(
        message_id=str(uuid.uuid4()), role=Role.ROLE_USER,
        parts=[Part(text="Hello")],
    ))
    async for response in client.send_message(request):
        print(response)
```

**Server** — implement `AgentExecutor.execute` and enqueue a reply. The
`DefaultRequestHandlerV2` connects that executor to HTTP routes:

```python
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events.event_queue_v2 import EventQueue
from a2a.server.request_handlers.default_request_handler_v2 import DefaultRequestHandlerV2
from a2a.server.tasks.inmemory_task_store import InMemoryTaskStore
from a2a.types import Message, Part, Role

class HelloExecutor(AgentExecutor):
    async def execute(self, context: RequestContext, queue: EventQueue) -> None:
        await queue.enqueue_event(Message(
            message_id="reply-1", role=Role.ROLE_AGENT,
            parts=[Part(text="Hello from Python")],
        ))

    async def cancel(self, context: RequestContext, queue: EventQueue) -> None:
        pass

# `card` is an AgentCard; pass `handler` to create_rest_routes(handler).
handler = DefaultRequestHandlerV2(
    agent_executor=HelloExecutor(), task_store=InMemoryTaskStore(), agent_card=card,
)
```

## Java

**Client** — register a consumer, select the REST transport, then send:

```java
AgentCard card = A2ACardResolver.builder().baseUrl("http://localhost:9999")
        .build().getAgentCard();
Client client = Client.builder(card)
        .addConsumers(List.of((event, agentCard) -> System.out.println(event)))
        .withTransport(RestTransport.class, new RestTransportConfig())
        .build();
client.sendMessage(A2A.toUserMessage("Hello"));
```

**Server** — the Quarkus SDK discovers an `AgentExecutor` producer and a
`@PublicAgentCard` producer. The core callback is:

```java
@ApplicationScoped
public class HelloExecutorProducer {
    @Produces
    public AgentExecutor agentExecutor() {
        return new AgentExecutor() {
            @Override
            public void execute(RequestContext context, AgentEmitter emitter) throws A2AError {
                emitter.sendMessage("Hello from Java");
            }

            @Override
            public void cancel(RequestContext context, AgentEmitter emitter) throws A2AError {
                throw new UnsupportedOperationError();
            }
        };
    }
}
```

The [card producer](https://github.com/a2aproject/a2a-java/blob/main/examples/helloworld/server/src/main/java/org/a2aproject/sdk/examples/helloworld/server/AgentCardProducer.java)
declares the URL, skill, and `HTTP+JSON` interface; the example server chooses
that binding with `-Dquarkus.agentcard.protocol=HTTP+JSON`.

## Rust

**Client** — resolve the card, choose a REST transport, and send a typed request:

```rust
let card = AgentCardResolver::new(None).resolve("http://localhost:9804").await?;
let factory = A2AClientFactory::builder().no_defaults()
    .register(Arc::new(RestTransportFactory::new(None)))
    .preferred_bindings(vec![TRANSPORT_PROTOCOL_HTTP_JSON.to_string()])
    .build();
let client = factory.create_from_card(&card).await?;
let message = Message::new(Role::User, vec![Part::text("Hello")]);
let reply = client.send_message(&SendMessageRequest {
    message, configuration: None, metadata: None, tenant: None,
}).await?;
println!("{reply:?}");
```

**Server** — implement `AgentExecutor`; its callback returns a stream of
`StreamResponse` values. Then mount the SDK router:

```rust
struct HelloExecutor;

impl AgentExecutor for HelloExecutor {
    fn execute(&self, context: ExecutorContext)
        -> BoxStream<'static, Result<StreamResponse, A2AError>> {
        let reply = Message {
            role: Role::Agent, message_id: new_message_id(),
            context_id: Some(context.task_info().1), task_id: None,
            parts: vec![Part::text("Hello from Rust")],
            metadata: None, extensions: None, reference_task_ids: None,
        };
        Box::pin(futures::stream::once(async move { Ok(StreamResponse::Message(reply)) }))
    }

    fn cancel(&self, _context: ExecutorContext)
        -> BoxStream<'static, Result<StreamResponse, A2AError>> {
        Box::pin(futures::stream::empty())
    }
}

let handler = Arc::new(DefaultRequestHandler::new(HelloExecutor, InMemoryTaskStore::new()));
let app = axum::Router::new()
    .nest("/rest", a2a_server::rest::rest_router(handler))
    .merge(a2a_server::agent_card::agent_card_router(Arc::new(StaticAgentCard::new(card))));
```

The Rust card's interface URL must point to `/rest`, matching the mounted
router.

## Go

**Client** — resolve the card and send one request:

```go
ctx := context.Background()
card, err := agentcard.DefaultResolver.Resolve(ctx, "http://localhost:9802")
if err != nil { log.Fatal(err) }
client, err := a2aclient.NewFromCard(ctx, card,
    a2aclient.WithDefaultsDisabled(), a2aclient.WithRESTTransport(nil))
if err != nil { log.Fatal(err) }
message := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart("Hello"))
reply, err := client.SendMessage(ctx, &a2a.SendMessageRequest{Message: message})
if err != nil { log.Fatal(err) }
fmt.Printf("%+v\n", reply)
```

**Server** — implement `Execute`/`Cancel` and register the SDK handlers:

```go
type helloExecutor struct{}

func (helloExecutor) Execute(ctx context.Context, ec *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
    return func(yield func(a2a.Event, error) bool) {
        yield(a2a.NewMessage(a2a.MessageRoleAgent, a2a.NewTextPart("Hello from Go")), nil)
    }
}
func (helloExecutor) Cancel(ctx context.Context, ec *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
    return func(yield func(a2a.Event, error) bool) {}
}

handler := a2asrv.NewHandler(helloExecutor{})
mux := http.NewServeMux()
mux.Handle("/", a2asrv.NewRESTHandler(handler))
mux.Handle(a2asrv.WellKnownAgentCardPath, a2asrv.NewStaticAgentCardHandler(card))
```

## .NET (C#)

**Client** — resolve the card, choose HTTP+JSON, and send:

```csharp
var card = await new A2ACardResolver(new Uri("http://localhost:9806")).GetAgentCardAsync();
IA2AClient client = A2AClientFactory.Create(card,
    options: new A2AClientOptions { PreferredBindings = ["HTTP+JSON"] });
var reply = await client.SendMessageAsync(new SendMessageRequest {
    Message = new Message {
        Role = Role.User, MessageId = Guid.NewGuid().ToString("N"),
        Parts = [Part.FromText("Hello")]
    }
});
Console.WriteLine(reply);
```

**Server** — implement `IAgentHandler` and register it with ASP.NET Core:

```csharp
sealed class HelloAgent : IAgentHandler
{
    public async Task ExecuteAsync(RequestContext context, AgentEventQueue queue, CancellationToken ct)
    {
        await new MessageResponder(queue, context.ContextId)
            .ReplyAsync("Hello from .NET", cancellationToken: ct);
    }

    public Task CancelAsync(RequestContext context, AgentEventQueue queue, CancellationToken ct)
        => Task.CompletedTask;
}

builder.Services.AddA2AAgent<HelloAgent>(card);
var app = builder.Build();
app.MapHttpA2A(app.Services.GetRequiredService<IA2ARequestHandler>(), "");
app.MapWellKnownAgentCard(card);
await app.RunAsync();
```

This .NET example follows the SDK source used by the interop rig; its API may
differ from the older `1.0.0-preview2` NuGet package.

## Ballerina

**Client** — resolve the card and send a message:

```ballerina
import ballerina/a2a;
import ballerina/io;

public function main() returns error? {
    a2a:AgentCard card = check a2a:resolveAgentCard("http://localhost:9611");
    a2a:HttpClient client = check new (card);
    a2a:Task|a2a:Message reply = check client->sendMessage({
        message: {messageId: "hello-1", role: a2a:ROLE_USER, parts: [{text: "Hello"}]}
    });
    io:println(reply);
}
```

**Server** — implement `a2a:Service.onMessage`, then attach it to a listener:

```ballerina
import ballerina/a2a;

isolated service class HelloAgent {
    *a2a:Service;

    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        return {messageId: "reply-1", role: a2a:ROLE_AGENT,
            parts: [{text: "Hello from Ballerina"}]};
    }
}

a2a:AgentCard card = {
    name: "Hello Agent", description: "Replies to a greeting", version: "1.0.0",
    skills: [{id: "hello", name: "Hello", description: "Replies to a greeting", tags: ["hello"]}],
    defaultInputModes: ["text"], defaultOutputModes: ["text"],
    capabilities: {}, supportedInterfaces: []
};
final a2a:DefaultHandler handler = new (card);
listener a2a:HttpListener agent = new (9611, handler);

public function main() returns error? {
    check agent.attach(new HelloAgent());
}
```
