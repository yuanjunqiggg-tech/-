#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_capability_doc.py —— 生成「外部 AI 直连能力手册」

数据来源（都是实测/逆向得来，不是猜的）：
  1. docs/prism-endpoints.json        —— 从 libprism.so 抽出的 193 个本机端点
  2. prism_dump/frontend_api_calls.json —— 从 Prism 前端 JS 抽出的 107 个调用（含方法+参数体）
  3. prism_dump/plugin/ds_ai_agent.lua  —— 插件「AI帮写」的 15 个工具标记

产出：
  docs/外部AI直连能力手册.md
  docs/prism-capabilities.json
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DOCS = os.path.join(ROOT, "docs")
DUMP = os.path.join(ROOT, "prism_dump")


def load_json(p, default):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


# ---------- 1. 端点总表 ----------
raw_eps = load_json(os.path.join(DOCS, "prism-endpoints.json"), {})

# Go 的字符串池会把相邻字符串字面量拼在一起（例如
# "/api/market-proxy/api/market/files" 其实是两条）。所有来源都要先拆。
BOUNDARY = re.compile(r"(?=/api/)")

# 手写黑名单：Go 字符串池把「路径 + 紧邻的普通字符串」粘在一起，
# 且中间没有 /api/ 边界，靠规则拆不开。数量极少，直接列出来。
JUNK = {
    "/api/camera/clear0123456789abcdefg",   # = /api/camera/clear + "0123456789abcdefg"
    "/api/node/byehistory_bytesdisabled",   # = /api/node/bye + "history_bytes" + "disabled"
}


def clean_path(p):
    """剔除 Go 字符串池粘连出来的假路径。

    粘连长这样：/api/config + ConditionalTrackOutput + region_mode + ...
    → 一整串全是字母数字，没有分隔，靠大小写和长度就能识别。
    合法 REST 段应该全是小写/数字/下划线/连字符，且不会太长。
    """
    segs = p.split("/")[1:]          # 去掉开头的空串
    if p in JUNK:
        return None
    for s in segs:
        if not s:
            return None
        if any(c.isupper() for c in s):
            return None
        if len(s) > 24:
            return None
    return p


def split_concatenated(s):
    parts = [p for p in BOUNDARY.split(s) if p.startswith("/api/") and len(p) > 5]
    return [q for q in (clean_path(p) for p in parts) if q] or \
           ([q] if (q := clean_path(s)) else [])


eps = set()


def walk(o):
    if isinstance(o, str):
        for p in split_concatenated(o):
            eps.add(p)
    elif isinstance(o, list):
        for x in o:
            walk(x)
    elif isinstance(o, dict):
        for k, v in o.items():
            if isinstance(k, str) and k.startswith("/"):
                for p in split_concatenated(k):
                    eps.add(p)
            walk(v)


walk(raw_eps)

# 从 .so 直接兜底重扫（更全）
SO = r"C:\Users\16650\AppData\Local\Temp\prismx\libprism.so"
if os.path.exists(SO):
    with open(SO, "rb") as f:
        blob = f.read()
    for m in re.finditer(rb"/api/[a-zA-Z0-9_\-/]+", blob):
        for p in split_concatenated(m.group().decode()):
            eps.add(p)

# ---------- 2. 前端已验证的调用 ----------
calls = load_json(os.path.join(DUMP, "frontend_api_calls.json"), [])
verified = {}
for c in calls:
    verified.setdefault(c["path"], []).append(c)

