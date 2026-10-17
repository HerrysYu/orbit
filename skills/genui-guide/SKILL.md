---
name: genui-guide
description: 准备用 ui_render / ui_patch 向用户展示结构化信息时加载。给出信息类型到 GenUI 组件（text_card、table、comparison、calendar_events、order_card、ticket_card、booking_card、map_place、choice_list、form、task_progress、approval_card、memory_saved 等）的映射和 JSON 调用示例，说明何时纯文字就够、如何用 ui_patch 做状态流转（如订单 draft→confirming→placed）、涉及花钱或发消息的按钮必须 requiresApproval，以及每条消息最多 1–2 张卡并配一句文字。
---

# genui-guide：用卡片传达信息

## 1. 基本规则

- 调用形式：`ui_render({component, props, actions?})`，返回卡片 `id`。`ui_patch(id, props)` 对 props 做浅合并。
- 组件目录是封闭的，只能用下表里的 component 和字段。Host 会校验，失败会把错误回给你，按错误修正后重发。
- 每条消息最多 1–2 张卡片。信息多时合并进一张 table / comparison，而不是发 5 张卡。
- 每张卡都要配一句文字（`say`），说出结论或你希望用户做什么。卡片放细节，文字放结论。
- 卡片保持小：table 不超过 8 行、comparison 不超过 4 项、choice_list 不超过 5 个选项。更多内容放 `document` 或只给前几项并说明"还有 N 项"。
- 价格用数字，币种放 `currency`；时间用 ISO 8601 本地时间字符串。
- 不要把 session 的原始输出直接塞进卡片，先筛选和改写。
- 手机任务的截图、工作区里的本地图片（仅限 Orbit 数据目录 OPA_HOME 内，默认 `~/.opa`），可以直接把本地路径放进 `image_gallery`，Host 会自动转成手机能显示的图片；不要把本地路径写进文字消息里。

## 2. 什么时候纯文字就够

- 一句话能答完的事实（"明天 9 点有组会"）。
- 只有 1–2 个数值的结果（"顺丰明天中午前到"）。
- 闲聊、确认收到、简单进度。
- 用户在专注模式或只是随口一问时，尽量文字。

## 3. 信息类型 → 组件

| 信息 | 组件 |
|---|---|
| 一段简短说明、提示、总结 | `text_card` |
| 一个链接 | `link_preview` |
| 3 个以上同构数据（账单、清单、时刻表） | `table` |
| 2–4 个需要用户挑选的方案 | `comparison`（带 `recommendedId`） |
| 长文、报告、带附件的整理结果 | `document` |
| 日程、时间段、行程 | `calendar_events` |
| 外卖 / 点单 | `order_card` |
| 火车、航班、电影、演出 | `ticket_card` |
| 餐厅、酒店、挂号等预约 | `booking_card` |
| 一个地点 | `map_place` |
| 图片集合 | `image_gallery` |
| 视频 | `video` |
| 让用户从几个选项中选 | `choice_list` |
| 需要用户填多个字段 | `form` |
| 进行中的 Task | `task_progress` |
| 需要用户批准的操作 | `approval_card`（由 `request_approval` 产生的 approvalId） |
| 刚写入的记忆 | `memory_saved` |

## 4. 示例

### 比较方案
```json
{"component":"comparison","props":{"title":"今晚川菜外卖","recommendedId":"b",
 "items":[
  {"id":"a","title":"蜀大侠","subtitle":"约 35 分钟","price":62,"pros":["评分 4.8"],"cons":["偏辣"]},
  {"id":"b","title":"川味小馆","subtitle":"约 25 分钟","price":48,"pros":["最快","有免辣选项"],"highlight":"推荐"},
  {"id":"c","title":"老成都","subtitle":"约 40 分钟","price":55,"cons":["配送费 6 元"]}]},
 "actions":[{"id":"pick_b","label":"就点川味小馆","style":"primary"},{"id":"more","label":"再看看","style":"secondary"}]}
```
配文："找到 3 家，川味小馆最快也最便宜，要点它吗？"

