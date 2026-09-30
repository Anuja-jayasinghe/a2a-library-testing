// A ~75s stream that is silent except for the listener's SSE keep-alive comments, read by Node's own (undici) SSE
// parser. Run against a listener started with -CPACE_SECONDS=75 -CKEEPALIVE_SECONDS=15.
import { ClientFactory, ClientFactoryOptions, RestTransportFactory } from '@a2a-js/sdk/client';
import { Role, TaskState } from '@a2a-js/sdk';
const f = new ClientFactory(ClientFactoryOptions.createFrom(ClientFactoryOptions.default, { transports: [new RestTransportFactory()], preferredTransports: ['HTTP+JSON'] }));
const c = await f.createFromUrl(process.argv[2] || 'http://localhost:9612');
const t0 = Date.now(); const kinds = []; let state;
for await (const ev of c.sendMessageStream({ message: { messageId: 'interop-task-paced-long', role: Role.ROLE_USER, parts: [{ content: { $case: 'text', value: 'slow' }, metadata: undefined, filename: '', mediaType: 'text/plain' }], taskId: '', contextId: '', extensions: [], metadata: {}, referenceTaskIds: [] }, configuration: undefined, metadata: {}, tenant: '' })) {
  kinds.push(ev.payload?.$case); state = ev.payload?.value?.status?.state ?? state;
}
const secs = ((Date.now() - t0) / 1000).toFixed(1);
console.log(`events=${kinds.join(',')} finalState=${state} elapsed=${secs}s`);
const ok = state === TaskState.TASK_STATE_COMPLETED && secs > 70;
console.log(ok ? 'PASS: survived >70s of silence' : 'FAIL'); process.exit(ok ? 0 : 1);
