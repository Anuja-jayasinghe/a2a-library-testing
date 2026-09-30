// Real a2a-rs client (a2a-client-lf 0.2.5, HTTP+JSON only) -> ballerina/a2a Listener (interop/bal-listener).
// Same scenario set as go-agent/client, plus getTask on the real id, get push config, cancel of a RUNNING task,
// historyLength on send, and ListTasks paging with pageToken.
use std::sync::Arc;

use a2a::*;
use a2a_client::agent_card::AgentCardResolver;
use a2a_client::rest::RestTransportFactory;
use a2a_client::A2AClientFactory;
use futures::StreamExt;

static mut FAILURES: u32 = 0;

fn expect(name: &str, ok: bool, detail: impl std::fmt::Debug) {
    if ok {
        println!("PASS: {name}");
    } else {
        unsafe { FAILURES += 1 };
        println!("FAIL: {name} -- {detail:?}");
    }
}

fn user(id: &str, text: &str, task: Option<&str>, ctx: Option<&str>) -> SendMessageRequest {
    let mut m = Message::new(Role::User, vec![Part::text(text)]);
    m.message_id = id.into();
    m.task_id = task.map(Into::into);
    m.context_id = ctx.map(Into::into);
    SendMessageRequest { message: m, configuration: None, metadata: None, tenant: None }
}

fn with_config(mut r: SendMessageRequest, c: SendMessageConfiguration) -> SendMessageRequest {
    r.configuration = Some(c);
    r
}

fn cfg() -> SendMessageConfiguration {
    SendMessageConfiguration { accepted_output_modes: None, task_push_notification_config: None, history_length: None, return_immediately: None }
}

fn art_text(t: &Task) -> String {
    t.artifacts.iter().flatten().flat_map(|a| a.parts.iter()).filter_map(|p| match &p.content {
        PartContent::Text(s) => Some(s.clone()),
        _ => None,
    }).collect()
}

fn as_task(r: Result<SendMessageResponse, A2AError>) -> Result<Task, String> {
    match r {
        Ok(SendMessageResponse::Task(t)) => Ok(t),
        Ok(SendMessageResponse::Message(_)) => Err("got a Message".into()),
        Err(e) => Err(format!("{} ({})", e.message, e.code)),
    }
}

fn list_req() -> ListTasksRequest {
    ListTasksRequest { context_id: None, status: None, page_size: None, page_token: None, history_length: None,
                       status_timestamp_after: None, include_artifacts: None, tenant: None }
}

