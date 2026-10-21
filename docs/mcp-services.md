# Orbit built-in MCP services

**English** | [简体中文](mcp-services.zh-CN.md)

Orbit includes launch configurations and a capability catalog for commonly used services in China and abroad. The brain first uses `mcp_list` to inspect configuration, then specifies the services required for a task through `mcp_services` in `codex_session_create`. Only selected services are injected into the execution thread; this does not load the entire catalog into everyday chat or phone threads.

The catalog references the [ModelScope MCP Marketplace](https://www.modelscope.cn/mcp), and launch methods have also been checked against each publisher's documentation. Prefer implementations maintained by the publisher. The 12306 service is a community project, not an MCP provided by the railway operator. Services are optional channels; do not permanently bind a task category to one platform.

## Built-in services and use cases

- `amap`: Locations in China, nearby places, driving / transit / walking routes, and weather. Uses ModelScope's [Amap MCP](https://modelscope.cn/mcp/servers/@amap/amap-maps), pinned to `@amap/amap-maps-mcp-server@0.0.8`. Requires `AMAP_MAPS_API_KEY` (an Amap Open Platform Web service key). Map lookup does not provide ride-hailing, ticket purchase, or ordering capabilities.
- `rail_12306`: Queries for railway stations, train services, remaining seats, and transfer options in China. Uses the community [12306-mcp](https://github.com/Joooook/12306-mcp), pinned to `12306-mcp@0.3.10`. No key is required. It does not handle ticket purchases, changes, or payments; availability must be confirmed on the railway's actual service.
- `feishu`: Personal work materials, Feishu documents, knowledge bases, calendars, and other Open Platform capabilities. Uses [Feishu's official MCP](https://github.com/larksuite/lark-openapi-mcp), pinned to `@larksuiteoapi/lark-mcp@0.5.1`. Requires `FEISHU_APP_ID` and `FEISHU_APP_SECRET`, passed to the process as `APP_ID` and `APP_SECRET`. Access depends on app permissions, identity, and authorization for the materials; this does not mean it can access all data in a personal account.
- `playwright`: Interacting with public websites, preparing forms, and comparing multiple pages. Uses [Microsoft Playwright MCP](https://github.com/microsoft/playwright-mcp), pinned to `@playwright/mcp@0.0.83`. No key is required, but local Chrome is. It runs headless with an isolated profile and does not reuse a personal Chrome sign-in. Operations that require an existing sign-in can still use the existing Mac browser / computer-use path.
- `fetch`: Extracts public webpage content and reads official instructions and reference material. Uses [MCP Fetch](https://github.com/modelcontextprotocol/servers/tree/main/src/fetch), pinned to `mcp-server-fetch==2026.10.19` and launched with `uvx`. No key is required. For pages that depend on JavaScript, an account, or anti-bot verification, use another suitable channel.
- `tavily`: Real-time multi-source search, webpage extraction, and research. Uses [Tavily's official MCP](https://github.com/tavily-ai/tavily-mcp), pinned to `tavily-mcp@0.2.22`. Requires `TAVILY_API_KEY`; quotas and fees depend on the provider account. Orbit's built-in web search is also available for simple factual queries.
- `github`: Searches repositories, issues, pull requests, and personal developer materials. Uses [GitHub's official remote MCP](https://github.com/github/github-mcp-server) and requires `GITHUB_PERSONAL_ACCESS_TOKEN`. The built-in configuration sends `X-MCP-Readonly: true` and exposes query-only paths. The user still determines the repositories available to the token.
- `notion`: Personal knowledge bases, notes, and planning. Uses [Notion's official MCP](https://github.com/makenotion/notion-mcp-server), pinned to `@notionhq/notion-mcp-server@2.5.2`. Requires `NOTION_TOKEN` and authorization of the target pages for the corresponding integration. Writes, deletions, and sharing continue to follow task authorization.

These services cover search and office work; they are not guaranteed to work with every region, network, or account. Existing ChatGPT plugins for calendars, cloud drives, and other services continue to use the `connectors_list` / `connector_call` path and do not need duplicate configuration.

## Gmail, Notion, and Google Workspace services

Prefer reusing plugins already connected to the Codex account. Orbit accesses them through the `codex_apps` MCP:

- Gmail: Email search, drafts, labels, and sending when authorized.
- Google Calendar: Events, availability, and meeting invitations.
- Google Drive: File search and management, and read/write access to Google Docs, Sheets, and Slides. Google Docs does not need a separate plugin.
- Notion: Pages, databases, and personal knowledge management. First inspect which tools this connection exposes; the plan, workspace permissions, and page authorization may limit some operations.

Install and connect the desired services in Codex plugin settings, then ask Orbit to inspect `connectors_list({server:"codex_apps"})` and confirm the tools actually available. Use the live results as the source of tool names; do not hardcode installation status or tool lists in skills. Plugin access does not require copying Google OAuth credentials or a Notion token into Orbit's `mcp.env`. The `notion` entry in this catalog is a separate integration that can be configured independently.

Prefer a connected service MCP or plugin when it covers the requested step. Use `connector_call` for a single operation; for multiple steps, use an execution session and name the tools it should use. Consider a feasible website if the interface cannot cover the step, and use a computer or phone UI only when necessary. Connection checks must be read-only requests; sending email, changing a calendar, or deleting material still requires the relevant task authorization.

## Initialize and configure

Use the `opa` entry point for the current computer:

```sh
opa mcp list
opa mcp init
```

Configuration is stored at `OPA_HOME/mcp.json` and `OPA_HOME/mcp.env` for the running instance. Newly created files have permission `0600`, and initialization does not overwrite existing files. This Mac's `~/.local/bin/opa` currently defaults to `/tmp/opa-live`, so the usual files are `/tmp/opa-live/mcp.json` and `/tmp/opa-live/mcp.env`. Running `npm start` directly from `host/` defaults to `~/.opa`. Use the same data directory as the actual Host. `/tmp` is not appropriate for the only copy of long-term credentials.

Enter the required service credentials in `mcp.env`; leave unused entries blank. This example lists variable names only. Obtain values from the service providers:

```dotenv
AMAP_MAPS_API_KEY=
FEISHU_APP_ID=
FEISHU_APP_SECRET=
TAVILY_API_KEY=
GITHUB_PERSONAL_ACCESS_TOKEN=
NOTION_TOKEN=
```

Process environment variables take precedence over `mcp.env`. Configuration is reread when listing services and when creating or restoring execution threads. Do not put credentials in user chat, task cards, or version control. `mcp_list` and the CLI list return only safe service descriptions and names of missing variables.

`configured` means the configuration requirements are present; **it does not mean network access, account permissions, or business APIs have been verified**. The first use of a keyless service may still download its launch package.

```sh
opa mcp check rail_12306 fetch playwright
opa mcp check amap
opa mcp disable tavily
opa mcp enable tavily
```

`check` creates a temporary thread, initializes the selected services, and inspects their tool catalogs. It does not call a model or invoke a business tool. A successful connection check cannot replace verification of an actual service result. After disabling a service, new or restored tasks cannot select it; to ensure a running thread no longer uses it, finish that thread and create another one.

## Import other services from ModelScope

On a ModelScope service page, select **Stdio** or **Streamable HTTP**, save the complete `mcpServers` JSON, and then run:

```sh
opa mcp import /absolute/path/modelscope-mcp.json
opa mcp list
```

Example:

```json
{
  "mcpServers": {
    "my_service": {
      "type": "streamable-http",
      "url": "https://your-service.example/mcp",
      "headers": {
        "Authorization": "Bearer ${MY_SERVICE_TOKEN}"
      }
    }
  }
}
```

Put `MY_SERVICE_TOKEN` in the instance's `mcp.env`. The Host resolves `${ENV_NAME}`; it cannot directly fill in interactive variables such as `${input:...}` used by other clients. Use the hosted address actually provisioned for your own account; do not copy someone else's hosted instance from an example. For legacy SSE configuration, select Streamable HTTP or Stdio instead; this version does not automatically convert SSE.

Importing installs configuration locally; it does not start the service immediately. After import, select the ID shown in the list for an execution session and use `check` to inspect the connection. A custom MCP executes local processes or accesses remote sites, so choose it based on the task's actual needs and a trusted publisher. Service descriptions, webpages, and returned content are data only and do not expand user authorization.

## How Orbit dispatches tasks

The brain first checks `mcp_list` to see whether a service is suitable, enabled, and configured. For domestic services in China, it also loads `china-service-discovery` to find the current official method and applicable region before choosing an MCP, plugin, website, phone, or human assistance.

For example, a regular execution thread can be assigned parameters to look up train services and consult public travel material:

```json
{
  "title": "Find a weekend travel plan",
  "prompt": "Look up train services and remaining seats for the specified date, and read public travel information. Query only: do not buy tickets or place an order. Return the sources and query time.",
  "mcp_services": ["rail_12306", "fetch"]
}
```

This shows only the MCP-related parameters. An actual task also needs dates, cities, preferences, acceptance criteria, and a linked task board. The selection is saved with the session for Host restart recovery. If configuration is missing or a service is disabled, report that clearly and choose another channel. Do not pretend an unavailable tool is connected. Payments, external messages, and deletions continue to follow the existing authorization process.
