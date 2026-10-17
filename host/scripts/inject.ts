// Test helper: push a chat message + GenUI cards through a running host's control socket (as the CLI user).
import { controlClient } from '../src/control.ts';
const c = await controlClient(() => {});
await c.send({ cmd: 'req', m: 'chat.send', d: { clientId: 'cli1', text: '帮我订周六晚上两个人的日料' } });
console.log((await c.send({ cmd: 'req', m: 'devices.list' })).d);
c.close();
