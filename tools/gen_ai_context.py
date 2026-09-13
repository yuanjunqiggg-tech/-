#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_ai_context.py —— 把「AI帮写」的整套上下文打包，供外部 AI Agent 使用。

背景（用户原话）：
    「当 AI Agent 去给我们改插件的时候，也就是自己用 AI帮写的时候，
      要把那个 MC 指令库、还是什么 F 开头的那个知识库，一起加进去，
      然后他客观地也能知道插件给 AI 了什么提示词。」

所以这个脚本做两件事：

  1) 生成人类可读的上下文包  →  extracted/ai_assist/
     （系统提示词 / 29 个工具 / 两个技能知识库 / 插件开发文档）

  2) 生成 Worker 常量模块     →  workers/src/aicontext.ts
     这样外部 AI 只要调一个 MCP 工具 `ai_assist_context`，
     不用碰云手机、不用设备在线，就能拿到和 AI帮写 完全一样的知识底座。

数据来源（全部是本地已解包/已捕获的原始文件，不联网）：
    extracted/system_prompt.txt   —— 捕获代理拦到的 AI帮写系统提示词原文
    extracted/tools.json          —— AI帮写 29 个工具的完整 schema
    extracted/skills/*.md         —— 从 libprism.so 里挖出的内置技能知识库
    prism_dump/so/libprism.so     —— 技能正文的出处（供复核）

用法：
    python tools/gen_ai_context.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # ds-platform-ai-assist/
OUT_HUMAN = os.path.join(ROOT, 'extracted', 'ai_assist')
OUT_TS = os.path.join(ROOT, 'workers', 'src', 'aicontext.ts')


def read(path, required=True):
    p = os.path.join(ROOT, path)
    if not os.path.exists(p):
        if required:
            raise SystemExit('缺少文件：' + p)
        return ''
    with open(p, encoding='utf-8') as f:
        return f.read()


# ------------------------------------------------------------
# 1. 读源
# ------------------------------------------------------------
system_prompt = read('extracted/system_prompt.txt').strip()

tools_raw = json.loads(read('extracted/tools.json'))
# tools.json 是 OpenAI tools 数组：[{"type":"function","function":{...}}, ...]
tool_lines = []
for t in tools_raw:
    fn = t.get('function', t)
    params = (fn.get('parameters') or {}).get('properties') or {}
    required = (fn.get('parameters') or {}).get('required') or []
    args = []
    for k in params:
        args.append(k + ('*' if k in required else ''))
    tool_lines.append('- **%s**(%s)\n  %s' % (fn.get('name'), ', '.join(args),
                                              (fn.get('description') or '').replace('\n', ' ').strip()))
tools_md = ('# AI帮写 · 29 个内置工具\n\n'
            '> 来源：捕获代理拦截到的真实 `tools` 数组（`extracted/tools.json`）。\n'
            '> `*` = 必填参数。\n\n' + '\n'.join(tool_lines) + '\n')

# 技能知识库：把同一技能的多页合并成一节
bedrock = read('extracted/skills/command-list.md')
bedrock += '\n\n---\n\n' + read('extracted/skills/selector-parameter.md')
bedrock += '\n\n---\n\n' + read('extracted/skills/command-argument-type.md')
fmbe = read('extracted/skills/display-entities.md')

plugin_doc = read('extracted/skills/plugin-dev.md')
wordbank_doc = read('extracted/skills/wordbank-plugin-dev.md')

# ------------------------------------------------------------
# 2. 人类可读的上下文包
# ------------------------------------------------------------
os.makedirs(OUT_HUMAN, exist_ok=True)

files = {
    '01_系统提示词.md': (
        '# AI帮写 · 系统提示词（原文）\n\n'
        '> 这是 Prism 内置「AI帮写」每次发消息时放在 `messages[0]` 的 system 内容，\n'
        '> 通过捕获代理从真实请求里拦下来的，一字未改。\n\n'
        '```text\n' + system_prompt + '\n```\n\n'
        '## 它说明了什么\n\n'
        '- AI帮写 的身份是「插件开发助手」，面向 **Lua 插件 / 词库插件** 开发。\n'
        '- 它明确要求：调用工具必须真的发起 `tool_calls`，不许只在文字里写「我已调用」。\n'
        '- 它把**专项知识**委托给【技能知识库】（即 `list_skills` / `load_skill` 那一套）。\n'
        '- 机器人没连上时它会直接「哑掉」——这正是我们做 `bot_keeper` 的原因。\n'),
    '02_工具集_29个.md': tools_md,
    '03_技能_基岩版指令.md': (
        '# 技能知识库 · 基岩版指令（bedrock-commands）\n\n'
        '> 内置技能，id=`bedrock-commands`，默认已加载。\n'
        '> 正文从 `libprism.so` 里直接挖出，含三页：命令清单 / 选择器参数 / 命令参数类型。\n\n'
        + bedrock),
    '04_技能_FMbe显示实体.md': (
        '# 技能知识库 · FMbe 显示实体（fmbe-display）\n\n'
        '> 内置技能，id=`fmbe-display`，默认已加载。\n'
        '> 就是用户说的「F 开头的那个知识库」——FMbe = 狐狸方块实体（Fox MBE）。\n\n'
        + fmbe),
    '05_插件开发文档.md': (
        '# Prism 工具箱 · 插件开发文档\n\n'
        '> 写 / 改 Lua 插件必读。Prism 本体自带，同样从 `libprism.so` 挖出。\n\n'
        + plugin_doc),
    '06_词库插件开发文档.md': (
        '# Prism 工具箱 · 词库插件开发文档\n\n'
        '> 写词库（wordbank）插件用。\n\n'
        + wordbank_doc),
}
for name, body in files.items():
    with open(os.path.join(OUT_HUMAN, name), 'w', encoding='utf-8') as f:
        f.write(body)

readme = """# AI帮写 等价上下文包

> 生成脚本：`tools/gen_ai_context.py`（源文件变了重跑即可）
> 目的：让**外部 AI Agent** 在改插件时，拿到和 Prism 内置「AI帮写」**完全一样**的知识底座。

## 为什么要这个包

外部 AI 直接打 Prism 的本机接口（`prism_rest`），权限比 AI帮写更高。
但**权限高不等于知识全** —— AI帮写手里有三样东西是接口给不了的：

| 东西 | 作用 | 本包对应文件 |
|---|---|---|
| 系统提示词 | 告诉 AI 它的身份、该写什么、怎么调工具 | `01_系统提示词.md` |
| 29 个工具 | 它能做的动作清单 | `02_工具集_29个.md` |
| 技能知识库 | 基岩版指令 / FMbe 动画等专项知识 | `03_` `04_` |

再加上 Prism 自己的插件开发文档（`05_` `06_`），外部 AI 才算真的「能替 AI帮写干活」。

## 怎么用

**给外部 AI Agent（推荐）**：调 MCP 工具 `ai_assist_context`，不用设备在线：

```
POST https://ai-api.youyuanqi.dpdns.org/mcp?key=<平台密钥>
{"jsonrpc":"2.0","id":1,"method":"tools/call",
 "params":{"name":"ai_assist_context","arguments":{"part":"all"}}}
```

`part` 可选：`index`（默认，先看有什么）/ `prompt` / `tools` / `skills` / `plugin_doc` / `all`

**本地查阅**：直接看本目录的 markdown 文件。

## 文件清单

| 文件 | 内容 |
|---|---|
| `01_系统提示词.md` | AI帮写 系统提示词原文（585 字符） |
| `02_工具集_29个.md` | 29 个内置工具 + 参数 |
| `03_技能_基岩版指令.md` | 命令清单 / 选择器参数 / 命令参数类型 |
| `04_技能_FMbe显示实体.md` | 狐狸方块实体动画 |
| `05_插件开发文档.md` | Lua 插件开发文档（Prism 本体自带） |
| `06_词库插件开发文档.md` | 词库插件开发文档 |

## 这些内容哪来的

- **系统提示词 + 工具集**：捕获代理（`tools/capture_proxy.py`）拦截 Prism 发往上游模型的真实请求，
  从 `messages[0].content` 和 `tools` 里原样取出。见 `extracted/提取说明.md`。
- **技能知识库 + 插件文档**：Prism 把它们**编译进了 `libprism.so`**（Go embed）。
  直接从二进制里按 UTF-8 文本段提取，出处可复核：
  `skills/bedrock-commands/command-list.md`、`skills/fmbe-display/display-entities.md` 等路径
  就在 `.so` 的字符串表里。

## 注意

- 技能里的 `{{video|youtube|...}}`、`/// note` 是 MkDocs Material 语法，是原样保留的，不是乱码。
- 技能正文里引用了 `./block-entities.md`、`./playanimation.md` 等页面，
  这些**没有**被打进 `.so`（内置版是节选），需要时得上 FMbe 的原始 wiki 找。
"""
with open(os.path.join(OUT_HUMAN, '00_README.md'), 'w', encoding='utf-8') as f:
    f.write(readme)

# ------------------------------------------------------------
# 3. Worker 常量模块
# ------------------------------------------------------------
def ts_str(s):
    # JSON.stringify 出来的双引号字符串，TS 直接可用；
    # 里面不会出现模板字符串的 ${ 语义，也不需要转义反引号。
    return json.dumps(s, ensure_ascii=False)

ts = '''// ============================================================
//  aicontext.ts —— 「AI帮写」的知识底座（自动生成，请勿手改）
// ============================================================
//
//  生成：python tools/gen_ai_context.py
//  说明：见 extracted/ai_assist/00_README.md
//
//  为什么要把这些塞进 Worker：
//    外部 AI 用 prism_rest 能拿到比 AI帮写 更高的权限，
//    但拿不到 AI帮写 的**知识**（提示词 / 技能库）。
//    把知识也搬上云端，外部 AI 才算真正能替 AI帮写干活，
//    而且**不依赖云手机在线** —— 设备掉线也能先把上下文读进去。
// ============================================================

/** AI帮写 的系统提示词原文（捕获代理拦到的 messages[0].content） */
export const AI_ASSIST_SYSTEM_PROMPT = %s;

