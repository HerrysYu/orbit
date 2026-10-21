---
name: genui-guide
description: Load when preparing to show structured information with `ui_render` / `ui_patch`. Maps information types to GenUI components (`text_card`, `table`, `comparison`, `calendar_events`, `order_card`, `ticket_card`, `booking_card`, `map_place`, `choice_list`, `form`, `task_progress`, `approval_card`, `memory_saved`, and others), gives JSON examples, explains when plain text is enough, how to use `ui_patch` for state transitions (such as order draft→confirming→placed), and that buttons involving money or messaging require `requiresApproval`; keep each message to at most 1–2 cards and add one sentence.
---

**English** | [简体中文](SKILL.md)

# genui-guide: Communicate with cards

## 1. Basic rules

- Call `ui_render({component, props, actions?})`; it returns a card `id`. `ui_patch(id, props)` shallow-merges props.
- The component catalog is closed: use only the components and fields in the table below. Host validates them; on error, correct and resend.
- Use at most 1–2 cards per message. When there is a lot of information, combine it into one `table` / `comparison` instead of sending 5 cards.
- Pair each card with a sentence (`say`) that states the conclusion or what you want the user to do. Put detail in the card and the conclusion in the text.
- Keep cards small: at most 8 rows in a `table`, 4 items in a `comparison`, and 5 options in a `choice_list`. Put more content in a `document`, or show only the first items and say "还有 N 项".
- Use numbers for prices and put the currency in `currency`; represent times as local-time ISO 8601 strings.
- Do not paste raw session output into a card; filter and rewrite it first.
- Phone-task screenshots and local images in the workspace (only inside Orbit's data directory `OPA_HOME`, default `~/.opa`) can be given directly as local paths in `image_gallery`; Host converts them into images the phone can display. Do not put local paths in text messages.

## 2. When plain text is enough

- A fact that fits in one sentence ("明天 9 点有组会").
- A result with only 1–2 values ("顺丰明天中午前到").
- Casual chat, confirming receipt, or a simple progress update.
- When the user is in focus mode or asks casually, prefer text.

## 3. Information type → component

| Information | Component |
|---|---|
| Brief explanation, notice, or summary | `text_card` |
| One link | `link_preview` |
| 3 or more records with the same shape (bills, lists, timetables) | `table` |
| 2–4 options for the user to choose from | `comparison` (with `recommendedId`) |
| Long-form text, report, or organized result with attachments | `document` |
| Calendar events, time slots, itinerary | `calendar_events` |
| Food delivery / order | `order_card` |
| Train, flight, movie, performance | `ticket_card` |
| Restaurant, hotel, appointment, and similar booking | `booking_card` |
| One place | `map_place` |
| Image collection | `image_gallery` |
| Video | `video` |
| Ask the user to choose from options | `choice_list` |
| Ask the user to fill several fields | `form` |
| Task in progress | `task_progress` |
| Operation requiring user approval | `approval_card` (created by `request_approval` with an approvalId) |
| Memory just written | `memory_saved` |

## 4. Examples

### Compare options

```json
{"component":"comparison","props":{"title":"今晚川菜外卖","recommendedId":"b",
 "items":[
  {"id":"a","title":"蜀大侠","subtitle":"约 35 分钟","price":62,"pros":["评分 4.8"],"cons":["偏辣"]},
  {"id":"b","title":"川味小馆","subtitle":"约 25 分钟","price":48,"pros":["最快","有免辣选项"],"highlight":"推荐"},
  {"id":"c","title":"老成都","subtitle":"约 40 分钟","price":55,"cons":["配送费 6 元"]}]},
 "actions":[{"id":"pick_b","label":"就点川味小馆","style":"primary"},{"id":"more","label":"再看看","style":"secondary"}]}
```

Companion text: "找到 3 家，川味小馆最快也最便宜，要点它吗？"

### Table

```json
{"component":"table","props":{"title":"10 月报销","columns":[{"key":"date","label":"日期"},{"key":"item","label":"项目"},{"key":"amount","label":"金额","align":"right"}],
 "rows":[{"date":"10-08","item":"打车","amount":46.5},{"date":"10-09","item":"午餐","amount":38}],"footnote":"合计 84.5 元"}}
```

### Calendar

```json
{"component":"calendar_events","props":{"title":"下周出差","events":[
 {"title":"G101 北京南→上海虹桥","start":"2026-10-20T07:00","end":"2026-10-20T11:28","calendar":"出行"},
 {"title":"客户会议","start":"2026-10-20T14:00","end":"2026-10-20T15:30","location":"陆家嘴"}]}}
```

### Clarify intent

```json
{"component":"choice_list","props":{"question":"哪天出发？","options":[
 {"id":"d19","label":"周日晚上","detail":"住一晚，周一从容"},
 {"id":"d20","label":"周一早上 7 点","detail":"当天往返"}]}}
```

After the user chooses, receive `ui_action{actionId:"select", value:["d20"]}`.

```json
{"component":"form","props":{"title":"挂号信息","fields":[
 {"key":"dept","label":"科室","type":"select","options":["皮肤科","眼科"],"required":true},
 {"key":"date","label":"日期","type":"date","required":true},
 {"key":"am","label":"只要上午","type":"toggle","value":true}],"submitLabel":"去挂号"}}
```

### Order card (with approval button)

```json
{"component":"order_card","props":{"merchant":"瑞幸咖啡(国贸店)","items":[{"name":"生椰拿铁","qty":1,"price":19.9,"note":"大杯 少冰"}],
 "fees":[{"label":"配送费","amount":4}],"total":23.9,"currency":"CNY","eta":"约 25 分钟","status":"draft"},
 "actions":[{"id":"place","label":"下单","style":"primary","requiresApproval":true},{"id":"edit","label":"改一下","style":"secondary"}]}
```

## 5. Use `ui_patch` for state transitions

Use one card for the same item and patch it when the state changes; do not send a new card:

| Component | State flow |
|---|---|
| `order_card` | `draft` → `confirming` (user tapped order; awaiting approval or execution) → `placed` → `delivering` → `done`; any step may become `failed` |
| `ticket_card` | `options` → `holding` (seat held, awaiting payment) → `booked` (with `code`) or `failed` |
| `booking_card` | `draft` → `pending` → `confirmed` (with `confirmation`) or `failed` |

Example, after the user approves:

```json
ui_patch("card_123", {"status":"confirming"})
// The session reports that the order was submitted and the user completed payment.
ui_patch("card_123", {"status":"placed","eta":"约 22 分钟"})
```

Add a short sentence with a patch only at key points (ordered, delivered, failed); no message is needed for intermediate states.

## 6. Actions and approval

- Each `actions` item is `{id, label, style?, requiresApproval?}`. A user tap returns a `ui_action{cardId, actionId, value?}` event.
- The following actions must use `requiresApproval: true` and call `request_approval` before execution: placing an order, payment, holding a seat, submitting a booking, sending a message or email to someone, deleting data, publishing externally, or raising permissions.
- Use `style:"destructive"` for destructive actions (cancel an order, delete).
- Use no more than 3 actions on a card; mark the main action `primary`.
- After a `ui_action` arrives, do not ask "确定吗" again in text; the approval card is the confirmation.

## 7. Progress and approval cards

- After creating a Task, send one `task_progress {taskId}` card. Subsequent progress is driven automatically by `task_board_*` updates; do not spam progress in text.
- To ask for user approval, call `request_approval`, which creates an `approval_card`; do not hand-build an approve / reject `choice_list`.

## 8. Common mistakes

- Sending a card without companion text → always add one sentence.
- Using a table for 2 items → use text or `comparison`.
- Sending one card for each session result → combine the results into one card.
- Sending a new card for an order state change → use `ui_patch`.
- Inventing a component or field → use only the catalog.
