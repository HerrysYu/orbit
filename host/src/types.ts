// App-level data shapes — docs/protocol.md §4.5.

export type TaskStatus = 'planning' | 'running' | 'waiting_user' | 'blocked' | 'done' | 'failed' | 'cancelled';
export type StepStatus = 'pending' | 'running' | 'done' | 'failed' | 'skipped';
export interface Step { id: string; title: string; status: StepStatus; sessionId?: string }
export interface Task {
  id: string; title: string; goal: string; status: TaskStatus; steps: Step[];
  summary?: string; createdAt: number; updatedAt: number;
}

export type SessionStatus = 'running' | 'idle' | 'waiting_approval' | 'error' | 'archived';
export type Permission = 'manual' | 'auto';
export interface Session {
  id: string; taskId?: string; title: string; model?: string; status: SessionStatus;
  permission: Permission; lastActivity?: string; createdAt: number; updatedAt: number;
}

export type Risk = 'low' | 'medium' | 'high';
export interface Approval {
  id: string; title: string; detail: string; risk: Risk; sessionId?: string;
  kind: 'command' | 'fileChange' | 'permissions' | 'elicitation' | 'action';
  requireBiometric: boolean; createdAt: number; expiresAt?: number;
}

export interface CardAction { id: string; label: string; style?: 'primary' | 'secondary' | 'destructive'; requiresApproval?: boolean }
export interface Card { id: string; component: string; props: Record<string, unknown>; actions?: CardAction[]; msgId?: string; ts: number }

export type MemoryKind = 'profile' | 'preference' | 'fact' | 'person' | 'place' | 'date';
export interface Memory {
  id: string; text: string; kind: MemoryKind; source: 'explicit' | 'inferred'; confidence: number;
  createdAt: number; updatedAt: number;
}

export interface Attachment { kind: 'image' | 'file' | 'link'; name?: string; mime?: string; dataB64?: string; url?: string }
export interface ImportItem {
  kind: 'photo' | 'link' | 'text' | 'file' | 'reminder' | 'note';
  title?: string; text?: string; url?: string; mime?: string; dataB64?: string; createdAt?: number;
}

export interface DeviceContext {
  timezone: string; locale: string; now: number; deviceName: string;
  location?: { lat: number; lon: number; accuracy: number; placeName?: string };
  battery?: { level: number; charging: boolean };
  network?: 'wifi' | 'cellular' | 'none';
  focus?: string;
  upcomingEvents?: { title: string; start: number; end: number; location?: string }[];
  reminders?: { title: string; due?: number; done: boolean }[];
}

export interface Settings {
  butler: { name: string; avatar?: string; userTitle: string; persona: string };
  /** Models are ids ('' = auto); the `*Effort` fields are Codex reasoning efforts ('' / null / missing = auto) — protocol.md §4.5. */
  models: { butler: string; heartbeat: string; codexDefault?: string; butlerEffort?: string; heartbeatEffort?: string; codexEffort?: string };
  proactivity: 'low' | 'normal' | 'high';
  heartbeatMinutes: number;
  quietHours: { start: string; end: string };
  dailyNotifyBudget: number;
  defaultPermission: Permission;
  allowAutoFullAccess: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  butler: {
    name: 'Orbit',
    avatar: undefined,
    userTitle: '你',
    persona: '温和、靠谱、有一点幽默感的私人伙伴。说话简短，先说结论。会主动替你操心，但不啰嗦。',
  },
  models: { butler: '', heartbeat: '' }, // '' = Codex 默认模型
  proactivity: 'normal',
  heartbeatMinutes: 30,
  quietHours: { start: '23:00', end: '08:00' },
  dailyNotifyBudget: 8,
  defaultPermission: 'manual',
  allowAutoFullAccess: false,
};
