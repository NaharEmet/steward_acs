---
name: acs-service-setup
description: Complete workflow for adding a new service to the ACS MCP Tool Gateway. Use when registering a new app's REST APIs as MCP tools, setting up YAML definitions, or reviewing existing tool configurations.
---

# ACS Service Setup

Define the complete workflow for adding a new service to Steward ACS MCP Tool Gateway. This is the "ACS setup system" — a structured guide that any agent can load when they need to expose a new application's REST APIs as MCP tools.

## When to Use

- Asked to "add a service to ACS" or "register a new app"
- A new microservice has REST APIs that agents should call
- Setting up MCP tools for a newly deployed application
- Reviewing existing tool definitions for completeness
- Debugging why a tool isn't reachable from agents

## Architecture Overview

```
Agent calls tool (e.g., list_invoices)
       │
       ▼
ToolRegistry (GenServer) — looks up tool by name in ETS state
       │
       ├─ Internal (handler): dispatches to Acs.MCP.Tools.call_tool/2
       │
       └─ External (endpoint): routes to Bridge (Req HTTP client)
               │
               ▼
         POST http://service:4000/api/tools/list_invoices
               │
               ▼
         App REST API — processes the request and returns response
```

The Tool Gateway acts as a unified routing layer. Tools are defined in YAML files mounted at `/app/acstools/` (Docker volume). Each file defines one app's tool set, mapping MCP tool calls to REST API endpoints on that app.

## Complete Workflow

### Step 1: Identify the Service

Determine the service's identity within the Docker ecosystem:

- **Docker service name** — The service name in `docker-compose.yml` (e.g., `anantha`, `billing`, `notifications`)
- **Base URL** — The Docker-internal URL (e.g., `http://billing:4000`)
- **Running status** — Verify the service is running and reachable

```bash
docker ps | grep billing
curl -s http://billing:4000/health  # if health endpoint exists
```

#### ⚠️ Anti-Patterns

| Pattern | Why It's Wrong | What To Do Instead |
|---------|---------------|-------------------|
| ❌ Using external URLs (localhost, 127.0.0.1) | Docker containers resolve each other by service name, not localhost | Use `http://service-name:PORT` |
| ❌ Guessing the port | Wrong port = silent failures or wrong service | Check `docker-compose.yml` or the app's config |
| ❌ Skipping health check | You might invest time defining tools for a down service | Verify the service is running first |

### Step 2: Audit Available Endpoints

Catalog the REST API endpoints that should be callable by agents. For each endpoint, determine:

- **Path** (e.g., `/api/invoices`)
- **HTTP method** (GET, POST, PUT, DELETE, PATCH)
- **Request parameters** — URL query params, path params, and request body fields
- **Response format** — What the API returns (JSON structure)

Ask these questions for each endpoint:

- Is this endpoint useful for agents, or is it internal-only?
- What parameters does an agent need to provide?
- Is the response agent-parseable?

#### ⚠️ Anti-Patterns

| Pattern | Why It's Wrong | What To Do Instead |
|---------|---------------|-------------------|
| ❌ Exposing internal/admin-only endpoints | Agents may trigger destructive or unsafe operations | Only expose task-relevant endpoints |
| ❌ Forgetting path parameters | The tool will fail at runtime with no clear error | Map every URL path segment to a required param |
| ❌ Exposing overly broad endpoints (e.g., `/api/*`) | Agents can't discover individual tools; no parameter validation | Create specific tools for each distinct operation |

### Step 3: Create YAML Definitions

