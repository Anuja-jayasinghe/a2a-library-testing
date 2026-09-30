// A fourth-language A2A agent for interop testing: a2a-go v2.6.0 (A2A v1.0), HTTP+JSON/REST only.
// Claude-backed when ANTHROPIC_API_KEY is set, otherwise a deterministic stub (the artifact text says which: [claude]/[stub]).
// Same behaviour contract as node-agent/agent.mjs:
//
//	"slow ..." -> WORKING ~8s (cancellable) then COMPLETED;  "need input" -> INPUT_REQUIRED, follow-up completes it;
//	"msg: ..." -> direct Message reply;  anything else -> COMPLETED task with one text artifact.
package main

import (
	"context"
	"flag"
	"fmt"
	"iter"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
	"github.com/a2aproject/a2a-go/v2/a2asrv/push"
	"github.com/anthropics/anthropic-sdk-go"
)

var (
	port  = flag.Int("port", 9802, "port")
	model = "claude-haiku-4-5-20251001"
	llm   *anthropic.Client
)

func answer(ctx context.Context, prompt string) string {
	if llm == nil {
		return "[stub] echo: " + prompt
	}
	r, err := llm.Messages.New(ctx, anthropic.MessageNewParams{
		Model: anthropic.Model(model), MaxTokens: 200,
		Messages: []anthropic.MessageParam{anthropic.NewUserMessage(anthropic.NewTextBlock(prompt))},
	})
	if err != nil {
		return "[claude-error] " + err.Error()
	}
	var sb strings.Builder
	for _, b := range r.Content {
		sb.WriteString(b.Text)
	}
	return "[claude] " + sb.String()
}

func textOf(m *a2a.Message) string {
	var sb strings.Builder
	for _, p := range m.Parts {
		sb.WriteString(p.Text())
	}
	return sb.String()
}

// a2a-go scopes ListTasks to an authenticated owner; with no auth in front of the agent, treat every caller as one user.
type anonymousOwner struct {
	a2asrv.PassthroughCallInterceptor
}

func (anonymousOwner) Before(ctx context.Context, cc *a2asrv.CallContext, _ *a2asrv.Request) (context.Context, any, error) {
	cc.User = a2asrv.NewAuthenticatedUser("interop", nil)
	return ctx, nil, nil
}

type executor struct{}

func (executor) Execute(ctx context.Context, ec *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		text := textOf(ec.Message)
		if strings.HasPrefix(text, "msg:") {
			yield(a2a.NewMessage(a2a.MessageRoleAgent, a2a.NewTextPart(answer(ctx, strings.TrimPrefix(text, "msg:")))), nil)
			return
		}
		if ec.StoredTask == nil {
			if !yield(a2a.NewSubmittedTask(ec, ec.Message), nil) {
				return
			}
		}
		if strings.Contains(text, "need input") && ec.StoredTask == nil {
			yield(a2a.NewStatusUpdateEvent(ec, a2a.TaskStateInputRequired, a2a.NewMessageForTask(a2a.MessageRoleAgent, ec, a2a.NewTextPart("Which city?"))), nil)
			return
		}
		if !yield(a2a.NewStatusUpdateEvent(ec, a2a.TaskStateWorking, nil), nil) {
			return
		}
		if strings.HasPrefix(text, "slow") {
			select { // cancellation arrives through Cancel(); a cancelled execution's ctx is done
			case <-time.After(8 * time.Second):
			case <-ctx.Done():
				return
			}
		}
		if !yield(a2a.NewArtifactEvent(ec, a2a.NewTextPart(answer(ctx, text))), nil) {
			return
		}
		yield(a2a.NewStatusUpdateEvent(ec, a2a.TaskStateCompleted, nil), nil)
	}
}

func (executor) Cancel(ctx context.Context, ec *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		yield(a2a.NewStatusUpdateEvent(ec, a2a.TaskStateCanceled, nil), nil)
	}
}

func main() {
	flag.Parse()
	if os.Getenv("ANTHROPIC_API_KEY") != "" {
		c := anthropic.NewClient()
		llm = &c
	}
	url := fmt.Sprintf("http://localhost:%d", *port)
	if os.Getenv("TRAILING_SLASH") != "0" {
		url += "/"
	}
	card := &a2a.AgentCard{
		Name: "Go A2A Interop Agent", Description: "a2a-go agent (HTTP+JSON only)", Version: "1.0.0",
		SupportedInterfaces: []*a2a.AgentInterface{a2a.NewAgentInterface(url, a2a.TransportProtocolHTTPJSON)},
		DefaultInputModes:   []string{"text"}, DefaultOutputModes: []string{"text"},
		Capabilities: a2a.AgentCapabilities{Streaming: true, PushNotifications: true},
		Skills:       []a2a.AgentSkill{{ID: "chat", Name: "Chat", Description: "Answers questions", Tags: []string{"chat"}}},
	}
	pushStore := push.NewInMemoryStore()
	h := a2asrv.NewHandler(executor{}, a2asrv.WithCallInterceptors(anonymousOwner{}), a2asrv.WithPushNotifications(pushStore, push.NewHTTPPushSender(&push.HTTPSenderConfig{})))
	mux := http.NewServeMux()
	mux.Handle("/", a2asrv.NewRESTHandler(h))
	mux.Handle(a2asrv.WellKnownAgentCardPath, a2asrv.NewStaticAgentCardHandler(card))
	mode := "stub"
	if llm != nil {
		mode = "Claude " + model
	}
	log.Printf("go agent on %s (%s)", url, mode)
	log.Fatal(http.ListenAndServe(fmt.Sprintf(":%d", *port), mux))
}
