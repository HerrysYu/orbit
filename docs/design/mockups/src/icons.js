// SF-Symbols-like line icons for the mockups (24×24 grid). The app itself uses real SF Symbols.
const P = {
  plus: 'M12 5v14M5 12h14',
  arrowUp: 'M12 19V5.5M6.5 11 12 5.5 17.5 11',
  arrowDown: 'M12 5v13.5M6.5 13 12 18.5 17.5 13',
  chevR: 'M9.5 5.5 16 12l-6.5 6.5', chevL: 'M14.5 5.5 8 12l6.5 6.5', chevD: 'M5.5 9.5 12 16l6.5-6.5',
  x: 'M6.5 6.5l11 11M17.5 6.5l-11 11',
  check: 'M5.5 12.5 10 17l8.5-9.5',
  laptop: 'M5.5 6.5A1.5 1.5 0 0 1 7 5h10a1.5 1.5 0 0 1 1.5 1.5V15h-13V6.5ZM2.8 18.2h18.4',
  wifi: 'M4.5 10a10.6 10.6 0 0 1 15 0M7.6 13.3a6.2 6.2 0 0 1 8.8 0M12 17.2h.01',
  cloud: 'M7.2 18.5h9.6a4 4 0 0 0 .6-7.96A5.8 5.8 0 0 0 6.4 9.7 4.4 4.4 0 0 0 7.2 18.5Z',
  clock: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 7.5V12l3 2',
  warn: 'M12 4.2 21 19.5H3L12 4.2ZM12 10v4M12 16.9h.01',
  alert: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 7.5v5.6M12 16.4h.01',
  hand: 'M8.2 12.6V6.8a1.4 1.4 0 0 1 2.8 0v4.7M11 11.2V5.3a1.4 1.4 0 0 1 2.8 0v5.9M13.8 11.2V6.8a1.4 1.4 0 0 1 2.8 0v6.9c0 3.6-2.6 6.5-6.1 6.5-2.1 0-3.9-1.1-4.9-2.8l-2.1-3.6a1.4 1.4 0 0 1 2.4-1.4l2.3 3.2',
  qbubble: 'M5 18.8V7.5A3 3 0 0 1 8 4.5h8a3 3 0 0 1 3 3v6.2a3 3 0 0 1-3 3H9.6L5 18.8ZM10 9.4a2.1 2.1 0 1 1 3 1.9c-.6.3-1 .8-1 1.4v.2M12 14.8h.01',
  faceid: 'M4 8.5V6.5a2.5 2.5 0 0 1 2.5-2.5h2M15.5 4h2A2.5 2.5 0 0 1 20 6.5v2M20 15.5v2a2.5 2.5 0 0 1-2.5 2.5h-2M8.5 20h-2A2.5 2.5 0 0 1 4 17.5v-2M9 9.3v1.4M15 9.3v1.4M12.2 9.3v3.9h-1M9.4 15.5a3.8 3.8 0 0 0 5.2 0',
  lock: 'M7.5 11V8.2a4.5 4.5 0 0 1 9 0V11M6.5 11h11a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1Z',
  photo: 'M4 7a3 3 0 0 1 3-3h10a3 3 0 0 1 3 3v10a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3V7ZM4.2 16.2l4.3-4.3 3.6 3.6 2.4-2.4 5.3 5.3M15.6 8.6h.01',
  doc: 'M7 3.5h6.6l4.4 4.4v11.6a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1v-15a1 1 0 0 1 1-1ZM13.5 3.6V8h4.4M9 12.5h6M9 16h6',
  link: 'M10.3 13.7a3.8 3.8 0 0 0 5.4 0l2.9-2.9a3.8 3.8 0 0 0-5.4-5.4l-1 1M13.7 10.3a3.8 3.8 0 0 0-5.4 0l-2.9 2.9a3.8 3.8 0 0 0 5.4 5.4l1-1',
  reminders: 'M9.5 7h10M9.5 12h10M9.5 17h10M4.8 7h.01M4.8 12h.01M4.8 17h.01',
  calendar: 'M5 7a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V7ZM5 10h14M9 3.5V6.5M15 3.5V6.5',
  columns: 'M4.5 6a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-4a1 1 0 0 1-1-1V6ZM13.5 6a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-4a1 1 0 0 1-1-1V6Z',
  bell: 'M6.2 16.2V11a5.8 5.8 0 0 1 11.6 0v5.2l1.6 2H4.6l1.6-2ZM10 20.6a2.1 2.1 0 0 0 4 0',
  sparkle: 'M12 3.5l1.7 5.2 5.3 1.8-5.3 1.8L12 17.5l-1.7-5.2L5 10.5l5.3-1.8L12 3.5ZM18.5 15.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7.7-1.8Z',
  person: 'M12 12a3.8 3.8 0 1 0 0-7.6 3.8 3.8 0 0 0 0 7.6ZM4.8 20a7.2 7.2 0 0 1 14.4 0',
  memory: 'M6 5.4A2.4 2.4 0 0 1 8.4 3H19v14.6H8.4A2.4 2.4 0 0 0 6 20V5.4ZM6 20a2.4 2.4 0 0 1 2.4-2.4H19M10 7.6h5.5',
  slider: 'M4 7h9.5M17.5 7H20M4 17h2.5M10.5 17H20M15.5 4.8v4.4M8.5 14.8v4.4',
  moon: 'M19.2 14.4A7.6 7.6 0 0 1 9.6 4.8a7.6 7.6 0 1 0 9.6 9.6Z',
  shield: 'M12 3.5 18.8 6.4v5.4c0 4.2-2.9 7.4-6.8 8.7-3.9-1.3-6.8-4.5-6.8-8.7V6.4L12 3.5ZM9 12.2l2.1 2.1 3.9-4.1',
  cpu: 'M7.5 7.5h9v9h-9zM10 4v3.5M14 4v3.5M10 16.5V20M14 16.5V20M4 10h3.5M4 14h3.5M16.5 10H20M16.5 14H20',
  iphone: 'M8.2 3h7.6A1.7 1.7 0 0 1 17.5 4.7v14.6a1.7 1.7 0 0 1-1.7 1.7H8.2a1.7 1.7 0 0 1-1.7-1.7V4.7A1.7 1.7 0 0 1 8.2 3ZM11 18h2',
  android: 'M7.6 2.8h8.8a1.1 1.1 0 0 1 1.1 1.1v16.2a1.1 1.1 0 0 1-1.1 1.1H7.6a1.1 1.1 0 0 1-1.1-1.1V3.9a1.1 1.1 0 0 1 1.1-1.1ZM10.6 5.3h2.8',
  info: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 11v5.4M12 7.7h.01',
  qr: 'M4 9V5h4M16 5h4v4M20 15v4h-4M8 19H4v-4M9 9h2.2v2.2H9zM12.8 9H15v2.2h-2.2zM9 12.8h2.2V15H9zM13.6 13.6h1.4V15h-1.4z',
  camera: 'M4 8.6A1.6 1.6 0 0 1 5.6 7H8l1.5-2.2h5L16 7h2.4A1.6 1.6 0 0 1 20 8.6v8.8a1.6 1.6 0 0 1-1.6 1.6H5.6A1.6 1.6 0 0 1 4 17.4V8.6ZM12 16a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z',
  paste: 'M9 3.8h6v3H9zM8.5 5.3H7a1.5 1.5 0 0 0-1.5 1.5v12.7A1.5 1.5 0 0 0 7 21h10a1.5 1.5 0 0 0 1.5-1.5V6.8A1.5 1.5 0 0 0 17 5.3h-1.5',
  pin: 'M12 21s6.3-5.8 6.3-10.8a6.3 6.3 0 1 0-12.6 0C5.7 15.2 12 21 12 21ZM12 12.4a2.3 2.3 0 1 0 0-4.6 2.3 2.3 0 0 0 0 4.6Z',
  people: 'M9 11a3.4 3.4 0 1 0 0-6.8A3.4 3.4 0 0 0 9 11ZM2.8 20a6.2 6.2 0 0 1 12.4 0M15.8 4.5a3.4 3.4 0 0 1 0 6.2M18 13.8a6.2 6.2 0 0 1 3.2 6.2',
  trash: 'M4.8 7h14.4M9.8 7V5h4.4v2M7 7l1 13h8l1-13',
  pencil: 'M14.6 5.4l4 4L9 19H5v-4l9.6-9.6Z',
  refresh: 'M19 12a7 7 0 1 1-2-4.9M19 4.6v3.6h-3.6',
  open: 'M8 16l8-8M9.2 8H16v6.8',
  terminal: 'M4 6.5A1.5 1.5 0 0 1 5.5 5h13A1.5 1.5 0 0 1 20 6.5v11a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5v-11ZM7.5 10l2.8 2-2.8 2M12.5 15h4',
  globe: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM3.2 12h17.6M12 3c2.4 2.6 3.6 5.6 3.6 9s-1.2 6.4-3.6 9c-2.4-2.6-3.6-5.6-3.6-9S9.6 5.6 12 3Z',
  folder: 'M3.5 7.2A1.7 1.7 0 0 1 5.2 5.5h4l2 2.1h7.6a1.7 1.7 0 0 1 1.7 1.7v8.5a1.7 1.7 0 0 1-1.7 1.7H5.2a1.7 1.7 0 0 1-1.7-1.7V7.2Z',
  bubble: 'M5 18.8V7.5A3 3 0 0 1 8 4.5h8a3 3 0 0 1 3 3v6.2a3 3 0 0 1-3 3H9.6L5 18.8Z',
  arrowR: 'M5 12h13.5M13 6.5l5.5 5.5-5.5 5.5',
  minus: 'M6 12h12',
  eye: 'M2.8 12S6.2 5.5 12 5.5 21.2 12 21.2 12 17.8 18.5 12 18.5 2.8 12 2.8 12ZM12 14.8a2.8 2.8 0 1 0 0-5.6 2.8 2.8 0 0 0 0 5.6Z',
};
const FILL = {
  stop: '<rect x="7" y="7" width="10" height="10" rx="2.4"/>',
  dots: '<circle cx="6" cy="12" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="18" cy="12" r="1.7"/>',
  star: '<path d="M12 3.6l2.5 5.4 5.9.6-4.4 4 1.3 5.8L12 16.4l-5.3 3 1.3-5.8-4.4-4 5.9-.6L12 3.6Z"/>',
  tabChat: '<path d="M4.2 19.6V7.4A3.4 3.4 0 0 1 7.6 4h8.8a3.4 3.4 0 0 1 3.4 3.4v6.4a3.4 3.4 0 0 1-3.4 3.4H9.3L4.2 19.6Z"/>',
  tabTasks: '<rect x="3.5" y="4" width="17" height="16" rx="4"/>',
  dot: '<circle cx="12" cy="12" r="4"/>',
  battery: '<rect x="2" y="7.5" width="18" height="9" rx="2.6" fill="none" stroke="currentColor" stroke-width="1" opacity=".4"/><rect x="3.6" y="9.1" width="13" height="5.8" rx="1.4"/><path d="M21 10.5v3a1.5 1.5 0 0 0 0-3Z" opacity=".4"/>',
  signal: '<rect x="2" y="13" width="3" height="4" rx=".8"/><rect x="7" y="10.5" width="3" height="6.5" rx=".8"/><rect x="12" y="8" width="3" height="9" rx=".8"/><rect x="17" y="5.5" width="3" height="11.5" rx=".8"/>',
  wifiS: '<path d="M12 18.2a1.6 1.6 0 1 1 0-3.2 1.6 1.6 0 0 1 0 3.2ZM6.7 12.6a7.5 7.5 0 0 1 10.6 0l-1.5 1.5a5.4 5.4 0 0 0-7.6 0l-1.5-1.5ZM3.6 9.5a11.9 11.9 0 0 1 16.8 0L19 10.9a9.9 9.9 0 0 0-14 0L3.6 9.5Z"/>',
};

