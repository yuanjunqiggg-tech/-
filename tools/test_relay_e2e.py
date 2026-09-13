# -*- coding: utf-8 -*-
"""
端到端验证「云端中继」：
  起一个模拟被控端进程 → 通过 MCP 端点下发 prism_rest / prism_tool / prism_chat
  → 断言真的拿到了被控端回传的结果。

这是 P14 架构改造的验收测试：证明网关不再依赖用户电脑也能驱动 Prism。

用法：python tools/test_relay_e2e.py
"""
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

BASE = "https://ai-api.youyuanqi.dpdns.org"
KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

PASS = FAIL = 0


def http(path, method="GET", body=None, timeout=90):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    h = {"Content-Type": "application/json", "User-Agent": UA,
         "Authorization": "Bearer " + KEY}
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def mcp(name, args=None, timeout=90):
    st, txt = http("/mcp?key=" + KEY, "POST", {
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": name, "arguments": args or {}},
    }, timeout=timeout)
    try:
        j = json.loads(txt)
    except Exception:
        return {"_status": st, "_raw": txt[:300]}
    res = j.get("result") or {}
    txt_out = (res.get("content") or [{}])[0].get("text", "")
    try:
        out = json.loads(txt_out)
    except Exception:
        out = {"_text": txt_out}
    out["_status"] = st
    out["_isError"] = res.get("isError")
    return out


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}   {detail}")


def wait_online(secs=90):
    """等模拟被控端心跳上来"""
    for _ in range(secs // 5):
        st, txt = http("/api/v1/health")
        try:
            d = json.loads(txt)["data"]
        except Exception:
            d = {}
        if (d.get("devices_online") or 0) > 0:
            return True, d
        time.sleep(5)
    return False, {}


def main():
    print("=" * 62)
    print("端到端：云端中继（MCP → 网关 → 被控端 → 回传）")
    print("=" * 62)

    print("\n启动模拟被控端…")
    proc = subprocess.Popen([PY, os.path.join(HERE, "mock_device.py")],
                            cwd=os.path.dirname(HERE),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace")
    try:
        time.sleep(6)
        okd, d = wait_online(90)
        check("模拟被控端已上线", okd, f"health={d}")
        if not okd:
            print(proc.stdout.read()[:2000] if proc.stdout else "")
            return 1

        print()
        print("-- MCP tools/call: prism_rest --")
        r = mcp("prism_rest", {"path": "/api/bot/status"})
        check("prism_rest 返回 200", r.get("_status") == 200, str(r)[:200])
        check("拿到被控端回传的真实结果",
              r.get("ok") is True and (r.get("result") or {}).get("mock") is True,
              str(r)[:300])
        check("结果里带着设备 id", bool(r.get("device_id")), str(r)[:200])
        print(f"        device_id = {r.get('device_id')}")

        print()
        print("-- MCP tools/call: prism_tool --")
        r = mcp("prism_tool", {"tool_name": "list_packets", "arguments": {}})
        check("prism_tool 执行成功", r.get("ok") is True, str(r)[:250])
        check("工具名回传一致", r.get("tool") == "list_packets", str(r)[:250])
        check("executed = True", r.get("executed") is True, str(r)[:250])

        print()
        print("-- MCP tools/call: prism_chat --")
        r = mcp("prism_chat", {"prompt": "你好，报一下状态"})
        check("prism_chat 执行成功", r.get("ok") is True, str(r)[:250])
        check("拿回了文本结果",
              bool((r.get("result") or {}).get("text")), str(r)[:300])

        print()
        print("-- MCP tools/call: prism_chat 带 session_name（应落盘会话）--")
        r = mcp("prism_chat", {"prompt": "记一下：现在是自测",
                               "session_name": "e2e-自测会话"})
        check("带 session_name 的 prism_chat 执行成功",
              r.get("ok") is True, str(r)[:250])
        check("结果里回带了 session_name",
              (r.get("result") or {}).get("session_name") == "e2e-自测会话",
              str(r)[:300])

        print()
        print("-- MCP tools/call: prism_status（引擎自检）--")
        r = mcp("prism_status", {})
        check("prism_status 执行成功", r.get("ok") is True, str(r)[:250])
        check("prism_status 带回端口与探活结果",
              (r.get("result") or {}).get("port") == 8080
              and ((r.get("result") or {}).get("native") or {}).get("alive") is True,
              str(r)[:300])

        print()
        print("-- MCP tools/call: prism_session（AI帮写 会话增删改查）--")
        r = mcp("prism_session", {"action": "save",
                                  "session_name": "e2e-手写会话",
                                  "messages": [{"role": "user",
                                                "content": "你好"}]})
        check("session save 成功",
              (r.get("result") or {}).get("ok") is True
              or r.get("ok") is True, str(r)[:250])

        r = mcp("prism_session", {"action": "list"})
        names = (r.get("result") or {}).get("sessions")
        check("session list 能列出刚存的会话",
              isinstance(names, list) and "e2e-手写会话" in names, str(r)[:300])

        r = mcp("prism_session", {"action": "load",
                                  "session_name": "e2e-手写会话"})
        msgs = (r.get("result") or {}).get("messages")
        check("session load 能读回消息",
              isinstance(msgs, list) and len(msgs) == 1, str(r)[:300])

        r = mcp("prism_session", {"action": "delete",
                                  "session_name": "e2e-手写会话"})
        check("session delete 成功",
              (r.get("result") or {}).get("ok") is True, str(r)[:250])

        r = mcp("prism_session", {"action": "list"})
        check("删除后 list 里没有了",
              "e2e-手写会话" not in ((r.get("result") or {}).get("sessions") or []),
              str(r)[:300])

        print()
        print("-- 控制台同源的 /api/v1/mcp/tool --")
        st, txt = http("/api/v1/mcp/tool", "POST",
                       {"tool_name": "status"}, timeout=90)
        j = json.loads(txt)
        check("旧 MCP 路由仍可用（走中继）",
              st == 200 and j.get("ok") is True, txt[:250])

        print()
        print("-- 设备列表能看到模拟设备 --")
        r = mcp("list_devices", {})
        try:
            ds = json.loads(
                json.loads(
                    json.dumps(r)
                ).get("_text", "{}")
            ).get("devices", [])
        except Exception:
            ds = []
        check("list_devices 能列出在线设备",
              any(x.get("online") for x in ds) if ds else "devices" in str(r),
              str(r)[:300])

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()

    print()
    print("=" * 62)
    print(f"结果： {PASS} 通过 / {FAIL} 失败")
    print("=" * 62)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
