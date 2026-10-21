// What the bot is doing while a tool runs, in words for the person watching — sent as `butler.status` `detail`
// (docs/protocol.md §4.4) and shown by the app as-is. The raw tool name travels separately in `tool`.

/** Shown for anything without a specific phrase (web search and other built-ins, tools added later). */
export const FALLBACK_ACTIVITY = '处理中';

const LABELS: Record<string, string> = {
  // 自我管理
  yield: '收尾', // never shown: runTool keeps the state idle for it
  skill_load: '查阅方法',
  mcp_list: '查看服务能力',
  task_create: '建立任务',
  task_update: '更新任务',
  schedule: '设提醒',
  schedule_cancel: '取消提醒',
  watch: '留意执行进展',
  // Codex、电脑、手机
  codex_session_create: '派出任务',
  computer_use_task: '操作电脑',
  phone_task: '在手机上操作',
  phone_status: '检查手机状态',
  codex_session_send: '给执行会话补充指令',
  codex_session_steer: '给执行会话补充指令',
  codex_session_interrupt: '中止执行会话',
  codex_session_status: '查看执行进度',
  codex_sessions_list: '查看执行会话',
  codex_session_archive: '归档执行会话',
  codex_sessions_fork: '复制执行会话',
  codex_session_goal: '设定执行目标',
  codex_set_permission: '调整执行权限',
  codex_models: '查看可用模型',
  codex_answer: '回答执行会话的提问',
  connectors_list: '查看可用服务',
  connector_call: '查询服务',
  // 交互
  ui_render: '整理结果',
  ui_patch: '整理结果',
  ask_user: '准备问题',
  request_approval: '请求你确认',
  approval_decide: '处理审批',
  notify: '发通知',
  // 感知与记忆
  device_context_get: '了解你的当前情况',
  memory_write: '记下',
  memory_confirm: '确认记忆',
  memory_search: '回想',
  memory_delete: '忘掉',
  import_list: '查看导入内容',
  import_read: '阅读导入内容',
  import_mark: '整理导入内容',
  artifact_read: '查阅完整内容',
};

/** Short Chinese phrase for a tool name, e.g. `codex_session_create` → 「派出任务」; 「处理中」 when unknown. */
export function toolActivityLabel(name: string): string {
  return Object.hasOwn(LABELS, name) ? LABELS[name] : FALLBACK_ACTIVITY;
}
