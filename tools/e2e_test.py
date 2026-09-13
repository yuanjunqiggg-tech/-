#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
多设备中继 · 端到端自测

用法：
    # 本地（wrangler dev）
    python tools/e2e_test.py --base http://127.0.0.1:8799/api/v1 --key test-key-12345

    # 线上
    python tools/e2e_test.py --base https://ai-api.youyuanqi.dpdns.org/api/v1 --key <PLATFORM_ACCESS_KEY>

说明：
    - 所有请求强制绕过系统代理（本机 7897 代理会劫持 127.0.0.1）
    - 响应统一是 { ok, data } 信封，本脚本自动解包到 r["data"]
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request

# 强制绕过代理
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# ★ 必须带正常 User-Agent：Cloudflare 会对 urllib/3.x 这类 UA 返回
#   "error code: 1010"（浏览器完整性检查拦截），看起来像 403 权限问题，
#   实际只是 UA 被 WAF 拒了。
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " \
     "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

PASS = 0
FAIL = 0
RESULTS = []

# ★ 自测注册的设备必须带这个前缀，且**绝不能**跟用户真机重名。
#   旧版这里注册的名字叫「云手机1号」，和用户真机一模一样 ——
#   测试只删了第二台、没删第一台，于是每跑一次就多一个幽灵设备，
#   控制台里和真机混在一起，根本分不出哪个是真的。
TEST_DEV_PREFIX = "e2e自测-"


def chk(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        RESULTS.append((True, name, ""))
        print(f"  [PASS] {name}")
    else:
        FAIL += 1
        RESULTS.append((False, name, str(extra)[:200]))
        print(f"  [FAIL] {name}  {str(extra)[:200]}")


def make_caller(base):
    def call(method, path, body=None, headers=None, timeout=40):
        h = {
            "Content-Type": "application/json",
            "User-Agent": UA,
            "Accept": "application/json",
        }
        if headers:
            h.update({k: v for k, v in headers.items() if v is not None})
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data=data, headers=h, method=method)
        try:
            r = OPENER.open(req, timeout=timeout)
            txt = r.read().decode("utf-8", "replace")
            status = r.status
        except urllib.error.HTTPError as e:
            txt = e.read().decode("utf-8", "replace")
            status = e.code
        except Exception as e:
            return 0, {"_err": str(e)}
        try:
            return status, json.loads(txt)
        except Exception:
            return status, {"_raw": txt}

    return call


