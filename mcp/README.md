# Prism MCP 服务器

让 **Codex / Claude Desktop 等 MCP 客户端**直接操控 Prism 工具箱的「AI 帮写」——
读写插件文件、收发数据包、调用游戏 API、抓包监听，全部 38 个工具。

---

## 为什么需要 MCP 而不是普通 HTTP

Prism 的 29 个工具（`send_packet` / `game_call` / `write_plugin_file` …）**在它自己的进程内执行**，
没有对外暴露独立 HTTP 端点。所以本服务器采取的策略是：

```
MCP 客户端          本服务器                 Prism
   │                  │                       │
   ├─ tools/call ────►│                       │
   │  list_packets    ├─ POST /api/ai/chat ──►│
   │                  │  "请立即调用 list_packets"│
   │                  │                       ├─ AI 发起 tool_call
   │                  │                       ├─ 工具在进程内真实执行
   │                  │◄── SSE ai_tool_done ──┤
   │◄── 真实结果 ─────┤  （含 result 字段）    │
```

即：**用 AI 当工具执行的中介**，从 SSE 流里截取真实返回值。

---

## 两个版本

| 文件 | 模式 | 适用场景 | 环境变量 |
|------|------|----------|----------|
| `prism_mcp.py` | 本地直连 | Codex 与 Prism 同机 | `PRISM_URL` |
| `prism_http_mcp.py` | 云端中转 | 手机 / 异地电脑 | `PRISM_GATEWAY` `PRISM_API_KEY` |

---

## 快速开始（本地直连）

```bash
# 1. 确认 Prism 在跑
curl --noproxy '*' http://127.0.0.1:8080/api/bot/status

# 2. 自测 MCP 协议
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"prism_status","arguments":{}}}' \
  | python mcp/prism_mcp.py

# 3. 接进 Codex：把 codex_config.toml 的内容追加到 ~/.codex/config.toml
```

---

## 工具清单

### 本地直通（9 个，不走 AI，最快）
| 工具 | 说明 |
|------|------|
| `prism_status` | 机器人是否连服、维度、是否 OP |
| `prism_list_models` | AI 模型列表 |
| `prism_list_skills` | 技能知识库列表 |
| `prism_list_plugins` | 插件列表 |
| `prism_chat` | 自然语言驱动 AI |
| `prism_raw_tool` | 直调任意原生工具 |
| `prism_packet_history` | **历史抓包**回看（list / query / stats） |
| `prism_packet_subscribe` | **实时抓包**订阅 |
| `prism_packet_send` | 发包 |

### Prism 原生（29 个，走 AI 驱动）
**文件(7)**：`write_plugin_file` `read_file` `write_file` `edit_lines` `list_dir` `read_log` `read_plugin`
**游戏(4)**：`game_call` `wait_chat` `send_command_wait_output` `run_and_watch_chat`
**数据包(8)**：`listen_packet` `list_packets` `query_packets` `wait_packet` `packet_stats` `send_packet` `list_packet_schema` `run_and_watch_packet`
**网络(1)**：`network_request`
**系统(2)**：`system_shell` `shizuku_status`
**技能(2)**：`list_skills` `load_skill`
**插件(4)**：`list_plugins` `read_plugin` `call_plugin_function` `lua_call`
**其他(2)**：`user_question` `rename_session`

---

## 抓包实战示例

Codex 里直接说：

> 帮我看看最近一分钟服务器都发了什么包

Codex 会调 `prism_packet_history {action: "stats"}` 或 `{action: "query", limit: 100}`。

> 现在开始抓 20 秒的包，我去游戏里走两步

Codex 会调 `prism_packet_subscribe {duration: 20}`。

> 看看 PlayerAuthInput 这个包的字段结构

Codex 会调 `prism_raw_tool {tool_name: "list_packet_schema", arguments: {packet_type: "PlayerAuthInput"}}`。

---

## 已知限制

1. **机器人必须先连服**。`wait_packet` / `query_packets` / `game_call` 在未连服时返回错误，
   先调 `prism_status` 确认 `connected: true`。
2. **本机系统代理会拦截 127.0.0.1**（常见端口 7897）。两个脚本都已内置
   `ProxyHandler({})` 强制绕过；用 curl 测试时记得加 `--noproxy '*'`。
3. **每次工具调用消耗一次 AI 请求**（因为要驱动 AI 发起 tool_call）。
   高频抓包建议用 `query_packets` 一次性拉一批，而不是循环 `wait_packet`。
4. `system_shell` 在桌面端不支持（需要 Android + Shizuku）。
