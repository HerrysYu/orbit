// Test helper: print a pairing link and auto-confirm the first SAS (never use for real devices).
import { controlClient } from '../src/control.ts';
const c = await controlClient(async (f) => {
  if (f.t === 'pairing') { console.log('SAS', f.sas, f.deviceName); await c.send({ cmd: 'confirm', sas: f.sas, ok: true }); console.log('confirmed'); process.exit(0); }
});
const r = await c.send({ cmd: 'pair' });
console.log(r.link);