# ---------- 3. 插件工具标记 → 直连方式 ----------
MARKER_MAP = [
    ("[CMD]指令[/CMD]", "执行任意 Minecraft 指令（OP 身份）",
     "POST /api/bot/console", '{"input":"say 你好"}'),
    ("[SHELL4]指令[/SHELL4]", "同上（旧写法）",
     "POST /api/bot/console", '{"input":"give @s diamond 1"}'),
    ("[GETINFO]玩家名", "玩家维度/坐标/OP/等级",
     "GET /api/players/list", "（返回所有在线玩家，自己过滤）"),
    ("[LIST]", "在线玩家列表",
     "GET /api/players/list 或 GET /api/server/players", ""),
    ("[GETSCORE]玩家名 记分板", "读记分板",
     "POST /api/bot/console", '{"input":"scoreboard players get \\"玩家名\\" 记分板"}'),
    ("[GETTAG]玩家名 标签", "读标签",
     "POST /api/bot/console", '{"input":"tag \\"玩家名\\" list"}'),
    ("[GETINVENTORY]self", "读背包",
     "POST /api/bot/console", '{"input":"codebuilder_actorinfo inventory @s"}'),
    ("[LOCATE]结构名", "定位结构",
     "POST /api/bot/console", '{"input":"locate structure village"}'),
    ("[NBT]X Y Z", "读方块 NBT",
     "POST /api/bot/console", '{"input":"data get block X Y Z"}'),
    ("[SEARCH_WEB]内容", "联网搜索",
     "外部 AI 自己就有联网，直接搜；或 ai_chat 工具", ""),
    ("[TIME]", "现实时间",
     "外部 AI 本地时间即可", ""),
    ("[PERSONA]设定", "写人物设定",
     "POST /api/files/write", '{"path":".../ai_personas.json","content":"..."}'),
    ("[VOTE]time set day", "时间/天气投票",
     "POST /api/bot/console", '{"input":"..."}'),
    ("[MUTE]玩家名 时长", "禁言",
     "POST /api/bot/console", '{"input":"tag \\"玩家名\\" add 禁言"}'),
    ("[LOG]查询内容", "读服务端日志",
     "GET /api/plugin/file/read", '?id=ds_ai_agent&scope=code 读 runtime.log 走 /api/files/read'),
    ("[BUILD]开启建筑模式", "建筑模式",
     "外部 AI 自己规划 → POST /api/mcfunction/execute 批量执行", ""),
]

# ---------- 4. 外部 AI 独有（AI帮写做不到） ----------
EXTRA = [
    ("全盘文件读写", "GET /api/files/scan、GET /api/files/read、POST /api/files/write",
     "能读/写云手机上的任意文件 —— AI帮写 完全没这个能力"),
    ("改写插件源码", "GET /api/plugin/file/read、POST /api/plugin/file/write",
     "★ 这就是用户说的「改写底层代码」：写完自动热重载"),
    ("装/删/停插件", "POST /api/plugin/create / import / delete / run / stop / reload / export",
     "可以从插件市场装任意插件"),
    ("AI 模型管理", "GET /api/ai/models、POST /api/ai/models/fetch、DELETE /api/ai/models",
     "★ 给 Prism 加任意 OpenAI 兼容模型（BaseURL+Key），AI帮写 只能用已配好的"),
    ("会话快照", "GET/POST/DELETE /api/ai/snapshot、POST /api/ai/snapshot/restore",
     "给 AI帮写 会话打快照 / 回滚"),
    ("寻路", "POST /api/pathfinder/goto / follow / stop、GET /api/pathfinder/log",
     "让机器人自动走到坐标 / 跟随玩家"),
    ("飞行/移动", "POST /api/fly/start / stop / jump / teleport / look / move / press …",
     "精确控制机器人移动"),
    ("指令工程", "POST /api/mcfunction/execute / parse / stop、GET /api/mcfunction/status",
     "★ 批量执行成千上万条指令（建筑模式的正规通道）"),
    ("命令方块导入导出", "POST /api/cb/import/preview / start、/api/cb/export/scan / save",
     "把 .mcfunction 铺成命令方块，或反向导出"),
    ("建筑/预览", "POST /api/building/voxel / analyze / stats、/api/preview/generate / zip / render-isometric",
     "体素化、等距渲染、打包建筑"),
    ("地图画", "POST /api/mapart/preview、GET /api/mapart/preview",
     "把图片铺成地图画"),
    ("绘画", "GET /api/draw/state / palette、POST /api/draw/stroke / apply / sync / undo / redo",
     "在游戏里画画"),
    ("相机/摄影", "POST /api/camera/start / stop / generate / test、GET /api/camera/shots",
     "自动给玩家拍分镜截图"),
    ("音乐", "POST /api/music/play / queue/add / note / loop、GET /api/music/status",
     "让机器人演奏 MIDI"),
    ("皮肤", "POST /api/skin/build、GET /api/skin/online-list / online-head / online-preview",
     "皮肤相关"),
    ("系统级", "POST /api/system/restart、/api/cache/clear、/api/parse/cancel",
     "重启 Prism、清缓存"),
    ("多机编队", "POST /api/fleet/connect / disconnect、GET /api/fleet/status",
     "多台云手机协同"),
]


