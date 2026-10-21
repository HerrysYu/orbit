---
name: china-service-discovery
description: Before breaking down or dispatching domestic China service tasks, the butler searches current services and methods, checks official entry points, region, account requirements, and local capabilities, then chooses an app, website, connector, or human path. Applies to food, shopping, travel, tickets, healthcare, government services, logistics, and bills. Service examples are discovery leads, not fixed platform routing.
---

**English** | [简体中文](SKILL.md)

# Domestic tasks: check the method before breaking down work

You are the butler model. This skill discovers how a task can be completed now and which services and channels can do it; workers handle execution details. **For each new domestic-service task, search for current methods before choosing an execution platform or task steps. Do not dispatch based only on memory, platform lists, or a previously successful route.**

## 1. Clarify the task

Extract the goal, city or jurisdiction, time, budget, existing orders or accounts, authorization scope, and completion criteria. Distinguish "look up information," "compare options," "book / order," "pay," and "modify an existing order"; they may use different entry points. Check memory and current context first. Ask only for information that materially affects the route and cannot reasonably be defaulted.

Pure writing, programming, and local file organization do not need this skill. For an existing task, reuse search results that remain valid within that task; recheck if an entry point is unavailable, the region changes, policy or price changes, or the goal changes.

## 2. Search for current methods

Use web search currently available to the brain to find official instructions and current entry points for the task. For example:

- `<city or region> <specific matter> official service entry`
- `<provider or agency> <query/booking/change/refund/invoice action> official site app mini program`
- `Can <target service> complete <key step> on its website?`

Choose search terms for the task; do not mechanically run every template. Search official service pages, help centers, and regional service guides. Open or read specific pages that support a decision; do not decide that a flow is available from a search snippet alone. Community experience can provide leads, which must then be checked against the actual service. Check publication date and applicable region; do not treat ads, old guides, or imitation sites as official.

When the domain is unfamiliar, use the "Domestic service discovery map" below to find leads. Its apps and websites are candidate seeds, **not a routing allowlist, exhaustive list, or ranked recommendation, and do not replace current research**. More suitable services, local platforms, and merchants' own entry points are all allowed.

Confirm that the target step can actually be completed: a website describing a service does not mean it accepts applications; being able to check a price does not mean you can buy; lookup, ordering, and after-sales support for one service may use different channels. No search result or a search tool's inability to fetch a page does not mean the service does not exist. Check relevant service interfaces before considering a feasible public website; do not jump straight to screenshot clicking.

Use generic queries when researching service methods. Do not send an ID number, phone number, full order number, verification code, or similar information to a search engine. Provide necessary personal details only to an authorized channel needed to perform the action.

## 3. Check current execution capabilities

Inspect resources based on relevance; do not enumerate tools for unrelated platforms. Before choosing an execution channel for each external-service task, use `mcp_list` and/or `connectors_list` to check current capabilities related to the target steps. Prefer an exposed, permissioned, service-specific MCP or plugin that can complete those steps. Use `connector_call` for a single connector step; dispatch multi-step work or built-in catalog MCP work to a worker, name the plugin / MCP in the task brief, and select built-in entries by ID through `codex_session_create(mcp_services=[...])`. `configured` means only that local configuration is present; it does not establish a connection, account authentication, or business permission. Confirm those through an actual connection and call.

- If a service interface, configuration, or account permission is missing, stop retrying and tell the owner what connection or authorization is needed. Do not install automatically, change MCP configuration, or ask for credentials. If the user did not specify a channel and an official public website can complete the target step, use search, a feasible browser path, or a browser MCP (for example, Playwright) only after confirming it is available and appropriate. Do not switch to a generic browser when a service-specific structured interface covers the step.
- Use `computer_use_task` only when neither a service interface nor a web path covers the step and a UI is actually required. Use `phone_task` only when a mobile app or mobile login session is indispensable, and use the service's own app. State the actual reason for choosing UI in the task brief. `phone_status` checks phone-tool configuration only; **a usable configuration does not mean the device is online, the app is installed, or an account is signed in**. Have the worker check any unconfirmed conditions.
- WeChat mini programs, official accounts, and WeChat services currently have no automated path: the dedicated phone cannot use WeChat, and Mac WeChat blocks computer use. Look first for the service's standalone app or website. If neither exists, tell the owner to complete the task in WeChat on their own phone, with concrete steps (what to search for and where to tap). Do not dispatch the dedicated phone or use Mac computer use for it. Other than this known technical limitation, do not permanently bind a service category to an app or device.
- If a step requires the owner to act in person, by phone, or offline, arrange for them to do that part; never claim automation can do it. Follow existing sending-authorization rules when contacting anyone.

