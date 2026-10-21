---
name: codex-orchestration
description: Load when dispatching work to a Codex session. Covers task briefs, models, permissions, reuse, interruption, verification, and monitoring. Prefer currently available and authorized service MCPs / plugins; use computer or phone UI only when interfaces and feasible websites cannot cover the task.
---

**English** | [简体中文](SKILL.md)

# codex-orchestration: Dispatch and manage Codex sessions

## 1. Decide whether to open a session

For each external-service task, check `mcp_list` and/or `connectors_list` according to relevance, looking only at capabilities related to the target steps. Prefer a currently available and authorized service MCP / plugin that covers those steps. `configured` means only that local configuration is present; it does not establish a connection or account access. Use exposed tools and actual call results as evidence. Use `connector_call` for a single connector operation; dispatch multi-step tasks to Codex and name the listed plugins / MCPs. A built-in catalog MCP must be explicitly selected through `codex_session_create.mcp_services`; do not assume it is loaded. If an interface or permission is missing, stop retrying and explain what connection or authorization is needed. If the user did not specify a channel and a public website is feasible, use search / browser next. Use computer or phone UI only when interfaces and websites cannot cover the task, and state the actual reason in the brief. Do not automatically install, change connections, obtain credentials, or call an unknown service. Preserve the user's specified channel, authorization, and MCP selections within the same session.

| Situation | Action |
|---|---|
| A connected connector can complete a single query or explicit read/write | Call `connector_call` directly; follow existing authorization for writes |
| Only a built-in MCP covers a single operation | Create an execution session, select it through `mcp_services`, and name the operation in the brief |
| Multi-step operation, cross-service synthesis, or a specialized MCP is needed | Use `codex_session_create`; name the currently listed plugins and selected MCP |
| Service interface does not cover the task, but an official public website can | Answer directly using search, or use a feasible browser path; confirm and select Playwright MCP as needed |
| The task truly requires UI, and interfaces / websites cannot cover it | Use `computer_use_task` for Mac GUI; use `phone_task` only when a mobile app or mobile login is truly required |
| The user specifies a channel | Use it; if a technical limitation prevents completion, explain why and ask the owner to choose an alternative rather than silently switching |
| The task continues work from an active session | Reuse that session with `codex_session_send` |

For the dedicated phone and Mac WeChat: the phone cannot use WeChat, and Mac WeChat blocks computer use. If no authorized interface or standalone website covers the current task, explain the limitation and ask the owner to complete it in their own WeChat.

## 2. Create / reuse / steer / interrupt

- **Create** for a new independent goal; when the old session has too much context or the direction has changed completely; or when a different model, permission, or working directory is needed.
- **Reuse** with `codex_session_send` for the next step in the same Task when it needs earlier context (for example, "Check the menu at the second of the three places you just found"). Send only when the session is idle.
- **Steer** with `codex_session_steer` when the session is running and the user adds or corrects a requirement ("Make the budget under 300" or "window seats only"). Do not interrupt; let the current turn absorb it.
- **Interrupt** with `codex_session_interrupt` when the user cancels; the session is clearly off course and steering did not help; it is doing something harmful; or it exceeds budget. After interrupting, send a corrected brief again when appropriate.
- **Fork** with `codex_sessions_fork` to try two approaches from the same intermediate state.
- **Archive** a completed Task's session when there is no follow-up, to keep the board tidy.

## 3. Task brief template (use on every create or new task sent)

~~~text
## Goal
<One sentence describing a verifiable result. Example: Find 3 Sichuan restaurants on Meituan delivery with arrival within 30 minutes and per-person cost under 50 yuan; stop before ordering.>

## Background
<Only information needed for this task: location, time, relevant preferences ("no cilantro"), and a summary of prior results. Do not include unrelated memory.>

## Constraints
- Do not pay; stop at the payment page
- Do not message any contacts
- Budget / time / channel limits: <…>
- Read/write scope: <…>

## Permissions
<Current mode: manual or auto; actions to report instead of perform directly.>

## Tools
<Name needed plugins or skills. Example: use Google Calendar plugin; use Google Drive plugin; use china-services skill.>

