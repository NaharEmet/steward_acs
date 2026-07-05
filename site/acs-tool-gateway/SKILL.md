---
name: acs-tool-gateway
description: ACS MCP YAML Tool Gateway reference. Create and update {app}.yaml tool definitions for Steward ACS. Use when adding tools to the MCP gateway, defining tool endpoints, or registering new tools for agent access.
---

# ACS MCP Tool Creator

Create and update YAML tool definitions for Steward ACS MCP Tool Gateway. When an application exposes REST APIs, agents can call them through the gateway by declaring tools in a YAML configuration file.

## When to Use

- Asked to "add tools to the ACS" or "register MCP tools"
- An app has REST API endpoints that should be callable by agents
- Creating a new `{app}.yaml` tool definition file
- Adding a new tool to an existing app's tools
- Understanding how the Tool Gateway routes MCP calls to REST APIs
- Validating tool definitions before deployment
- Explaining the YAML schema for tool definitions

## Architecture Overview

```
Agent calls tool (e.g., send_message)
       │
       ▼
ToolRegistry (GenServer) — looks up tool by name in ETS state
       │
       ├─ Internal (handler): dispatches to Acs.MCP.Tools.call_tool/2
       │
       └─ External (endpoint): routes to Bridge (Req HTTP client)
               │
               ▼
         POST http://anantha:4000/api/tools/send_message
               │
               ▼
         App REST API — processes the request
```

Tools are loaded from YAML files in `/app/acstools/` (Docker volume). Each file defines one app's tools.

## YAML Schema Reference

### File structure
```yaml
app: app-name                    # Docker service name — used for routing
base_url: http://app:4000        # Docker service URL for HTTP calls
description: ACS MCP YAML Tool Gateway reference. Create and update {app}.yaml tool definitions for Steward ACS. Use when adding tools to the MCP gateway, defining tool endpoints, or registering new tools for agent access.

tools:
  - name: tool_name
    category: category_name
    level: 2
    description: "What the tool does"
    endpoint: /api/path
    method: POST
    params:
      - name: param_name
        type: string
        required: true
        description: "What this param is for"
    headers:
      Content-Type: application/json
```

