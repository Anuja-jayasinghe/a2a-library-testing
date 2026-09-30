import { ClientFactory, ClientFactoryOptions, RestTransportFactory } from '@a2a-js/sdk/client';
import { Role } from '@a2a-js/sdk';
const f = new ClientFactory(ClientFactoryOptions.createFrom(ClientFactoryOptions.default, { transports: [new RestTransportFactory()], preferredTransports: ['HTTP+JSON'] }));
const c = await f.createFromUrl('http://localhost:9801');
try { const r = await c.sendMessage({ message: { messageId: 's1', role: Role.ROLE_USER, parts: [{ content: { $case: 'text', value: 'hi' }, metadata: undefined, filename: '', mediaType: 'text/plain' }], taskId: '', contextId: '', extensions: [], metadata: {}, referenceTaskIds: [] }, configuration: undefined, metadata: {}, tenant: '' }); console.log('Node client OK with trailing-slash card URL'); } catch (e) { console.log('Node client FAILED:', e.message); }