/** AI帮写 的 29 个内置工具（可读版 markdown） */
export const AI_ASSIST_TOOLS_MD = %s;

/** 技能知识库：基岩版指令（命令清单 + 选择器参数 + 命令参数类型） */
export const SKILL_BEDROCK_COMMANDS = %s;

/** 技能知识库：FMbe 显示实体（狐狸方块实体动画） */
export const SKILL_FMBE_DISPLAY = %s;

/** Prism 工具箱 · Lua 插件开发文档（本体自带） */
export const PRISM_PLUGIN_DEV_DOC = %s;

/** Prism 工具箱 · 词库插件开发文档 */
export const PRISM_WORDBANK_DEV_DOC = %s;

/** 各部分的元信息，供 ai_assist_context 的 index 分支使用 */
export const AI_ASSIST_PARTS: { key: string; title: string; chars: number; desc: string }[] = [
  { key: 'prompt', title: 'AI帮写 系统提示词', chars: AI_ASSIST_SYSTEM_PROMPT.length,
    desc: 'AI帮写 的身份设定与工具调用规则，原文' },
  { key: 'tools', title: 'AI帮写 29 个工具', chars: AI_ASSIST_TOOLS_MD.length,
    desc: '内置工具清单（读/写文件、调 Lua、抓包、shell、游戏内调用…）' },
  { key: 'skills', title: '技能知识库（基岩版指令 + FMbe）', chars: SKILL_BEDROCK_COMMANDS.length + SKILL_FMBE_DISPLAY.length,
    desc: '基岩版命令清单/选择器/参数类型 + 狐狸方块实体动画' },
  { key: 'plugin_doc', title: 'Prism 插件开发文档', chars: PRISM_PLUGIN_DEV_DOC.length + PRISM_WORDBANK_DEV_DOC.length,
    desc: '写 / 改 Lua 插件与词库插件必读' },
];