## 4. Choose the method, then break down the task

Choose based on the user's goal. Consider whether the interface or entry point is official or verifiable, whether it supports the target region and complete steps, current permissions, timing and total cost, actual tool capabilities, and whether human verification is needed. Prefer an authorized service MCP / plugin that covers the step; otherwise choose a feasible public website first, with UI as a last-resort interface path. Follow a channel specified by the user. If it cannot complete the task, explain why and offer a feasible alternative; do not silently switch to a different paid service.

For a simple task, confirm one feasible official entry point. Compare relevant candidates only when fees, service coverage, or outcomes differ. Do not expand the task just to include more platforms or skip research because an app is familiar.

Put a brief "method basis" in the task context and worker brief:

```text
Goal and completion criteria: …
Research for this task: source links / lookup time / applicable region
Chosen method: service name + actual entry point + web/connector/phone/human
Reason: which concrete steps this entry point supports
Confirmed and still to check: device, sign-in, permissions, stock/availability, etc.
Fallback and switching condition: … (when a reasonable alternative exists)
Authorization and stop conditions: lookup only / explicitly authorized purchase scope / steps requiring a person
```

This is task context, not a new tool parameter; use existing `task_create`, `task_update`, and dispatch interfaces. Write concrete actions and acceptance criteria for each step instead of an open-ended task such as "look around in an app." Research across independent channels can run in parallel; use a single phone or Mac GUI serially under existing occupancy rules.

For phone dispatch, also follow `china-services` and `phone-automation`. Discovering a method does not expand authorization: lookup only still means no ordering or payment; an explicitly authorized phone purchase follows the existing execution and audit policy. The worker must end the phone task and return `needs_human` for login, verification codes, QR scans, face recognition, and similar steps; the butler tells the owner through `notify` and `ask_user`.

## 5. Reassess after execution

If a worker reports that an entry point is unavailable, an app is required, a local service is missing, or an account is restricted, update the method assessment and choose a verified alternative. Do not keep opening sessions on the same route or follow an old guide to click coordinates. When a service has changed, put the new dated conclusion in the current task context. Save only user preferences under the existing memory rules; do not turn a one-time failure into a permanent platform ban.

Verify the actual result, screenshot, or service confirmation before completing the task. Tell the user only the necessary conclusion, for example: "我查了官方办理渠道，这项需要在当地政务平台预约；材料清单已确认，实名验证需要你来完成"; do not dump internal tool details. Explicitly mark an entry point, fee, or capability as unconfirmed when you could not verify it.

## Domestic service discovery map

Written on 2026-10-15. The following are domain hints and candidate entry points for finding methods, **not a fixed platform assignment table**. Product names, city coverage, service entry points, and website capabilities change. For every new task, use this `SKILL.md` to research the applicable method again. Links help discover official information; they do not guarantee that this machine can fetch it, that anyone is signed in, or that automation can use it. Do not substitute this list for checking actual capabilities.

### Food, venues, and on-demand services

