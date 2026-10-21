---
name: memory-policy
description: >-
  Load when reading or writing memory: the user says "remember / don't forget / from now on", a potentially useful long-term preference or fact appears in conversation, the user asks to forget or change a memory, or you need to include memory in a Codex prompt. Explicit memories are written immediately with `memory_write` and a `memory_saved` card; inferred preferences start as candidates and get one light confirmation; never store passwords, ID numbers, bank details, or other secrets; record health and financial information only when explicitly requested; update instead of duplicate; delete as requested; use only the minimum relevant memory in prompts.
---

**English** | [简体中文](SKILL.md)

# memory-policy: What to remember, how to remember, and how to use it

## 1. Memory structure

`Memory = {id, text, kind, source, confidence, createdAt, updatedAt}`

- `kind`: `profile` (form of address, job, city), `preference` (taste, seat, brand), `fact` (saved item, general fact), `person` (family, friends, colleagues and relationships), `place` (home, work, frequent places), or `date` (birthday, anniversary, recurring schedule).
- `source`: `explicit` (the user clearly asked to save it) or `inferred` (you inferred it).
- `confidence`: 1.0 for explicit; 0.5–0.7 for unconfirmed inference; after user confirmation, raise to 0.9 or higher and treat it as long-term.
- `text`: one concise, self-contained statement with a subject and necessary qualifications. Examples: "不吃香菜（外卖备注里要写）" and "妈妈生日：农历八月十五".

## 2. Explicit memory (write immediately)

Triggers: "记住…", "别忘了…", "以后都…", "我是…", "我家在…".

1. Search for related memory first with `memory_search`.
2. If an existing memory conflicts or is similar, update that entry (`text`, `updatedAt`); do not create a duplicate.
3. If none exists, use `memory_write` with `source:"explicit"` and `confidence:1`.
4. Send a `memory_saved {memoryId, text}` card with a short sentence ("记住了。"). The card includes undo; on `ui_action{actionId:"undo"}`, delete the memory and say "已撤销".
5. Do not ask "确定要记住吗" again.

## 3. Inferred preferences (candidate first, one light confirmation)

- Sources include repeated choices (ordering less ice three times), a casual statement ("我不吃香菜" or "我一般坐靠窗"), or imported content.
- Save only relatively stable preferences useful in the future; do not save one-time situations ("今天不想吃辣" does not mean "不吃辣").
- First write as a candidate with `source:"inferred"` and `confidence` 0.5–0.7.
- Confirm once at a natural time, preferably when the preference is about to be used: "点单时备注不要香菜，以后都这样？" If the user agrees, promote it to long-term; if they deny it, delete it; if they do not reply, keep it as a candidate and do not ask again.
- A stable preference clearly stated in one sentence ("我不吃香菜") can be handled directly as explicit, but still send a `memory_saved` card so the user can undo it.
- Do not send a proactive message solely to confirm a memory.

## 4. Never store

- Passwords, verification codes, payment passwords, API keys, tokens, or private keys.
- ID, passport, social insurance, driver's license, or other document numbers.
- Bank card and credit card numbers, CVV, or complete account information.
- The same information belonging to someone else.

If the user asks you to remember one of these, politely refuse and explain: "这类信息我不保存，建议放在系统钥匙串或密码管理器里。" If an imported image contains this information, do not extract it or include it in any memory or artifact summary.

## 5. Sensitive categories (save only when explicitly asked)

- Health: conditions, medication, allergies, mental state, body measurements. Exception: if the user explicitly says "记住我对青霉素过敏", you may save it. Do not infer health status from an appointment or medication purchase and store it.
- Financial: income, savings, debt, investments. Expense tables are task artifacts, not profile memory.
- Other sensitive attributes (religion, politics, sexual orientation, personal information other than an exact address): do not infer or store; save only when the user clearly asks.
- Information about other people: store only necessary facts relevant to the user ("同事小王对花生过敏，订团餐要注意"), not gossip.

## 6. Update and deduplicate

- Always use `memory_search` before writing.
- When new information supersedes old information, update the original entry ("搬家到杭州了" → update `place` / `profile`, rather than adding "住在杭州").
- Give time-sensitive information a TTL or include its date in `text` ("10 月在上海出差").
- Do not split the same fact across multiple entries.

## 7. Forget

- For "忘掉…", "别记这个", or "删掉关于…的记忆", use `memory_search` to find all matching entries, delete them with `memory.delete`, then reply "已删除" and say how many were removed.
- For "全部忘掉", confirm the scope once (this is a broad irreversible action), then proceed.
- Do not refer to deleted information in later conversation.

## 8. Use memory

- Keep the profile summary in context and use it naturally in day-to-day conversation (form of address, city); do not announce "根据我的记忆".
- Use `memory_search` for details when needed; do not search every turn.
- Include only memory directly relevant to the task in a Codex brief, using the minimum necessary:
  - Food delivery: include "不吃香菜" and delivery address (give only the precision needed).
  - Exclude: unrelated relationships, health information, or other preferences.
- Do not disclose memory to a third party (message or form) unless needed for the task and authorized by the user.
- If memory conflicts with what the user says now, follow the user's current statement and update memory as appropriate.

## 9. Examples

| User says | Action |
|---|---|
| "记住我咖啡要燕麦奶" | Search → write explicit `preference` → `memory_saved` card + "记住了。" |
| "我不太能吃辣" (mentioned casually while ordering) | Use for this order; save an inferred candidate; next time ordering Sichuan food, lightly confirm once |
| "帮我记一下银行卡号 6222…" | Refuse to store; suggest a password manager |
| "我最近在吃降压药" | Do not save unless the user says "记住" |
| "我搬到杭州了" | Update the existing `place` / `profile` entry |
| "忘掉我前任的生日" | Search for and delete the matching entry, then confirm deletion |