/** 把多个部分拼成一段可直接塞进上下文的大文本 */
export function buildAiAssistContext(part: string): string {
  const p = (part || 'index').toLowerCase();
  if (p === 'prompt') return AI_ASSIST_SYSTEM_PROMPT;
  if (p === 'tools') return AI_ASSIST_TOOLS_MD;
  if (p === 'skills') {
    return '===== 技能知识库 · 基岩版指令（bedrock-commands） =====\\n\\n'
      + SKILL_BEDROCK_COMMANDS
      + '\\n\\n===== 技能知识库 · FMbe 显示实体（fmbe-display） =====\\n\\n'
      + SKILL_FMBE_DISPLAY;
  }
  if (p === 'plugin_doc') {
    return '===== Prism 工具箱 · 插件开发文档 =====\\n\\n' + PRISM_PLUGIN_DEV_DOC
      + '\\n\\n===== Prism 工具箱 · 词库插件开发文档 =====\\n\\n' + PRISM_WORDBANK_DEV_DOC;
  }
  if (p === 'all') {
    return '===== AI帮写 系统提示词（原文） =====\\n\\n' + AI_ASSIST_SYSTEM_PROMPT
      + '\\n\\n===== AI帮写 29 个内置工具 =====\\n\\n' + AI_ASSIST_TOOLS_MD
      + '\\n\\n' + buildAiAssistContext('skills')
      + '\\n\\n' + buildAiAssistContext('plugin_doc');
  }
  // index
  return AI_ASSIST_PARTS
    .map((x) => `- ${x.key}（${x.chars} 字符）：${x.title} —— ${x.desc}`)
    .join('\\n');
}
''' % (ts_str(system_prompt), ts_str(tools_md), ts_str(bedrock), ts_str(fmbe),
       ts_str(plugin_doc), ts_str(wordbank_doc))

with open(OUT_TS, 'w', encoding='utf-8') as f:
    f.write(ts)

# ------------------------------------------------------------
# 4. 汇报
# ------------------------------------------------------------
print('人类可读包 →', OUT_HUMAN)
for name in sorted(os.listdir(OUT_HUMAN)):
    print('   %-28s %8d 字符' % (name, len(open(os.path.join(OUT_HUMAN, name), encoding='utf-8').read())))
print('Worker 模块 →', OUT_TS, os.path.getsize(OUT_TS), 'bytes')
