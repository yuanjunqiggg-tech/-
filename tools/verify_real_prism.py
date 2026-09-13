# -*- coding: utf-8 -*-
"""
★ 真 Prism 验收脚本 —— 一条命令证明整套东西真的能用。

前置条件（两步，都必须）：
  1. 双击启动 Prism 工具箱（本机 127.0.0.1:8080 会起服务）
  2. 跑这个脚本（它会自己拉起被控端 exe）

    python tools/verify_real_prism.py

它会依次验证：
  · 本机 Prism 是否真的在 8080 上
  · 被控端能否注册上线（穿透到 Cloudflare）
  · 通过 MCP 拿 Prism 的机器人状态 / 模型列表
  · 通过 MCP 让 Prism 的内置 AI 真正回一句话（走真模型）
  · 控制台那条 SSE 对话链路
  · 抓包订阅

退出码 0 = 全通过。
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

GATEWAY = "https://ai-api.youyuanqi.dpdns.org"
KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.1 Safari/537.36")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
LOCAL = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # 绕过本机代理

PASS = FAIL = 0
_procs = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}")
        if detail:
            print(f"        {str(detail)[:220]}")


def spawn(cmd, cwd=None, env=None):
    p = subprocess.Popen(cmd, cwd=cwd, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, encoding="utf-8", errors="replace")
    _procs.append(p)
    return p


def cleanup():
    for p in _procs:
        try:
            p.terminate(); p.wait(timeout=8)
        except Exception:
            try: p.kill()
            except Exception: pass


def local(path):
    try:
        with LOCAL.open("http://127.0.0.1:8080" + path, timeout=6) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:
        return {"_err": str(e)}


def api(path, method="GET", body=None, timeout=120):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    r = urllib.request.Request(GATEWAY + path, data=data, method=method,
                               headers={"Content-Type": "application/json",
                                        "Authorization": "Bearer " + KEY,
                                        "User-Agent": UA})
    try:
        with urllib.request.urlopen(r, timeout=timeout, context=CTX) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"HTTP {e.code}",
                "raw": e.read().decode("utf-8", "replace")[:200]}


def mcp(name, args=None, timeout=120):
    j = api("/mcp?key=" + KEY, "POST",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": name, "arguments": args or {}}}, timeout=timeout)
    res = j.get("result") or {}
    t = (res.get("content") or [{}])[0].get("text", "")
    try:
        return json.loads(t)
    except Exception:
        return {"_text": t, "_err": j.get("error")}


def main():
    print("=" * 64)
    print("  真 Prism 验收")
    print("=" * 64)

    # ---------- 1. 本机 Prism ----------
    print("\n[1] 本机 Prism（127.0.0.1:8080）")
    cfg = local("/api/config")
    if "_err" in cfg:
        print("\n  ✗ Prism 没在跑：", cfg["_err"])
        print("\n  请先双击桌面上的 prism工具箱.exe，等它界面出来后再跑本脚本。")
        return 2
    check("Prism 本地 API 可达", True)
    models = local("/api/ai/models")
    print(f"        可用模型：{str(models)[:120]}")

    # ---------- 2. 起被控端 ----------
    exe = os.path.join(ROOT, "agent", "dist", "prism-agent.exe")
    cmd = [exe] if os.path.exists(exe) else [PY, os.path.join(ROOT, "agent", "prism_agent.py")]
    print(f"\n[2] 启动被控端：{os.path.basename(cmd[0])}")
    env = dict(os.environ)
    env["PRISM_GATEWAY"] = GATEWAY
    env["PRISM_URL"] = "http://127.0.0.1:8080"
    proc = spawn(cmd + ["--name", "验收机"],
                 cwd=os.path.join(ROOT, "agent", "dist"), env=env)

    try:
        time.sleep(8)
        online, d = False, {}
        for _ in range(24):
            try:
                d = api("/api/v1/health")["data"]
                if (d.get("devices_online") or 0) > 0:
                    online = True
                    break
            except Exception:
                pass
            time.sleep(3)
        check("被控端上线（穿透到 Cloudflare）", online, d)
        if not online:
            try: print((proc.stdout.read() or "")[:1500])
            except Exception: pass
            return 1

        # ---------- 3. MCP 驱动真 Prism ----------
        print("\n[3] MCP 驱动真实 Prism")
        r = mcp("prism_rest", {"path": "/api/bot/status"})
        check("拿到机器人状态", r.get("ok") is True, r)
        print(f"        {str(r.get('result'))[:140]}")

        r = mcp("prism_rest", {"path": "/api/ai/models"})
        check("拿到 Prism 的模型列表", r.get("ok") is True, r)
        print(f"        {str(r.get('result'))[:140]}")

        # ---------- 4. 真·AI 对话 ----------
        print("\n[4] 让 Prism 内置 AI 真回一句话（走官方上游，可能较慢）")
        r = mcp("prism_chat", {"prompt": "回复四个字：验收通过"}, timeout=180)
        ok_chat = r.get("ok") is True and bool((r.get("result") or {}).get("text"))
        check("Prism AI 返回了文本", ok_chat, r)
        txt = str((r.get("result") or {}).get("text", ""))[:150]
        print(f"        AI：{txt}")
        if not ok_chat:
            print("        （若提示未登录/无积分，属 Prism 账号侧问题，非本系统问题）")

        # ---------- 5. 控制台 SSE 链路 ----------
        print("\n[5] 控制台 SSE 对话链路")
        body = {"plugin_id": "ds_ai_agent",
                "session_name": "verify-" + str(int(time.time())),
                "messages": [{"role": "user", "content": "回复四个字：验收通过"}]}
        req = urllib.request.Request(
            GATEWAY + "/api/v1/ai-assist/chat", data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer " + KEY, "User-Agent": UA}, method="POST")
        buf, text, evs, done = "", "", [], False
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=180, context=CTX) as resp:
                while time.time() - t0 < 180:
                    c = resp.read1(4096) if hasattr(resp, "read1") else resp.read(512)
                    if not c:
                        c = resp.read(1)
                        if not c: break
                    buf += c.decode("utf-8", "replace")
                    while "\n\n" in buf:
                        blk, buf = buf.split("\n\n", 1)
                        ev, dat = "", ""
                        for ln in blk.split("\n"):
                            if ln.startswith("event:"): ev = ln[6:].strip()
                            elif ln.startswith("data:"): dat = ln[5:].strip()
                        if not ev: continue
                        evs.append(ev)
                        try: dd = json.loads(dat)
                        except Exception: dd = {}
                        if ev == "ai_chunk": text += dd.get("text", "")
                        elif ev == "ai_done": done = True
                    if done: break
        except Exception as e:
            print("        SSE 异常：", e)
        check("SSE 收到流式文本", len(text.strip()) > 0, sorted(set(evs)))
        check("SSE 正常收尾(ai_done)", done, sorted(set(evs)))
        print(f"        {time.time()-t0:.1f}s  事件={sorted(set(evs))}")
        print(f"        AI：{text[:120]}")

        # ---------- 6. 抓包 ----------
        print("\n[6] 抓包订阅（需要机器人已进服，否则为空属正常）")
        r = api("/api/v1/mcp/packet/subscribe", "POST",
                {"duration": 8}, timeout=180)
        check("抓包订阅不报错", r.get("ok") is True, r)
        print(f"        captured = {(r.get('data') or {}).get('captured')}")

    finally:
        cleanup()

    print()
    print("=" * 64)
    print(f"  结果： {PASS} 通过 / {FAIL} 失败")
    print("=" * 64)
    return 1 if FAIL else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        cleanup()
