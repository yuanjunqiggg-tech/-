#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
============================================================
 真实被控端集成测试
============================================================

和 tools/e2e_test.py 的区别：

  e2e_test.py        用 requests 库自己拼 HTTP，验证的是「网关 API 契约」对不对
  本脚本             直接拉起 agent/prism_agent.py 这个真实被控端进程，
                     验证的是「被控端代码本身」能不能跑通完整协议

后者更接近真实部署：云手机里跑的就是这套逻辑（APK 里是同协议的 JS 版）。

覆盖的环节：
  ① 注册   —— 走被控端自己的 register 流程，拿到 device_id + token
  ② 心跳   —— 被控端自动上报，云端标记为在线
  ③ 领指令 —— 云端下发，被控端长轮询领走（验证原子领取、不重复）
  ④ 执行   —— 被控端真的去调本机 Prism
  ⑤ 上报   —— 事件回传云端，指令正确终结
  ⑥ 流式   —— 控制端能增量拉到事件

用法：
  python tools/integration_test_agent.py
  python tools/integration_test_agent.py --gateway https://xxx/api/v1 --key xxx

说明：
  Prism 没启动时，第 ④ 步会失败，但这仍然是一次有效测试 ——
  它会验证「被控端能否优雅处理 Prism 不可达」并把错误如实上报，
  而不是卡死或丢指令。真实部署里 Prism 掉线是常态。
============================================================
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
AGENT = os.path.join(ROOT, "agent", "prism_agent.py")

DEFAULT_GATEWAY = "https://ai-api.youyuanqi.dpdns.org/api/v1"
DEFAULT_KEY = "5dc5ad3751b01175e3e02a6f01ccc8cf0c32142d89345c62fd10af993ff71791"

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


# ------------------------------------------------------------
# HTTP（绕过系统代理，否则 127.0.0.1 会被劫持）
# ------------------------------------------------------------
def call(method, path, body=None, headers=None, timeout=30):
    url = BASE.rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json", "User-Agent": UA}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    # ProxyHandler({}) = 彻底直连，不要系统代理
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
    except Exception as e:
        return None, {"ok": False, "error": f"{type(e).__name__}: {e}"}
    try:
        return json.loads(raw), None
    except Exception:
        return None, {"ok": False, "error": raw[:200]}


def unwrap(r):
    return (r or {}).get("data") or {}


def auth():
    return {"X-Admin-Key": KEY, "Authorization": "Bearer " + KEY}


# ------------------------------------------------------------
PASS, FAIL = [], []


def check(cond, name, detail=""):
    if cond:
        PASS.append(name)
        print(f"  [PASS] {name}" + (f"\n        {detail}" if detail else ""))
    else:
        FAIL.append(name)
        print(f"  [FAIL] {name}" + (f"\n        {detail}" if detail else ""))
    return cond


