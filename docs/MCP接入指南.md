# 用任意 AI Agent 操控 Prism

三种方式都可以，**都已上线**。按顺序挑你顺手的。

---

## 方式一：给 AI 一个 MCP 网址（最推荐）

### 网址

```
https://ai-api.youyuanqi.dpdns.org/mcp?key=5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791
```

> 控制台 → 顶部「AI接入」页里也有这个网址，带「复制」按钮。
> 密钥也可以走 `Authorization: Bearer <key>` 头，`?key=` 是为了迁就只能填 URL 的客户端。

### Codex（`~/.codex/config.toml`）

```toml
[mcp_servers.prism]
url = "https://ai-api.youyuanqi.dpdns.org/mcp?key=5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
```

### Claude Desktop（`claude_desktop_config.json`）

```json
{
  "mcpServers": {
    "prism": {
      "command": "npx",
      "args": ["-y", "mcp-remote",
        "https://ai-api.youyuanqi.dpdns.org/mcp?key=5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"]
    }
  }
}
```

### Cursor / 其他支持 HTTP MCP 的客户端

类型选 `http` 或 `streamable-http`，URL 填上面那个即可。

---

## 方式二：换掉 Prism 内置的那个 AI（自己选、自己添加）

控制台 → 顶部「模型」页 → 填四项（显示名 / Base URL / 模型名 / API Key）
→ 下面有 **DeepSeek、Moonshot、OpenAI、通义千问** 四个一键预设。

- 任何 **OpenAI 兼容**的接口都能加（含自建的 One-API / New-API / vLLM）
- 密钥只存在 Cloudflare D1 里，**列表接口永远只返回 `sk-t****ef` 这样的掩码**，不会回到手机或浏览器
- 添加后聊天走 `POST /api/v1/chat`，网关拿着你存的 key 去调厂商

---

## 方式三：网页接管

```
https://prism-console-7v1.pages.dev/agent.html#key=5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791&api=https://ai-api.youyuanqi.dpdns.org
```

打开后网关地址和密钥**已经填好**，直接点「绑定设备」就行。
适合让 AI 用浏览器打开这个页面自己操作。

---

## AI 拿到手之后能干什么（10 个工具）

| 工具 | 干什么 |
|---|---|
| `list_devices` | 看云手机在不在线（**建议先调这个**） |
| `prism_status` | 查 Prism 引擎：APK 装没装、8080 响不响应、机器人连没连 |
| `prism_chat` | 让 Prism 内置 AI 跑一段话，驱动它干活。带 `session_name` 可连续追问 |
| `prism_tool` | 调 Prism 的 29 个内置工具之一（list_packets / send_packet / …） |
| `prism_rest` | 直连 Prism 的 REST 端点（`/api/bot/status`、`/api/plugin/list` 等） |
| `prism_session` | 管理 Prism「AI帮写」的会话（list / load / save / delete） |
| `packet_history` | 抓包历史回看（list / stats / query） |
| `packet_send` | 发包 |
| `list_ai_models` | 看你在控制台配了哪些模型 |
| `ai_chat` | 用你配的外部大模型思考（非流式） |

> 区别：`prism_chat` 是「让 Prism 干活」，`ai_chat` 是「让大模型思考」。别混。

### ★ 「不用再接密钥和 API」是什么意思

`prism_chat` / `prism_tool` / `prism_session` 走的都是 **Prism 自己的内置 AI**
（它自己配的模型、自己的 29 个工具）。外部 AI Agent 只拿到上面那个网址，
**不需要再准备任何 API Key** —— 模型是 Prism 的，钱也是 Prism 那边出。

想换成自己的模型也可以：控制台「模型」页加一个，然后用 `ai_chat` 或
在 `prism_chat` 里传 `model_name`。两条路并行，不冲突。

---

## 前提：云手机上得先跑起被控端

AI 只能通过云端中继找到被控端，所以云手机里必须有一个在跑：

- **Android 云手机**：装 `Prism被控端-v1.1.apk`（在 `apk/dist/`）
  和 Prism 装同一台机器。v1.1 起会**自动拉起 Prism**：
  每条指令执行前先探测 8080，没响应就用 Intent 把 Prism APK 唤醒。
  云手机把 Prism 杀了也不用人去点。
- **Windows 云主机**：跑 `agent/prism_agent.py`
- 或者直接在云手机浏览器打开方式三的链接（不用装 App）

被控端起来后，`https://ai-api.youyuanqi.dpdns.org/api/v1/health` 里
`devices_online` 会从 0 变成 1，AI 就能调 `prism_*` 了。

> Prism 装在哪、被控端装在哪：**必须同一台**。它们之间是 127.0.0.1 直连，
> 跨机器连不上。

---

## 链路（确认过端到端 11/11）

```
AI Agent ──MCP──► Cloudflare Worker
                        │ 写 pending 指令到 D1
                        ▼
              云手机里的被控端（长轮询领走）
                        │ 127.0.0.1:8080 调 Prism
                        ▼
              Prism 执行 → 结果回传 → AI 拿到
```

**你的电脑全程不参与。**
