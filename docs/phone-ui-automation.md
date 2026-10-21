# Phone UI Automation Integration: Execution Steps (Handoff to the Implementation Agent)

**English** | [简体中文](手机UI自动化-执行步骤.md)

Date: 2026-10-15, revised v2. Repository: `/Users/herrysyu/Documents/OpenPersonalAgent`; reference project: `/Users/herrysyu/Documents/ChatGPT/OpenMuse`, read-only; do not modify it.

## 0. Background and goal

- The Mac version of WeChat blocks computer use, so the original approach of using WeChat Mini Programs / Official Accounts through Mac WeChat does not work.
- New approach: migrate OpenMuse’s phone automation capability and expose it as MCP tools callable by Codex. Anything that cannot be done on the computer—for example WeChat Mini Programs, Official Accounts, services available only in a phone App, or actions requiring a phone login session—goes through phone UI automation.
- The user’s phone is **not connected yet**. First finish the code and pass all offline tests in this round; the user will run the real-device tests later. See §7.

Before starting, read these files:
- [`docs/architecture.md`](architecture.md) (Chinese source: `docs/方案.md`)
- `skills/china-services/SKILL.en.md`
- `host/src/codex/bridge.ts`
- `host/src/butler/{butler,brain,tools,prompt}.ts`
- OpenMuse’s `loong/skills/autoglm.py`
- OpenMuse’s `loong/devices/android.py` (only inspect `_parse_foreground_activity` and related regular expressions)
- `phone_agent/config/prompts_zh.py` after `phone/.venv` is installed

## 1. Decisions confirmed by the user (must follow)

1. **Automatically allow sensitive taps.** The user explicitly agreed to keep OpenMuse’s confirm=lambda _: True semantics: payment and privacy-related buttons on the phone do not ask the user for approval and execute directly. The tradeoff is that every sensitive tap must be written to the audit log (see step 2.4). **Login, verification codes, and QR scanning still go back to a person**, because automation cannot complete them; these are not approval steps.
2. **Device**: the user’s Xiaomi Android phone is dedicated to agent use:
   - Model `23116PN5BC`, serial `e7fe2f2a`
   - Android 17 / API 37, resolution 1440×3200, density 560
   - Foreground detection must read `topResumedActivity`; `mCurrentFocus` does not exist on this device

   Default `OPA_PHONE_SERIAL=e7fe2f2a`. V1 supports Android (ADB) only. Because this is a dedicated device, there is no need to account for disturbing the user’s primary phone.
3. **The phone sub-agent uses the same model and Codex agent settings; do not use Zhipu autoglm-phone and do not require a separate API Key.** Create a Codex worker session to act as the phone sub-agent:
   - Follow the existing Codex session model rule: prefer `settings.models.codexDefault`, otherwise use `bridge.defaultModel()`; billing uses the ChatGPT subscription.
   - The MCP server only provides low-level “see screen / tap / swipe / type” primitives and **does not call any model**.
   - The Codex worker performs visual understanding and the decision loop: the screenshot is passed to the model through MCP `ImageContent`, and the model calls tools such as tap and swipe.
   - Rewrite OpenMuse and Open-AutoGLM action experience (coordinate grid, action rules, `_DECISIVE_RULES`) as a skill for this worker.

## 2. Current-state notes (verified at the time)

- Host is TypeScript. Test command: cd host && npx tsc --noEmit && OPA_HOME=/tmp/opa-test npx vitest run; all 19 tests currently pass.
- The brain is itself a Codex thread (`brain.ts`) with shell, apps, and plugins built-in capabilities disabled; our tools are registered as dynamic tools. The worker session does the actual work and is created by `bridge.createSession`. `thread/start` config can override configuration per thread (the brain uses this to disable built-in features).
- Approval routing is in `butler.ts`’s `onApprovalAsk`. MCP elicitation is handled by the `mcpServer/elicitation/request` branch in `bridge.ts`. Codex may also request elicitation while calling an MCP tool (with _meta.codex_approval_kind = "mcp_tool_call"); this was seen during earlier computer-use testing.
- OpenMuse has made several fixes to Open-AutoGLM’s ADB layer that must be migrated:
  - Foreground App detection: read `topResumedActivity`
  - Support launching an App by package name
  - Compress screenshots to JPEG (longest side no more than 1280) while keeping original pixel dimensions for coordinate conversion
  - Use a 0–999 coordinate grid (`_to_device_point`); values over 999 are treated as real pixels
