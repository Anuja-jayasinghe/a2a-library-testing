import { ClientFactory, ClientFactoryOptions, RestTransportFactory } from '@a2a-js/sdk/client';
const f = new ClientFactory(ClientFactoryOptions.createFrom(ClientFactoryOptions.default, { transports: [new RestTransportFactory()], preferredTransports: ['HTTP+JSON'] }));
const c = await f.createFromUrl(process.argv[2]);
const r = await c.listTasks({ tenant: '' });
console.log(`@a2a-js/sdk: OK tasks=${r.tasks.length} nextPageToken=${JSON.stringify(r.nextPageToken)}`);