### Field Reference

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `app` | Yes | string | Docker service name (e.g., anantha, billing) |
| `base_url` | No | string | URL for Bridge HTTP routing (e.g., http://anantha:4000) |
| `description` | No | string | Human-readable app description |
| `tools` | Yes | list | Non-empty list of tool definitions |

### Per-Tool Fields

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `name` | ✅ Yes | string | kebab-case tool name, unique per app |
| `description` | ✅ Yes | string | Shown to agents in tool listings |
| `endpoint` | See note | string | REST API path (e.g., /api/tools/send_message) |
| `method` | See note | string | GET, POST, PUT, DELETE, or PATCH |
| `handler` | See note | string | Elixir module for internal tools |
| `category` | No | string | For grouping (messaging, workflows, etc.) |
| `level` | No | integer | 1=always visible, 2=on-demand, 3=admin-only |
| `params` | No | list | Parameter definitions |
| `headers` | No | map | HTTP headers to include in the request |

**Note on endpoint/handler**: Every tool must have EITHER `handler` (internal ACS tool) OR `endpoint` + `method` (external API tool). Not both.

### Per-Parameter Fields

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `name` | ✅ Yes | string | Parameter name |
| `type` | ✅ Yes | string | string, integer, boolean, or json |
| `required` | No | boolean | Whether param is mandatory (default: false) |
| `description` | No | string | Shown to agents when describing the tool |

## Progressive Disclosure System

Tools have visibility levels that control when agents can discover them:

- **Level 1** (acs_core): Always visible — basic ACS tools like acs_claim_work, acs_create_work
- **Level 2** (per-app): On-demand — agents must call `mcp_list_categories` then `mcp_list_tools(category)` to see them
- **Level 3** (admin): Only visible to admin agents

Agents connect and see Level 1 tools. They discover more through `mcp_list_categories` and `mcp_list_tools`.

## Discovery MCP Tools

Three discovery tools are always available in the ToolRegistry:

| Tool | Purpose |
|------|---------|
| `mcp_list_categories` | List all available tool categories |
| `mcp_list_tools(category)` | Get tools for a specific category |
| `mcp_refresh_tools` | Hot-reload all YAML tool definitions |

## Requesting New Tools (Agent Flow)

If an agent needs a tool that doesn't exist yet:

1. Agent calls `request_tool(definition)` MCP tool
2. The definition is saved as a pending request in the database (`tool_requests` table)
3. A human operator sees the request in the ACS dashboard (`/tools/requests`)
4. Operator reviews and clicks **Approve** or **Reject**
5. On approve, the tool is registered in ToolRegistry memory and visible immediately
6. For permanent persistence, the operator adds the tool to the app's YAML file

## Step-by-Step: Creating a New App's Tools

1. **Identify the app** — What Docker service name? What's its REST API base URL?
2. **List endpoints** — Which REST API endpoints should be callable by agents?
3. **Write the YAML** — Create `{app}.yaml` following the schema above:
   - Each endpoint becomes a tool
   - Map URL path params and request body fields to tool params
   - Choose category and level for each tool
4. **Validate** — Check all required fields, valid method values, correct param structure
5. **Mount the file** — Ensure the YAML file is in the Docker volume at `/app/acstools/`
6. **Refresh** — Call `mcp_refresh_tools` to hot-reload without restart

## Mapping REST APIs to MCP Tools

### GET endpoint example
```yaml
# REST: GET /api/workflows?org_id=123&status=active
- name: list_workflows
  category: workflows
  level: 2
  description: List workflows with optional filters
  endpoint: /api/workflows
  method: GET
  params:
    - name: org_id
      type: string
      required: true
    - name: status
      type: string
      required: false
```

### POST endpoint example
```yaml
# REST: POST /api/messages  { "org_id": "123", "content": "hello" }
- name: send_message
  category: messaging
  level: 2
  description: Send a message
  endpoint: /api/messages
  method: POST
  params:
    - name: org_id
      type: string
      required: true
    - name: content
      type: string
      required: true
```

### Full app YAML example

```yaml
app: anantha
base_url: http://anantha:4000
description: ACS MCP YAML Tool Gateway reference. Create and update {app}.yaml tool definitions for Steward ACS. Use when adding tools to the MCP gateway, defining tool endpoints, or registering new tools for agent access.

tools:
  - name: send_message
    category: messaging
    level: 2
    description: Send a message to an actor
    endpoint: /api/tools/send_message
    method: POST
    params:
      - name: org_id
        type: string
        required: true
      - name: actor_id
        type: string
        required: true
      - name: content
        type: string
        required: true
    headers:
      Content-Type: application/json

  - name: list_workflows
    category: workflows
    level: 2
    description: List workflows with optional status filter
    endpoint: /api/tools/list_workflows
    method: GET
    params:
      - name: org_id
        type: string
        required: true
      - name: status
        type: string
        required: false
      - name: limit
        type: integer
        required: false
```

## Validation Rules (from Acs.MCP.ToolLoader)

The loader validates at load time. Common errors:

| Error | Cause | Fix |
|-------|-------|-----|
| "Missing required field: 'app'" | No `app` at top level | Add `app: your-app-name` |
| "'tools' must be a list" | `tools` is not an array | Ensure `tools:` has a list of items |
| "'tools' list cannot be empty" | `tools: []` | Add at least one tool definition |
| "must have 'handler' or 'endpoint' + 'method'" | Tool missing both | Add `handler` or `endpoint` + `method` |
| "'method' must be GET, POST, PUT, DELETE, or PATCH" | Invalid HTTP method | Use one of the 5 valid methods |
| "missing 'name'" in params | Param without name | Add `name` field to each param |

## Validation Checklist

Before finalizing any tool definition:

- [ ] Top-level `app` is a non-empty string
- [ ] `tools` is present with at least one tool
- [ ] Every tool has `name` and `description` as strings
- [ ] Every tool has `handler` (internal) OR `endpoint` + `method` (external)
- [ ] `method` is one of: GET, POST, PUT, DELETE, PATCH
- [ ] Every param has `name` (string) and `type` (string)
- [ ] YAML is syntactically valid
- [ ] File is named `{app}.yaml` matching the `app` field
- [ ] Tool names are kebab-case and unique within the file