function ic(name, size = 20, sw = 1.8) {
  if (FILL[name]) return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">${FILL[name]}</svg>`;
  if (name === 'gear' || name === 'gearFill') return gear(size, name === 'gearFill');
  if (name === 'tasksFill') return tasksGlyph(size, true);
  if (name === 'tasks') return tasksGlyph(size, false);
  const d = P[name];
  if (!d) return `<svg width="${size}" height="${size}"></svg>`;
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;
}

function gear(size, filled) {
  const teeth = 8, R = 10.2, r = 8.0, cx = 12, cy = 12;
  let d = '';
  for (let i = 0; i < teeth * 2; i++) {
    const a0 = (i / (teeth * 2)) * Math.PI * 2 - Math.PI / 2;
    const a1 = ((i + 1) / (teeth * 2)) * Math.PI * 2 - Math.PI / 2;
    const rad = i % 2 === 0 ? R : r;
    const p0 = [cx + rad * Math.cos(a0 + 0.06), cy + rad * Math.sin(a0 + 0.06)];
    const p1 = [cx + rad * Math.cos(a1 - 0.06), cy + rad * Math.sin(a1 - 0.06)];
    d += (i === 0 ? `M${p0[0].toFixed(2)} ${p0[1].toFixed(2)}` : `L${p0[0].toFixed(2)} ${p0[1].toFixed(2)}`) + `A${rad} ${rad} 0 0 1 ${p1[0].toFixed(2)} ${p1[1].toFixed(2)}`;
  }
  d += 'Z';
  return filled
    ? `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" fill-rule="evenodd" d="${d}M12 15.3a3.3 3.3 0 1 0 0-6.6 3.3 3.3 0 0 0 0 6.6Z"/></svg>`
    : `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/><circle cx="12" cy="12" r="3.2"/></svg>`;
}

