# -*- coding: utf-8 -*-
"""
真·端到端：用**打包出来的 prism-agent.exe** 当被控端。

链路：
    MCP 客户端 → Cloudflare 网关 → 长轮询 → prism-agent.exe（真程序）
              → 127.0.0.1:8080 假 Prism → SSE 回传 → 网关 → MCP 客户端

和 test_relay_e2e.py 的区别：那个用 mock_device.py 假造结果，
这个跑的是真正要交付给用户的二进制文件。

用法：python tools/test_real_exe_e2e.py [--exe path]
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
ROOT = os.path.dirname(HERE)
PY = sys.executable

BASE = "https://ai-api.youyuanqi.dpdns.org"
KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

PASS = FAIL = 0
_procs = []


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
        res = (json.loads(txt).get("result") or {})
    except Exception:
        return {"_status": st, "_raw": txt[:300]}
    t = (res.get("content") or [{}])[0].get("text", "")
    try:
        out = json.loads(t)
    except Exception:
        out = {"_text": t}
    out["_status"] = st
    return out


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}   {detail}")


def spawn(cmd, cwd=None, env=None):
    p = subprocess.Popen(cmd, cwd=cwd, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, encoding="utf-8", errors="replace")
    _procs.append(p)
    return p


def cleanup():
    for p in _procs:
        try:
            p.terminate()
            p.wait(timeout=8)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass


def main():
    exe = os.path.join(ROOT, "agent", "dist", "prism-agent.exe")
    if "--py" in sys.argv or not os.path.exists(exe):
        cmd = [PY, os.path.join(ROOT, "agent", "prism_agent.py")]
        label = "prism_agent.py"
    else:
        cmd = [exe]
        label = "prism-agent.exe"

    print("=" * 62)
    print(f"真·端到端：被控端 = {label}")
    print("=" * 62)

    print("\n[1/4] 启动假 Prism (127.0.0.1:8080)")
    spawn([PY, os.path.join(HERE, "fake_prism.py")], cwd=ROOT)
    time.sleep(2)

    # 让子进程也绕过系统代理去连 127.0.0.1
    env = dict(os.environ)
    env["PRISM_GATEWAY"] = "https://ai-api.youyuanqi.dpdns.org"
    env["PRISM_URL"] = "http://127.0.0.1:8080"

    print(f"[2/4] 启动被控端 {label}")
    proc = spawn(cmd + ["--name", "E2E-真实被控端"], cwd=os.path.join(ROOT, "agent", "dist"), env=env)
    time.sleep(8)

    try:
        print("[3/4] 等被控端上报在线…")
        online, d = False, {}
        for _ in range(20):
            st, txt = http("/api/v1/health")
            try:
                d = json.loads(txt)["data"]
            except Exception:
                d = {}
            if (d.get("devices_online") or 0) > 0:
                online = True
                break
            time.sleep(3)
        check("被控端已上线", online, f"health={str(d)[:200]}")
        if not online:
            try:
                out = proc.stdout.read() if proc.stdout else ""
            except Exception:
                out = ""
            print("---- 被控端输出 ----")
            print((out or "")[:2000])
            return 1

        # 被控端自己探到的 Prism 状态应该是在线（因为假 Prism 在跑）
        print("\n[4/4] 通过 MCP 驱动真实被控端")
        r = mcp("prism_rest", {"path": "/api/bot/status"})
        check("prism_rest 拿到假 Prism 的真实响应",
              r.get("ok") is True and (r.get("result") or {}).get("connected") is True,
              str(r)[:300])
        print(f"        bot status = {str(r.get('result'))[:120]}")

        r = mcp("prism_tool", {"tool_name": "list_packets", "arguments": {}})
        check("prism_tool 走通 Prism /api/ai/chat 并拿到工具结果",
              r.get("ok") is True and r.get("executed") is True, str(r)[:300])
        check("工具结果里有假 Prism 造的数据包",
              "packets" in str(r), str(r)[:300])

        r = mcp("prism_chat", {"prompt": "报一下你的状态"})
        check("prism_chat 拿到流式文本",
              r.get("ok") is True and bool((r.get("result") or {}).get("text")),
              str(r)[:300])
        txt_out = str((r.get("result") or {}).get("text", ""))[:80]
        print(f"        chat 回文 = {txt_out}")

        # ---- 抓包的两条路（控制台「抓包」页用的就是这两个）----
        dev_id = r.get("device_id")
        st, txt = http(f"/api/v1/devices/{dev_id}/packets?seconds=3600&limit=200")
        j = json.loads(txt)
        check("抓包历史接口可用", st == 200 and j.get("ok") is True, txt[:200])

        st, txt = http("/api/v1/mcp/packet/subscribe", "POST",
                       {"duration": 5, "device_id": dev_id}, timeout=120)
        j = json.loads(txt)
        check("实时抓包订阅不报错", st == 200 and j.get("ok") is True, txt[:250])
        print(f"        subscribe = {str(j.get('data'))[:120]}")

    finally:
        cleanup()

    print()
    print("=" * 62)
    print(f"结果： {PASS} 通过 / {FAIL} 失败")
    print("=" * 62)
    return 1 if FAIL else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        cleanup()