def unwrap(resp):
    """解 {ok, data} 信封；不是信封就原样返回"""
    if isinstance(resp, dict) and "data" in resp and "ok" in resp:
        d = resp.get("data")
        return d if isinstance(d, dict) else {}
    return resp if isinstance(resp, dict) else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8799/api/v1")
    ap.add_argument("--key", default="test-key-12345")
    ap.add_argument("--keep", action="store_true", help="测试后不删除设备")
    a = ap.parse_args()

    call = make_caller(a.base.rstrip("/"))
    AUTH = {"Authorization": f"Bearer {a.key}"}
    t0 = time.time()

    print("=" * 60)
    print("  多设备中继 · 端到端自测")
    print(f"  目标: {a.base}")
    print("=" * 60)

    # ---- 1. 健康检查（免鉴权）----
    s, r = call("GET", "/health")
    d = unwrap(r)
    chk("01 /health 免鉴权可访问", s == 200, f"status={s} {r}")
    chk("02 /health 返回网关状态", d.get("gateway") == "online", d)
    print(f"        prism_online={d.get('prism_online')}  tunnel={d.get('prism_tunnel_url')}")
    if d.get("prism_error"):
        print(f"        prism_error={d.get('prism_error')}")

    # ---- 1.5 清扫上次残留的自测设备（中途崩过就会留下）----
    # ★ 必须带 ?all=1：默认列表会过滤掉停用设备，而残留的正是被软删（status=0）的，
    #   不带 all 就一个都扫不到，清扫等于没写。
    # 用硬删除：这些是一次性的自测设备，没必要在库里留停用记录。
    swept = 0
    s, r = call("GET", "/devices?all=1", headers=AUTH)
    if s == 200:
        for dv in (unwrap(r).get("devices") or []):
            if str(dv.get("name", "")).startswith(TEST_DEV_PREFIX):
                if call("DELETE", f"/devices/{dv.get('id')}?hard=1", headers=AUTH)[0] == 200:
                    swept += 1
    if swept:
        print(f"        （清扫了 {swept} 个上次残留的自测设备）")

    # ---- 2. 注册被控端 ----
    s, r = call("POST", "/device/register", {
        "name": TEST_DEV_PREFIX + "A", "platform": "android",
        "prism_url": "http://127.0.0.1:8080",
        "meta": {"model": "Redfinger", "android": "9"},
    })
    d = unwrap(r)
    chk("03 设备注册成功", s == 200 and d.get("device_id"), f"status={s} {r}")
    did = d.get("device_id")
    dtok = d.get("token") or d.get("device_token")
    chk("04 返回设备令牌", bool(dtok), d)
    if not (did and dtok):
        print("\n[中止] 注册未返回 device_id/token，后续测试无法继续")
        return 1
    print(f"        device_id={did}")

    # ---- 3. 鉴权负向测试 ----
    s, _ = call("POST", "/device/heartbeat", {"status": "idle"},
                {"X-Device-Id": did, "X-Device-Token": "wrong-token"})
    chk("05 错误设备令牌被拒(401)", s == 401, f"status={s}")

    s, _ = call("GET", "/devices")
    chk("06 无管理密钥被拒(401)", s == 401, f"status={s}")

    s, _ = call("GET", "/devices", headers={"Authorization": "Bearer wrong-key"})
    chk("07 错误管理密钥被拒(401)", s == 401, f"status={s}")

    s, _ = call("POST", "/device/heartbeat", {"status": "idle"},
                {"X-Device-Id": "dev_notexist12345678", "X-Device-Token": dtok})
    chk("08 伪造设备ID被拒", s in (401, 404), f"status={s}")

    # ---- 4. 心跳 ----
    s, r = call("POST", "/device/heartbeat",
                {"status": "idle", "prism_online": True, "battery": 87},
                {"X-Device-Id": did, "X-Device-Token": dtok})
    chk("09 心跳上报成功", s == 200, f"status={s} {r}")

    # ---- 5. 设备列表 ----
    s, r = call("GET", "/devices", headers=AUTH)
    d = unwrap(r)
    devs = d.get("devices", []) if isinstance(d, dict) else []
    chk("10 设备列表可拉取", s == 200 and len(devs) >= 1, f"status={s} {r}")
    mine = next((x for x in devs if x.get("id") == did), None)
    chk("11 目标设备在列表中", mine is not None, [x.get("id") for x in devs])
    chk("12 设备被标记为在线", bool(mine and mine.get("online")), mine)

    # ---- 6. 下发指令 → 长轮询取件 ----
    s, r = call("POST", f"/devices/{did}/command",
                {"kind": "chat", "payload": {"prompt": "你好，自测一下"}}, AUTH)
    d = unwrap(r)
    cid = d.get("command_id") or d.get("id")
    chk("13 下发指令成功", s == 200 and cid, f"status={s} {r}")
    if not cid:
        print("\n[中止] 未取得 command_id")
        return 1

    s, r = call("POST", "/device/poll", {"wait": 5},
                {"X-Device-Id": did, "X-Device-Token": dtok})
    d = unwrap(r)
    cmd = d.get("command")
    chk("14 长轮询取到指令", s == 200 and cmd, f"status={s} {r}")
    chk("15 取到的是同一条指令", bool(cmd and cmd.get("id") == cid),
        f"expect={cid} got={cmd.get('id') if cmd else None}")
    chk("16 指令内容未损坏",
        bool(cmd and (cmd.get("payload") or {}).get("prompt") == "你好，自测一下"),
        cmd)

    # ---- 7. 原子性：重复取件不应再拿到同一条 ----
    s, r = call("POST", "/device/poll", {"wait": 2},
                {"X-Device-Id": did, "X-Device-Token": dtok})
    d = unwrap(r)
    again = d.get("command")
    chk("17 指令不会被重复拾取", again is None or again.get("id") != cid, again)

    # ---- 8. 事件回传 ----
    #   注意：按契约，指令收尾必须显式传 done=True。
    #   事件流里的 {type:'done'} 只是「AI 这一轮回复结束」，不触发指令收尾。
    s, r = call("POST", "/device/report", {
        "command_id": cid, "status": "ok",
        "events": [
            {"type": "thinking", "data": {"text": "正在思考"}},
            {"type": "chunk", "data": {"text": "你好！"}},
            {"type": "tool_start", "data": {"name": "list_plugins"}},
            {"type": "tool_done", "data": {"name": "list_plugins", "ok": True}},
            {"type": "ai_round_done", "data": {}},
        ],
        "packets": [
            {"direction": "in", "packet_type": "s2c_login", "size": 128, "summary": "登录包"},
            {"direction": "out", "packet_type": "c2s_ready", "size": 64, "summary": "就绪包"},
        ],
    }, {"X-Device-Id": did, "X-Device-Token": dtok})
    chk("18 事件批量回传成功", s == 200, f"status={s} {r}")

    # 中间批次不应终结指令（回归保护）
    s, r = call("GET", f"/devices/{did}/command/{cid}", headers=AUTH)
    mid_state = unwrap(r).get("command", {}).get("status")
    chk("18b 事件批次不误终结指令", mid_state in ("pending", "taken"), f"state={mid_state}")

    # ---- 9. 控制端拉事件流 ----
    s, r = call("GET", f"/devices/{did}/stream?since=0", headers=AUTH)
    d = unwrap(r)
    evs = d.get("events", []) if isinstance(d, dict) else []
    chk("19 事件流可拉取", s == 200 and len(evs) >= 5, f"status={s} n={len(evs)}")
    if len(evs) > 1:
        seqs = [e.get("seq") for e in evs]
        chk("20 事件 seq 单调递增", all(seqs[i] < seqs[i + 1] for i in range(len(seqs) - 1)), seqs)
    chk("21 事件类型保留", any(e.get("type") == "ai_round_done" for e in evs),
        [e.get("type") for e in evs])

    # 增量拉取
    s, r = call("GET", f"/devices/{did}/stream?since={evs[1].get('seq') if len(evs) > 1 else 0}",
                headers=AUTH)
    d2 = unwrap(r)
    evs2 = d2.get("events", []) if isinstance(d2, dict) else []
    chk("22 游标增量拉取生效", 0 < len(evs2) < len(evs), f"full={len(evs)} incr={len(evs2)}")

    # ---- 10. 显式收尾（带 result）----
    s, r = call("POST", "/device/report", {
        "command_id": cid, "done": True,
        "result": {"ok": True, "tool": "list_plugins", "result": "暂无已安装插件"},
    }, {"X-Device-Id": did, "X-Device-Token": dtok})
    chk("22b 显式 done 收尾成功", s == 200 and unwrap(r).get("finished") is True,
        f"status={s} {r}")

    # ---- 11. 指令状态 ----
    s, r = call("GET", f"/devices/{did}/command/{cid}", headers=AUTH)
    d = unwrap(r)
    cmd_obj = d.get("command") or {}
    st = cmd_obj.get("status")
    chk("23 指令状态已终结", s == 200 and st in ("done", "ok", "completed"), f"status={s} state={st}")
    chk("23b 结果已完整落库", isinstance(cmd_obj.get("result"), dict)
        and cmd_obj["result"].get("tool") == "list_plugins",
        f"result={cmd_obj.get('result')}")

    # ---- 11. 抓包 ----
    s, r = call("GET", f"/devices/{did}/packets", headers=AUTH)
    d = unwrap(r)
    pks = d.get("packets", []) if isinstance(d, dict) else []
    chk("24 抓包数据已持久化", s == 200 and len(pks) >= 2, f"status={s} n={len(pks)}")

    s, r = call("GET", f"/devices/{did}/packets?type=s2c_login", headers=AUTH)
    d = unwrap(r)
    pks2 = d.get("packets", []) if isinstance(d, dict) else []
    chk("25 按类型过滤抓包生效", len(pks2) >= 1 and all(
        p.get("packet_type") == "s2c_login" for p in pks2), f"n={len(pks2)}")

    # ---- 12. 总览（全局，不带设备 ID）----
    s, r = call("GET", "/devices/overview", headers=AUTH)
    d = unwrap(r)
    chk("26 全局总览可拉取", s == 200 and isinstance(d.get("devices"), dict),
        f"status={s} {r}")

    # ---- 13. 多设备 ----
    s, r = call("POST", "/device/register", {"name": TEST_DEV_PREFIX + "B", "platform": "android"})
    d2 = unwrap(r)
    d2id = d2.get("device_id")
    chk("27 第二台设备可注册", s == 200 and d2id, f"status={s} {r}")
    s, r = call("GET", "/devices", headers=AUTH)
    d = unwrap(r)
    chk("28 列表含多台设备", len(d.get("devices", [])) >= 2, len(d.get("devices", [])))

    # ---- 14. 离线设备拒发指令 ----
    s, r = call("POST", f"/devices/{d2id}/command",
                {"kind": "chat", "payload": {"prompt": "x"}}, AUTH)
    chk("29 离线设备拒发指令(409)", s == 409, f"status={s} {r}")

    # ---- 15. 清理 ----
    # ★ 这里故意走**默认**（软）删除，因为那才是用户点「删除」走的路径；
    #   然后断言设备真的从列表里消失了 —— 这才是「删除」对用户该有的语义。
    #   （旧版只删了第二台，第一台永远留着；而且软删除后列表不过滤停用设备，
    #     所以「删成功」了却还在列表里，攒出一堆幽灵设备。）
    if not a.keep:
        s1, _ = call("DELETE", f"/devices/{d2id}", headers=AUTH)
        s2, _ = call("DELETE", f"/devices/{did}", headers=AUTH)
        chk("30 自测设备删除成功", s1 == 200 and s2 == 200, f"A={s1} B={s2}")
        s, r = call("GET", "/devices", headers=AUTH)
        left = [x.get("name") for x in (unwrap(r).get("devices") or [])
                if str(x.get("name", "")).startswith(TEST_DEV_PREFIX)]
        chk("31 删除后不再出现在列表里", not left, f"残留={left}")
        # 断言完「软删除后列表要隐藏」这个用户可见的契约，再把行真正清掉，
        # 免得库里攒一堆 status=0 的自测残留。
        for _id in (d2id, did):
            call("DELETE", f"/devices/{_id}?hard=1", headers=AUTH)

    print("=" * 60)
    print(f"  结果: 通过 {PASS} / {PASS + FAIL}    耗时 {time.time() - t0:.1f}s")
    if FAIL:
        print("  失败项:")
        for okk, nm, ex in RESULTS:
            if not okk:
                print(f"    - {nm}  {ex}")
    print("=" * 60)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
