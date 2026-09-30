// Minimal reproduction: a2a-go client's REST error decoding depends on the response Content-Type.
// The server below is a bare net/http handler returning the spec's own 11.6 error body (TASK_NOT_FOUND) for GET /tasks/x;
// the ONLY variable is the Content-Type header.
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2aclient"
)

const body = `{"error":{"code":404,"status":"NOT_FOUND","message":"The specified task ID does not exist or is not accessible","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"TASK_NOT_FOUND","domain":"a2a-protocol.org"}]}}`

func main() {
	for _, ct := range []string{"application/json", "application/json; charset=utf-8", "application/a2a+json", "application/problem+json"} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", ct)
			w.WriteHeader(404)
			fmt.Fprint(w, body)
		}))
		iface := a2a.NewAgentInterface(srv.URL, a2a.TransportProtocolHTTPJSON)
		c, _ := a2aclient.NewFromEndpoints(context.Background(), []*a2a.AgentInterface{iface}, a2aclient.WithDefaultsDisabled(), a2aclient.WithRESTTransport(nil))
		_, err := c.GetTask(context.Background(), &a2a.GetTaskRequest{ID: "x"})
		fmt.Printf("%-36s errors.Is(ErrTaskNotFound)=%-5v err=%v\n", ct, errors.Is(err, a2a.ErrTaskNotFound), err)
		srv.Close()
	}
}
