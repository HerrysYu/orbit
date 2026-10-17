// Host identity key + device allowlist + pairing tokens.
import { randomBytes } from 'node:crypto';
import { hostname, networkInterfaces } from 'node:os';
import type { Db } from '../store/db.ts';
import { b64, generateSigningKey, idFromPub, signingKeyFromSeed, unb64, type SigningKey } from './crypto.ts';

export interface Device { id: string; pub: string; name: string; pairedAt: number; lastSeen?: number }

/** Same shape as `os.networkInterfaces()`, so tests can feed in a fake machine. */
export type NetworkInterfaces = ReturnType<typeof networkInterfaces>;

function ipv4Octets(addr: string): number[] | undefined {
  const parts = addr.split('.');
  if (parts.length !== 4 || !parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)) return undefined;
  return parts.map(Number);
}

/** Sort rank of an IPv4 address (lower = try first), or -1 when the phone can't use it to reach this Mac. */
function lanRank([a, b]: number[]): number {
  if (a === 0 || a === 127) return -1;                 // "this network", loopback
  if (a === 169 && b === 254) return -1;               // 169.254/16 link-local (self-assigned fallback)
  if (a === 198 && (b === 18 || b === 19)) return -1;  // 198.18/15: the fake range proxy tools in TUN mode use
  if (a === 192 && b === 168) return 0;
  if (a === 10) return 1;
  if (a === 172 && b >= 16 && b <= 31) return 2;
  return 3;                                            // anything else routable, e.g. Tailscale's 100.64/10
}

/**
 * Addresses the phone might reach this Mac on, best first: private ranges (192.168/16, 10/8, 172.16/12), then the rest.
 * Loopback, link-local and 198.18/15 are dropped — advertising them just makes the phone try dead addresses first.
 * Interface order is kept within a rank; duplicates are listed once.
 */
export function lanAddrsFrom(ifaces: NetworkInterfaces, port: number): { host: string; port: number }[] {
  const found: { host: string; rank: number }[] = [];
  for (const list of Object.values(ifaces)) {
    for (const a of list ?? []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      const octets = ipv4Octets(a.address);
      const rank = octets ? lanRank(octets) : -1;
      if (rank >= 0 && !found.some((f) => f.host === a.address)) found.push({ host: a.address, rank });
    }
  }
  return found.sort((x, y) => x.rank - y.rank).map(({ host }) => ({ host, port }));
}

export class Identity {
  readonly key: SigningKey;
  readonly hostId: string;
  readonly hostName: string;
  private pairTokens = new Map<string, number>(); // token -> expiresAt

  constructor(private db: Db) {
    let seed = db.get<string>('host.seed');
    if (!seed) {
      // Seed stored in the local sqlite under ~/.opa (0700). Keychain storage is a follow-up.
      seed = b64(generateSigningKey().seed);
      db.set('host.seed', seed);
    }
    this.key = signingKeyFromSeed(unb64(seed));
    this.hostId = idFromPub(this.key.pub);
    this.hostName = db.get<string>('host.name') ?? `${hostname().replace(/\.local$/, '')}`;
  }

  get pubB64() { return b64(this.key.pub); }

  newPairToken(ttlMs = 5 * 60_000): { token: string; exp: number } {
    const token = randomBytes(16).toString('base64url');
    const exp = Date.now() + ttlMs;
    this.pairTokens.set(token, exp);
    return { token, exp };
  }

  /** Validates and burns a pairing token. */
  consumePairToken(token: string | undefined): boolean {
    if (!token) return false;
    const exp = this.pairTokens.get(token);
    this.pairTokens.delete(token);
    return !!exp && exp > Date.now();
  }

  pairingOpenUntil(): number {
    let max = 0;
    for (const exp of this.pairTokens.values()) max = Math.max(max, exp);
    return max;
  }

  devices(): Device[] {
    return (this.db.sql.prepare('SELECT id, pub, name, paired_at, last_seen FROM devices ORDER BY paired_at').all() as any[])
      .map((r) => ({ id: r.id, pub: r.pub, name: r.name, pairedAt: r.paired_at, lastSeen: r.last_seen ?? undefined }));
  }

  device(id: string): Device | undefined {
    return this.devices().find((d) => d.id === id);
  }

  addDevice(d: { id: string; pub: string; name: string }) {
    this.db.sql.prepare(`INSERT INTO devices(id, pub, name, paired_at) VALUES (?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET pub = excluded.pub, name = excluded.name`).run(d.id, d.pub, d.name, Date.now());
  }

  removeDevice(id: string) {
    this.db.sql.prepare('DELETE FROM devices WHERE id = ?').run(id);
    this.db.sql.prepare('DELETE FROM push_tokens WHERE device_id = ?').run(id);
  }

  touch(id: string) { this.db.sql.prepare('UPDATE devices SET last_seen = ? WHERE id = ?').run(Date.now(), id); }

  static lanAddrs(port: number): { host: string; port: number }[] {
    return lanAddrsFrom(networkInterfaces(), port);
  }
}