- Dependencies: `mcp==2.3.0` is available from PyPI and was verified to include `mcp.server.fastmcp`. Upstream ADB library is phone-agent @ git+https://github.com/zai-org/Open-AutoGLM.git@86f55382982fb054e8fc98ca80609dff8a2cdc3c (`phone_agent.adb.*` and `phone_agent.config.apps.APP_PACKAGES`). This machine has uv 0.11.6 and Python 3.12.

## 3. Architecture

    Brain (Codex thread) ──phone_task──▶ host creates “📱 Phone sub-agent” worker session
                                       (model = Codex default/settings; inject orbit_phone MCP + phone-automation skill at thread/start)
    Phone sub-agent (Codex) ──MCP tools/call──▶ orbit-phone (Python, stdio, no model) ──ADB──▶ Xiaomi phone
             ▲ observe returns screenshot (ImageContent) + foreground App + optional UI-tree summary │
             └──────────── tap/swipe/type/back/home/launch… ◀──────────────────────────────────────┘

- Create a Python package under `phone/` as a standalone MCP stdio server named `orbit_phone`.
- Inject it **only** into the phone sub-agent worker session: use `thread/start` `config.mcp_servers.orbit_phone` per thread. **Do not** add it to global `~/.codex/config.toml`, or the brain and other sessions will also get the phone tools.
- Disable computer use for this worker (`config.features.computer_use=false`) so it cannot operate the Mac. Keep shell enabled so it can read and write workspace files.
- Each Codex session starts its own MCP process, so device locking and cancellation signals must work across processes, using a file lock and cancellation marker file.

## 4. Implementation steps

### Step 1: Python package `phone/` (MCP server; does not call a model)

    phone/
      pyproject.toml        # name=orbit-phone, requires-python>=3.11
      orbit_phone/__init__.py
      orbit_phone/adb.py    # migrate OpenMuse ADB fixes: foreground parsing, package launch, screenshot compression, coordinate conversion
      orbit_phone/lock.py   # cross-process device lock + cancellation marker
      orbit_phone/server.py # FastMCP stdio entry point: python -m orbit_phone.server
      tests/test_*.py

Pin dependencies to exact versions: `mcp==2.3.0`, phone-agent @ git+…@86f55382982fb054e8fc98ca80609dff8a2cdc3c (use only `phone_agent.adb` and `config.apps`; **do not** use `PhoneAgent` / `ModelClient`), `Pillow==12.3.0`. Dev dependencies: `pytest==9.1.1` and `pytest-asyncio==1.4.0`. Run uv sync to generate `uv.lock`; put the venv at `phone/.venv`.

**adb.py**:
- `list_devices()`: parse adb devices -l.
- `pick_serial()`: prefer `OPA_PHONE_SERIAL` (default `e7fe2f2a`); otherwise select the only device whose state is device; return a clear error if none is available.
- `status(serial)`: return screen-on/locked state, foreground package and Activity (migrate OpenMuse’s `_parse_foreground_activity` and its regular expressions), whether ADB Keyboard is installed, and screen dimensions.
- `screenshot(serial)`: return compressed JPEG base64 and original width/height. Migrate from OpenMuse’s `_install_screenshot_fix`; accurately mark `is_sensitive` pages (for example, a blacked-out password page).
- ui_tree(serial, max_nodes=120): optional uiautomator dump; keep only clickable or text-bearing nodes and convert coordinates to the 0–999 grid. **Redact** password-field and input-field content (refer to OpenMuse `android.py`’s `_SENSITIVE_WORDS`). If dump fails, return an empty list without throwing an error.
- `to_device_point()`: migrate `_to_device_point`.
- For other actions, directly call `phone_agent.adb` tap, double_tap, long_press, swipe, back, home, type_text, clear_text, detect_and_set_adb_keyboard, restore_keyboard, and launch_app with the “launch by package name” patch.
- Pass every adb call as an argument array; do not use shell command strings.

