#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
pull_prism.py —— 把云手机里 Prism 的东西整份拉到本地

「外部 AI 当执行者」的落地工具：不走 Prism 内置 AI，直接读它的文件/配置/会话。

用法：
    python tools/pull_prism.py            # 拉全套（插件源码 + 配置 + 会话列表）
    python tools/pull_prism.py plugin     # 只拉插件源码
    python tools/pull_prism.py config     # 只拉插件配置
    python tools/pull_prism.py sessions   # 只拉 AI帮写 会话
    python tools/pull_prism.py endpoint /api/bot/status   # 拉任意端点

产物落在 prism_dump/ 目录。
"""
import json
import os
import sys
import urllib.parse
import urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

DEFAULT_KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
GATEWAY = os.environ.get("DS_GATEWAY", "https://ai-api.youyuanqi.dpdns.org").rstrip("/")
KEY = os.environ.get("DS_KEY", DEFAULT_KEY)
DEVICE = os.environ.get("DS_DEVICE", "dev_elribseuror12ih7i3zb")
PLUGIN_ID = os.environ.get("DS_PLUGIN", "ds_ai_agent")

# Cloudflare WAF 拦 urllib 默认 UA
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "prism_dump")


def rpc(name, arguments, timeout=180):
    body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }).encode("utf-8")
    req = urllib.request.Request(
        GATEWAY + "/mcp?key=" + KEY, data=body, method="POST",
        headers={"Content-Type": "application/json", "User-Agent": UA})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as r:
        raw = r.read().decode("utf-8", "replace")
    if "\ndata: " in raw:
        for line in raw.splitlines():
            if line.startswith("data: "):
                raw = line[6:]
                break
    d = json.loads(raw)
    res = d.get("result") or {}
    txt = "".join(c.get("text", "") for c in (res.get("content") or [])
                  if c.get("type") == "text")
    try:
        return json.loads(txt)
    except Exception:
        return {"_text": txt}


def rest(path, method="GET", body=None, timeout=70):
    """调一次 Prism 本机端点。任何异常都吞掉返回 None —— 一个端点卡住不该拖死整批。"""
    a = {"path": path, "method": method, "device_id": DEVICE}
    if body is not None:
        a["body"] = body
    try:
        d = rpc("prism_rest", a, timeout=timeout)
    except Exception as e:
        print("  !! %s -> %s: %s" % (path, type(e).__name__, e))
        return None
    if not d.get("ok"):
        print("  !! %s -> %s" % (path, d.get("error")))
    return d.get("result")


def save(rel, content):
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    mode = "wb" if isinstance(content, bytes) else "w"
    with open(p, mode, **({} if isinstance(content, bytes) else {"encoding": "utf-8"})) as f:
        f.write(content)
    print("  -> %s (%d 字节)" % (os.path.relpath(p, os.path.dirname(HERE)), len(content)))
    return p


def do_plugin():
    print("[插件源码]")
    r = rest("/api/plugin/file/read?" + urllib.parse.urlencode(
        {"id": PLUGIN_ID, "scope": "code"}))
    if not r or not r.get("content"):
        print("  读失败：%s" % r)
        return
    save("plugin/%s.lua" % PLUGIN_ID, r["content"])
    # 顺带存一份 docs
    r2 = rest("/api/plugin/file/read?" + urllib.parse.urlencode(
        {"id": PLUGIN_ID, "scope": "docs"}))
    if r2 and r2.get("content"):
        save("plugin/%s.docs.md" % PLUGIN_ID, r2["content"])


def do_config():
    print("[插件配置 / Prism 配置]")
    for name, path in [
        ("prism_config.json", "/api/config"),
        ("plugin_config.json", "/api/plugin/config?id=" + PLUGIN_ID),
        ("plugin_meta.json", "/api/plugin/meta?id=" + PLUGIN_ID),
        ("plugin_data_files.json", "/api/plugin/data?id=" + PLUGIN_ID),
        ("plugin_list.json", "/api/plugin/list"),
        ("ai_models.json", "/api/ai/models"),
        ("ai_skills.json", "/api/ai/skills"),
    ]:
        r = rest(path)
        if r is None:
            print("  %-24s 无返回" % name)
            continue
        save("config/" + name, json.dumps(r, ensure_ascii=False, indent=2))


def do_sessions():
    print("[AI帮写 会话]")
    lst = rest("/api/ai/sessions")
    if lst:
        save("sessions/_list.json", json.dumps(lst, ensure_ascii=False, indent=2))
    sessions = (lst or {}).get("sessions") or []
    print("  共 %d 个会话，逐个拉取正文…" % len(sessions))
    for s in sessions:
        nm = s.get("name") or ""
        r = rest("/api/ai/sessions/load?" + urllib.parse.urlencode({"name": nm}))
        if r:
            safe = nm.replace("/", "_").replace("\\", "_").replace(":", "_")
            save("sessions/%s.json" % safe, json.dumps(r, ensure_ascii=False, indent=2))


def main(argv):
    what = argv[0] if argv else "all"
    if what == "endpoint":
        if len(argv) < 2:
            print("用法: pull_prism.py endpoint /api/bot/status [METHOD] [body-json]")
            return 2
        m = argv[2] if len(argv) > 2 else "GET"
        b = json.loads(argv[3]) if len(argv) > 3 else None
        print(json.dumps(rest(argv[1], m, b), ensure_ascii=False, indent=2))
        return 0

    if what in ("all", "plugin"):
        do_plugin()
    if what in ("all", "config"):
        do_config()
    if what in ("all", "sessions"):
        do_sessions()
    print("\n产物目录: %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
