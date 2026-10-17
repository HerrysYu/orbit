# Skills

每个 skill 是一个文件夹，里面的 `SKILL.md` 带 YAML frontmatter（`name`、`description`）。管家上下文里只放索引（name + description），正文通过 `skill_load(name)` 按需加载；`butler-core` 始终加载。

| Skill | 安装位置 | 用途 |
|---|---|---|
| `china-service-discovery` | 管家（国内任务拆解前加载） | 实时查询办理方法、官方入口与本机能力；领域地图只提供候选种子，不固定平台 |
| `china-services` | Codex（`~/.codex/skills`）+ 管家 | 中国本土服务：手机 App 与网页路由（微信无自动通道，交主人）、授权与结构化交付 |
| `phone-automation` | 手机 worker + Codex（`~/.codex/skills`） | orbit_phone 设备锁、截图动作循环、0–999 坐标、人工接管和证据 |
| `butler-core` | 管家（始终加载） | 管家行为准则：主动性、汇报节奏、对话风格、打断处理、诚实 |
| `codex-orchestration` | 管家 | session 新建/复用/steer/interrupt、任务单模板、模型与权限、并行与成本 |
| `genui-guide` | 管家 | 信息类型到 GenUI 组件的映射、ui_patch 状态流转、审批按钮 |
| `import-triage` | 管家 | 导入的照片、链接、文本、提醒的分拣与默认动作 |
| `memory-policy` | 管家 | 记什么、不记什么、何时确认、如何在 prompt 中使用 |

## 安装手机相关 skills 到 Codex

在 `host/` 执行 `npx tsx src/cli.ts install-skills`，会链接 `china-services` 和 `phone-automation`。Host 派单也会通过 skill 输入显式挂载对应仓库文件；这里只安装技能，不把手机 MCP 写进全局配置。

软链接（推荐，仓库更新后自动生效）：

```sh
mkdir -p ~/.codex/skills
ln -s "$(pwd)/skills/china-services" ~/.codex/skills/china-services
ln -s "$(pwd)/skills/phone-automation" ~/.codex/skills/phone-automation
```

或复制：

```sh
mkdir -p ~/.codex/skills
cp -R skills/china-services ~/.codex/skills/china-services
cp -R skills/phone-automation ~/.codex/skills/phone-automation
```

以上命令在仓库根目录执行。管家侧的 skills 由 Host 直接从本目录读取。

`china-service-discovery` 供管家决策，由始终加载的 `butler-core` 要求在国内任务拆解前加载；无需安装到手机 worker。App / 网站检索地图直接包含在 `SKILL.md`，保证关闭 shell 的大脑仅用 `skill_load` 就能完整读取；地图不是强制路由表。
