#!/usr/bin/env python3
"""
构建控制台产物 —— 把网关地址与访问密钥注入 HTML，产出「打开即用」的静态站点。

为什么需要它：
    控制台默认要手动填网关地址 + 密钥才能用。部署到 Pages 后，
    我们希望用户打开链接就直接连上，不用记任何东西。

用法：
    python tools/build_console.py \
        --endpoint https://ai-api.youyuanqi.dpdns.org \
        --key      <PLATFORM_ACCESS_KEY> \
        --out      .pages_dist

安全性说明：
    密钥会以明文写进 JS。这是「方便」与「安全」的取舍：
    - 该密钥只用于你自己部署的网关；
    - Pages 站点是公开 URL，任何知道链接的人都能拿到密钥；
    - 如需更高安全性，请改用 --no-key，让用户手动填。
"""

import argparse
import os
import re
import shutil
import sys

# 允许的占位符写法
PLACEHOLDER_ENDPOINT = "__PRISM_ENDPOINT__"
PLACEHOLDER_KEY = "__PRISM_KEY__"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WEB = os.path.join(ROOT, "web")


def js_escape(s: str) -> str:
    """转义成可安全嵌入单引号 JS 字符串的形式。"""
    return s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n").replace("\r", "")


def process(src: str, endpoint: str, key: str) -> str:
    if PLACEHOLDER_ENDPOINT not in src:
        print(f"  ⚠ 未找到占位符 {PLACEHOLDER_ENDPOINT}，可能已注入过")
    src = src.replace(PLACEHOLDER_ENDPOINT, js_escape(endpoint or ""))
    src = src.replace(PLACEHOLDER_KEY, js_escape(key or ""))
    return src


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="https://ai-api.youyuanqi.dpdns.org")
    ap.add_argument("--key", default="", help="PLATFORM_ACCESS_KEY；留空则需手动填")
    ap.add_argument("--out", default=".pages_dist")
    ap.add_argument("--inject-web", action="store_true",
                    help="同时把注入结果写回 web/console.html（本地预览用）")
    args = ap.parse_args()

    out = args.out if os.path.isabs(args.out) else os.path.join(ROOT, args.out)
    os.makedirs(out, exist_ok=True)

    # ★ 控制台主页面早已从 console.html 换成 index.html（含抓包/设备/模型/AI接入/名单等全部页面）。
    #   这里必须跟着改，否则 Pages 上跑的还是几小时前的旧版。
    pairs = [
        ("index.html", "index.html"),
        ("agent.html", "agent.html"),
    ]

    print(f"构建控制台 → {out}")
    for src_name, dst_name in pairs:
        src_path = os.path.join(WEB, src_name)
        if not os.path.exists(src_path):
            print(f"  ⚠ 跳过（不存在）: {src_name}")
            continue
        with open(src_path, "r", encoding="utf-8") as f:
            content = f.read()
        rendered = process(content, args.endpoint, args.key)
        dst_path = os.path.join(out, dst_name)
        with open(dst_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(rendered)
        size = os.path.getsize(dst_path)
        print(f"  ✓ {src_name} → {dst_name}  ({size:,} bytes)")
        if args.inject_web:
            with open(src_path, "w", encoding="utf-8", newline="\n") as f:
                f.write(rendered)
            print(f"    ↳ 已回写 {src_name}")

    if not args.key:
        print("\n⚠ 未提供 --key：部署后需在页面上手动填写密钥。")
    else:
        print(f"\n✓ 已注入 endpoint={args.endpoint}")
        print("  （密钥已写入站点，请勿将 .pages_dist 提交到公开仓库）")

    return 0


if __name__ == "__main__":
    sys.exit(main())
