// Real a2a-go v2.6.0 client (HTTP+JSON only) -> ballerina/a2a Listener (interop/bal-listener).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2aclient"
	"github.com/a2aproject/a2a-go/v2/a2aclient/agentcard"
)

var failures int

func expect(name string, ok bool, detail ...any) {
	tag := "PASS"
	if !ok {
		tag, failures = "FAIL", failures+1
	}
	fmt.Printf("%s: %s", tag, name)
	if len(detail) > 0 {
		fmt.Printf(" -- %v", detail...)
	}
	fmt.Println()
}

func user(id, text string, taskID a2a.TaskID, ctxID string) *a2a.Message {
	m := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart(text))
	m.ID, m.TaskID, m.ContextID = id, taskID, ctxID
	return m
}

func artText(t *a2a.Task) string {
	s := ""
	for _, a := range t.Artifacts {
		for _, p := range a.Parts {
			s += p.Text()
		}
	}
	return s
}

func main() {
	base := "http://localhost:9611"
	if len(os.Args) > 1 {
		base = os.Args[1]
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	fmt.Println("== I1: card + REST-only negotiation ==")
	card, err := agentcard.DefaultResolver.Resolve(ctx, base)
	if err != nil {
		fmt.Println("FAIL: resolve card:", err)
		os.Exit(1)
	}
	expect("card resolved", card.Name == "Ballerina A2A Interop Listener", card.Name)
	c, err := a2aclient.NewFromCard(ctx, card, a2aclient.WithDefaultsDisabled(), a2aclient.WithRESTTransport(nil))
	if err != nil {
		fmt.Println("FAIL: client:", err)
		os.Exit(1)
	}

	fmt.Println("== I3: blocking send ==")
	res, err := c.SendMessage(ctx, &a2a.SendMessageRequest{Message: user("n-1", "what is 2+2?", "", "")})
	task, _ := res.(*a2a.Task)
	expect("completed Task with artifact", err == nil && task != nil && task.Status.State == a2a.TaskStateCompleted && artText(task) == "echo: what is 2+2?", err, task)

	fmt.Println("== I8: streaming ==")
	var kinds []string
	var last a2a.Event
	for ev, err := range c.SendStreamingMessage(ctx, &a2a.SendMessageRequest{Message: user("n-2", "stream me", "", "")}) {
		if err != nil {
			expect("stream had no error", false, err)
			break
		}
		kinds = append(kinds, fmt.Sprintf("%T", ev))
		last = ev
	}
	su, ok := last.(*a2a.TaskStatusUpdateEvent)
	expect("stream: Task first, ends with COMPLETED, then EOF", len(kinds) >= 3 && kinds[0] == "*a2a.Task" && ok && su.Status.State == a2a.TaskStateCompleted, kinds)

	fmt.Println("== I10: multi-turn ==")
	r1, err := c.SendMessage(ctx, &a2a.SendMessageRequest{Message: user("interop-task-input-required-1", "plan a trip", "", "")})
	t1, _ := r1.(*a2a.Task)
	expect("first turn INPUT_REQUIRED", err == nil && t1 != nil && t1.Status.State == a2a.TaskStateInputRequired, err)
	if t1 != nil {
		r2, err := c.SendMessage(ctx, &a2a.SendMessageRequest{Message: user("interop-continue-1", "Paris", t1.ID, t1.ContextID)})
		t2, _ := r2.(*a2a.Task)
		expect("continuation COMPLETED on same task id", err == nil && t2 != nil && t2.ID == t1.ID && t2.Status.State == a2a.TaskStateCompleted, err)
	}

	fmt.Println("== I4 + I9: returnImmediately, then subscribe ==")
	r3, err := c.SendMessage(ctx, &a2a.SendMessageRequest{Message: user("interop-task-paced-1", "pace", "", ""), Config: &a2a.SendMessageConfig{ReturnImmediately: true}})
	t3, _ := r3.(*a2a.Task)
	expect("non-terminal immediately", err == nil && t3 != nil && t3.Status.State != a2a.TaskStateCompleted, err)
	done := false
	if t3 != nil {
		for ev, err := range c.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: t3.ID}) {
			if err != nil {
				break
			}
			if u, ok := ev.(*a2a.TaskStatusUpdateEvent); ok && u.Status.State == a2a.TaskStateCompleted {
				done = true
			}
		}
	}
	expect("subscribe observed COMPLETED and stream ended", done)

	fmt.Println("== I6/I7: typed errors ==")
	_, err = c.CancelTask(ctx, &a2a.CancelTaskRequest{ID: task.ID})
	expect("cancel completed -> ErrTaskNotCancelable", errors.Is(err, a2a.ErrTaskNotCancelable), err)
	_, err = c.GetTask(ctx, &a2a.GetTaskRequest{ID: "no-such-task"})
	expect("unknown task -> ErrTaskNotFound", errors.Is(err, a2a.ErrTaskNotFound), err)

	fmt.Println("== I5: ListTasks + filters ==")
	l1, err := c.ListTasks(ctx, &a2a.ListTasksRequest{PageSize: 2})
	expect("pageSize honoured", err == nil && len(l1.Tasks) == 2, err)
	zero := 0
	l2, err := c.ListTasks(ctx, &a2a.ListTasksRequest{HistoryLength: &zero})
	noHist := err == nil && len(l2.Tasks) > 0
	if noHist {
		for _, t := range l2.Tasks {
			noHist = noHist && len(t.History) == 0
		}
	}
	expect("historyLength=0 -> no history on any task", noHist, err)
	future := time.Date(2999, 1, 1, 0, 0, 0, 0, time.UTC)
	l3, err := c.ListTasks(ctx, &a2a.ListTasksRequest{StatusTimestampAfter: &future})
	expect("statusTimestampAfter (future) -> none", err == nil && len(l3.Tasks) == 0, err)
	past := time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)
	l4, err := c.ListTasks(ctx, &a2a.ListTasksRequest{StatusTimestampAfter: &past})
	expect("statusTimestampAfter (past) -> all", err == nil && len(l4.Tasks) >= 3, err)
	g0, err := c.GetTask(ctx, &a2a.GetTaskRequest{ID: task.ID, HistoryLength: &zero})
	expect("getTask historyLength=0", err == nil && len(g0.History) == 0, err)

	fmt.Println("== I12: push config CRUD + delivery ==")
	os.Remove("/tmp/go_client_push.json")
	pc, err := c.CreateTaskPushConfig(ctx, &a2a.PushConfig{TaskID: task.ID, ID: "cfg1", URL: "http://localhost:19873/hook", Token: "tok"})
	expect("create push config", err == nil && pc != nil && pc.ID == "cfg1", err)
	lst, err := c.ListTaskPushConfigs(ctx, &a2a.ListTaskPushConfigRequest{TaskID: task.ID})
	expect("list push configs", err == nil && len(lst) == 1, err)
	err = c.DeleteTaskPushConfig(ctx, &a2a.DeleteTaskPushConfigRequest{TaskID: task.ID, ID: "cfg1"})
	lst, _ = c.ListTaskPushConfigs(ctx, &a2a.ListTaskPushConfigRequest{TaskID: task.ID})
	expect("delete push config", err == nil && len(lst) == 0, err)
	_, err = c.SendMessage(ctx, &a2a.SendMessageRequest{Message: user("interop-task-paced-2", "push me", "", ""),
		Config: &a2a.SendMessageConfig{ReturnImmediately: true, PushConfig: &a2a.PushConfig{URL: "http://localhost:19873/hook", Token: "tok2"}}})
	var body []byte
	for i := 0; i < 20 && body == nil; i++ {
		time.Sleep(500 * time.Millisecond)
		body, _ = os.ReadFile("/tmp/go_client_push.json")
	}
	var env map[string]json.RawMessage
	_ = json.Unmarshal(body, &env)
	_, hasTask := env["task"]
	_, hasStatus := env["statusUpdate"]
	expect("webhook delivered as a StreamResponse envelope", err == nil && (hasTask || hasStatus), string(body[:min(len(body), 60)]))

	if failures > 0 {
		fmt.Printf("OVERALL: FAIL (%d)\n", failures)
		os.Exit(1)
	}
	fmt.Println("OVERALL: PASS")
}