**lock.py**:
- Lock file: `~/.opa/phone/<serial>.lock` (`fcntl.flock`); the owner writes the task description to the file.
- Cancellation marker: `~/.opa/phone/<serial>.cancel`.
- Provide acquire(task) / release().

**server.py**: implement with FastMCP. Tool descriptions must state purpose, when to use each tool, parameter meaning, and the coordinate convention (0–999 grid, top-left is 0,0):
- `phone_begin`(task: str): acquire the device lock, clear the cancellation marker, return status and the first observe result. If the lock is unavailable, return busy and the current owner.
- `phone_observe`(include_tree: bool = True): return `ImageContent` (screenshot) plus `TextContent` (JSON containing foreground App, screen dimensions, whether the page is sensitive, and optional UI-tree summary).
- phone_tap(x, y), `phone_double_tap`, phone_long_press(x, y, ms=800), phone_swipe(x1, y1, x2, y2, ms=300), `phone_type(text)` (switch to ADB Keyboard before input and restore the previous IME afterwards), `phone_clear_text`, `phone_back`, `phone_home`, `phone_launch(app)` (accept a Chinese name from `APP_PACKAGES` or a package name), `phone_wait(seconds≤10)`.
  - After each action, wait about 0.6 seconds and automatically attach a fresh screenshot to the response to avoid an extra observe round trip.
  - Before each action, check the cancellation marker; return cancelled if cancellation has been requested.
  - Reject actions directly if the caller does not hold the lock (did not call begin).
- `phone_end`(summary: str): save one final screenshot to `~/.opa/phone/evidence/<ts>.jpg`, release the lock, and return the screenshot path.
- `phone_devices()` and `phone_cancel()`: read-only or control tools; set `readOnlyHint`.
- No model is called, so no API Key is required.
- **stdout is the MCP protocol channel**: some `phone_agent.adb` functions print, so redirect `sys.stdout` to stderr at startup and reserve actual stdout for the MCP transport. Add a test proving stdout is not contaminated.
- Release the lock on process exit if it is still held.

**Tests** (all offline; mock `subprocess.run` / `phone_agent.adb`):
- Coordinate conversion boundary cases
- Foreground Activity parsing (use the Android 17 dump sample from OpenMuse)
- Device-lock mutual exclusion with two processes or threads
- Cancellation marker behavior
- Reject actions called before begin
- UI-tree redaction
- Call `phone_devices` and `phone_observe` using an in-memory MCP client; verify `ImageContent` structure
- stdout is not contaminated

### Step 2: Host wiring (TypeScript)

1. Add `host/src/phone/config.ts` with `phoneMcpConfig()`, returning `{ command: <repo>/phone/.venv/bin/python, args: ['-m', 'orbit_phone.server'], env: { OPA_PHONE_SERIAL, OPA_HOME }, startup_timeout_sec: 30, tool_timeout_sec: 120 }`.
   - `OPA_PHONE_CMD` may override command.
   - If the venv is missing, return undefined and provide the reason.
   - Use field names from Codex `config.toml`. **Before implementation**, confirm them with codex app-server generate-json-schema --experimental or `config/read`.
   - Then verify with one real `thread/start` plus `mcpServerStatus/list`: after injecting `config.mcp_servers.orbit_phone`, that thread must show this server. A script under `host/scripts` may be used; no real phone is needed.
2. In `bridge.ts`, add phone?: boolean to `CreateSessionOpts`. When true, merge { `mcp_servers`: { `orbit_phone`: `phoneMcpConfig()` }, features: { computer_use: false } } into `thread/start.config`. Do not change model selection: o.model ?? defaultModel(), the same as other Codex sessions. If phone support is unavailable, throw an error that says to run opa phone setup.
3. In `tools.ts`:
   - Add `phone_task`(title, goal, china=true, task_id, step_id, deliverable). It creates a phone: true session, prefixes the title with 📱, attaches the phone-automation skill, adds china-services when china is true, and uses `settings.models.codexDefault`.
     - The task brief must say: use orbit_phone tools to do the work on the phone; call phone_begin first and phone_end last; do not operate the Mac; return structured JSON at the end.
     - Allow only one 📱 session at a time, following the 🖥 logic in computer_use_task.
   - Remove WeChat-specific material from the `computer_use_task` description and change it to “WeChat / phone Apps always use `phone_task`”.
   - Add read-only `phone_status`, returning whether `phoneMcpConfig()` is available and the reason.
