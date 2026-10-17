export type Route =
  | { kind: "healthz" }
  | { kind: "host"; hostId: string }
  | { kind: "device"; hostId: string }
  | { kind: "tunnel_phone"; phoneId: string }
  | { kind: "tunnel_client"; phoneId: string }
  | { kind: "not_found" };

export function matchRoute(method: string, pathname: string): Route {
  if (method !== "GET") return { kind: "not_found" };
  if (pathname === "/healthz") return { kind: "healthz" };
  const t = /^\/v1\/tunnel\/([^/]+)\/(phone|client)$/.exec(pathname);
  if (t) return { kind: t[2] === "phone" ? "tunnel_phone" : "tunnel_client", phoneId: t[1] };
  const m = /^\/v1\/(host|device)\/([^/]+)$/.exec(pathname);
  if (!m) return { kind: "not_found" };
  return { kind: m[1] as "host" | "device", hostId: m[2] };
}
