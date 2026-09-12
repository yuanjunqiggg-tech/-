#!/usr/bin/env python3
"""
============================================================
Prism MCP Server  v2.0
把 Prism 工具箱「AI 帮写」的 29 个工具暴露为 MCP 工具，
供 Codex / Claude Desktop / 任何 MCP 客户端直接调用。

核心原理
--------
Prism 的工具在它进程内部执行，没有独立 HTTP 端点。
本服务器构造 /api/ai/chat 请求，驱动 AI 发起指定的 tool_call，
再从 SSE 流中截取 ai_tool_done 的真实执行结果返回。

两种连接模式
------------
1. 本地直连（默认）
     PRISM_URL=http://127.0.0.1:8080
   —— Codex 和 Prism 在同一台机器上时用这个，延迟最低。

2. 云端中转（手机 Codex / 异地电脑）
     PRISM_URL=https://prism.youyuanqi.dpdns.org
     附带 PRISM_API_KEY=<你的网关密钥>
   —— Cloudflare Tunnel 把本机 8080 暴露成公网域名，
      Workers 网关负责鉴权和 SSE 转发。

能力覆盖
--------
  ✓ 全部 29 个 Prism 工具（文件 / 数据包 / 游戏 / 网络 / 系统 / 插件）
  ✓ 实时抓包订阅      —— prism_packet_subscribe  (轮询式长订阅)
  ✓ 历史数据包回看    —— prism_packet_history    (query_packets / packet_stats)
  ✓ 自然语言驱动      —— prism_chat
  ✓ 原始工具直调      —— prism_raw_tool
============================================================
"""
import json
import os
import sys
import time
import threading
import urllib.request
import urllib.error
from typing import Any

# ------------------------------------------------------------
# 配置
# ------------------------------------------------------------
PRISM_URL = os.environ.get("PRISM_URL", "http://127.0.0.1:8080").rstrip("/")
PRISM_MODEL = os.environ.get("PRISM_MODEL", "prism自动")
PRISM_API_KEY = os.environ.get("PRISM_API_KEY", "")   # 云端模式必填
PLUGIN_ID = os.environ.get("PRISM_PLUGIN_ID", "")
TIMEOUT = int(os.environ.get("PRISM_TIMEOUT", "120"))

# 强制禁用代理（本机系统代理会拦截 127.0.0.1，导致 502）
os.environ["NO_PROXY"] = "localhost,127.0.0.1,::1"
os.environ["no_proxy"] = "localhost,127.0.0.1,::1"

_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


# ------------------------------------------------------------
# Prism HTTP 客户端
# ------------------------------------------------------------
def _headers() -> dict:
    h = {"Content-Type": "application/json"}
    if PRISM_API_KEY:
        h["Authorization"] = f"Bearer {PRISM_API_KEY}"
        h["X-Api-Key"] = PRISM_API_KEY
    return h


def prism_request(path: str, method: str = "GET", body: Any = None) -> Any:
    """直接调用 Prism 的 HTTP API"""
    url = f"{PRISM_URL}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, headers=_headers(), method=method)
    with _opener.open(req, timeout=TIMEOUT) as resp:
        raw = resp.read().decode("utf-8", "replace")
    try:
        return json.loads(raw)
    except Exception:
        return {"raw": raw}


def chat_stream(messages: list, session_name: str = None, on_event=None) -> list:
    """
    发起一次 chat 调用，解析 SSE 流，返回完整事件列表。
    on_event 回调可在流式过程中实时消费事件（用于抓包订阅）。
    """
    if not session_name:
        session_name = f"mcp-{int(time.time() * 1000)}"

    body = {
        "model_name": PRISM_MODEL,
        "plugin_id": PLUGIN_ID,
        "mode": "",
        "session_name": session_name,
        "messages": messages,
    }
    req = urllib.request.Request(
        f"{PRISM_URL}/api/ai/chat",
        data=json.dumps(body).encode("utf-8"),
        headers=_headers(),
        method="POST",
    )

    events = []
    with _opener.open(req, timeout=TIMEOUT) as resp:
        buf = ""
        for chunk in iter(lambda: resp.read(512), b""):
            buf += chunk.decode("utf-8", "replace")
            while "\n\n" in buf:
                idx = buf.index("\n\n")
                block, buf = buf[:idx], buf[idx + 2:]
                ev, payload = None, None
                for line in block.split("\n"):
                    if line.startswith("event:"):
                        ev = line[6:].strip()
                    elif line.startswith("data:"):
                        try:
                            payload = json.loads(line[5:].strip())
                        except Exception:
                            payload = {"raw": line[5:].strip()}
                if ev:
                    item = {"event": ev, "data": payload}
                    events.append(item)
                    if on_event:
                        try:
                            on_event(item)
                        except Exception:
                            pass
    return events


