import type { HostRelay } from "./relay";
import type { TunnelRelay } from "./tunnel";

export interface Env {
  HOST_RELAY: DurableObjectNamespace<HostRelay>;
  TUNNEL_RELAY: DurableObjectNamespace<TunnelRelay>;
  /** Optional comma-separated list of hostIds allowed to register. */
  ALLOWED_HOST_IDS?: string;
  /** Optional comma-separated list of phoneIds allowed to open an ADB tunnel. */
  ALLOWED_PHONE_IDS?: string;
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
}
