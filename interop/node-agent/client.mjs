// Real @a2a-js/sdk 1.2.1 client (HTTP+JSON only) -> ballerina/a2a Listener (interop/bal-listener).
// The Ballerina rig picks behaviour from the messageId prefix (see bal-listener/main.bal).
import { ClientFactory, ClientFactoryOptions, RestTransportFactory } from '@a2a-js/sdk/client';
import { TaskState, Role } from '@a2a-js/sdk';
import fs from 'node:fs';

const URL_ = process.argv[2] || 'http://localhost:9611';
const HOOK_FILE = '/tmp/node_client_push.json';
let failures = 0;
const expect = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}: ${name}${detail ? ' -- ' + detail : ''}`); if (!ok) failures++; };
const part = (t) => ({ content: { $case: 'text', value: t }, metadata: undefined, filename: '', mediaType: 'text/plain' });
const req = (messageId, text, extra = {}, cfg) => ({ message: { messageId, role: Role.ROLE_USER, parts: [part(text)], taskId: '', contextId: '', extensions: [], metadata: {}, referenceTaskIds: [], ...extra }, configuration: cfg, metadata: {}, tenant: '' });
const artText = (t) => (t.artifacts ?? []).flatMap((a) => a.parts.map((p) => p.content?.value ?? '')).join('');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const lc = (e) => e?.constructor?.name + ':' + (e?.message ?? e);

const factory = new ClientFactory(ClientFactoryOptions.createFrom(ClientFactoryOptions.default, {
  transports: [new RestTransportFactory()], preferredTransports: ['HTTP+JSON'],
}));
console.log('== I1: card + transport negotiation ==');
const client = await factory.createFromUrl(URL_);
const card = await client.getAgentCard();
expect('card resolved', card.name === 'Ballerina A2A Interop Listener', card.name);
expect('negotiated HTTP+JSON at v1.0', client.transport.protocolName === 'HTTP+JSON' && client.protocolVersion === '1.0', `${client.transport.protocolName} ${client.protocolVersion}`);

console.log('== I3: blocking send ==');
const r = await client.sendMessage(req('n-1', 'what is 2+2?'));
const task = r.task ?? r;
expect('completed Task with artifact', task.status?.state === TaskState.TASK_STATE_COMPLETED && artText(task).includes('echo: what is 2+2?'), `${task.status?.state} ${artText(task)}`);

console.log('== I8: streaming send ==');
const kinds = []; let last;
for await (const ev of client.sendMessageStream(req('n-2', 'stream me'))) { const k = ev.payload?.$case ?? Object.keys(ev)[0]; kinds.push(k); last = ev; }
console.log('  events:', kinds.join(','));
expect('stream: task first, ends after terminal state', kinds[0] === 'task' && kinds.includes('artifactUpdate') && kinds.at(-1) === 'statusUpdate' && last.payload?.value?.status?.state === TaskState.TASK_STATE_COMPLETED, kinds.join(','));

console.log('== I10: multi-turn ==');
const t1 = (await client.sendMessage(req('interop-task-input-required-1', 'plan a trip'))); const T1 = t1.task ?? t1;
expect('first turn INPUT_REQUIRED', T1.status.state === TaskState.TASK_STATE_INPUT_REQUIRED, T1.status.state);
const t2r = await client.sendMessage(req('interop-continue-1', 'Paris', { taskId: T1.id, contextId: T1.contextId })); const T2 = t2r.task ?? t2r;
expect('continuation COMPLETED on same task id', T2.id === T1.id && T2.status.state === TaskState.TASK_STATE_COMPLETED, T2.status.state);

console.log('== I4 + I9: returnImmediately then subscribe ==');
const p = await client.sendMessage(req('interop-task-paced-1', 'pace', {}, { acceptedOutputModes: [], returnImmediately: true })); const P = p.task ?? p;
expect('non-terminal immediately', P.status.state !== TaskState.TASK_STATE_COMPLETED, P.status.state);
let sawDone = false;
for await (const ev of client.resubscribeTask({ id: P.id, tenant: '' })) {
  const s = ev.payload?.value?.status?.state ?? ev.task?.status?.state ?? ev.statusUpdate?.status?.state;
  if (s === TaskState.TASK_STATE_COMPLETED) sawDone = true;
}
expect('subscribe observed COMPLETED and stream ended', sawDone);

console.log('== I6/I7: typed errors ==');
try { await client.cancelTask({ id: task.id, tenant: '' }); expect('cancel completed task errors', false, 'succeeded'); }
catch (e) { expect('cancel completed -> TaskNotCancelable', /cancel/i.test(e.constructor.name + e.message), lc(e)); }
try { await client.getTask({ id: 'no-such-task', historyLength: undefined, tenant: '' }); expect('unknown task errors', false); }
catch (e) { expect('unknown task -> TaskNotFound', /not.?found/i.test(e.constructor.name + e.message), lc(e)); }

console.log('== I5: ListTasks + filters ==');
const l1 = await client.listTasks({ pageSize: 2, tenant: '' });
expect('pageSize honoured', l1.tasks.length === 2, String(l1.tasks.length));
const l2 = await client.listTasks({ tenant: '', historyLength: 0 });
expect('historyLength=0 -> no history on any task', l2.tasks.length > 0 && l2.tasks.every((t) => (t.history ?? []).length === 0));
const l3 = await client.listTasks({ tenant: '', statusTimestampAfter: '2999-01-01T00:00:00Z' });
expect('statusTimestampAfter (future) -> none', l3.tasks.length === 0, String(l3.tasks.length));
const l4 = await client.listTasks({ tenant: '', statusTimestampAfter: '2000-01-01T00:00:00Z' });
expect('statusTimestampAfter (past) -> all', l4.tasks.length >= 3, String(l4.tasks.length));
const g0 = await client.getTask({ id: task.id, historyLength: 0, tenant: '' });
expect('getTask historyLength=0', (g0.history ?? []).length === 0);

console.log('== I12: push config CRUD + delivery ==');
try { fs.rmSync(HOOK_FILE, { force: true }); } catch {}
const cfg = await client.createTaskPushNotificationConfig({ tenant: '', taskId: task.id, id: 'cfg1', url: 'http://localhost:19872/hook', token: 'tok', authentication: undefined });
expect('create push config', cfg.id === 'cfg1', lc(cfg));
const lst = await client.listTaskPushNotificationConfig({ taskId: task.id, tenant: '', pageSize: 0, pageToken: '' });
expect('list push configs', (lst.configs ?? []).length === 1);
await client.deleteTaskPushNotificationConfig({ taskId: task.id, id: 'cfg1', tenant: '' });
const lst2 = await client.listTaskPushNotificationConfig({ taskId: task.id, tenant: '', pageSize: 0, pageToken: '' });
expect('delete push config', (lst2.configs ?? []).length === 0);
const pp = await client.sendMessage(req('interop-task-paced-2', 'push me', {}, { acceptedOutputModes: [], returnImmediately: true, taskPushNotificationConfig: { tenant: '', taskId: '', id: '', url: 'http://localhost:19872/hook', token: 'tok2', authentication: undefined } }));
for (let i = 0; i < 20 && !fs.existsSync(HOOK_FILE); i++) await sleep(500);
const hook = fs.existsSync(HOOK_FILE) ? JSON.parse(fs.readFileSync(HOOK_FILE, 'utf8')) : null;
expect('webhook delivered as a StreamResponse envelope', !!hook && ('task' in hook || 'statusUpdate' in hook || 'artifactUpdate' in hook), hook ? Object.keys(hook).join(',') : 'nothing received');

console.log(failures ? `OVERALL: FAIL (${failures})` : 'OVERALL: PASS');
process.exit(failures ? 1 : 0);