4. Approval (automatically allow sensitive taps): in `bridge.ts`’s elicitation branch, when `serverName === 'orbit_phone'`, accept directly without calling `onApprovalAsk`. Every time, call `db.audit('phone', 'auto-accept', {thread, tool: meta.tool_name, params: meta.tool_params_display})`; bridge therefore needs an audit callback injected by Butler. Likewise, automatically approve any Codex MCP-tool-call approval such as `item/permissions/requestApproval` for `orbit_phone`.
   - Optional: if Codex supports an MCP tool approval mode in `mcp_servers` (such as `default_tools_approval_mode` / `approval_mode`), set it to no-prompt in injected config only after confirming the schema.
   - **Login, verification codes, and QR scans are not included in auto-allow**: the skill must tell the child agent to call `phone_end` and return `status:"needs_human"` in these cases; the brain then notifies the user through notify and `ask_user` to handle the phone.
5. `prompt.ts`: add a **“手机（phone_task）” (Phone)** section to the resource description with these points:
   - Hand work the computer cannot do to the phone; WeChat Mini Programs and Official Accounts always use the phone.
   - This is a dedicated Xiaomi phone and can be operated freely.
   - Sensitive phone taps (such as payment) execute automatically, so **confirm the user’s intent before dispatch**: only put ordering/payment in the task brief when the user explicitly asks for it; otherwise write “只查询，不要下单 / 付款”.
   - If the device is busy, wait until the previous task is done.
   - Validate the result.
6. Add a “手机：可用 / 未配置（原因）” (“Phone: available / not configured (reason)”) line to `butler.ts` `statusBar()`.
7. `cli.ts`:
   - Add opa phone setup: run uv sync inside `phone/`.
   - Add opa phone status: print configuration, run adb devices -l, and check ADB Keyboard and “USB 调试（安全设置）” readiness. To check the latter, try input keyevent 0; if it fails, tell the user to enable it.
   - **No** set-key is needed.
8. Tests:
   - Unit test `phoneMcpConfig`.
   - Extend `test/fake-codex.mjs` to record `thread/start` config. In `loop.test.ts` assert that after the brain calls `phone_task`, the worker has `config.mcp_servers.orbit_phone`, features.computer_use === false, and uses the same model as other sessions; the brain thread config must **not** contain `orbit_phone`.
   - `orbit_phone` elicitation is automatically accepted and audited; other servers still use the existing approval flow.

### Step 3: Skills and documentation

1. Create `skills/phone-automation/SKILL.md` for the phone child agent, and sync a copy to Codex using the same method as opa install-skills. Rewrite the action rules from Open-AutoGLM `prompts_zh.py` and OpenMuse’s `_DECISIVE_RULES`:
   - Work loop: `phone_begin` → inspect screenshot and UI tree → do one action → judge the result from the returned screenshot → repeat → `phone_end`.
   - Coordinates use a 0–999 grid; prefer the center of a UI-tree element, and estimate from the screenshot only if no UI tree is available.
   - Open Apps with `phone_launch`. Before entering text, tap the input field and then call `phone_type`.
   - For lookup-only tasks, stop as soon as the current screen answers the question; do not open details repeatedly just to add information. Tap the same position at most twice; if nothing happens, try another method.
   - Pop-ups: close ads and update prompts directly; grant system permissions as needed for the task, including location, phone number, and privacy-related access.
   - When login, verification code, QR scanning, or face recognition appears, immediately call `phone_end` and return `needs_human`, clearly explaining what the user must do.
   - Payment and ordering: proceed only when the task brief explicitly authorizes it; otherwise stop at the confirmation page, return order details, and mark `needs_approval`.
   - End with JSON matching GenUI cards (order_card / ticket_card / booking_card / table) and attach the evidence screenshot path.
