---
name: china-services
description: Channel selection and structured-delivery rules for domestic China services. Prefer currently authorized service MCPs / plugins that cover the required steps, then feasible websites; use computer or phone UI only when an interface is necessary and no suitable service interface is available. For delivery, travel, tickets, appointments, government services, logistics, and local businesses.
---

**English** | [简体中文](SKILL.md)

# Services in mainland China

This skill describes channel constraints and result formats for service execution. The dedicated phone cannot use WeChat, and Mac WeChat blocks computer use. If no authorized service interface or standalone website covers the steps for this task, the owner must handle WeChat mini programs, official accounts, and services in WeChat on their own phone. Use the phone only with each service's own standalone app.

Before breaking down a task or choosing a service, the butler must search current methods for this task with `china-service-discovery`; this file describes technical constraints on execution channels. The platforms below are examples for discovery, not fixed assignments, an allowlist, or a ranking. Applicability depends on the current goal, region, official process, and actual capabilities.

## Choose a path

1. If the user specifies a channel, follow it. If it cannot complete the task, explain the actual limitation and offer a feasible alternative; do not silently switch routes.
2. Before handling an external service, use `mcp_list` and/or `connectors_list` as relevant to check current capabilities and connection state. Prefer an exposed, permissioned, service-specific MCP / plugin that covers the target steps. A complete configuration does not mean it is connected or authenticated. Use `connector_call` for a single connector step; name the tool in a multi-step worker brief; explicitly select built-in MCP through `mcp_services`. If a tool, configuration, or permission is missing, stop retrying and explain the needed connection / authorization. Do not install automatically, change configuration, or obtain credentials.
3. Without a suitable authorized service interface, first check whether a public website can complete the task. Use search or a browser for steps they can perform. Confirm browser MCPs such as Playwright are currently available before using them; do not switch to a generic browser when a service-specific structured interface covers the task.
4. Use `computer_use_task` only when a UI is necessary and neither a service interface nor a feasible website can complete the step. Use `phone_task` only when the step truly requires a mobile app or mobile login session, and use the service's own standalone app. State the actual reason for choosing UI in the brief.
5. This dedicated phone cannot use WeChat, and Mac WeChat blocks computer use. If no authorized interface or standalone website covers this task, tell the owner to handle it in WeChat on their own phone, with concrete steps. Do not treat the dedicated phone or Mac WeChat as available channels.
6. If you are already a phone worker with `orbit_phone`, use the phone tools directly; do not dispatch another worker. If a service interface or website becomes a better fit during execution, end the phone task and return to Orbit for a dispatch change; do not switch to Mac yourself. A regular worker without `phone_task` or phone tools should tell Orbit that a phone is needed so Orbit can dispatch it.

## Mobile-app path

1. Call `phone_begin` to acquire the lock and `phone_launch` to open the service's own app (see names at the end). If the app is not on the phone, call `phone_end` and return `blocked`, naming the missing app; do not switch to WeChat. If a better channel appears, first call `phone_end` and ask Orbit to choose again; do not switch devices yourself.
2. Use in-app search or entry points to find the official name. Prefer a result whose name matches the brand and whose verified operator is clear.
3. After opening the target, select the city, venue, item, date, or service needed for the task. Perform one action at a time and inspect the new screenshot returned by that action before continuing.
4. Stop when the current screen provides the requested answer. A result visible on one screen does not establish the highest rating or lowest price across the entire platform; state the scope in the result.
5. When complete or blocked, call `phone_end` and record the final evidence path it returns. If the device is busy, return `busy` to Orbit and use `watch` for the existing phone session.

See `phone-automation` for phone coordinates, input, retries, and dialogs.

## Authorization and human handoff

- Place an order or pay only when the task brief clearly authorizes it. If the user asks only for a price, business, stock, or seat availability, only look it up; do not order or pay. Without payment authorization, stop before the confirmation page and return an existing order summary as `needs_approval`.
- Sensitive payment and privacy taps on the phone are automatically executed and audited; the task brief must still follow the user's specified target, amount, quantity, and purpose. Web and Mac operations follow the existing approval rules.
- Login, verification codes, QR scans, face recognition, and entry of the owner's password require the owner. The phone worker first calls `phone_end`, returns `needs_human`, and says what is needed. Orbit uses `notify` and `ask_user` to alert the owner, who can then continue.
- Location permission may be allowed when needed for the task. Handle phone number and privacy permissions only to the scope the task needs. Close ads and update prompts; do not proactively change account, notification, or payment settings.
- Do not message contacts, add friends, post to Moments, or delete records unless the task explicitly authorizes the target and content / action.
- If the price, merchant, date, or quantity conflicts with the task, stop and return the discrepancy. Do not spend money on a replacement plan yourself.

## Structured delivery

End successful, partial, and failed reports with a JSON code block. Keep the following business fields, omitting those that do not apply:

```json
{
  "status": "done | partial | blocked | needs_approval | needs_human | cancelled | failed",
  "channel": "phone_app | browser",
  "service": "service name",
  "summary": "result, scope, and whether an order was placed",
  "result_type": "order | ticket_options | booking | info | list",
  "items": [],
  "fees": [],
  "total": null,
  "currency": "CNY",
  "merchant": null,
  "times": {},
  "options": [],
  "needs": {"kind": "payment | login | captcha | scan | user_action", "detail": "what the owner needs to do"},
  "evidence": "absolute path returned by phone_end",
  "screenshots": [],
  "steps_log": []
}
```

Amounts are numbers. If a value was not visible, use `null` and explain. Use timezone-qualified ISO 8601 for readable times. You may include `component` and `props` aligned with `order_card / ticket_card / booking_card / table`; card time fields must be Unix milliseconds. Do not use an outer task status such as `needs_human` directly as a business status. Use the path from `phone_end` for phone screenshots and an absolute path in the task directory for browser screenshots. Return only task-relevant information; do not paste full page contents or private text from input fields.

## Common apps and search terms

- Delivery and ordering: 美团、美团外卖、饿了么、瑞幸咖啡、喜茶GO、星巴克、奈雪的茶、蜜雪冰城.
- Travel and tickets: 滴滴出行、高德地图、铁路12306、携程旅行、同程旅行、airline-official apps, 猫眼、淘票票、大麦.
- Medical appointments and government services: the hospital's full name, local official appointment services, 国务院客户端、国家政务服务平台、local government services, 国家医保服务平台.
- Parcels: 顺丰速运、中国邮政、EMS、京东、菜鸟.
- Queueing and attractions: the business or attraction's full name, 美味不用等, and official apps.

Names are only search leads; use the verified operator and service entry point currently shown on the phone. If the owner needs to intervene, stop immediately and deliver the result; do not wait idle or keep searching the same entry point.
