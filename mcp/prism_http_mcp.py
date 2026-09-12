#!/usr/bin/env python3
"""
============================================================
Prism HTTP MCP Server (云端中转版)
供 Codex / Claude 在【手机】或【异地电脑】上使用。

与 prism_mcp.py 的区别：
  prism_mcp.py      直连 127.0.0.1:8080        —— 同机使用
  prism_http_mcp.py 走 Cloudflare Workers 网关 —— 跨网使用

环境变量：
  PRISM_GATEWAY   https://ai-api.youyuanqi.dpdns.org   (Workers 网关)
  PRISM_API_KEY   <PLATFORM_ACCESS_KEY>                (网关密钥)
============================================================
"""
import json
import os
import sys
import urllib.request
import urllib.error
import time

GATEWAY = os.environ.get("PRISM_GATEWAY", "https://ai-api.youyuanqi.dpdns.org").rstrip("/")
API_KEY = os.environ.get("PRISM_API_KEY", "")
TIMEOUT = int(os.environ.get("PRISM_TIMEOUT", "180"))

os.environ["NO_PROXY"] = "localhost,127.0.0.1,::1"

_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def gw(path: str, method: str = "GET", body=None):
    h = {"Content-Type": "application/json"}
    if API_KEY:
        h["Authorization"] = f"Bearer {API_KEY}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{GATEWAY}{path}", data=data, headers=h, method=method)
    with _opener.open(req, timeout=TIMEOUT) as r:
        raw = r.read().decode("utf-8", "replace")
    try:
        return json.loads(raw)
    except Exception:
        return {"raw": raw}


TOOLS = [
    # ---------------- 状态类 ----------------
    ("prism_status", "查询机器人/Prism 状态（是否连服、维度、是否 OP）。排查问题先调它。", {}),
    ("prism_list_models", "列出 Prism 已配置的 AI 模型。", {}),
    ("prism_list_skills", "列出 Prism 可加载的技能知识库。", {}),
    ("prism_list_plugins", "列出 Prism 已安装的插件。", {}),
    # ---------------- 抓包 ----------------
    ("prism_packet_history",
     "【历史抓包】回看已收到的数据包。action=list 包型清单 / query 按条件过滤 / stats 统计。",
     {"action": {"type": "string", "enum": ["list", "query", "stats"]},
      "packet_type": {"type": "string"}, "limit": {"type": "integer"}}),
    ("prism_packet_subscribe",
     "【实时抓包】订阅一段时间内的实时数据包，边玩边抓，监听结束汇总返回。",
     {"duration": {"type": "integer"}, "packet_type": {"type": "string"}}),
    ("prism_packet_send",
     "【发包】向服务器发送数据包。字段结构先用 prism_raw_tool 调 list_packet_schema 查。",
     {"packet_type": {"type": "string"}, "data": {"type": "object"}}),
    # ---------------- 通用 ----------------
    ("prism_raw_tool",
     "直接调用 Prism 任意原生工具并拿回真实结果。工具名如 list_packets / query_packets / "
     "wait_packet / send_packet / game_call / write_plugin_file / list_plugins / read_file / "
     "list_packet_schema / packet_stats / network_request 等 29 个。",
     {"tool_name": {"type": "string"}, "arguments": {"type": "object"}}),
    ("prism_chat",
     "用自然语言与 Prism 的 AI 帮写对话，由它自行决定调用哪些工具。适合复杂任务。",
     {"message": {"type": "string"}, "session_name": {"type": "string"}}),
]


def call(name: str, args: dict) -> dict:
    try:
        if name == "prism_status":
            return gw("/api/v1/mcp/tool", "POST", {"tool_name": "status"})
        if name == "prism_list_models":
            return gw("/api/v1/mcp/tool", "POST", {"tool_name": "models"})
        if name == "prism_list_skills":
            return gw("/api/v1/mcp/tool", "POST", {"tool_name": "skills"})
        if name == "prism_list_plugins":
            return gw("/api/v1/mcp/tool", "POST", {"tool_name": "plugins"})

        if name == "prism_packet_history":
            return gw("/api/v1/mcp/tool", "POST",
                      {"tool_name": "packet_history", "arguments": args})

        if name == "prism_packet_subscribe":
            return gw("/api/v1/mcp/packet/subscribe", "POST", args)

        if name == "prism_packet_send":
            return gw("/api/v1/mcp/tool", "POST",
                      {"tool_name": "packet_send", "arguments": args})

        if name == "prism_raw_tool":
            tn = args.get("tool_name")
            if not tn:
                return {"ok": False, "error": "tool_name 必填"}
            return gw("/api/v1/mcp/tool", "POST",
                      {"tool_name": tn, "arguments": args.get("arguments") or {}})

        if name == "prism_chat":
            return gw("/api/v1/ai-assist/chat", "POST",
                      {"messages": [{"role": "user", "content": args.get("message", "")}],
                       "session_name": args.get("session_name")})

    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"网关 HTTP {e.code}：{e.read().decode('utf-8', 'replace')[:300]}"}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}

    return {"ok": False, "error": f"未知工具 {name}"}


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(m):
    sys.stderr.write(f"[prism-http-mcp] {m}\n")
    sys.stderr.flush()


def main():
    log(f"启动 | 网关={GATEWAY} | 密钥={'已设置' if API_KEY else '未设置(可能 401)'}")
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
                "serverInfo": {"name": "prism-http-mcp", "version": "1.0.0"}}})

        elif method == "tools/list":
            tools = []
            for nm, desc, props in TOOLS:
                tools.append({"name": nm, "description": desc,
                              "inputSchema": {"type": "object", "properties": props,
                                              "required": list(props.keys())[:1] if props else []}})
            send({"jsonrpc": "2.0", "id": rid, "result": {"tools": tools}})

        elif method == "tools/call":
            p = req.get("params") or {}
            try:
                res = call(p.get("name"), p.get("arguments") or {})
                send({"jsonrpc": "2.0", "id": rid, "result": {
                    "content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False, indent=2)}],
                    "isError": not res.get("ok", True)}})
            except Exception as e:
                send({"jsonrpc": "2.0", "id": rid, "result": {
                    "content": [{"type": "text", "text": f"失败：{e}"}], "isError": True}})

        elif method in ("notifications/initialized", "notifications/cancelled"):
            pass
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif rid is not None:
            send({"jsonrpc": "2.0", "id": rid,
                  "error": {"code": -32601, "message": f"未支持: {method}"}})


if __name__ == "__main__":
    main()