function tasksGlyph(size, filled) {
  // checklist: three rows, leading check circles
  const rows = [6.5, 12, 17.5];
  const fill = filled ? 'currentColor' : 'none';
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    ${rows.map((y, i) => `<circle cx="5.2" cy="${y}" r="2.3" fill="${i < 2 ? fill : 'none'}" stroke-width="1.6"/>`).join('')}
    <path d="M10 6.5h10M10 12h10M10 17.5h7"/></svg>`;
}

/**
 * Orbit mark — simplified vector symbol for 16–24 pt (Live Activity, Dynamic Island, status lines).
 * Body silhouette + tilted apricot ring (front/back occlusion) + single satellite. Proposed asset: orbit-mark.svg.
 */
function orbitMark(size = 24, { face = false, body = '#F7ECDF', stroke = null, ring = '#F2A15F', sat = '#EE8A3C', spin = false } = {}) {
  const st = stroke ? `stroke="${stroke}" stroke-width="1.6"` : '';
  const ringBack = `<path d="M7 40 A25 8.2 0 0 1 57 40" fill="none" stroke="${ring}" stroke-width="3.4" stroke-linecap="round" opacity=".85"/>`;
  const ringFront = `<path d="M7 40 A25 8.2 0 0 0 57 40" fill="none" stroke="${ring}" stroke-width="3.6" stroke-linecap="round"/>`;
  const bodyPath = 'M32 56 C20.5 56 14.5 47.5 15.4 37.4 C16.2 28.4 21 21.6 24.6 16.6 C26.2 14.3 26.8 10.6 27.8 7.4 C28.5 5.3 30.7 5.2 31.6 7.1 C33.2 10.6 35.6 14.4 39.6 17.4 C45.6 21.9 49.2 28.6 49.2 37.4 C49.2 48 43.4 56 32 56 Z';
  const eyes = face ? `<ellipse cx="26.6" cy="34.6" rx="2.5" ry="3.1" fill="#3A2A22"/><ellipse cx="38.4" cy="34.6" rx="2.5" ry="3.1" fill="#3A2A22"/><ellipse cx="27.3" cy="33.6" rx=".8" ry=".9" fill="#fff"/><ellipse cx="39.1" cy="33.6" rx=".8" ry=".9" fill="#fff"/><path d="M30.6 40.2 q1.4 1.2 2.8 0" stroke="#3A2A22" stroke-width="1.2" fill="none" stroke-linecap="round"/><ellipse cx="22.6" cy="40.4" rx="2.6" ry="1.6" fill="#F6B9A0" opacity=".55"/><ellipse cx="42.6" cy="40.4" rx="2.6" ry="1.6" fill="#F6B9A0" opacity=".55"/>` : '';
  return `<svg width="${size}" height="${size}" viewBox="0 0 64 64" aria-hidden="true"${spin ? ' class="spin"' : ''}>
    <g transform="rotate(-14 32 40)">${ringBack}</g>
    <path d="${bodyPath}" fill="${body}" ${st}/>
    ${eyes}
    <g transform="rotate(-14 32 40)">${ringFront}<circle cx="50.2" cy="46.2" r="4.6" fill="${sat}"/></g>
  </svg>`;
}
