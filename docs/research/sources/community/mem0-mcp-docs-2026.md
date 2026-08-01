# Mem0 MCP — hosted memory tools via MCP

URL: https://docs.mem0.ai/platform/mem0-mcp
Author: Mem0 docs
Status: 2026-07（官方开源 mem0-mcp-server 仓库已归档，官方转向云托管 MCP：https://mcp.mem0.ai/mcp）

---

> MCP (Model Context Protocol) is a standard way for AI clients to call external tools. The Mem0 MCP server hands your agent a set of memory tools, so it can decide for itself when to save something, look something up, or update what it already knows. Nothing runs on your machine: the server is hosted by Mem0, and your client connects to it over HTTPS. Memories you store this way live in your Mem0 account, not on your computer.

快速接入（写入各客户端配置）：
```
npx mcp-add --name mem0-mcp --type http --url "https://mcp.mem0.ai/mcp" \
  --clients "claude,claude code,cursor,windsurf,vscode,opencode"
```

## 暴露的 memory 工具

| Tool | Description |
| --- | --- |
| `add_memory` | Save text or conversation history for a user/agent |
| `search_memories` | Semantic search across existing memories with filters |
| `get_memories` | List memories with structured filters and pagination |
| `get_memory` | Retrieve one memory by its `memory_id` |
| `update_memory` | Overwrite a memory's text and/or metadata |
| `delete_memory` | Delete a single memory by `memory_id` |
| `delete_all_memories` | Bulk delete all memories in scope |
| `delete_entities` | Delete a user/agent/app/run entity and its memories |
| `list_entities` | Enumerate users/agents/apps/runs |
| `list_events` | List memory operation events with filters |
| `get_event_status` | Check the status of an async memory operation |

认证：浏览器 OAuth 登录（多数客户端）或 API key 作为 bearer token。