def _parse_result(raw):
    """工具 result 字段常见是 JSON 字符串，尽量还原成对象"""
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except Exception:
            return raw
    return raw


def call_tool_via_ai(tool_name: str, tool_input: dict) -> dict:
    """
    ★ 核心：驱动 Prism 的 AI 调用指定工具，返回工具的真实执行结果。
    """
    sys_prompt = (
        "你是工具执行器。用户会指定一个工具名和参数，"
        "你必须立即发起该工具的 tool_calls，不要解释、不要闲聊、不要修改参数。"
        "只调用这一个工具，然后简短说明结果。"
    )
    user_prompt = (
        f"请立即调用工具 `{tool_name}`，参数如下（JSON）：\n"
        f"{json.dumps(tool_input, ensure_ascii=False, indent=2)}\n\n"
        f"只调用这一个工具。"
    )

    events = chat_stream([
        {"role": "system", "content": sys_prompt},
        {"role": "user", "content": user_prompt},
    ])

    tool_results, text_parts = [], []
    for e in events:
        d = e.get("data") or {}
        if e["event"] == "ai_tool_done":
            tool_results.append({
                "name": d.get("name"),
                "result": d.get("result", ""),
                "is_error": bool(d.get("is_error")),
                "evidence": d.get("evidence"),
            })
        elif e["event"] == "ai_chunk" and d.get("text"):
            text_parts.append(d["text"])
        elif e["event"] == "ai_error":
            return {"ok": False, "error": d.get("error", "AI 报错")}

    if not tool_results:
        return {
            "ok": False,
            "error": f"AI 未调用工具 {tool_name}（该工具可能依赖机器人连接）",
            "ai_text": "".join(text_parts)[:500],
        }

    tr = tool_results[-1]
    return {
        "ok": not tr["is_error"],
        "tool": tr["name"],
        "executed": tr.get("evidence") == "executed",
        "result": _parse_result(tr["result"]),
        "ai_comment": "".join(text_parts)[:800],
    }


# ------------------------------------------------------------
# 工具定义加载
# ------------------------------------------------------------
def load_tool_defs() -> list:
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.path.join(here, "..", "extracted", "tools.json"),
              os.path.join(here, "tools.json")):
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                return json.load(f)
    return []


TOOL_DEFS = load_tool_defs()
TOOLS_BY_NAME = {}
for t in TOOL_DEFS:
    fn = t.get("function", {})
    if fn.get("name"):
        TOOLS_BY_NAME[fn["name"]] = fn


# ------------------------------------------------------------
# 本地工具（直连 Prism HTTP，不走 AI）
# ------------------------------------------------------------
LOCAL_TOOLS = [
    {
        "name": "prism_status",
        "description": "查询 Prism 工具箱与机器人当前状态：是否连接服务器、所在维度、是否 OP。排查一切问题先调它。",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "prism_list_models",
        "description": "列出 Prism 已配置的 AI 模型（含 base_url 与是否内置）。",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "prism_list_skills",
        "description": "列出 Prism 可加载的技能知识库。",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "prism_list_plugins",
        "description": "列出 Prism 已安装的插件。",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "prism_chat",
        "description": "用自然语言与 Prism 的 AI 帮写对话，由它自行决定调用哪些工具。适合复杂任务，例如「写一个自动签到插件」。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "message": {"type": "string", "description": "发给 AI 的内容"},
                "session_name": {"type": "string", "description": "会话名，可选；同名会话会保持上下文"},
            },
            "required": ["message"],
        },
    },
    {
        "name": "prism_raw_tool",
        "description": "直接调用 Prism 的任意工具并拿回真实执行结果。工具名清单：" + ", ".join(sorted(TOOLS_BY_NAME.keys())),
        "inputSchema": {
            "type": "object",
            "properties": {
                "tool_name": {"type": "string", "description": "工具名，如 listen_packet / query_packets / send_packet"},
                "arguments": {"type": "object", "description": "工具参数（JSON 对象）"},
            },
            "required": ["tool_name"],
        },
    },
    # ---------------- 抓包专用 ----------------
    {
        "name": "prism_packet_history",
        "description": (
            "【历史抓包】回看已经收到的数据包。"
            "action=list 看包型清单与计数；action=query 按条件过滤包内容；action=stats 看统计。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["list", "query", "stats"], "description": "操作类型"},
                "packet_type": {"type": "string", "description": "包类型名，如 PlayerAuthInput / LevelChunk"},
                "limit": {"type": "integer", "description": "返回条数上限，默认 50"},
                "keyword": {"type": "string", "description": "在包内容里搜索的关键字"},
            },
            "required": ["action"],
        },
    },
    {
        "name": "prism_packet_subscribe",
        "description": (
            "【实时抓包】订阅一段时间内的实时数据包，持续监听指定秒数后汇总返回。"
            "等价于「边玩边抓包」——期间游戏里发生的包都会被收集。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "duration": {"type": "integer", "description": "监听秒数，默认 10，最大 60"},
                "packet_type": {"type": "string", "description": "只监听某类包（可选）"},
                "note": {"type": "string", "description": "对本次监听的备注（可选）"},
            },
            "required": [],
        },
    },
    {
        "name": "prism_packet_send",
        "description": "【发包】向服务器发送一个数据包。参数结构请先用 prism_raw_tool 调 list_packet_schema 查询。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "packet_type": {"type": "string", "description": "要发送的包类型"},
                "data": {"type": "object", "description": "包字段内容"},
            },
            "required": ["packet_type"],
        },
    },
]

