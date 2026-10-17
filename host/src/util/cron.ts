// Minimal 5-field cron (minute hour dom month dow) evaluated in a given IANA timezone.
// Supports *, numbers, ranges a-b, lists a,b and steps */n or a-b/n. dow: 0-6 (0 = Sunday, 7 also Sunday).

function parseField(f: string, min: number, max: number): Set<number> {
  const out = new Set<number>();
  for (const part of f.split(',')) {
    const [range, stepS] = part.split('/');
    const step = stepS ? Number(stepS) : 1;
    let lo = min, hi = max;
    if (range !== '*') {
      const [a, b] = range.split('-').map(Number);
      lo = a; hi = b ?? (stepS ? max : a);
    }
    if (![lo, hi, step].every(Number.isFinite) || step <= 0 || lo < min || hi > max) throw new Error(`bad cron field "${f}"`);
    for (let v = lo; v <= hi; v += step) out.add(v);
  }
  return out;
}

export interface Cron { min: Set<number>; hour: Set<number>; dom: Set<number>; mon: Set<number>; dow: Set<number>; domAny: boolean; dowAny: boolean }

export function parseCron(expr: string): Cron {
  const p = expr.trim().split(/\s+/);
  if (p.length !== 5) throw new Error('cron needs 5 fields');
  const dow = parseField(p[4], 0, 7);
  if (dow.has(7)) { dow.delete(7); dow.add(0); }
  return {
    min: parseField(p[0], 0, 59), hour: parseField(p[1], 0, 23), dom: parseField(p[2], 1, 31), mon: parseField(p[3], 1, 12), dow,
    domAny: p[2] === '*', dowAny: p[4] === '*',
  };
}

function partsIn(tz: string, t: number) {
  const f = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', weekday: 'short',
  });
  const o: Record<string, string> = {};
  for (const x of f.formatToParts(new Date(t))) o[x.type] = x.value;
  const wd = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(o.weekday);
  return { mon: +o.month, dom: +o.day, hour: +o.hour, min: +o.minute, dow: wd };
}

/** Next fire time strictly after `after` (ms). Scans minute by minute up to ~400 days. */
export function nextCron(c: Cron, after: number, tz: string): number | undefined {
  let t = Math.floor(after / 60_000) * 60_000 + 60_000;
  const limit = t + 400 * 24 * 3600_000;
  while (t < limit) {
    const p = partsIn(tz, t);
    const dayOk = c.domAny && c.dowAny ? true
      : c.domAny ? c.dow.has(p.dow)
        : c.dowAny ? c.dom.has(p.dom)
          : c.dom.has(p.dom) || c.dow.has(p.dow);
    if (!c.mon.has(p.mon) || !dayOk) { t += 3600_000 - (p.min * 60_000); continue; }
    if (!c.hour.has(p.hour)) { t += (60 - p.min) * 60_000; continue; }
    if (c.min.has(p.min)) return t;
    t += 60_000;
  }
  return undefined;
}

/** "HH:mm" in tz → is `t` inside [start, end) (wrapping past midnight)? */
export function inQuietHours(q: { start: string; end: string }, t: number, tz: string): boolean {
  const p = partsIn(tz, t);
  const cur = p.hour * 60 + p.min;
  const [sh, sm] = q.start.split(':').map(Number);
  const [eh, em] = q.end.split(':').map(Number);
  const s = sh * 60 + sm, e = eh * 60 + em;
  return s <= e ? cur >= s && cur < e : cur >= s || cur < e;
}

export function fmtLocal(t: number, tz: string): string {
  return new Intl.DateTimeFormat('zh-CN', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).format(new Date(t));
}