def main():
    global BASE, KEY
    ap = argparse.ArgumentParser()
    ap.add_argument("--gateway", default=DEFAULT_GATEWAY)
    ap.add_argument("--key", default=DEFAULT_KEY)
    ap.add_argument("--prism", default="http://127.0.0.1:8080",
                    help="本机 Prism 地址")
    args = ap.parse_args()

    BASE = args.gateway.rstrip("/")
    KEY = args.key

    print("=" * 62)
    print("  真实被控端集成测试")
    print("=" * 62)
    print(f"  网关    : {BASE}")
    print(f"  被控端  : {AGENT}")
    print(f"  本机Prism: {args.prism}")
    print("=" * 62)

    # ---- 健康检查 ----
    r, err = call("GET", "/health", timeout=15)
    if not check(r is not None and r.get("ok"), "00 网关可达",
                 json.dumps(unwrap(r), ensure_ascii=False)[:160] if r else str(err)):
        print("\n[中止] 网关不通，后续测试无意义")
        return 1

    prism_online = unwrap(r).get("prism_online")
    print(f"        （本机 Prism 状态：{'在线' if prism_online else '未运行'}）")

    # ---- 准备独立的状态文件，避免污染真实设备 ----
    state_file = tempfile.mktemp(prefix="prism_it_", suffix=".json")
    env = dict(os.environ)
    env["AGENT_STATE"] = state_file
    env["PRISM_GATEWAY"] = BASE.replace("/api/v1", "")
    env["PRISM_URL"] = args.prism
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUNBUFFERED"] = "1"

    name = f"集成测试-{int(time.time()) % 100000}"

    # ---- ① 注册 ----
    print("\n--- ① 注册（走被控端自己的流程）---")
    p = subprocess.run(
        [sys.executable, AGENT, "--register-only", "--name", name],
        env=env, capture_output=True, text=True, timeout=90,
        cwd=ROOT, encoding="utf-8", errors="replace",
    )
    if p.returncode != 0:
        print(p.stdout[-1500:])
        print(p.stderr[-1500:] if p.stderr else "")
    check(p.returncode == 0, "01 被控端注册进程正常退出")

    if not os.path.exists(state_file):
        print("\n[中止] 没生成状态文件，注册失败")
        print(p.stdout[-1200:])
        return 1

    st = json.load(open(state_file, encoding="utf-8"))
    did = st.get("device_id")
    check(bool(did), "02 拿到 device_id", f"device_id={did}")
    check(bool(st.get("token")), "03 拿到设备令牌",
          f"token={str(st.get('token'))[:16]}…")
    if not did:
        return 1

    # ---- 启动被控端主循环 ----
    print("\n--- ② 启动被控端主循环 ---")
    proc = subprocess.Popen(
        [sys.executable, AGENT], env=env, cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace",
    )
    print(f"        进程 PID={proc.pid}")

    agent_log = []

    def drain():
        """非阻塞地把子进程输出收集起来（用于失败时排查）"""
        try:
            import threading
            def rd():
                for line in proc.stdout:
                    agent_log.append(line.rstrip())
                    if len(agent_log) > 400:
                        agent_log.pop(0)
            threading.Thread(target=rd, daemon=True).start()
        except Exception:
            pass

    drain()

    try:
        # ---- 等它上线 ----
        print("\n--- ③ 等待心跳上报 ---")
        online = False
        for _ in range(30):
            time.sleep(2)
            r, _ = call("GET", "/devices", headers=auth(), timeout=20)
            for d in unwrap(r).get("devices") or []:
                # ★ 注意：列表里主键字段是 id，不是 device_id。
                #   写成 device_id 会永远匹配不上，误判成「不在线」。
                if d.get("id") == did and d.get("online"):
                    online = True
                    break
            if online:
                break
        check(online, "04 被控端心跳上报，云端标记在线")

        # ---- ④ 下发指令 ----
        print("\n--- ④ 云端下发 chat 指令 ---")
        r, _ = call("POST", f"/devices/{did}/command",
                    {"kind": "chat",
                     "payload": {"prompt": "用一句话介绍你自己"}},
                    headers=auth(), timeout=30)
        cid = unwrap(r).get("command_id")
        if not cid:
            cid = (unwrap(r).get("command") or {}).get("id")
        check(bool(cid), "05 指令下发成功", f"command_id={cid}")

        if not cid:
            print("\n[中止] 拿不到 command_id")
            return 1

        # ---- ⑤ 等被控端领走 ----
        print("\n--- ⑤ 等待被控端领取并执行 ---")
        status = None
        for _ in range(45):
            time.sleep(2)
            r, _ = call("GET", f"/devices/{did}/command/{cid}",
                        headers=auth(), timeout=20)
            status = (unwrap(r).get("command") or {}).get("status")
            if status in ("done", "error", "failed"):
                break

        check(status in ("done", "error", "failed"),
              "06 指令已终结", f"最终 status={status}")

        # ---- ⑥ 校验事件 ----
        print("\n--- ⑥ 校验事件流 ---")
        # ★ 事件走 /stream?since=N，不是 /command/{id}/events
        r, _ = call("GET", f"/devices/{did}/stream?since=0",
                    headers=auth(), timeout=20)
        ev = unwrap(r).get("events") or []
        check(isinstance(ev, list), "07 事件流接口可用",
              f"共 {len(ev) if isinstance(ev, list) else 0} 条事件")

        if ev:
            types = sorted({(e.get("type") or "?") for e in ev})
            print(f"        事件类型：{', '.join(types)}")
            seqs = [e.get("seq") for e in ev if e.get("seq") is not None]
            check(seqs == sorted(seqs), "08 事件 seq 单调递增")

        # ---- 指令必须带回「结果」或「错误」，二者必有其一 ----
        # 不能只判接口可用就算过 —— 那样空事件也能蒙混过关。
        r2, _ = call("GET", f"/devices/{did}/command/{cid}",
                     headers=auth(), timeout=20)
        cobj = unwrap(r2).get("command") or {}
        err = cobj.get("error")
        res = cobj.get("result")
        check(bool(err) or bool(res), "09 指令带回了结果或错误",
              ("error=" + str(err)[:160]) if err
              else ("result=" + str(res)[:160]))

        # Prism 没开时，正确行为是「优雅失败」：
        # 指令要终结、错误信息要清楚，而不是卡住或丢指令。
        if not prism_online:
            check(bool(err) and ("Prism" in str(err) or "连接" in str(err)),
                  "10 Prism 不可达时优雅失败并给出可读错误",
                  f"error={str(err)[:160]}")
        else:
            check(bool(res) and not err,
                  "10 Prism 在线时返回真实结果",
                  f"result={str(res)[:160]}")

        # ---- ⑦ 掉线检测 ----
        print("\n--- ⑦ 停止被控端，验证会变离线 ---")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=12)
        except subprocess.TimeoutExpired:
            proc.kill()
        print("        被控端已停止")

    # 清理
    try:
        call("DELETE", f"/devices/{did}", headers=auth(), timeout=20)
        print(f"        已删除测试设备 {did}")
    except Exception:
        pass
    try:
        os.remove(state_file)
    except Exception:
        pass

    # ---- 汇总 ----
    print()
    print("=" * 62)
    print(f"  结果: 通过 {len(PASS)} / {len(PASS) + len(FAIL)}")
    print("=" * 62)
    if FAIL:
        print("  失败项：")
        for f in FAIL:
            print(f"    - {f}")
        print()
        print("  ---- 被控端日志尾部 ----")
        for line in agent_log[-25:]:
            print("   ", line)
        print()
    return 0 if not FAIL else 1


if __name__ == "__main__":
    sys.exit(main())