def cat_of(p):
    p2 = p.lower()
    table = [
        ("机器人 / 游戏", ["/api/bot/", "/api/players/", "/api/server/", "/api/mcfunction/", "/api/fleet/"]),
        ("寻路 / 移动", ["/api/pathfinder/", "/api/fly/"]),
        ("插件", ["/api/plugin"]),
        ("AI / 模型 / 会话", ["/api/ai/"]),
        ("文件", ["/api/files/", "/api/file/"]),
        ("建筑 / 预览 / 地图画", ["/api/building/", "/api/preview/", "/api/mapart/", "/api/draw/", "/api/itemmaker/"]),
        ("命令方块", ["/api/cb/"]),
        ("相机 / 皮肤 / 音乐", ["/api/camera/", "/api/skin/", "/api/music/", "/api/media/"]),
        ("任务 / 节点", ["/api/task/", "/api/node/"]),
        ("账号 / 市场 / 系统", ["/api/toolbox/", "/api/market", "/api/plugin-market", "/api/system/",
                                "/api/accounts", "/api/version", "/api/announcements", "/api/cache/",
                                "/api/heartbeat", "/api/integrity", "/api/permission", "/api/prism/"]),
    ]
    for name, kws in table:
        if any(k in p2 for k in kws):
            return name
    return "其他"


