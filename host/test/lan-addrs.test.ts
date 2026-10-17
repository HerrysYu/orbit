import type { NetworkInterfaceInfo } from 'node:os';
import { describe, expect, it } from 'vitest';
import { Identity, lanAddrsFrom, type NetworkInterfaces } from '../src/gateway/identity.ts';

const v4 = (address: string, internal = false): NetworkInterfaceInfo => ({
  address, netmask: '255.255.255.0', family: 'IPv4', mac: '00:00:00:00:00:00', internal, cidr: `${address}/24`,
});
const v6 = (address: string): NetworkInterfaceInfo => ({
  address, netmask: 'ffff:ffff:ffff:ffff::', family: 'IPv6', mac: '00:00:00:00:00:00', internal: false, cidr: `${address}/64`, scopeid: 0,
});
const hosts = (ifaces: NetworkInterfaces, port = 7420) => lanAddrsFrom(ifaces, port).map((a) => a.host);

describe('lanAddrsFrom', () => {
  it('drops loopback, link-local and the 198.18.0.0/15 proxy range', () => {
    const ifaces: NetworkInterfaces = {
      lo0: [v4('127.0.0.1', true), v4('127.0.1.1')], // even when `internal` is missing
      utun4: [v4('198.18.0.1'), v4('198.19.255.254')], // Clash / Surge style TUN
      en9: [v4('169.254.12.34')], // self-assigned fallback
      en0: [v4('192.168.1.20')],
    };
    expect(hosts(ifaces)).toEqual(['192.168.1.20']);
  });

  it('keeps addresses just outside the excluded ranges', () => {
    // 198.18.0.0/15 is 198.18.0.0 – 198.19.255.255; 169.254.0.0/16 is exactly 169.254.x.x.
    const ifaces: NetworkInterfaces = {
      a: [v4('198.17.255.255'), v4('198.20.0.1'), v4('169.253.1.1'), v4('169.255.1.1')],
      b: [v4('198.18.0.0'), v4('198.19.255.255'), v4('169.254.0.0'), v4('169.254.255.255')],
    };
    expect(hosts(ifaces)).toEqual(['198.17.255.255', '198.20.0.1', '169.253.1.1', '169.255.1.1']);
  });

  it('puts 192.168/16 first, then 10/8, then 172.16/12, then everything else', () => {
    const ifaces: NetworkInterfaces = {
      utun3: [v4('100.101.102.103')], // Tailscale
      en2: [v4('172.20.0.2')],
      en1: [v4('10.0.0.5')],
      en0: [v4('192.168.1.20')],
      bridge100: [v4('192.168.64.1')],
      en7: [v4('203.0.113.9')],
    };
    expect(hosts(ifaces)).toEqual(['192.168.1.20', '192.168.64.1', '10.0.0.5', '172.20.0.2', '100.101.102.103', '203.0.113.9']);
  });

  it('only treats 172.16.0.0 – 172.31.255.255 as private', () => {
    const ifaces: NetworkInterfaces = {
      a: [v4('172.32.0.1'), v4('172.15.255.255'), v4('172.31.255.254'), v4('172.16.0.1')],
    };
    expect(hosts(ifaces)).toEqual(['172.31.255.254', '172.16.0.1', '172.32.0.1', '172.15.255.255']);
  });

  it('keeps interface order within a rank and lists duplicates once', () => {
    const ifaces: NetworkInterfaces = {
      en1: [v4('192.168.2.7')],
      en0: [v4('192.168.1.7'), v4('192.168.2.7')],
      en3: [v4('10.1.1.1')],
    };
    expect(hosts(ifaces)).toEqual(['192.168.2.7', '192.168.1.7', '10.1.1.1']);
  });

  it('ignores IPv6, malformed addresses and missing interface lists', () => {
    const ifaces: NetworkInterfaces = {
      en0: [v6('fe80::1'), v6('2001:db8::1'), v4('192.168.1.20')],
      en5: undefined,
      en6: [],
      en7: [v4('999.1.1.1'), v4('192.168.1'), v4('not-an-ip'), v4('10.0.0')],
    };
    expect(hosts(ifaces)).toEqual(['192.168.1.20']);
  });

  it('stamps every address with the port', () => {
    const ifaces: NetworkInterfaces = { en0: [v4('192.168.1.20')], en1: [v4('10.0.0.5')] };
    expect(lanAddrsFrom(ifaces, 7488)).toEqual([{ host: '192.168.1.20', port: 7488 }, { host: '10.0.0.5', port: 7488 }]);
  });

  it('returns nothing for a machine with no usable interface', () => {
    expect(lanAddrsFrom({ lo0: [v4('127.0.0.1', true)] }, 7420)).toEqual([]);
    expect(lanAddrsFrom({}, 7420)).toEqual([]);
  });

  it('Identity.lanAddrs applies the same rules to this machine', () => {
    const addrs = Identity.lanAddrs(7420);
    for (const a of addrs) {
      expect(a.port).toBe(7420);
      expect(a.host).not.toMatch(/^(127\.|169\.254\.|198\.1[89]\.)/);
    }
    // Private ranges never come after a public one.
    const rank = (h: string) => (h.startsWith('192.168.') ? 0 : h.startsWith('10.') ? 1 : /^172\.(1[6-9]|2\d|3[01])\./.test(h) ? 2 : 3);
    const ranks = addrs.map((a) => rank(a.host));
    expect(ranks).toEqual([...ranks].sort((x, y) => x - y));
  });
});