2. Rewrite `skills/china-services/SKILL.md`:
   - Always use the phone through `phone_task` for WeChat Mini Programs, Official Accounts, and WeChat services. Phone route: open WeChat → top search → 搜一搜 → filter “小程序 / 公众号 / 服务” → open target.
   - Remove the Mac WeChat computer-use flow and explain why.
   - Keep browser for services with a web version; use the phone only for App-only services.
   - Keep the structured JSON ending requirement.
   - Change “do not pay” to “pay only when explicitly authorized in the task brief”.
3. Update [`docs/architecture.md`](architecture.md) (Chinese source: `docs/方案.md`): add `orbit_phone` to §5.1 and §3, and state that the phone child agent shares Codex’s model and billing. Sync the getting-started steps in `README.md` and `host/README.md`.

### Step 4: One-time device setup (write these steps in README for the user)

1. On the Xiaomi phone, turn on “USB 调试” and “USB 调试（安全设置）” in Developer Options. Without the latter, tap injection and typing will not work. Connect to the Mac by USB and authorize it on the phone.
2. Install ADB Keyboard (download the APK from https://github.com/senzhk/ADBKeyBoard/releases): run `adb install ADBKeyboard.apk`, then enable it in phone settings.
3. Install and sign in to WeChat, Meituan, and other Apps. In Developer Options, enable “充电时不锁屏” or set a long screen timeout; disable the lock-screen password or keep the phone unlocked.
4. Run `opa phone setup`, then `opa phone status`.
5. Optional wireless connection: adb pair → adb connect, then set `OPA_PHONE_SERIAL=<ip:port>`.

## 5. Constraints (must follow)

- Do not modify the OpenMuse repository; copy code only.
- Do not add `orbit_phone` to global `~/.codex/config.toml`; the brain thread must not receive phone tools.
- Do not configure a separate model for the phone child agent or add a new API Key. Use the same model-selection rules as Codex sessions.
- Automatically allow sensitive taps, but audit every one. Login and verification codes still go to a person.
- Pin dependencies exactly; do not pass ADB calls through shell command strings; redact input-field contents in UI trees and logs.
- Do not change the iOS project or `docs/protocol.md`.
- Do not git commit unless the user asks.

## 6. Acceptance (offline; all required this round)

    cd phone && uv sync && .venv/bin/python -m pytest -q
    cd host && npx tsc --noEmit && OPA_HOME=/tmp/opa-test npx vitest run

Also run these manual smoke checks:
- With no phone connected, run `phone/.venv/bin/python -m orbit_phone.server` directly and use a small MCP client to call `phone_devices`. Expected: an empty list and a clear hint; the process must not crash.
- Create a real Codex session with phone: true and call `mcpServerStatus/list`. Confirm `orbit_phone` and its tool list are visible.

Submit a report listing changed files, test results, and items that still require a real-device check.

## 7. User real-device test checklist (the implementation agent must not run these; include them in the report)

1. opa phone status: shows `e7fe2f2a`, state device, ADB Keyboard ready, and USB debugging (security settings) ready.
2. Read-only task: “在手机微信里搜一下‘瑞幸咖啡’小程序，告诉我附近门店”. Expected: task card, 📱 session, and structured result appear in order; no order is placed.
3. Authorized order: “用美团帮我点一杯 xx 咖啡，直接付款”. Expected: the phone child agent taps through payment automatically, the audit contains auto-accept, and the result is an order_card. (Test only if an actual charge is acceptable.)
4. Unauthorized order: “用美团看看 xx 咖啡多少钱”. Expected: stop before the confirmation page, return the price, and do not pay.
5. Login or verification code: return `needs_human` when encountered and notify the iPhone user.
6. Cancellation: stop from the task or interrupt from the task page while it is in progress; the phone stops at the next step and releases the device lock.
7. Busy device: dispatch two phone tasks at once; the second reports that the device is busy and waits until the first completes.
