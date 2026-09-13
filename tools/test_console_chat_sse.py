# -*- coding: utf-8 -*-
"""
验证**控制台真正在用的**那条链路：

    POST /api/v1/ai-assist/chat  →  streamCommandSSE  →  SSE 事件流

和 MCP 那条路的区别：
  · MCP 的 prism_chat 走 runOnDevice，等指令跑完一次性拿结果（非流式）
  · 控制台走 streamCommandSSE，边轮询 D1 边往外吐 SSE，才能有打字机效果

这条路径之前**一次都没测过**。这里用真 exe + 假 Prism 把它跑通。

用法：python tools/test_console_chat_sse.py
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

BASE = "https://ai-api.youyuanqi.dpdns.org/api/v1"
KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

PASS = FAIL = 0
_procs = []


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


def get_json(path):
    r = urllib.request.Request("https://ai-api.youyuanqi.dpdns.org" + path,
                               headers={"Authorization": "Bearer " + KEY, "User-Agent": UA})
    with urllib.request.urlopen(r, timeout=30, context=CTX) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def wait_online(secs=90):
    for _ in range(secs // 5):
        try:
            d = get_json("/api/v1/health")["data"]
            if (d.get("devices_online") or 0) > 0:
                return True, d
        except Exception:
            pass
        time.sleep(5)
    return False, {}


def main():
    exe = os.path.join(ROOT, "agent", "dist", "prism-agent.exe")
    cmd = [exe] if os.path.exists(exe) else [PY, os.path.join(ROOT, "agent", "prism_agent.py")]

    print("=" * 62)
    print("控制台对话链路：/api/v1/ai-assist/chat → SSE")
    print("=" * 62)

    spawn([PY, os.path.join(HERE, "fake_prism.py")], cwd=ROOT)
    time.sleep(2)

    env = dict(os.environ)
    env["PRISM_GATEWAY"] = "https://ai-api.youyuanqi.dpdns.org"
    env["PRISM_URL"] = "http://127.0.0.1:8080"
    proc = spawn(cmd + ["--name", "SSE-测试机"], cwd=os.path.join(ROOT, "agent", "dist"), env=env)

    try:
        time.sleep(8)
        okd, d = wait_online(90)
        check("被控端已上线", okd, str(d)[:150])
        if not okd:
            print((proc.stdout.read() or "")[:1500])
            return 1

        # 完全照控制台 send() 的请求体来
        body = {
            "plugin_id": "ds_ai_agent",
            "session_name": "sse-test-" + str(int(time.time())),
            "messages": [{"role": "user", "content": "用一句话介绍一下你自己"}],
        }
        req = urllib.request.Request(
            BASE + "/ai-assist/chat",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer " + KEY, "User-Agent": UA},
            method="POST",
        )

        print("\n  发起 SSE 请求（最多等 90s）…")
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=90, context=CTX) as resp:
            ctype = resp.headers.get("Content-Type", "")
            check("响应是 text/event-stream", "text/event-stream" in ctype, ctype)

            buf = ""
            text = ""
            events = []
            done = False
            meta = None
            while time.time() - t0 < 90:
                chunk = resp.read1(4096) if hasattr(resp, "read1") else resp.read(512)
                if not chunk:
                    chunk = resp.read(1)
                    if not chunk:
                        break
                buf += chunk.decode("utf-8", "replace")
                while "\n\n" in buf:
                    block, buf = buf.split("\n\n", 1)
                    ev, data = "", ""
                    for line in block.split("\n"):
                        if line.startswith("event:"):
                            ev = line[6:].strip()
                        elif line.startswith("data:"):
                            data = line[5:].strip()
                    if not ev:
                        continue
                    events.append(ev)
                    try:
                        dd = json.loads(data)
                    except Exception:
                        dd = {"raw": data}
                    if ev == "ai_chunk":
                        text += dd.get("text", "")
                    elif ev == "ai_meta":
                        meta = dd
                    elif ev == "ai_done":
                        done = True
                    elif ev == "ai_error":
                        print("        ai_error:", dd.get("error"))
                if done:
                    break

        print(f"        耗时 {time.time()-t0:.1f}s，事件序列：{sorted(set(events))}")

        check("拿到了 ai_meta（含 command_id / 设备名）",
              bool(meta and meta.get("command_id")), str(meta)[:150])
        check("收到了流式 ai_chunk", "ai_chunk" in events, str(sorted(set(events))))
        check("流式文本非空", len(text.strip()) > 0, repr(text[:100]))
        check("流以 ai_done 正常收尾", done, str(sorted(set(events))))
        check("文本来自假 Prism", "假 Prism" in text, repr(text[:120]))
        print(f"        AI 回文 = {text[:80]}")

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