LOCAL_NAMES = {t["name"] for t in LOCAL_TOOLS}


# ------------------------------------------------------------
# 本地工具实现
# ------------------------------------------------------------
def _packet_history(args: dict) -> dict:
    action = args.get("action", "list")
    ptype = args.get("packet_type", "")
    limit = int(args.get("limit", 50))

    if action == "list":
        r = call_tool_via_ai("list_packets", {})
        if isinstance(r.get("result"), list):
            return {"ok": True, "action": "list", "count": len(r["result"]), "packets": r["result"]}
        return r

    if action == "stats":
        r = call_tool_via_ai("packet_stats", {"type": ptype} if ptype else {})
        return {"ok": r.get("ok", False), "action": "stats", "stats": r.get("result")}

    # query
    qargs = {"limit": limit}
    if ptype:
        qargs["type"] = ptype
    if args.get("keyword"):
        qargs["keyword"] = args["keyword"]
    r = call_tool_via_ai("query_packets", qargs)
    return {"ok": r.get("ok", False), "action": "query", "packets": r.get("result"), "note": r.get("ai_comment")}


def _packet_subscribe(args: dict) -> dict:
    """
    实时订阅：用 wait_packet 工具做长轮询。
    每轮等一个包，收集到 duration 秒上限后返回全部。
    这样即使不依赖机器人事件推送，也能拿到实时流。
    """
    duration = min(int(args.get("duration", 10)), 60)
    ptype = args.get("packet_type", "")
    note = args.get("note", "")

    collected = []
    deadline = time.time() + duration
    round_no = 0
    while time.time() < deadline and round_no < 30:
        round_no += 1
        wargs = {"timeout": 3}
        if ptype:
            wargs["type"] = ptype
        r = call_tool_via_ai("wait_packet", wargs)
        res = r.get("result")
        if r.get("ok") and res and (not isinstance(res, str) or len(res) > 1):
            collected.append(res)
        if not r.get("ok") and not collected:
            # 机器人没连接时 wait_packet 会直接报错，提前退出
            if "未连接" in str(r.get("error", "")) or "未连接" in str(r.get("ai_comment", "")):
                return {
                    "ok": False,
                    "error": "机器人未连接服务器，无法抓包。请先在 Prism 里让机器人进服。",
                    "hint": "调用 prism_status 确认 connected 字段",
                }
            break

    return {
        "ok": True,
        "action": "subscribe",
        "duration": duration,
        "packet_type": ptype or "(全部)",
        "note": note,
        "rounds": round_no,
        "captured": len(collected),
        "packets": collected[:100],
    }


def _packet_send(args: dict) -> dict:
    ptype = args.get("packet_type")
    if not ptype:
        return {"ok": False, "error": "packet_type 必填"}
    r = call_tool_via_ai("send_packet", {
        "type": ptype,
        "data": args.get("data") or {},
    })
    return {"ok": r.get("ok", False), "sent": r.get("executed", False),
            "packet_type": ptype, "result": r.get("result"), "note": r.get("ai_comment")}


