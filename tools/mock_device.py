# -*- coding: utf-8 -*-
"""
模拟被控端（不依赖 Prism 本体）—— 用来验证「云端中继」整条链路。

真实被控端（云手机里的 Agent）要连本机 127.0.0.1:8080 的 Prism；
开发机上没有 Prism，所以这里伪造执行结果，专门验证：

  控制端/MCP → 网关写 pending 指令 → 被控端长轮询领走 → 回传 result → 网关返回

用法：
    python tools/mock_device.py            一直跑（Ctrl+C 退出）
    python tools/mock_device.py --once     只跑 60 秒
"""
import json
import ssl
import sys
import time
import urllib.request
import urllib.error

BASE = "https://ai-api.youyuanqi.dpdns.org/api/v1"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def http(path, method="GET", body=None, dev=None, timeout=40):
    url = BASE + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    h = {"Content-Type": "application/json", "User-Agent": UA}
    if dev:
        h["X-Device-Id"] = dev["id"]
        h["X-Device-Token"] = dev["token"]
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"HTTP {e.code}",
                "raw": e.read().decode("utf-8", "replace")[:200]}


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def fake_exec(cmd):
    """伪造执行结果 —— 不需要真 Prism"""
    kind = cmd.get("kind")
    cid = cmd.get("id")
    payload = cmd.get("payload") or {}
    events, result = [], None

    if kind == "chat":
        text = f"（模拟被控端）已收到：{str(payload.get('messages', [{}])[-1].get('content', ''))[:40]}"
        for ch in text:
            events.append({"type": "chunk", "payload": {"text": ch}})
        result = {"text": text, "tools": []}
    elif kind == "tool":
        tn = payload.get("tool_name")
        events = [
            {"type": "tool_start", "payload": {"name": tn}},
            {"type": "tool_done", "payload": {"name": tn, "result": '{"mock": true}'}},
        ]
        result = {"tool": tn, "executed": True, "result": {"mock": True, "tool": tn}}
    elif kind == "prism_rest":
        p = payload.get("path")
        result = {"mock": True, "path": p, "status": "ok",
                  "bot_connected": True, "server": "模拟服务器"}
    elif kind == "packet_send":
        result = {"sent": True, "packets": []}
    else:
        result = {"mock": True, "kind": kind}

    return {
        "command_id": cid,
        "events": events,
        "done": True,
        "result": result,
        "session_id": cmd.get("session_id"),
    }


def main():
    once = "--once" in sys.argv
    limit = time.time() + (60 if once else 3600 * 24)

    r = http("/device/register", "POST", {
        "name": "MOCK-模拟被控端",
        "platform": "mock",
        "memo": "开发自测用，可随时删除",
    })
    if not r.get("ok"):
        log(f"注册失败：{r}")
        return 1
    dev = {"id": r["data"]["device_id"], "token": r["data"]["token"]}
    log(f"注册成功 device_id={dev['id']}")

    http("/device/heartbeat", "POST", {"prism_online": True, "bot_connected": True}, dev)
    log("心跳已发 → 现在设备在线")

    last_hb = time.time()
    while time.time() < limit:
        # 心跳保活（20s 一次）
        if time.time() - last_hb > 20:
            http("/device/heartbeat", "POST",
                 {"prism_online": True, "bot_connected": True}, dev)
            last_hb = time.time()

        # ★ 注意：poll 返回的是 data.command（单个），不是 commands 数组
        p = http("/device/poll", "POST", {"wait": 25}, dev)
        c = (p.get("data") or {}).get("command")
        if not c:
            continue
        log(f"领到指令 {c.get('id')} [{c.get('kind')}]")
        rep = fake_exec(c)
        rr = http("/device/report", "POST", rep, dev)
        if not rr.get("ok"):
            log(f"  上报失败：{rr}")
        else:
            log(f"  已回传结果 ✓")

    log("退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