Write the YAML file following the [YAML Schema Reference](#yaml-schema-reference). Each endpoint becomes a tool definition.

General rules:
- Tool names are **snake_case** and unique within the file
- URL path params and request body fields become tool params
- Choose an appropriate **category** for grouping (e.g., `billing`, `messaging`, `workflows`)
- Choose an appropriate **level** (see [Progressive Disclosure System](#progressive-disclosure-system))

```yaml
app: billing
base_url: http://billing:4000
description: Billing service for invoice management

tools:
  - name: list_invoices
    category: billing
    level: 2
    description: List all invoices with optional filters
    endpoint: /api/invoices
    method: GET
    params:
      - name: org_id
        type: string
        required: true
        description: Organization ID to filter invoices
      - name: status
        type: string
        required: false
        description: Filter by status (paid, pending, overdue)
```

#### ⚠️ Anti-Patterns

| Pattern | Why It's Wrong | What To Do Instead |
|---------|---------------|-------------------|
| ❌ Using camelCase or PascalCase tool names | Inconsistent with the ACS convention (existing tools use snake_case) | Use snake_case: `list_invoices`, `send_message` |
| ❌ Missing required params | Agent gets a runtime error with no guidance | Add all required path/body params with `required: true` |
| ❌ Using wrong HTTP method | The bridge sends wrong verb; API returns 405 | Double-check the API's expected method |
| ❌ Forgetting `endpoint` or `method` | The tool has no routing target | Every external tool needs BOTH `endpoint` AND `method` |

### Step 4: Validate

Check the YAML definition against the ToolLoader validation rules before deploying:

| Validation | What to Check |
|-----------|---------------|
| Required fields | `app` is present and non-empty at the top level |
| Tools list | `tools` is present with at least one tool |
| Tool structure | Every tool has `name` and `description` as strings |
| Routing | Every tool has `handler` (internal) OR `endpoint` + `method` (external) |
| Method | `method` is one of: GET, POST, PUT, DELETE, PATCH |
| Params | Every param has `name` (string) and `type` (string) |
| YAML syntax | File parses as valid YAML (no syntax errors) |
| File naming | File is named `{app}.yaml` matching the `app` field |
| Uniqueness | Tool names are unique within the file |

Manual validation steps:

```bash
# Check YAML syntax
python3 -c "import yaml; yaml.safe_load(open('billing.yaml'))" && echo "Valid YAML"

# Verify required fields (quick grep)
grep -q "^app:" billing.yaml && echo "app present"
grep -q "^tools:" billing.yaml && echo "tools present"
```

#### ⚠️ Anti-Patterns

| Pattern | Why It's Wrong | What To Do Instead |
|---------|---------------|-------------------|
| ❌ Skipping YAML syntax check | A syntax error causes the entire file to fail loading | Validate YAML syntax before deploying |
| ❌ Assuming the file validates correctly | Without explicit checks, subtle issues slip through | Walk the validation checklist for each tool |
| ❌ Mis-matching filename to app name | The loader may not find the file | Name it exactly `{app}.yaml` |

### Step 5: Deploy

Mount the YAML file where the ToolGateway can find it and trigger a hot-reload:

1. **Place the file** in the `acstools` directory:
   ```bash
   cp billing.yaml /app/acstools/billing.yaml
   ```

2. **Hot-reload** the tool registry without restarting the server:
   ```elixir
   mcp_refresh_tools()
   ```
   This triggers `ToolLoader.load_all/0`, which re-reads every `.yaml` file in the `/app/acstools/` directory.

3. **Verify the refresh** — Check for any load errors in the response or logs.

#### ⚠️ Anti-Patterns

| Pattern | Why It's Wrong | What To Do Instead |
|---------|---------------|-------------------|
| ❌ Restarting the server to pick up tools | Unnecessary downtime; hot-reload exists | Always use `mcp_refresh_tools` |
| ❌ Putting the file in the wrong directory | The loader won't find it | Mount in `/app/acstools/` specifically |
| ❌ Forgetting to copy into Docker volume | File exists on host but not in container | Ensure the file reaches the container's filesystem |

### Step 6: Verify

Confirm the tools are visible and functionally correct:

1. **List categories** to see the new category:
   ```elixir
   mcp_list_categories()
   # Should include "billing" (or whatever category you chose)
   ```

2. **List tools** in the new category:
   ```elixir
   mcp_list_tools(category: "billing")
   # Should show your new tools with names, descriptions, and params
   ```

3. **Optionally test** a tool call to verify end-to-end routing:
   ```elixir
   list_invoices(org_id: "test-org", status: "paid")
   # Should return real data from the service
   ```

#### ⚠️ Anti-Patterns

| Pattern | Why It's Wrong | What To Do Instead |
|---------|---------------|-------------------|
| ❌ Assuming the tool works without testing | Params could be mapped wrong; endpoint could 404 | Test at least one tool end-to-end |
| ❌ Only checking categories without listing tools | A category can exist but be empty | Drill into `mcp_list_tools(category)` to verify each tool |
| ❌ Ignoring error responses | A 500 from the API looks like a tool definition problem | Check the logs if a tool call fails |

## YAML Schema Reference

### File Structure

```yaml
app: app-name                    # Docker service name — used for routing
base_url: http://app:4000        # Docker service URL for HTTP calls
description: "Human-readable description of this app"

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
| `app` | ✅ Yes | string | Docker service name (e.g., anantha, billing) |
| `base_url` | No | string | URL for Bridge HTTP routing (e.g., http://billing:4000) |
| `description` | No | string | Human-readable app description |
| `tools` | ✅ Yes | list | Non-empty list of tool definitions |

### Per-Tool Fields

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `name` | ✅ Yes | string | snake_case tool name, unique per app |
| `description` | ✅ Yes | string | Shown to agents in tool listings |
| `endpoint` | See note | string | REST API path (e.g., /api/invoices) |
| `method` | See note | string | GET, POST, PUT, DELETE, or PATCH |
| `handler` | See note | string | Elixir module for internal tools |
| `category` | No | string | For grouping (billing, messaging, workflows, etc.) |
| `level` | No | integer | 1=always visible, 2=on-demand, 3=admin-only (default: 2) |
| `params` | No | list | Parameter definitions |
| `headers` | No | map | HTTP headers to include in the request |

**Note on endpoint/handler**: Every tool must have EITHER `handler` (internal ACS tool) OR `endpoint` + `method` (external API tool). Not both.

### Per-Parameter Fields

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `name` | ✅ Yes | string | Parameter name (snake_case) |
| `type` | ✅ Yes | string | `string`, `integer`, `boolean`, or `json` |
| `required` | No | boolean | Whether param is mandatory (default: false) |
| `description` | No | string | Shown to agents when describing the tool |

## Progressive Disclosure System

Tools have visibility levels that control when agents can discover them:

| Level | Name | Visibility | Example Use |
|-------|------|------------|-------------|
| **1** | acs_core | Always visible — appears in every agent's default tool list | Basic ACS tools like `acs_claim_work`, `acs_create_work` |
| **2** | per-app | On-demand — agents must call `mcp_list_categories` then `mcp_list_tools(category)` | Service-specific tools like `list_invoices`, `send_message` |
| **3** | admin | Only visible to agents with admin credentials | System administration, user management, destructive operations |

When connecting, agents see Level 1 tools by default. They discover Level 2 tools by calling `mcp_list_categories` to see available categories, then `mcp_list_tools(category)` to drill into a specific category.

**Recommendation**: Most service tools should be **Level 2**. Use Level 1 sparingly (only for universally-needed tools). Use Level 3 for any tool that could cause data loss or security issues.

## Full Worked Example: Adding a Billing Service

This example walks through adding a hypothetical billing service with invoice management.

### Step 1: Identify the Service

- **Docker service name**: `billing`
- **Base URL**: `http://billing:4000`
- **Status**: Running (verified via `docker ps`)

### Step 2: Audit Endpoints

| Endpoint | Method | Purpose | Agent-Relevant? |
|----------|--------|---------|-----------------|
| `/api/invoices` | GET | List invoices (query: org_id, status, limit) | ✅ Yes |
| `/api/invoices` | POST | Create invoice (body: org_id, customer_id, amount, due_date) | ✅ Yes |
| `/api/invoices/{id}` | GET | Get single invoice details | ✅ Yes |
| `/api/invoices/{id}` | PUT | Update invoice | ⚠️ Maybe (agents shouldn't modify invoices) |
| `/api/invoices/{id}` | DELETE | Delete invoice | ❌ No (destructive) |
| `/api/health` | GET | Health check | ❌ No (infra-only) |
| `/api/internal/reindex` | POST | Reindex search data | ❌ No (internal/admin) |

### Step 3: Create YAML

```yaml
app: billing
base_url: http://billing:4000
description: Billing service for invoice and payment management

tools:
  - name: list_invoices
    category: billing
    level: 2
    description: List all invoices with optional status and limit filters
    endpoint: /api/invoices
    method: GET
    params:
      - name: org_id
        type: string
        required: true
        description: Organization ID to scope the invoice list
      - name: status
        type: string
        required: false
        description: Filter by invoice status (paid, pending, overdue, cancelled)
      - name: limit
        type: integer
        required: false
        description: Maximum number of invoices to return (default 20)

  - name: create_invoice
    category: billing
    level: 2
    description: Create a new invoice for a customer
    endpoint: /api/invoices
    method: POST
    params:
      - name: org_id
        type: string
        required: true
        description: Organization ID
      - name: customer_id
        type: string
        required: true
        description: Customer to bill
      - name: amount
        type: integer
        required: true
        description: Invoice amount in cents
      - name: due_date
        type: string
        required: true
        description: Due date in ISO 8601 format (e.g., 2026-06-01)
      - name: description
        type: string
        required: false
        description: Optional line item description
    headers:
      Content-Type: application/json

  - name: get_invoice
    category: billing
    level: 2
    description: Get detailed information about a specific invoice
    endpoint: /api/invoices/{id}
    method: GET
    params:
      - name: org_id
        type: string
        required: true
        description: Organization ID
      - name: id
        type: string
        required: true
        description: Invoice ID to retrieve
```

### Step 4: Validate

Checklist walkthrough:

- ✅ `app: billing` — non-empty string present
- ✅ `tools` — 3 tools defined
- ✅ Each tool has `name` and `description`
- ✅ Each tool has `endpoint` + `method` (no `handler` — these are external)
- ✅ Methods are GET or POST (valid)
- ✅ Every param has `name` and `type`
- ✅ YAML syntax is valid
- ✅ File named `billing.yaml` matches `app: billing`
- ✅ Tool names are unique and snake_case

### Step 5: Deploy

```bash
# Place the file
cp billing.yaml /app/acstools/billing.yaml

# Hot-reload
mcp_refresh_tools()
```

### Step 6: Verify

```elixir
mcp_list_categories()
# → ["acs_core", "billing", "messaging", "workflows"]

mcp_list_tools(category: "billing")
# → [list_invoices, create_invoice, get_invoice]

mcp_list_tool(tool_name: "list_invoices")
# → Shows full tool definition with params
```

## Validation Checklist

Before finalizing any YAML tool definition for a new service:

- [ ] Top-level `app` is a non-empty string matching the Docker service name
- [ ] `tools` is present with at least one tool
- [ ] Every tool has `name` and `description` as strings
- [ ] Every tool has `handler` (internal) OR `endpoint` + `method` (external)
- [ ] `method` is one of: GET, POST, PUT, DELETE, PATCH
- [ ] Every param has `name` (string) and `type` (string)
- [ ] Param names use snake_case
- [ ] YAML is syntactically valid (parseable)
- [ ] File is named `{app}.yaml` matching the `app` field
- [ ] Tool names are snake_case and unique within the file
- [ ] Each tool has an appropriate `level` set (1, 2, or 3)
- [ ] Each tool has an appropriate `category` for grouping
- [ ] Required params are marked `required: true`
- [ ] All URL path segments (e.g., `{id}`) have corresponding params
- [ ] Service is running and reachable at the `base_url`

## Cross-Reference

For hands-on YAML file creation, tool definition syntax, and detailed ToolLoader behavior, see the **ACS MCP Tool Creator** skill:

- **Skill**: [`acs-tool-gateway`](../acs-tool-gateway/SKILL.md) — Low-level YAML authoring, field-level schema, mapping REST APIs to MCP tools, validation rules from `Acs.MCP.ToolLoader`

The relationship between these two skills:

| This Skill (acs-service-setup) | acs-tool-gateway |
|-------------------------------|-------------------|
| **What** to do — the full workflow from service identification to verification | **How** to do it — the YAML syntax, field reference, and validation rules |
| Orchestration-level view | Implementation-level view |
| When to add a new service | How to write the YAML file |
