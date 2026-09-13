#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mcp.py —— 从命令行直接经 MCP 操控 Prism（「我就是执行者」工具）

外部 AI Agent 拿到的那个 https 网址，和这个脚本走的是同一条路：
    POST https://ai-api.youyuanqi.dpdns.org/mcp?key=<平台密钥>
    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":..., "arguments":{...}}}

用法：
    # 列出所有 MCP 工具
    python tools/mcp.py tools

    # 看设备
    python tools/mcp.py call list_devices

    # 直接读 Prism 本机 REST（不经内置 AI）
    python tools/mcp.py rest /api/bot/status
    python tools/mcp.py rest /api/config
    python tools/mcp.py rest /api/ai/sessions

    # 直接写 Prism 本机 REST（POST）
    python tools/mcp.py rest /api/bot/console POST '{"input":"say 你好"}'
    python tools/mcp.py rest /api/bot/connect POST '{"token":"adb//...","server":"98014267","use_new_protocol":false,"auth":"","password":""}'

    # 调任意 MCP 工具
    python tools/mcp.py call prism_rest '{"path":"/api/plugin/list"}'
    python tools/mcp.py call prism_chat '{"prompt":"你好"}'

环境变量可覆盖：
    DS_KEY       平台访问密钥
    DS_GATEWAY   网关根地址（默认 https://ai-api.youyuanqi.dpdns.org）
    DS_DEVICE    默认设备 id
"""
import json
import os
import sys
import urllib.request

# Windows 控制台默认 GBK，print 中文会 UnicodeEncodeError
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

DEFAULT_KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
GATEWAY = os.environ.get("DS_GATEWAY", "https://ai-api.youyuanqi.dpdns.org").rstrip("/")
KEY = os.environ.get("DS_KEY", DEFAULT_KEY)
DEVICE = os.environ.get("DS_DEVICE", "")

# ★ Cloudflare WAF 会拦 urllib 默认 UA（403 error 1010）—— 这条踩过三次了
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")


def rpc(name, arguments, timeout=90):
    """发一次 JSON-RPC tools/call，返回 (ok, payload)。"""
    body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }).encode("utf-8")
    req = urllib.request.Request(
        GATEWAY + "/mcp?key=" + KEY, data=body, method="POST",
        headers={"Content-Type": "application/json", "User-Agent": UA,
                 "Accept": "application/json, text/event-stream"},
    )
    # 系统代理会劫持请求（Windows 代理），必须绕过
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
    except Exception as e:
        return False, {"_transport_error": "%s: %s" % (type(e).__name__, e)}

    # 兼容 SSE 包装（有些 MCP 客户端会收到 event: message\ndata: {...}）
    if raw.lstrip().startswith("event:") or "\ndata: " in raw:
        for line in raw.splitlines():
            if line.startswith("data: "):
                raw = line[6:]
                break
    try:
        d = json.loads(raw)
    except Exception:
        return False, {"_raw": raw[:2000]}

    if d.get("error"):
        return False, d["error"]
    res = d.get("result") or {}
    txt = ""
    for c in res.get("content") or []:
        if c.get("type") == "text":
            txt += c.get("text", "")
    try:
        return True, json.loads(txt)
    except Exception:
        return True, {"_text": txt}


def pretty(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0

    cmd = argv[0]

    if cmd == "tools":
        # MCP 标准的 tools/list
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode("utf-8")
        req = urllib.request.Request(
            GATEWAY + "/mcp?key=" + KEY, data=body, method="POST",
            headers={"Content-Type": "application/json", "User-Agent": UA})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=30) as r:
            raw = r.read().decode("utf-8", "replace")
        if "\ndata: " in raw:
            for line in raw.splitlines():
                if line.startswith("data: "):
                    raw = line[6:]
                    break
        d = json.loads(raw)
        tools = ((d.get("result") or {}).get("tools")) or []
        for t in tools:
            print("%-16s %s" % (t.get("name"), (t.get("description") or "").split("\n")[0][:88]))
        print("\n共 %d 个工具" % len(tools))
        return 0

    if cmd == "rest":
        # mcp.py rest <path> [METHOD] [body-json]
        if len(argv) < 2:
            print("用法: mcp.py rest <path> [METHOD] [body-json]"); return 2
        args = {"path": argv[1], "method": (argv[2] if len(argv) > 2 else "GET").upper()}
        if len(argv) > 3:
            args["body"] = json.loads(argv[3])
        if DEVICE:
            args["device_id"] = DEVICE
        ok, d = rpc("prism_rest", args)
        pretty(d)
        return 0 if ok else 1

    if cmd == "call":
        if len(argv) < 2:
            print("用法: mcp.py call <tool> [args-json]"); return 2
        args = json.loads(argv[2]) if len(argv) > 2 else {}
        if DEVICE and "device_id" not in args:
            args["device_id"] = DEVICE
        ok, d = rpc(argv[1], args)
        pretty(d)
        return 0 if ok else 1

    if cmd == "raw":
        # 透传原始 JSON-RPC
        if len(argv) < 2:
            print("用法: mcp.py raw '<json-rpc>'"); return 2
        req = urllib.request.Request(
            GATEWAY + "/mcp?key=" + KEY, data=argv[1].encode("utf-8"), method="POST",
            headers={"Content-Type": "application/json", "User-Agent": UA})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=90) as r:
            print(r.read().decode("utf-8", "replace"))
        return 0

    print("未知命令: %s（用 mcp.py help 看用法）" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