#[tokio::main]
async fn main() {
    let base = std::env::args().nth(1).unwrap_or_else(|| "http://localhost:9611".into());
    let push_url = std::env::args().nth(2).unwrap_or_else(|| "http://localhost:19875/hook".into());

    println!("== I1: card + REST-only negotiation ==");
    let card = match AgentCardResolver::new(None).resolve(&base).await {
        Ok(c) => c,
        Err(e) => { println!("FAIL: resolve card: {e:?}"); std::process::exit(1) }
    };
    expect("card resolved", card.name == "Ballerina A2A Interop Listener", &card.name);
    println!("  interface: {:?}", card.supported_interfaces);
    let factory = A2AClientFactory::builder().no_defaults()
        .register(Arc::new(RestTransportFactory::new(None)))
        .preferred_bindings(vec![TRANSPORT_PROTOCOL_HTTP_JSON.to_string()]).build();
    let c = match factory.create_from_card(&card).await {
        Ok(c) => c,
        Err(e) => { println!("FAIL: client: {e:?}"); std::process::exit(1) }
    };

    println!("== I3: blocking send ==");
    let task = as_task(c.send_message(&user("r-1", "what is 2+2?", None, None)).await);
    expect("completed Task with artifact",
           matches!(&task, Ok(t) if t.status.state == TaskState::Completed && art_text(t) == "echo: what is 2+2?"), &task);
    let task = task.unwrap_or_else(|e| { println!("cannot continue: {e}"); std::process::exit(1) });

    println!("== I8: streaming ==");
    let mut kinds = vec![];
    let mut last_state = None;
    match c.send_streaming_message(&user("r-2", "stream me", None, None)).await {
        Ok(mut s) => while let Some(ev) = s.next().await {
            match ev {
                Ok(StreamResponse::Task(_)) => kinds.push("task"),
                Ok(StreamResponse::Message(_)) => kinds.push("message"),
                Ok(StreamResponse::ArtifactUpdate(_)) => kinds.push("artifact"),
                Ok(StreamResponse::StatusUpdate(u)) => { kinds.push("status"); last_state = Some(u.status.state) }
                Err(e) => { expect("stream had no error", false, e); break }
            }
        },
        Err(e) => expect("stream opened", false, e),
    }
    expect("stream: Task first, artifact, ends with COMPLETED, then EOF",
           kinds.first() == Some(&"task") && kinds.contains(&"artifact") && last_state == Some(TaskState::Completed), &kinds);

    println!("== I10: multi-turn ==");
    let t1 = as_task(c.send_message(&user("interop-task-input-required-r1", "plan a trip", None, None)).await);
    expect("first turn INPUT_REQUIRED", matches!(&t1, Ok(t) if t.status.state == TaskState::InputRequired), &t1);
    if let Ok(t1) = &t1 {
        let t2 = as_task(c.send_message(&user("interop-continue-r1", "Paris", Some(&t1.id), Some(&t1.context_id))).await);
        expect("continuation COMPLETED on same task id",
               matches!(&t2, Ok(t) if t.id == t1.id && t.status.state == TaskState::Completed), &t2);
    }

    println!("== I4 + I9: returnImmediately, then subscribe ==");
    let t3 = as_task(c.send_message(&with_config(user("interop-task-paced-r1", "pace", None, None),
        SendMessageConfiguration { return_immediately: Some(true), ..cfg() })).await);
    expect("non-terminal immediately", matches!(&t3, Ok(t) if t.status.state != TaskState::Completed), &t3);
    let mut done = false;
    if let Ok(t3) = &t3 {
        match c.subscribe_to_task(&SubscribeToTaskRequest { id: t3.id.clone(), tenant: None }).await {
            Ok(mut s) => while let Some(ev) = s.next().await {
                match ev {
                    Ok(StreamResponse::StatusUpdate(u)) if u.status.state == TaskState::Completed => done = true,
                    Ok(StreamResponse::Task(t)) if t.status.state == TaskState::Completed => done = true,
                    Err(e) => { println!("  subscribe error: {e:?}"); break }
                    _ => {}
                }
            },
            Err(e) => println!("  subscribe failed: {e:?}"),
        }
    }
    expect("subscribe observed COMPLETED and stream ended", done, ());

    println!("== I6: cancel a RUNNING task ==");
    let t4 = as_task(c.send_message(&with_config(user("interop-task-paced-r2", "pace", None, None),
        SendMessageConfiguration { return_immediately: Some(true), ..cfg() })).await);
    if let Ok(t4) = &t4 {
        let cx = c.cancel_task(&CancelTaskRequest { id: t4.id.clone(), metadata: None, tenant: None }).await;
        expect("cancel running task -> CANCELED", matches!(&cx, Ok(t) if t.status.state == TaskState::Canceled), &cx);
    } else {
        expect("returnImmediately returned a Task", false, &t4);
    }

    println!("== I6/I7: typed errors ==");
    let e1 = c.cancel_task(&CancelTaskRequest { id: task.id.clone(), metadata: None, tenant: None }).await;
    expect("cancel completed -> TASK_NOT_CANCELABLE", matches!(&e1, Err(e) if e.code == error_code::TASK_NOT_CANCELABLE), &e1);
    let e2 = c.get_task(&GetTaskRequest { id: "no-such-task".into(), history_length: None, tenant: None }).await;
    expect("unknown task -> TASK_NOT_FOUND", matches!(&e2, Err(e) if e.code == error_code::TASK_NOT_FOUND), &e2);
    let e3 = c.subscribe_to_task(&SubscribeToTaskRequest { id: task.id.clone(), tenant: None }).await;
    let e3 = match e3 {
        Ok(mut s) => s.next().await.map(|r| r.map(|_| "event")).unwrap_or(Ok("empty stream")),
        Err(e) => Err(e),
    };
    expect("subscribe to finished task -> UNSUPPORTED_OPERATION (spec 3.1.6)",
           matches!(&e3, Err(e) if e.code == error_code::UNSUPPORTED_OPERATION), &e3);

    println!("== getTask ==");
    let g = c.get_task(&GetTaskRequest { id: task.id.clone(), history_length: None, tenant: None }).await;
    expect("getTask on the real id", matches!(&g, Ok(t) if t.id == task.id && t.status.state == TaskState::Completed), &g);
    let g0 = c.get_task(&GetTaskRequest { id: task.id.clone(), history_length: Some(0), tenant: None }).await;
    expect("getTask historyLength=0 -> no history", matches!(&g0, Ok(t) if t.history.as_ref().is_none_or(|h| h.is_empty())), &g0);

    println!("== send with historyLength=0 ==");
    let h = as_task(c.send_message(&with_config(user("r-h0", "hist", None, None),
        SendMessageConfiguration { history_length: Some(0), ..cfg() })).await);
    expect("send historyLength=0 -> no history", matches!(&h, Ok(t) if t.history.as_ref().is_none_or(|h| h.is_empty())), &h);

    println!("== I5: ListTasks + filters ==");
    let l1 = c.list_tasks(&ListTasksRequest { page_size: Some(2), ..list_req() }).await;
    expect("pageSize honoured", matches!(&l1, Ok(r) if r.tasks.len() == 2), l1.as_ref().map(|r| (r.tasks.len(), r.next_page_token.clone())));
    if let Ok(r1) = &l1 {
        let l2 = c.list_tasks(&ListTasksRequest { page_size: Some(2), page_token: Some(r1.next_page_token.clone()), ..list_req() }).await;
        expect("second page via pageToken differs", matches!(&l2, Ok(r) if !r.tasks.is_empty() && r.tasks[0].id != r1.tasks[0].id), &l2.as_ref().map(|r| r.tasks.len()));
    }
    let all = c.list_tasks(&list_req()).await;
    expect("list all (last page has no more)", all.is_ok(), all.as_ref().map(|r| (r.tasks.len(), r.next_page_token.clone(), r.page_size, r.total_size)));
    let l3 = c.list_tasks(&ListTasksRequest { history_length: Some(0), ..list_req() }).await;
    expect("historyLength=0 -> no history on any task",
           matches!(&l3, Ok(r) if !r.tasks.is_empty() && r.tasks.iter().all(|t| t.history.as_ref().is_none_or(|h| h.is_empty()))), l3.is_ok());
    let l4 = c.list_tasks(&ListTasksRequest { status: Some(TaskState::Canceled), ..list_req() }).await;
    expect("status filter CANCELED", matches!(&l4, Ok(r) if !r.tasks.is_empty() && r.tasks.iter().all(|t| t.status.state == TaskState::Canceled)), &l4.as_ref().map(|r| r.tasks.len()));
    let fut = chrono::DateTime::parse_from_rfc3339("2999-01-01T00:00:00Z").unwrap().to_utc();
    let l5 = c.list_tasks(&ListTasksRequest { status_timestamp_after: Some(fut), ..list_req() }).await;
    expect("statusTimestampAfter (future) -> none", matches!(&l5, Ok(r) if r.tasks.is_empty()), &l5);
    let past = chrono::DateTime::parse_from_rfc3339("2000-01-01T00:00:00Z").unwrap().to_utc();
    let l6 = c.list_tasks(&ListTasksRequest { status_timestamp_after: Some(past), ..list_req() }).await;
    expect("statusTimestampAfter (past) -> all", matches!(&l6, Ok(r) if r.tasks.len() >= 5), &l6.as_ref().map(|r| r.tasks.len()));
    let l7 = c.list_tasks(&ListTasksRequest { page_size: Some(0), ..list_req() }).await;
    expect("pageSize=0 -> INVALID_PARAMS", matches!(&l7, Err(e) if e.code == error_code::INVALID_PARAMS), &l7.as_ref().map(|r| r.tasks.len()));

    println!("== I12: push config CRUD ==");
    let mk = |id: &str| TaskPushNotificationConfig { url: push_url.clone(), id: Some(id.into()), task_id: task.id.clone(),
                                                     token: Some("tok".into()), authentication: None, tenant: None };
    let pc = c.create_push_config(&mk("cfg1")).await;
    expect("create push config keeps id", matches!(&pc, Ok(p) if p.id.as_deref() == Some("cfg1")), &pc);
    let pg = c.get_push_config(&GetTaskPushNotificationConfigRequest { task_id: task.id.clone(), id: "cfg1".into(), tenant: None }).await;
    expect("get push config", matches!(&pg, Ok(p) if p.url == push_url), &pg);
    let pl = c.list_push_configs(&ListTaskPushNotificationConfigsRequest { task_id: task.id.clone(), page_size: None, page_token: None, tenant: None }).await;
    expect("list push configs", matches!(&pl, Ok(r) if r.configs.len() == 1), &pl);
    let pd = c.delete_push_config(&DeleteTaskPushNotificationConfigRequest { task_id: task.id.clone(), id: "cfg1".into(), tenant: None }).await;
    let pl2 = c.list_push_configs(&ListTaskPushNotificationConfigsRequest { task_id: task.id.clone(), page_size: None, page_token: None, tenant: None }).await;
    expect("delete push config", pd.is_ok() && matches!(&pl2, Ok(r) if r.configs.is_empty()), (&pd, &pl2));

    println!("== I12b: push delivery (checked by the runner) ==");
    let pt = as_task(c.send_message(&with_config(user("interop-task-paced-r3", "push me", None, None),
        SendMessageConfiguration { return_immediately: Some(true),
            task_push_notification_config: Some(TaskPushNotificationConfig { url: push_url.clone(), id: None, task_id: String::new(),
                token: Some("tok2".into()), authentication: None, tenant: None }), ..cfg() })).await);
    expect("send with inline push config", pt.is_ok(), &pt);
    if let Ok(t) = &pt { println!("PUSH_TASK_ID={}", t.id) }

    let f = unsafe { FAILURES };
    if f > 0 { println!("OVERALL: FAIL ({f})"); std::process::exit(1) }
    println!("OVERALL: PASS");
}
