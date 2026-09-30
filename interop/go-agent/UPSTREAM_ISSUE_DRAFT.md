**Title:** REST client ignores A2A error bodies sent as `application/a2a+json` (returns generic `server error`)

**Version:** a2a-go v2.6.0 (main == v2.6.0 at time of writing)

**What happens.** `internal/rest.FromRESTError` returns `a2a.ErrServerError` unless the response `Content-Type` starts with
`application/json`. A server that follows the HTTP+JSON binding's media type therefore never has its `google.rpc.Status` /
`ErrorInfo` body decoded: `errors.Is(err, a2a.ErrTaskNotFound)` (and every other typed error) is false, and the message and
details are lost.

**Spec.** Section 11.1: "Content-Type: application/a2a+json SHOULD be used for requests and responses". The spec's own error example
(section 11.6, 404 TASK_NOT_FOUND) is served as `Content-Type: application/a2a+json`. (Not a MUST, so `application/json` servers are
fine too; the client should just accept both. The registered type is in section 14.1.1.)

**Reproduction** (only the header varies; server is a bare `httptest` handler returning the section 11.6 body):

```go
// GET /tasks/x -> 404 with {"error":{"code":404,"status":"NOT_FOUND","message":"...","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"TASK_NOT_FOUND","domain":"a2a-protocol.org"}]}}
c.GetTask(ctx, &a2a.GetTaskRequest{ID: "x"})
```
```
application/json                     errors.Is(ErrTaskNotFound)=true
application/json; charset=utf-8      errors.Is(ErrTaskNotFound)=true
application/a2a+json                 errors.Is(ErrTaskNotFound)=false  err=server error
```
Also seen end to end against a real `application/a2a+json` server (ballerina/a2a): TaskNotFound and TaskNotCancelable both surface as `server error`.
Success responses are unaffected (the body is decoded without checking the type); a2a-go's own server accepts `application/a2a+json` requests.

**Proposed fix** (small; tests included, they fail without it): parse the media type with `mime.ParseMediaType` and accept
`application/json` and `application/a2a+json` in `FromRESTError`. Happy to send the PR.

**Possibly related, for a follow-up:** the server side answers `application/json` everywhere, and the client always sends `Content-Type`/`Accept: application/json`.