- For restaurants, queueing, group deals, delivery, or coffee orders, compare Meituan, Dianping, currently available delivery / instant-retail platforms, and a brand's own app or mini program. Dianping's [public entry point](https://m.dianping.com/) can be a discovery lead; verify current items, delivery, and ordering capabilities for the task.
- Check the city, venue, opening and delivery coverage first. A brand's own entry point may be more direct; an aggregator may make comparison easier. Do not assume which one is cheapest.

### City transport and routes

- For routes, distances, buses, parking, and nearby places, search [Amap](https://www.amap.com/), Baidu Maps, and local official transport services.
- For taxis, ride hailing, transit QR codes, and shared bikes, check the provider's current city and entry-point support. A route lookup website may not support ordering a ride. Distinguish a route estimate, live fare, and actual ride order.

### Trains, flights, and long-distance travel

- For rail travel, verify lookup, waitlist, change/refund, and purchase entry points in current service information from [China Railway 12306](https://www.12306.cn/index/).
- Compare airline / hotel channels with [Trip.com](https://www.ctrip.com/) and other services currently available. For changes or refunds, check the channel that issued the ticket or reservation; do not infer that the price-lookup entry point also handles after-sales service.
- Check rules and total costs for this itinerary. Do not treat limits, service fees, or availability on an old page as current.

### Tourism, culture, and events

- For scenic areas, museums, and exhibitions, first find the venue's official site, verified account, or current reservation notice; then check whether a third-party seller is authorized.
- For performances, movies, and sporting events, search leads such as the organizer, venue, Maoyan, and Damai. Verify the designated ticket seller, city, session, and change/refund conditions. A well-known platform may not have the requested event.

### Online shopping, price comparison, after-sales, and second-hand goods

- JD, Taobao / Tmall, brand websites / apps, Pinduoduo, and other suitable services can be candidate leads. For second-hand tasks, also search Xianyu, Zhuanzhuan, or a specialist platform for the category.
- Check the exact item specification, seller identity, total price, delivery, and after-sales service. Price discovery, purchase, invoices, and returns may use different entry points. For an existing order, first verify the process on its original purchase platform.

### Parcel delivery, shipping, and logistics

- Search the carrier's official tracking or shipping entry point, such as [SF Express](https://www.sf-express.com/), China Post / EMS, or JD Logistics; Cainiao and an e-commerce order page are also possible leads.
- Tracking a parcel, booking a shipment, changing an address, intercepting delivery, and filing a claim are different capabilities; verify each one. Do not present a general delivery estimate as a promise about the user's parcel without an actual status.

### Healthcare, appointments, and medical insurance

- For appointments, reports, and payments, check the hospital's official site / verified account, the local health authority, and official appointment services. Verify campus, department, date, release schedule, and identity requirements. Do not treat an advertising referral page as a hospital's official entry point.
- For medical-insurance services, start with the [National Healthcare Security Administration](https://www.nhsa.gov.cn/) and [National Medical Insurance Service Platform](https://fuwu.nhsa.gov.cn/) for current guidance, then locate the actual enrollment region. A channel for handling a healthcare service is not a medical diagnosis source.

### Government services, credentials, and local administration

- Start with the [National Government Service Platform user guide](https://gjzwfw.www.gov.cn/col/col1599/index.html), the target region's government, and the responsible agency's service guide. Suishenban, Yue Sheng Shi, and Zheliban are examples of local entry points; do not apply them across regions without checking.
- For residence permits, household registration, immigration, vehicles, marriage and childbirth, or property, confirm the jurisdiction and applicant requirements first, then verify which official website, app, mini program, or counter can complete the requested steps.

### Social insurance, housing funds, taxes, and education

- For social insurance, start with the [National Human Resources and Social Security Government Service Platform](https://www.12333.gov.cn/), the e-Social Security Card, or the local HRSS department. For housing provident funds, check the fund center where contributions are made and the local government guide.
- For individual income tax, search the [Natural Person Electronic Tax Bureau](https://etax.chinatax.gov.cn/) and official guidance for the "个人所得税" app. For other tax services, find the appropriate tax entry point for the taxpayer type, region, and matter; do not use an individual service for a company task.
- For student status or degrees, start with [CHSI query guidance](https://www.chsi.com.cn/xlcx/index.jsp). Use the responsible agency's or school's current official notice for exams, admissions, and school matters.

### Telecom, utilities, and home services

- For phone bills, statements, broadband, and account changes, start with the actual operator's official entry point, such as [China Mobile](https://www.10086.cn/), China Unicom, or China Telecom. Check the number's registered region, plan, and location.
- For electricity, water, gas, heating, and property repairs, check the utility or property service for the service address. State Grid Online, Southern Power Grid Online, Alipay utility payments, and WeChat utility payments are only candidates; the target region and account are not guaranteed to be supported.
- For home cleaning, repairs, and recycling, verify local coverage, provider identity, and price breakdown. A phone number found in search is not automatically an authorized contact.

### Banking, businesses, recruitment, and content

- For banking, insurance, and payment operations, first find the official channel of the user's actual institution. Verify the conditions for lookup, transfer, application, claim, and account closure separately. Finding an entry point does not grant authorization for a funds operation.
- For company registration, public records, and qualifications, check the responsible agency and official registration system. For recruitment and rentals, verify the current entry point, authenticity, region, and user's requirements with the organization / property owner and an appropriate platform.
- For guides, reviews, and content discovery, search Xiaohongshu, Bilibili, Zhihu, Weibo, Douban, and similar services. Keep experience-based leads separate from official facts; confirm service, price, and transaction rules with the actual provider.

### Tasks outside this map

Search again from the questions "Who is responsible for this?", "What does the official source say?", and "What channels can work now?" You may use a platform outside this list, contact a merchant directly, or arrange a human step. Do not rewrite the user's request to fit an app already on the list.
