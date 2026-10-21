# Skills

**English** | [简体中文](README.zh-CN.md)

Each skill lives in its own directory, with YAML frontmatter (`name`, `description`) in `SKILL.md`. The butler context contains only the index (name + description); the body is loaded on demand with `skill_load(name)`. `butler-core` is always loaded.

The `.en.md` files are English reading copies. Runtime still loads the Chinese `SKILL.md`; this changes the documentation reading entry point only and does not change skill loading or the app UI.

| Skill | Installed for | Purpose |
|---|---|---|
| [`china-service-discovery`](china-service-discovery/SKILL.en.md) | Butler (load before planning domestic-service tasks) | Search current methods, official entry points, and local capabilities; treat the domain map as candidate leads, not fixed routing |
| [`china-services`](china-services/SKILL.en.md) | Codex (`~/.codex/skills`) + Butler | China-based services: route between mobile apps and websites (no automated WeChat path; hand off to the owner), authorization, and structured delivery |
| [`phone-automation`](phone-automation/SKILL.en.md) | Phone worker + Codex (`~/.codex/skills`) | `orbit_phone` device lock, screenshot/action loop, 0–999 coordinates, human handoff, and evidence |
| [`butler-core`](butler-core/SKILL.en.md) | Butler (always loaded) | Butler conduct: initiative, reporting cadence, conversation style, interruption handling, and honesty |
| [`codex-orchestration`](codex-orchestration/SKILL.en.md) | Butler | Create/reuse/steer/interrupt sessions, task templates, models and permissions, parallel work, and cost |
| [`genui-guide`](genui-guide/SKILL.en.md) | Butler | Map information types to GenUI components, `ui_patch` state transitions, and approval buttons |
| [`import-triage`](import-triage/SKILL.en.md) | Butler | Triage imported photos, links, text, reminders, and choose default actions |
| [`memory-policy`](memory-policy/SKILL.en.md) | Butler | What to remember, what not to remember, when to confirm, and how to use memory in prompts |

## Install phone-related skills in Codex

From `host/`, run `npx tsx src/cli.ts install-skills`. This links `china-services` and `phone-automation`. Host dispatch also explicitly mounts the corresponding repository skill file as input; this only installs skills and does not add the phone MCP to global configuration.

Symlinks are recommended because repository updates take effect automatically:

```sh
mkdir -p ~/.codex/skills
ln -s "$(pwd)/skills/china-services" ~/.codex/skills/china-services
ln -s "$(pwd)/skills/phone-automation" ~/.codex/skills/phone-automation
```

Or copy the directories:

```sh
mkdir -p ~/.codex/skills
cp -R skills/china-services ~/.codex/skills/china-services
cp -R skills/phone-automation ~/.codex/skills/phone-automation
```

Run these commands from the repository root. Host reads Butler-side skills directly from this directory.

`china-service-discovery` guides Butler decisions. The always-loaded `butler-core` requires it to be loaded before planning domestic-service tasks, so it does not need to be installed for the phone worker. Its app and website discovery map is included in `SKILL.md`, allowing the brain to read it in full with `skill_load` even when shell access is disabled; the map is not a mandatory routing table.

Query the built-in MCP catalog with Host's `mcp_list`, then select services as needed for a task through `codex_session_create`'s `mcp_services`. The `china-service-discovery` and `codex-orchestration` skills describe this selection flow. Service, credential, and ModelScope import instructions are in [Built-in MCP services](../docs/mcp-services.md).