def handle_local_tool(name: str, args: dict) -> dict:
    try:
        if name == "prism_status":
            bot = prism_request("/api/bot/status")
            cfg = prism_request("/api/config")
            return {"ok": True, "bot": bot, "prism_url": PRISM_URL,
                    "auth_url": (cfg.get("config") or {}).get("auth_url"),
                    "mode": "cloud" if PRISM_API_KEY else "local"}

        if name == "prism_list_models":
            return {"ok": True, "models": prism_request("/api/ai/models").get("models", [])}

        if name == "prism_list_skills":
            return {"ok": True, "skills": prism_request("/api/ai/skills").get("skills", [])}

        if name == "prism_list_plugins":
            return {"ok": True, "plugins": prism_request("/api/plugin/list").get("plugins", [])}

        if name == "prism_chat":
            msg = args.get("message", "")
            if not msg:
                return {"ok": False, "error": "message 不能为空"}
            events = chat_stream([{"role": "user", "content": msg}],
                                 session_name=args.get("session_name"))
            text, tools_used, tool_outputs = [], [], []
            for e in events:
                d = e.get("data") or {}
                if e["event"] == "ai_chunk" and d.get("text"):
                    text.append(d["text"])
                elif e["event"] == "ai_tool_done":
                    tools_used.append(d.get("name"))
                    tool_outputs.append({
                        "name": d.get("name"),
                        "result": str(d.get("result", ""))[:3000],
                        "is_error": d.get("is_error"),
                    })
                elif e["event"] == "ai_error":
                    return {"ok": False, "error": d.get("error")}
            return {"ok": True, "reply": "".join(text),
                    "tools_used": tools_used, "tool_outputs": tool_outputs}

        if name == "prism_raw_tool":
            tn = args.get("tool_name")
            if not tn:
                return {"ok": False, "error": "tool_name 必填"}
            return call_tool_via_ai(tn, args.get("arguments") or {})

        if name == "prism_packet_history":
            return _packet_history(args)

        if name == "prism_packet_subscribe":
            return _packet_subscribe(args)

        if name == "prism_packet_send":
            return _packet_send(args)

    except urllib.error.URLError as e:
        return {"ok": False, "error": f"无法连接 Prism（{PRISM_URL}）：{e}. "
                                      f"本地模式请确认 Prism 已启动且端口 8080 未被代理拦截。"}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}

    return {"ok": False, "error": f"未知的本地工具：{name}"}


def dispatch(tool_name: str, args: dict) -> dict:
    """统一分发：本地工具直连，Prism 原生工具走 AI 驱动"""
    if tool_name in LOCAL_NAMES:
        return handle_local_tool(tool_name, args)
    return call_tool_via_ai(tool_name, args)


# ------------------------------------------------------------
# MCP JSON-RPC over stdio
# ------------------------------------------------------------
def send(obj: dict):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(msg: str):
    sys.stderr.write(f"[prism-mcp] {msg}\n")
    sys.stderr.flush()


def list_all_tools() -> list:
    out = [{"name": t["name"], "description": t["description"],
            "inputSchema": t["inputSchema"]} for t in LOCAL_TOOLS]
    for name, fn in sorted(TOOLS_BY_NAME.items()):
        out.append({
            "name": name,
            "description": fn.get("description", ""),
            "inputSchema": fn.get("parameters") or {"type": "object", "properties": {}},
        })
    return out


def main():
    log(f"启动 v2.0 | Prism={PRISM_URL} | 模式={'云端中转' if PRISM_API_KEY else '本地直连'} "
        f"| 本地工具 {len(LOCAL_TOOLS)} 个 | Prism 工具 {len(TOOLS_BY_NAME)} 个")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue

        method, rid = req.get("method"), req.get("id")

        if method == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "prism-mcp", "version": "2.0.0"},
            }})

        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": rid, "result": {"tools": list_all_tools()}})

        elif method == "tools/call":
            params = req.get("params") or {}
            tname = params.get("name")
            targs = params.get("arguments") or {}
            try:
                result = dispatch(tname, targs)
                send({"jsonrpc": "2.0", "id": rid, "result": {
                    "content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=2)}],
                    "isError": not result.get("ok", True),
                }})
            except Exception as e:
                send({"jsonrpc": "2.0", "id": rid, "result": {
                    "content": [{"type": "text", "text": f"执行失败：{e}"}],
                    "isError": True,
                }})

        elif method in ("notifications/initialized", "notifications/cancelled"):
            pass

        elif method == "ping":
            send({"jsonrpc": "2.0", "id": rid, "result": {}})

        else:
            if rid is not None:
                send({"jsonrpc": "2.0", "id": rid,
                      "error": {"code": -32601, "message": f"未支持的方法: {method}"}})


if __name__ == "__main__":
    main()