def main():
    grouped = {}
    for p in sorted(eps):
        grouped.setdefault(cat_of(p), []).append(p)

    caps = []
    for cat, paths in grouped.items():
        for p in paths:
            vs = verified.get(p) or []
            caps.append({
                "category": cat,
                "path": p,
                "methods": sorted({v["method"] for v in vs}) or ["GET"],
                "verified_from_frontend": bool(vs),
                "sample_body": vs[0]["sample_body"] if vs else "",
            })
    with open(os.path.join(DOCS, "prism-capabilities.json"), "w", encoding="utf-8") as f:
        json.dump(caps, f, ensure_ascii=False, indent=2)

    L = []
    L.append("# 外部 AI 直连能力手册（我就是执行者）")
    L.append("")
    L.append("> 这份手册回答一个问题：**外部 AI Agent 拿到那个 MCP 网址之后，到底能干什么？**")
    L.append("> 所有内容来自实测与逆向，不是推测：")
    L.append("> - 端点表：从 `libprism.so` 抽出的 %d 个本机 REST 端点" % len(eps))
    L.append("> - 调用格式：从 Prism 前端 JS 抽出的 %d 个真实调用（方法 + 参数体）" % len(calls))
    L.append("> - 插件源码：`ds_ai_agent.lua` 7185 行（真机读回来的）" % ())
    L.append("")
    L.append("---")
    L.append("")
    L.append("## 一、先搞清楚分层（这是理解一切的关键）")
    L.append("")
    L.append("```")
    L.append("┌─────────────────────────────────────────────────────────┐")
    L.append("│  你的云手机                                              │")
    L.append("│                                                          │")
    L.append("│   ┌────────────────────────────────────────────┐        │")
    L.append("│   │ Prism APK (com.prismtool.box)              │        │")
    L.append("│   │                                            │        │")
    L.append("│   │  Go 引擎  libprism.so                     │        │")
    L.append("│   │    └─ %3d 个本机 REST 端点 @127.0.0.1:8080 │  ← 外部 AI 打这里" % len(eps))
    L.append("│   │                                            │        │")
    L.append("│   │  Lua 插件  ds_ai_agent.lua (7185 行)      │        │")
    L.append("│   │    └─ 游戏内 AI帮写：ai 内容 / .指令       │  ← 玩家打这里")
    L.append("│   └────────────────────────────────────────────┘        │")
    L.append("│                        ▲                                 │")
    L.append("│                        │ 127.0.0.1 直连                  │")
    L.append("│   ┌────────────────────┴───────────────────────┐        │")
    L.append("│   │ 被控端 APK（我们做的）                     │        │")
    L.append("│   └────────────────────┬───────────────────────┘        │")
    L.append("└────────────────────────┼─────────────────────────────────┘")
    L.append("                         │ 主动外连长轮询（穿透 NAT）")
    L.append("                         ▼")
    L.append("              Cloudflare Worker  ai-api.youyuanqi.dpdns.org")
    L.append("                         │")
    L.append("                         ▼")
    L.append("              外部 AI Agent（Codex / Claude / 任意）")
    L.append("              https://ai-api.youyuanqi.dpdns.org/mcp?key=<密钥>")
    L.append("```")
    L.append("")
    L.append("**结论**：AI帮写（Lua 插件）是**业务层**，Prism 引擎是**能力层**。")
    L.append("外部 AI 直接打能力层 —— 所以它**天然比 AI帮写 权限大**，而且不需要 AI帮写 同意。")
    L.append("")
    L.append("---")
    L.append("")
    L.append("## 二、AI帮写 的每个能力 → 外部 AI 怎么直接做")
    L.append("")
    L.append("| AI帮写 的工具标记 | 作用 | 外部 AI 直连方式 |")
    L.append("|---|---|---|")
    for mk, desc, api, sample in MARKER_MAP:
        L.append("| `%s` | %s | `%s` |" % (mk, desc, api))
    L.append("")
    L.append("> 用法统一是 MCP 的 `prism_rest`：")
    L.append("> ```")
    L.append('> prism_rest(path="/api/bot/console", method="POST", body={"input":"say 你好"})')
    L.append("> ```")
    L.append("> ⚠ 需要被控端 **v1.3+**（v1.1/v1.2 的 prism_rest 只实现了 GET，POST 体被丢掉，Prism 回「无效JSON」）。")
    L.append("")
    L.append("---")
    L.append("")
    L.append("## 三、★ 外部 AI 独有 —— AI帮写 根本做不到的事")
    L.append("")
    L.append("| 能力 | 端点 | 说明 |")
    L.append("|---|---|---|")
    for name, api, note in EXTRA:
        L.append("| **%s** | `%s` | %s |" % (name, api, note))
    L.append("")
    L.append("---")
    L.append("")
    L.append("## 四、前端已验证的调用格式（照着填就行）")
    L.append("")
    L.append("> 这些是从 Prism 自己的前端 JS 里逐条抽出来的，**参数名就是真名**，不是猜的。")
    L.append("")
    for cat, paths in grouped.items():
        rows = []
        for p in paths:
            for v in (verified.get(p) or []):
                rows.append(v)
        if not rows:
            continue
        L.append("### %s" % cat)
        L.append("")
        L.append("| 方法 | 路径 | 参数体 |")
        L.append("|---|---|---|")
        for v in rows:
            b = (v["sample_body"] or "").replace("|", "\\|")
            if len(b) > 110:
                b = b[:110] + "…"
            L.append("| `%s` | `%s` | `%s` |" % (v["method"], v["path"], b or "—"))
        L.append("")
    L.append("---")
    L.append("")
    L.append("## 五、全部端点按类别")
    L.append("")
    for cat, paths in grouped.items():
        L.append("### %s（%d 个）" % (cat, len(paths)))
        L.append("")
        for p in paths:
            mark = " ★已验证" if verified.get(p) else ""
            L.append("- `%s`%s" % (p, mark))
        L.append("")
    L.append("---")
    L.append("")
    L.append("## 六、怎么用（三种入口）")
    L.append("")
    L.append("1. **MCP 网址**（外部 AI 用）")
    L.append("   `https://ai-api.youyuanqi.dpdns.org/mcp?key=<平台密钥>`")
    L.append("   10 个工具：`prism_rest` 是主通道，`prism_status` 用来诊断，")
    L.append("   `prism_chat`/`prism_tool` 是走内置 AI 的旧通道（不推荐）。")
    L.append("2. **命令行**（我调试用）")
    L.append("   `python tools/mcp.py rest /api/bot/status`")
    L.append("   `python tools/mcp.py rest /api/bot/console POST '{\"input\":\"say 你好\"}'`")
    L.append("3. **控制台网页**：https://prism-console-7v1.pages.dev/")
    L.append("")
    L.append("---")
    L.append("")
    L.append("生成脚本：`tools/gen_capability_doc.py`（端点表变了重跑即可）")
    L.append("")

    out = os.path.join(DOCS, "外部AI直连能力手册.md")
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    print("端点总数 %d，前端已验证调用 %d" % (len(eps), len(calls)))
    print("写出: %s" % out)
    print("写出: %s" % os.path.join(DOCS, "prism-capabilities.json"))
    for cat, paths in grouped.items():
        print("  %-22s %d" % (cat, len(paths)))


if __name__ == "__main__":
    main()
