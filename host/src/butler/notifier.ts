// Push decisions: quiet hours + daily budget + "is the phone looking at us right now" — 方案 §4.1.
import type { Db } from '../store/db.ts';
import type { Gateway } from '../gateway/gateway.ts';
import type { Settings } from '../types.ts';
import { inQuietHours } from '../util/cron.ts';
import { log } from '../util/log.ts';

export type NotifyLevel = 'log' | 'silent' | 'normal' | 'timeSensitive';

export class Notifier {
  constructor(private db: Db, private gw: Gateway, private settings: () => Settings, private tz: () => string) {}

  private dayKey() {
    return `notify.count.${new Intl.DateTimeFormat('en-CA', { timeZone: this.tz() }).format(new Date())}`;
  }

  usedToday(): number { return this.db.get<number>(this.dayKey()) ?? 0; }

  quietNow(): boolean { return inQuietHours(this.settings().quietHours, Date.now(), this.tz()); }

  /**
   * Returns what happened so the butler can learn from it.
   * - Devices currently connected see the message in-app; we still push for timeSensitive.
   */
  notify(o: { title: string; body: string; level: NotifyLevel; threadId?: string; approvalId?: string; force?: boolean }): string {
    if (o.level === 'log') return '已记录，未通知';
    const s = this.settings();
    const online = this.gw.onlineDevices.length > 0;
    if (online && o.level !== 'timeSensitive' && !o.approvalId) return '主人正在看 App，消息已直接显示，未推送';
    if (!o.force && o.level !== 'timeSensitive' && this.quietNow()) return '勿扰时段，未推送（消息已在 App 中）';
    const used = this.usedToday();
    if (!o.force && !o.approvalId && used >= s.dailyNotifyBudget && o.level !== 'timeSensitive') return `今日通知预算已用完（${used}/${s.dailyNotifyBudget}），未推送`;
    const aps: Record<string, unknown> = {
      alert: { title: o.title, body: o.body.slice(0, 180) },
      sound: o.level === 'silent' ? undefined : 'default',
      'interruption-level': o.level === 'timeSensitive' ? 'time-sensitive' : o.level === 'silent' ? 'passive' : 'active',
      'thread-id': o.threadId ?? 'butler',
    };
    if (o.approvalId) aps.category = 'OPA_APPROVAL';
    const n = this.gw.push({ pushType: 'alert', payload: { aps, approvalId: o.approvalId }, priority: o.level === 'silent' ? 5 : 10 });
    if (!o.approvalId) this.db.set(this.dayKey(), used + 1);
    log.info('notify', `${o.level} → ${n} device(s): ${o.title}`);
    return n ? `已推送到 ${n} 台设备` : '没有可用的推送通道（未注册推送或 Relay 未连接），消息已在 App 中';
  }
}
