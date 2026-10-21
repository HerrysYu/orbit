# OPA Host (Mac Butler)

**English** | [简体中文](README.zh-CN.md)

The butler brain, Codex control layer, and iPhone gateway run continuously on the Mac. Requires Node ≥ 22.13 and an installed, signed-in `codex` CLI. The brain and workers use Codex and do not need a separate OpenAI API key. All workers (ordinary sessions, computer use, phone workers, and new turns in reused sessions) prioritize the App's “执行模型” (Execution model) setting, `settings.models.codexDefault`. If that setting is empty (automatic), they use the model selected by the bot; if neither is set, they fall back to the Codex default model.

```bash
cd host
npm install
npx tsx src/cli.ts config relay wss://<your-worker>.workers.dev  # configure when accessed over the internet
npx tsx src/cli.ts install-skills          # link china-services and phone-automation
npx tsx src/cli.ts start
npx tsx src/cli.ts pair                    # in another terminal, display a QR code and verify the SAS
npx tsx src/cli.ts chat                    # chat with the butler in the terminal
npx tsx src/cli.ts launchd                 # create a LaunchAgent that starts at login
```

After installing the Host's `opa` command, you can use `opa <command>` instead of `npx tsx src/cli.ts <command>`.

## Start, stop, and restart

`opa` is installed on this Mac. Start the computer-side Host in a terminal and keep that window open:

```bash
opa start
```

- To stop it, return to the terminal where it was started and press **Control+C**.
- To restart it, press **Control+C**, wait for the process to exit, then run `opa start` again.
- To check its status, open another terminal and run `opa status`.

This Mac's existing `~/.local/bin/opa` is a test-instance entry point. Its default data directory is `/tmp/opa-live` and its port is `7488`. Running `npm start` directly inside `host/` uses the default directory `~/.opa` and port `7420`; keep the same entry point and environment variables when continuing to use an already-paired instance. These stop and restart instructions apply to a foreground terminal process. If you separately enabled a LaunchAgent, manage that background service with `launchctl`.

The model list supplements the Host's dynamic catalog with `GPT-6.1 Sol` (`gpt-6.1-sol`), which can be selected for the bot, heartbeat, and Codex default model. If the server already returns this model, its metadata is preserved and no duplicate is added; saved selections are not changed automatically. Having this supplemental catalog entry does not mean that the current account has been verified to run inference with the model.

## Clear chat history

The iPhone App's chat page has a **「清除聊天记录」(Clear chat history)** command in its upper-right menu. After confirmation, it clears the chat and starts a new conversation context. Long-term memory, tasks, execution sessions, and pairing information are retained, and independent tasks continue running. The Mac must be connected. After a successful clear, the change syncs to other paired devices; offline devices update when they reconnect. This feature requires both an updated Host and a rebuilt App.

| Directory | Contents |
|---|---|
| `src/codex/` | app-server JSON-RPC client and generated protocol types |
| `src/phone/` | Phone MCP configuration, availability, cancellation markers, and notification listener |
| `src/gateway/` | Pairing, E2E encryption, LAN WebSocket, Bonjour, relay, and push notifications |
| `src/butler/` | Codex brain, dynamic tools, task scheduling, GenUI, memory, and notifications |
| `../phone/` | Python Android MCP service and offline tests |

Data is stored in `~/.opa/` by default. Set `OPA_HOME` and `OPA_PORT` to run an isolated instance.

## Prepare the Android phone

V1 uses a dedicated Xiaomi Android phone (`23116PN5BC`, default serial `e7fe2f2a`). Prefer service MCPs or connected plugins for steps they can complete, then consider a feasible website; dispatch a phone worker only when the task requires a phone app or phone sign-in state. WeChat is unavailable on this dedicated phone, and the Mac WeChat app blocks computer use. When there is no other feasible route, the owner must complete the step in WeChat on their own phone.

On the Mac, prepare `uv`, Python ≥ 3.11, and Android Platform Tools (`adb` must be on PATH). Then:

1. In the phone's developer options, enable “USB debugging” and “**USB debugging (Security settings)**”. With only the first option enabled, screenshots may work while taps and typing do not. Connect the phone to the Mac over USB and trust this computer on the phone.
2. Download the APK from [ADB Keyboard releases](https://github.com/senzhk/ADBKeyBoard/releases), run `adb -s e7fe2f2a install ADBKeyboard.apk`, and enable that keyboard in the phone's settings. The tool switches to it temporarily for input and restores the previous keyboard afterward.
3. Install and sign in to any standalone service apps you need (for example, Meituan). Keep the phone unlocked; you can enable “Stay awake while charging” or extend the screen timeout.
4. Run the following from `host/`:

```bash
npx tsx src/cli.ts phone setup             # run uv sync under ../phone
npx tsx src/cli.ts phone status            # diagnose configuration, ADB device, keyboard, and security debugging
npx tsx src/cli.ts install-skills
```

For a wireless connection, use `adb pair <ip:pairing-port>` → `adb connect <ip:debug-port>`, then set `OPA_PHONE_SERIAL=<ip:debug-port>` for the Host. Restart the Host for the environment variable to take effect.

## Phone configuration and operation

- `OPA_PHONE_SERIAL`: target device, default `e7fe2f2a`. If the device is disconnected or unauthorized, the command returns a clear error and does not operate another connected device.
- `OPA_PHONE_CMD`: overrides the MCP launch command. Default: `../phone/.venv/bin/python`; arguments remain `-m orbit_phone.server`.
- `OPA_HOME`: root directory for the phone lock, cancellation markers, screenshots, and Host data. Default: `~/.opa`.

`phone_task` creates a Codex worker titled `📱` and attaches `phone-automation`; for China-specific services it also attaches `china-services`. `orbit_phone` is injected through that thread's `config.mcp_servers`, computer use is disabled, and shell access is retained for workspace files. Do not add it to the global `~/.codex/config.toml`; the brain and ordinary workers must not receive phone tools.

The MCP service pins `mcp==2.3.0`, `Pillow==12.3.0`, and a specified `phone-agent` commit. It does not instantiate PhoneAgent / ModelClient or call a model. This MCP version's public entry point is `MCPServer`; the `FastMCP` name in the original execution document has been migrated. The service still uses stdio MCP.

The worker obtains the cross-process device lock with `phone_begin`, reads the automatically attached new screenshot after each action, and finally saves evidence and releases the lock with `phone_end`. The lock and cancellation files are under `OPA_HOME/phone/`; evidence is under `OPA_HOME/phone/evidence/`. Only one phone task runs at a time; while the phone is busy, wait for the existing session to finish. Stopping chat or cancelling a task signals the phone to stop, but does not undo actions that have already run.

Sensitive phone taps are automatically allowed and audited. Ordering or payment is permitted only when the task explicitly authorizes it; otherwise, the worker must only query and must not order or pay. If sign-in, a verification code, QR scan, or face recognition needs a person, the worker ends and releases the lock, returns `needs_human`, and the butler notifies the owner to handle it before continuing. UI trees and audit records redact input values. Screenshots may contain visible page information and are stored in the local evidence directory.

## Phone notifications

New notifications on the dedicated phone wake the bot, which decides whether and how to tell the owner (see the “Phone notifications” section in `skills/butler-core`). Every 30 seconds, the Host runs the read-only command `adb -s <serial> shell dumpsys notification --noredact`. This does not acquire the phone device lock, so it can run while a phone worker is active. It only requires adb; polling continues even if `opa phone setup` has not been run.

- **Filtering:** Skips notification group summaries, ongoing / foreground-service notifications, importance ≤ 1, notifications with both title and body empty, and system packages such as `android`, `com.android.systemui`, and `com.miui.securitycenter`.
- **Deduplication:** Keeps an in-memory set of seen `key + when` values (up to 2,000). The first successful poll after Host startup records existing phone notifications without waking the bot; they are not considered new.
- **Batching and rate limit:** New notifications are buffered. If less than 3 minutes have passed since the last wake-up (15 minutes during the owner's quiet hours), they stay buffered. Each wake-up includes at most 8 notifications, with titles truncated to 40 characters and bodies to 120; the remainder are summarized as “N more”.
- **Privacy:** Notification bodies are sent only to the bot. Logs and audit records contain only the count and package names (`phone / notifications`).
- **Switch:** Enabled by default. `opa config phone-notify on|off` writes `config.phoneNotify`, which the running Host reads on its next poll. Set `OPA_PHONE_NOTIFY=0` to turn it off as well. `OPA_PHONE_NOTIFY_POLL_MS` changes the polling interval in milliseconds (default 30000, minimum 1000); the device follows `OPA_PHONE_SERIAL`.
- If adb is missing, the phone is offline, or the command times out, one debug log entry is written (visible with `OPA_LOG=debug`). The next polling cycle tries again without waking the bot.

## Context management

The bot's brain is a persistent Codex thread whose history only grows. The Host controls its size in two ways: it sends only changed status-bar sections and automatically compacts the thread while idle.

- **Send only changed status-bar sections:** After each event turn, the status bar is assembled from fixed sections (`time`, `presence`, `phone`, `device`, `calendar`, `reminders`, `tasks`, `sessions`, `approvals`, `schedules`, `imports`, `memory`). `time` is sent every turn. Other sections are sent only when their content differs from the version last sent to this thread; a section that changes from populated to empty is sent once as “(none)”. The status bar begins with: “Only list sections that changed since the previous update; omitted sections retain their previous state.” When the thread changes, compaction completes, or the Host has just started, the next turn sends the full status bar.
- **Memory is in the status bar:** The memory summary is in the `memory` section rather than fixed instructions, so changing memory does not force a new thread. A change to fixed instructions (identity, tools, skills, or model) does create a new thread. The first turn after upgrading to this version creates one as well.
- **Automatic compaction:** After a turn finishes, the inbox is empty, and the butler is about to become idle, the Host checks the most recent request context size. If it reaches the threshold, Codex compacts the history into a summary (`thread/compact/start`, waiting up to 180 seconds). Set the threshold with `OPA_BRAIN_COMPACT_TOKENS`; the default is 60000. When the model's context window is known, the limit is at most 60% of that window.
- **No compaction during execution:** Compaction is deferred while a task is `planning` / `running`, a session is `running` / `waiting_approval`, an approval is pending, a phone task is starting, less than 5 minutes have passed since the previous compaction, or the inbox contains queued events. The Host checks again after the next turn.
- **During compaction:** New messages queue rather than being inserted into the active turn and are processed as soon as compaction ends. The App does not display “思考中” (“Thinking”). The token count before compaction is recorded in logs and audit (`bot / compact`).
- **If compaction fails:** The Host creates a new thread, carries over a summary of recent conversation, and archives the old thread. The next turn sends the full status bar.

## Discover methods for services in China

For domestic services and errands in China, the butler first loads `china-service-discovery`, searches for current methods and official entry points, checks region, sign-in requirements, and tool capabilities, and then breaks down and dispatches the task. The skill's service map suggests candidate apps and websites without fixing the task to a platform. A phone worker is created only when the research shows that a step requires a phone. This prerequisite is in the always-loaded `butler-core`; the Host reads the repository skill index automatically, so it does not need to be installed separately in the worker.

## Built-in MCP services

The domestic and international service directory includes Amap, 12306, Feishu, Playwright, web Fetch, Tavily, GitHub, and Notion. The brain first calls `mcp_list` to inspect configuration, then selects services through `mcp_services` for an ordinary execution thread. Services that need credentials are not treated as connected. Phone threads and existing ChatGPT plugins keep their own integration paths.

Use `opa mcp init` to create configuration for the current instance, `opa mcp list` to view status, and `opa mcp check rail_12306 fetch playwright` to check services that need no key. Import standard ModelScope configurations with `opa mcp import <json-path>`. See [Built-in MCP services](../docs/mcp-services.md) for the full service descriptions, credential variables, and configuration examples.

## Verification

Run these commands from the repository root:

```bash
cd phone
uv sync
.venv/bin/python -m pytest -q
cd ../host
npx tsc --noEmit
OPA_HOME=/tmp/opa-test npx vitest run
OPA_HOME=/tmp/opa-phone-smoke npx tsx scripts/smoke-phone.ts
```

`smoke-phone.ts` uses a real app-server to create a phone thread and inspect its MCP tool list, while checking that ordinary threads remain isolated. It only enumerates devices; it does not tap the phone and does not need model inference. Without a phone, it should return an empty device list and a clear message. Other smoke scripts are `scripts/smoke-host.ts` (simulated iPhone pairing) and `scripts/smoke-bridge.ts` (real Codex session).

After reconnecting a phone, verify these steps in order:

1. `opa phone status` reports `e7fe2f2a` as `device`, with ADB Keyboard and security debugging ready.
2. Query: “Search WeChat on the phone for Luckin Coffee and tell me nearby locations.” The task card, phone session, and structured result should work without placing an order.
3. Query: “Use Meituan to check the price of this coffee.” It should return a price without ordering or paying.
4. When willing to charge a real payment method, explicitly authorize an order and payment for a specified item and amount. Verify the payment result, order card, and phone audit record.
5. Sign-in and verification-code scenarios return `needs_human`, send a notification to the iPhone, and release the device lock.
6. After stopping chat or cancelling a task, the phone stops at the current action boundary and releases the lock; a later task can acquire the device.
7. Start two phone tasks at once. The second waits for the first to finish, and the device is never operated by both tasks concurrently.
8. When the phone receives a personal message or food-delivery notification, the bot wakes within about 30 seconds and tells you in one or two sentences. Ads and system notifications do not interrupt you. After `opa config phone-notify off`, it no longer wakes for notifications.

Offline tests and no-device smoke checks cannot prove that real-device permissions, input, WeChat flows, or payments work. Those require confirmation after connecting the phone.
