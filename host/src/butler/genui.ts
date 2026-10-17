// GenUI component catalog (protocol.md §5). Host validates every ui_render/ui_patch before it reaches the phone;
// errors go back to the model so it can fix the call.
import { z } from 'zod';

const str = z.string();
const num = z.number();
const strOrNum = z.union([z.string(), z.number()]);
const status = <T extends [string, ...string[]]>(...v: T) => z.enum(v);

export const CATALOG = {
  text_card: z.object({ title: str.optional(), markdown: str, icon: str.optional() }),
  link_preview: z.object({ url: str, title: str, description: str.optional(), imageUrl: str.optional(), siteName: str.optional() }),
  table: z.object({
    title: str.optional(),
    columns: z.array(z.object({ key: str, label: str, align: z.enum(['leading', 'center', 'trailing']).optional() })).min(1),
    rows: z.array(z.record(z.string(), strOrNum)),
    footnote: str.optional(),
  }),
  document: z.object({ title: str, markdown: str, attachments: z.array(z.object({ name: str, url: str })).optional() }),
  calendar_events: z.object({
    title: str.optional(),
    events: z.array(z.object({ id: str.optional(), title: str, start: num, end: num, location: str.optional(), calendar: str.optional(), color: str.optional() })),
  }),
  video: z.object({ url: str, title: str.optional(), posterUrl: str.optional() }),
  image_gallery: z.object({ title: str.optional(), images: z.array(z.object({ url: str, caption: str.optional() })).min(1) }),
  map_place: z.object({ name: str, address: str.optional(), lat: num, lon: num, rating: num.optional(), phone: str.optional(), url: str.optional() }),
  choice_list: z.object({ question: str, options: z.array(z.object({ id: str, label: str, detail: str.optional() })).min(2), multi: z.boolean().optional() }),
  form: z.object({
    title: str,
    fields: z.array(z.object({
      key: str, label: str, type: z.enum(['text', 'number', 'date', 'time', 'select', 'toggle']),
      options: z.array(str).optional(), placeholder: str.optional(), required: z.boolean().optional(), value: z.any().optional(),
    })).min(1),
    submitLabel: str.optional(),
  }),
  order_card: z.object({
    merchant: str,
    items: z.array(z.object({ name: str, qty: num, price: num, note: str.optional() })),
    fees: z.array(z.object({ label: str, amount: num })).optional(),
    total: num, currency: str.default('CNY'), eta: str.optional(),
    status: status('draft', 'confirming', 'placed', 'delivering', 'done', 'failed'), imageUrl: str.optional(),
  }),
  ticket_card: z.object({
    kind: status('train', 'flight', 'movie', 'show', 'bus'), title: str, from: str.optional(), to: str.optional(),
    departAt: num.optional(), arriveAt: num.optional(), venue: str.optional(), seat: str.optional(), price: num.optional(),
    currency: str.optional(), status: status('options', 'holding', 'booked', 'failed'), code: str.optional(),
  }),
  booking_card: z.object({
    kind: status('restaurant', 'hotel', 'appointment', 'other'), name: str, time: num, partySize: num.optional(),
    address: str.optional(), status: status('draft', 'pending', 'confirmed', 'failed'), confirmation: str.optional(), note: str.optional(),
  }),
  task_progress: z.object({ taskId: str }),
  approval_card: z.object({ approvalId: str }),
  comparison: z.object({
    title: str.optional(),
    items: z.array(z.object({
      id: str, title: str, subtitle: str.optional(), imageUrl: str.optional(), price: strOrNum.optional(),
      pros: z.array(str).optional(), cons: z.array(str).optional(), highlight: str.optional(),
    })).min(2),
    recommendedId: str.optional(),
  }),
  memory_saved: z.object({ memoryId: str, text: str }),
} as const;

export type ComponentName = keyof typeof CATALOG;
export const COMPONENTS = Object.keys(CATALOG) as ComponentName[];

export function validateProps(component: string, props: unknown): { ok: true; props: Record<string, unknown> } | { ok: false; error: string } {
  const schema = (CATALOG as Record<string, z.ZodTypeAny>)[component];
  if (!schema) return { ok: false, error: `未知组件 "${component}"。可用：${COMPONENTS.join(', ')}` };
  const r = schema.safeParse(props);
  if (!r.success) {
    const issues = r.error.issues.slice(0, 6).map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`).join('; ');
    return { ok: false, error: `${component} props 不合法：${issues}` };
  }
  return { ok: true, props: r.data as Record<string, unknown> };
}

/** Validate a patch by merging into existing props. */
export function validatePatch(component: string, prev: Record<string, unknown>, patch: Record<string, unknown>) {
  return validateProps(component, { ...prev, ...patch });
}
