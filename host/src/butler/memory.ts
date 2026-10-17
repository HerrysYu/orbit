// User memory: SQLite rows + FTS5 trigram search — 方案 §6, skills/memory-policy.
import type { Db } from '../store/db.ts';
import type { Memory, MemoryKind } from '../types.ts';
import { uid } from '../util/log.ts';

const SECRET_RE = /(密码|口令|password|passwd|验证码|cvv|\b\d{15,19}\b|\b\d{17}[\dxX]\b|sk-[a-z0-9]{16,})/i;

export class MemoryStore {
  constructor(private db: Db) {}

  list(includeCandidates = false): Memory[] {
    const rows = this.db.sql.prepare(`SELECT * FROM memories WHERE status IN (${includeCandidates ? "'active','candidate'" : "'active'"}) ORDER BY updated_at DESC`).all() as any[];
    return rows.map(toMemory);
  }

  /** Writes or updates a memory. Rejects obvious secrets. Returns the stored memory. */
  write(text: string, kind: MemoryKind = 'fact', source: 'explicit' | 'inferred' = 'explicit', replaceId?: string): Memory {
    text = text.trim();
    if (!text) throw new Error('empty memory');
    if (SECRET_RE.test(text)) throw new Error('看起来包含密码、证件号或卡号等机密信息，按记忆规则不能保存');
    const now = Date.now();
    const status = source === 'explicit' ? 'active' : 'candidate';
    const confidence = source === 'explicit' ? 1 : 0.6;
    if (replaceId && this.get(replaceId)) {
      this.db.sql.prepare('UPDATE memories SET text = ?, kind = ?, source = ?, confidence = ?, status = ?, updated_at = ? WHERE id = ?')
        .run(text, kind, source, confidence, status, now, replaceId);
      return this.get(replaceId)!;
    }
    const dup = this.db.sql.prepare("SELECT id FROM memories WHERE text = ? AND status != 'deleted'").get(text) as { id: string } | undefined;
    if (dup) return this.get(dup.id)!;
    const id = uid('m_');
    this.db.sql.prepare('INSERT INTO memories(id, text, kind, source, confidence, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .run(id, text, kind, source, confidence, status, now, now);
    return this.get(id)!;
  }

  confirm(id: string): Memory | undefined {
    this.db.sql.prepare("UPDATE memories SET status = 'active', confidence = 1, updated_at = ? WHERE id = ?").run(Date.now(), id);
    return this.get(id);
  }

  delete(id: string): boolean {
    return Number(this.db.sql.prepare('DELETE FROM memories WHERE id = ?').run(id).changes) > 0;
  }

  get(id: string): Memory | undefined {
    const r = this.db.sql.prepare('SELECT * FROM memories WHERE id = ?').get(id) as any;
    return r ? toMemory(r) : undefined;
  }

  search(query: string, limit = 8): (Memory & { status: string })[] {
    const q = query.trim();
    if (!q) return [];
    let rows: any[] = [];
    if ([...q].length >= 3) {
      const fts = q.split(/\s+/).filter((t) => [...t].length >= 3).map((t) => `"${t.replace(/"/g, '""')}"`).join(' OR ');
      if (fts) {
        try {
          rows = this.db.sql.prepare(`SELECT m.* FROM memories_fts f JOIN memories m ON m.rowid = f.rowid
            WHERE memories_fts MATCH ? AND m.status != 'deleted' ORDER BY rank LIMIT ?`).all(fts, limit) as any[];
        } catch { rows = []; }
      }
    }
    if (rows.length < limit) {
      // Short CJK terms (< 3 chars) are not indexable by trigram — fall back to LIKE on each term.
      const terms = q.split(/\s+/).filter(Boolean).slice(0, 5);
      const like = this.db.sql.prepare(`SELECT * FROM memories WHERE status != 'deleted' AND (${terms.map(() => 'text LIKE ?').join(' OR ')}) LIMIT ?`)
        .all(...terms.map((t) => `%${t}%`), limit) as any[];
      const seen = new Set(rows.map((r) => r.id));
      for (const r of like) if (!seen.has(r.id)) rows.push(r);
    }
    return rows.slice(0, limit).map((r) => ({ ...toMemory(r), status: r.status }));
  }

  /** Compact profile block for the system prompt. */
  summary(max = 40): string {
    const items = this.list().slice(0, max);
    if (!items.length) return '（暂无。随着相处慢慢了解主人。）';
    return items.map((m) => `- [${m.kind}] ${m.text} (id:${m.id})`).join('\n');
  }
}

function toMemory(r: any): Memory {
  return { id: r.id, text: r.text, kind: r.kind, source: r.source, confidence: r.confidence, createdAt: r.created_at, updatedAt: r.updated_at };
}