### 表格
```json
{"component":"table","props":{"title":"10 月报销","columns":[{"key":"date","label":"日期"},{"key":"item","label":"项目"},{"key":"amount","label":"金额","align":"right"}],
 "rows":[{"date":"10-08","item":"打车","amount":46.5},{"date":"10-09","item":"午餐","amount":38}],"footnote":"合计 84.5 元"}}
```

### 日程
```json
{"component":"calendar_events","props":{"title":"下周出差","events":[
 {"title":"G101 北京南→上海虹桥","start":"2026-10-20T07:00","end":"2026-10-20T11:28","calendar":"出行"},
 {"title":"客户会议","start":"2026-10-20T14:00","end":"2026-10-20T15:30","location":"陆家嘴"}]}}
```

### 澄清意图
```json
{"component":"choice_list","props":{"question":"哪天出发？","options":[
 {"id":"d19","label":"周日晚上","detail":"住一晚，周一从容"},
 {"id":"d20","label":"周一早上 7 点","detail":"当天往返"}]}}
```
用户选择后会收到 `ui_action{actionId:"select", value:["d20"]}`。

```json
{"component":"form","props":{"title":"挂号信息","fields":[
 {"key":"dept","label":"科室","type":"select","options":["皮肤科","眼科"],"required":true},
 {"key":"date","label":"日期","type":"date","required":true},
 {"key":"am","label":"只要上午","type":"toggle","value":true}],"submitLabel":"去挂号"}}
```

### 订单卡（含审批按钮）
```json
{"component":"order_card","props":{"merchant":"瑞幸咖啡(国贸店)","items":[{"name":"生椰拿铁","qty":1,"price":19.9,"note":"大杯 少冰"}],
 "fees":[{"label":"配送费","amount":4}],"total":23.9,"currency":"CNY","eta":"约 25 分钟","status":"draft"},
 "actions":[{"id":"place","label":"下单","style":"primary","requiresApproval":true},{"id":"edit","label":"改一下","style":"secondary"}]}
```

## 5. 用 ui_patch 做状态流转

同一件事只用一张卡，状态变化时 patch，不要重发新卡：

| 组件 | 状态流 |
|---|---|
| `order_card` | `draft` → `confirming`（用户点了下单、正在审批或执行）→ `placed` → `delivering` → `done`；任何一步可能 `failed` |
| `ticket_card` | `options` → `holding`（已锁座待支付）→ `booked`（带 `code`）或 `failed` |
| `booking_card` | `draft` → `pending` → `confirmed`（带 `confirmation`）或 `failed` |

示例：用户批准后
```json
ui_patch("card_123", {"status":"confirming"})
// session 回报已提交且用户已完成支付
ui_patch("card_123", {"status":"placed","eta":"约 22 分钟"})
```
patch 时配一句简短文字只在关键节点（已下单、已送达、失败），中间状态不必说话。

## 6. Actions 与审批

- `actions` 每项 `{id, label, style?, requiresApproval?}`；用户点击后回流为 `ui_action{cardId, actionId, value?}` 事件。
- 以下动作必须 `requiresApproval: true`，并在执行前走 `request_approval`：下单、付款、锁座、预约提交、发消息或邮件给他人、删除数据、对外发布、提升权限。
- 破坏性动作用 `style:"destructive"`（取消订单、删除）。
- 一张卡的 actions 不超过 3 个，主要动作用 `primary`。
- 收到 `ui_action` 后，不要再用文字问一遍"确定吗"，审批卡就是确认。

## 7. 进度与审批卡

- 建好 Task 后发一张 `task_progress {taskId}`，之后进度由 `task_board_*` 更新自动驱动，不要用文字刷进度。
- 需要用户批准时调用 `request_approval`，它会产生 `approval_card`；不要自己拼一个"批准 / 拒绝"的 choice_list。

## 8. 常见错误

- 只发卡片不配文字 → 必须配一句。
- 用 table 展示 2 项 → 用文字或 comparison。
- 每个 session 结果各发一张卡 → 汇总成一张。
- 订单状态变化发新卡 → 用 ui_patch。
- 自造 component 或字段 → 只用目录里的。
