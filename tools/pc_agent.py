#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
============================================================
 PC Agent —— 让手机遥控这台电脑上跑的 AI CLI
============================================================

装在你自己电脑上（Windows / macOS / Linux 都行），常驻后台跑着。
之后在手机控制台里开一个会话，这台电脑就会：

  1. 领活（长轮询云端，不需要公网 IP、不用开端口、不用内网穿透）
  2. 启动对应的 CLI（codex / claude / 自定义）跑你发的那句话
  3. 把输出一段段回传云端，手机上实时看到

用法：
    python tools/pc_agent.py                      # 用默认密钥
    python tools/pc_agent.py --cli codex          # 默认用 codex
    python tools/pc_agent.py --cwd D:/myproject   # 默认工作目录
    python tools/pc_agent.py --once               # 只跑一轮就退出（调试用）

支持的 CLI（自动探测，按优先级）：
    codex      codex exec "<msg>"                 （Codex CLI）
    claude     claude -p "<msg>"                  （Claude Code）
    shell      直接把消息当成命令执行（兜底，慎用）

想加自己的 CLI：改下面的 CLI_PROFILES 就行。
"""

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

DEFAULT_KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"
DEFAULT_GATEWAY = "https://ai-api.youyuanqi.dpdns.org"

# 每种 CLI 怎么把一句话喂进去。{msg} 会被替换成用户的话。
CLI_PROFILES = {
    "codex": {
        "exe": "codex",
        # exec 是非交互模式，输出干净，适合管道捕获
        "argv": ["codex", "exec", "{msg}"],
        "check": ["codex", "--version"],
    },
    "claude": {
        "exe": "claude",
        # -p = print 模式（非交互），同样适合管道
        "argv": ["claude", "-p", "{msg}"],
        "check": ["claude", "--version"],
    },
    "gemini": {
        "exe": "gemini",
        "argv": ["gemini", "-p", "{msg}"],
        "check": ["gemini", "--version"],
    },
    "shell": {
        "exe": "",
        "argv": None,  # 特殊：把消息当命令跑
        "check": None,
    },
}


def http_json(url, method="GET", body=None, key=None, timeout=30):
    data = None
    headers = {"User-Agent": "Mozilla/5.0 (pc-agent)"}
    if key:
        headers["Authorization"] = "Bearer " + key
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as r:
        raw = r.read().decode("utf-8", errors="replace")
    try:
        return json.loads(raw)
    except Exception:
        return {"raw": raw}


def write_file(path, content_base64, cwd):
    """把手机传过来的文件落盘。相对路径算在会话工作目录下。"""
    import base64

    p = os.path.expanduser(path)
    if not os.path.isabs(p):
        p = os.path.join(cwd or os.getcwd(), p)
    p = os.path.abspath(p)
    # 别让 ../ 跑到工作目录外面去
    root = os.path.abspath(cwd or os.getcwd())
    if os.path.commonpath([p, root]) != root:
        raise ValueError(f"不允许写到工作目录之外：{path}")

    os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
    with open(p, "wb") as f:
        f.write(base64.b64decode(content_base64))
    return f"{p}  ({os.path.getsize(p)} 字节)"


def detect_clis():
    """探测这台电脑上装了哪些 AI CLI"""
    found = {}
    for name, p in CLI_PROFILES.items():
        if name == "shell":
            found[name] = True
            continue
        found[name] = shutil.which(p["exe"]) is not None
    return found


def pick_cli(want, available):
    if want and want != "auto":
        if available.get(want):
            return want
        print(f"  ⚠ 指定的 CLI 不可用：{want}，改用自动选择")
    for name in ("codex", "claude", "gemini"):
        if available.get(name):
            return name
    return "shell"


def run_cli(cli, message, cwd, on_chunk, timeout=600):
    """跑一次 CLI，把输出按块回调出去。返回 (returncode, ok)"""
    prof = CLI_PROFILES.get(cli) or CLI_PROFILES["shell"]
    if prof["argv"] is None:
        cmd = message
        shell = True
    else:
        cmd = [a.replace("{msg}", message) for a in prof["argv"]]
        shell = False

    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    # 别让 CLI 认为自己在交互式终端里（否则会画 TUI，管道拿不到干净输出）
    env["NO_COLOR"] = "1"
    env.pop("TERM", None)

    try:
        proc = subprocess.Popen(
            cmd, cwd=cwd or None, shell=shell, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True, encoding="utf-8", errors="replace",
            bufsize=1,
        )
    except Exception as e:
        on_chunk(f"[启动失败] {e}")
        return -1, False

    try:
        for line in proc.stdout:
            if line:
                on_chunk(line.rstrip("\r\n"))
        proc.wait(timeout=timeout)
        return proc.returncode, proc.returncode == 0
    except subprocess.TimeoutExpired:
        proc.kill()
        on_chunk(f"\n[超时 {timeout}s，已终止]")
        return -1, False
    except Exception as e:
        try:
            proc.kill()
        except Exception:
            pass
        on_chunk(f"\n[异常] {e}")
        return -1, False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway", default=DEFAULT_GATEWAY)
    ap.add_argument("--key", default=os.environ.get("DS_KEY", DEFAULT_KEY))
    ap.add_argument("--cli", default="auto", help="codex / claude / gemini / shell / auto")
    ap.add_argument("--cwd", default=os.getcwd(), help="默认工作目录")
    ap.add_argument("--pc", default=platform.node() or "my-pc", help="这台电脑的名字")
    ap.add_argument("--interval", type=float, default=3.0, help="轮询间隔秒")
    ap.add_argument("--once", action="store_true", help="只处理一轮就退出")
    args = ap.parse_args()

    base = args.gateway.rstrip("/") + "/api/v1"
    sess = f"{base}/pc/sessions"
    poll_url = base + "/pc/poll"
    claim_url = base + "/pc/claim"
    out_url = base + "/pc/output"

    # 注册成 pc 类 agent，也拿一个编号（游戏里也能点名它）
    try:
        r = http_json(
            base + "/agent/registry", "POST",
            {"kind": "pc", "name": "pc:" + args.pc, "label": f"电脑 {args.pc}"},
            key=args.key,
        )
        no = (r.get("data") or {}).get("no")
        if no:
            print(f"  已登记为 {no} 号 AI Agent（电脑 {args.pc}）")
    except Exception as e:
        print("  登记失败（不影响使用）：", e)

    available = detect_clis()
    print("=" * 56)
    print(" PC Agent 已启动")
    print(f"  电脑名   ：{args.pc}")
    print(f"  工作目录 ：{args.cwd}")
    print(f"  网关     ：{args.gateway}")
    print("  探测到的 CLI：" + ", ".join(k for k, v in available.items() if v))
    print("  现在去手机控制台开一个会话，这边会立刻领活。Ctrl+C 退出。")
    print("=" * 56)

    seen_input = {}  # session_id -> 已处理到的最大 msg id

    while True:
        try:
            res = http_json(poll_url, "POST", {"pc": args.pc}, key=args.key, timeout=40)
            data = res.get("data") or {}
            for s in data.get("sessions") or []:
                sid = s["id"]
                cli = pick_cli(s.get("cli") or args.cli, available)
                cwd = s.get("cwd") or args.cwd
                http_json(claim_url, "POST", {"id": sid}, key=args.key)
                print(f"\n▶ 领到会话 {sid[:12]}…  {s.get('name')}  [{cli}]  cwd={cwd}")

                inputs = s.get("pending_inputs") or []
                if not inputs:
                    continue
                last_id = max(int(i["id"]) for i in inputs)

                # ★ 先把要落盘的文件写掉（role='file'），再处理要说的话
                saved = []
                for i in inputs:
                    if i.get("role") != "file":
                        continue
                    try:
                        payload = json.loads(i["text"])
                        saved.append(write_file(payload["path"], payload["content_base64"], cwd))
                    except Exception as e:
                        saved.append(f"[写入失败] {e}")
                if saved:
                    http_json(out_url, "POST", {
                        "session_id": sid, "role": "system",
                        "text": "已收到文件：\n" + "\n".join("  " + x for x in saved),
                    }, key=args.key)

                # 只跑最新一条（前面几条如果没处理就合并进去，避免丢话）
                texts = [i["text"] for i in inputs if i.get("role") == "user"]
                if not texts:
                    # 只传了文件、没说话 —— 记一笔就结束这一轮
                    http_json(out_url, "POST", {
                        "session_id": sid, "role": "system", "text": "",
                        "done": True, "status": "done",
                    }, key=args.key)
                    seen_input[sid] = last_id
                    print(f"◀ 会话 {sid[:12]}… 只收文件，已落盘")
                    continue
                message = texts[-1]
                if len(texts) > 1:
                    message = "\n".join(texts)

                http_json(out_url, "POST", {
                    "session_id": sid, "role": "system",
                    "text": f"$ {cli} @ {cwd}\n> {message}",
                }, key=args.key)

                buf = []

                def flush(chunk, _sid=sid):
                    buf.append(chunk)
                    if len(buf) >= 8:
                        try:
                            http_json(out_url, "POST", {
                                "session_id": _sid, "role": "output",
                                "text": "\n".join(buf),
                            }, key=args.key)
                        except Exception:
                            pass
                        buf.clear()

                rc, ok = run_cli(cli, message, cwd, flush)
                if buf:
                    try:
                        http_json(out_url, "POST", {
                            "session_id": sid, "role": "output", "text": "\n".join(buf),
                        }, key=args.key)
                    except Exception:
                        pass
                http_json(out_url, "POST", {
                    "session_id": sid, "role": "system", "text": "",
                    "done": True, "status": "done" if ok else "error",
                }, key=args.key)
                seen_input[sid] = last_id
                print(f"◀ 会话 {sid[:12]}… 完成（rc={rc}）")

        except KeyboardInterrupt:
            print("\n已退出。")
            return
        except Exception as e:
            print("  轮询出错：", e, flush=True)

        if args.once:
            return
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