## Delivery format
The final message must end with a ```json code block containing fields:
<List field names and types, for example {"status","items":[{"name","price","eta"}],"screenshots":[]}>
Use null for unavailable fields; do not invent values.

## If blocked
For login, verification code, phone authorization, a price / merchant mismatch, payment, or messaging: stop immediately, report using the delivery format with status="blocked" or "needs_approval", and explain why. Do not guess or work around the restriction.
~~~

When `outputSchema` is available, also pass a structured schema. Align delivery fields with GenUI component props (order → `order_card`, ticket → `ticket_card`, booking → `booking_card`, multiple comparisons → `comparison` / `table`) so the result can render directly.

Use the `phone_task` template for phone work: `orbit_phone` is required; call `phone_begin` first and `phone_end` last; do not operate Mac. Put purchase authorization in the brief only when the user explicitly authorized ordering and payment; otherwise state "只查询，不要下单 / 付款". Handle phone and privacy permissions only as required. Return `needs_human` for login, verification codes, QR scans, and face recognition.

## 4. Choose model and effort

The owner's setting "Execution model" (`models.codexDefault`) controls worker models:

- When the owner specifies a non-empty execution model, all workers use it, including `codex_session_create`, `computer_use_task`, `phone_task`, and a new turn started by `codex_session_send` while the session is idle (if the owner changes the execution model mid-task, the next turn uses the new one). In this case, `codex_session_create`'s `model` parameter has no effect: omit it, and do not create a new session just to change models. `steer` cannot change the model.
- Only when the owner sets the execution model to "automatic" (empty) may you choose. Pass an ID from `codex_models` to `codex_session_create.model`; `computer_use_task`, `phone_task`, and `codex_session_send` do not have a `model` parameter and use the Codex default tier.

Reasoning effort is similarly controlled by the owner's "Execution task reasoning effort" setting (`models.codexEffort`):

- When the owner specifies a non-empty effort, all workers use it for every turn, including `codex_session_create`, `computer_use_task`, `phone_task`, and a new turn started by `codex_session_send` while the session is idle. In this case, `effort` on `codex_session_create` or `codex_session_send` has no effect: omit it, and do not create a new session just to change effort. `steer` cannot change effort.
- Only when the owner sets effort to "automatic" (empty) may you choose. For `codex_session_create` and `codex_session_send` (when the session is idle and starts a new turn), pass `low / medium / high / xhigh` as applicable. `computer_use_task` and `phone_task` have no `effort` parameter and use the Codex default effort. Omit it to use the Codex default.
- Choose an effort supported by the target model (see `efforts` in `codex_models`); the host discards unsupported effort values, which is equivalent to not passing one.

When you can choose, first use `codex_models` to get the current available list and only use names from that list; do not invent model names from memory:

| Task | Model tier | Effort (only when effort is "automatic") |
|---|---|---|
| Simple lookup, one price, form filling, formatting | `isDefault` or a tier labeled fast / mini (the corresponding `default_subagent_model`) | low |
| Compare multiple sources, plan a trip, summarize long documents | Default or high tier | medium |
| Complex research, coding, multi-step reasoning, high cost of error | Strongest tier in the list | high |
| Mac computer use / phone UI automation | Codex default tier (no separate phone model) | None (these tools have no `effort` parameter) |

If a task becomes more complex than expected, start a new high-tier session to take over rather than retrying repeatedly in a low-tier session. If the owner specified an execution model, you cannot change tiers; make the task brief clearer and adjust effort only if the owner has not also specified it. If the owner specified both, neither can be changed; rely on a clear task brief.

## 5. Permissions

- Default to the `defaultPermission` setting, usually manual (`untrusted` / `on-request` + `workspaceWrite`).
- Consider auto (`never` + `dangerFullAccess`) only when continuous unattended execution is genuinely required and manual mode would repeatedly block it:
  - If `allowAutoFullAccess = true`, you may use `codex_set_permission` to upgrade, and tell the user in your report.
  - Otherwise, call `request_approval` first, explaining why the broader permission is needed, what it will do, and for how long. Upgrade only after approval.
- Downgrade to manual at the end of the task or phase.
- Approval routing: low-risk (read-only commands, writing files inside the workspace) is auto-approved; assess medium risk yourself and record it; high risk (payment, messaging, deletion, external publication, credential access) always goes to the user.
- Sensitive taps through `orbit_phone` are automatically allowed under the user's confirmed phone policy and audited one by one; this does not upgrade shell or file permissions. Make sure purchase intent is clear before dispatch. Phone workers share `settings.models.codexDefault` / Bridge default model and subscription billing with other Codex sessions; no extra API key is needed.

## 6. Service MCPs and plugins

- For each external-service task, use current tools and connection state returned by `connectors_list`; use only listed names. Call `connector_call` directly for one operation; for multiple steps, open a session and name the actual tool in the brief.
- For a built-in catalog service, use `mcp_list` to check relevant capabilities, enablement, and configuration. `configured` is not proof of a connection or authentication. If only a built-in MCP covers the step, select it when creating the worker using `mcp_services`. If a tool is not exposed, authorization is missing, or an actual call fails, stop retrying and explain what connection or authorization the owner must provide. Do not automatically install, change configuration, or obtain credentials. Switch to web search / browser only when the user did not specify a channel and a public website method is feasible.
- If a suitable service interface covers the target step, do not use computer use or phone UI to click through screenshots. Preserve a user-specified channel; if it cannot work, explain why and ask for an alternative.
- Continue to obtain authorization for writes under existing rules; payment, external messages, deletion, and publication still use existing approval. Put only task-relevant information in the brief.

## 7. Computer use and phone tasks

- `computer_use_task` and `phone_task` are UI fallback paths, not default service entry points. Before dispatch, confirm that relevant MCPs / plugins and feasible websites cannot complete the task, and include the actual reason in the brief. Respect a user-specified device / channel; report first if it cannot work.
- Use `computer_use_task` for Mac desktop apps or steps that require a logged-in desktop UI. Use `phone_task` only for steps that truly require a mobile app or mobile login session. The dedicated phone cannot use WeChat, and Mac WeChat blocks computer use; if there is no authorized interface or standalone website, leave it to the owner in their own WeChat.
- For mainland China services, include the `china-services` skill. The brief must specify the goal, actual reason for choosing a UI, and stop conditions. Phone tasks must name the official service, budget, and authorization scope, and include `phone-automation`.
- Run only one computer-use session at a time: they share the same screen and mouse, so parallel runs conflict. Other non-GUI sessions may run in parallel.
- If the user is using the computer (as shown by the status bar), tell them "我需要用一下电脑大约 3 分钟" before a GUI task or defer it.
- The dedicated Xiaomi phone is independent of the Mac and can run alongside Mac work; run only one phone session at a time. If busy, use `watch` for the current phone task; do not poll or seize the device lock.

## 8. Long tasks and thread goals

- For work requiring more than an hour of autonomous progress (long research, multiple rounds of coding, repeated price comparisons), use `codex_session_goal` to set a goal and token budget so Codex can keep going across turns.
- State completion criteria and budget in the goal, and `watch` for `thread/goal/updated` and completion / blocked events.
- Do not make a goal for work that requires an intermediate user decision; divide it into stages instead.

## 9. Monitoring

- Immediately after dispatch, call `watch(session_id, "done | blocked | waiting_approval | error")`, then `yield`.
- For work with an expected duration, add a `schedule` check (for example, an estimated 10-minute task can be checked after 20 minutes) so a silent stall is caught.
- Do not repeatedly call `codex_session_status` in a loop. Read a summary once after being awakened; use `artifact_read` to read only the needed original content.
- Use `task_create` / `task_update` to synchronize the Task and each Step's state. The phone's `task_progress` card depends on this.

## 10. Parallel work

- Start sessions together for independent Steps, such as "check high-speed rail" and "check hotels".
- Run no more than 4 sessions at once (at most 1 Mac computer-use session and 1 phone session). Queue any excess.
- After parallel results arrive, combine them into one card (`comparison` or `table`); do not report every session separately.

## 11. Cost control

- Do not open a session when one `connector_call` can do the job; do not use a high-tier model when a lower one is enough.
- Include only necessary context in the task brief; do not paste the full conversation history.
- When reusing a session, send only incremental instructions.
- Give goals a token budget. If a session is going in circles (the same step fails more than three times or output repeats), interrupt it, change approach, or report to the user.
- Archive completed sessions promptly.

## 12. Failure handling

| Situation | Response |
|---|---|
| Session returns blocked (login, verification code) | Tell the user what to do ("请在你自己手机的微信上确认登录"), `watch` for follow-up, and use `codex_session_send` to continue after they finish |
| Phone session returns `needs_human` | Confirm `phone_end` released the lock; use `notify` and `ask_user` to state the human step. Resume in the same session and call `phone_begin` again after the user is done |
| `needs_approval` (phone authorization, payment) | Use `request_approval` or an approval card; continue after approval |
| Error / timeout / missing permission | Read recent output and verify the specific gap. Do not retry authentication or missing tools, or automatically switch to GUI; explain the needed connection or authorization. Retry a transient error once when there is a reason; use another channel only if the user did not specify one and the current capability supports it |
| Result does not meet completion criteria | Ask a follow-up or do more work; do not report an incomplete result as done |
| Result conflicts with the user's expectations (price doubled, sold out) | Stop and offer choices; do not spend money on a replacement plan yourself |

A failure report should say which step is blocked, what you already tried, and the next step you recommend (use `choice_list` to offer 2–3 options).
