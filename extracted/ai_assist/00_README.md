# AI帮写 等价上下文包

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

## ★ 还有一份「能力宣言」

`00_能力宣言.md` —— 用户明确要求的**强提示**：
> 「让 AI Agent 知道他可以有这些能力，而不是他只有这项能力」

外部 AI 很容易因为用户只提了一个需求，就以为自己只有那一项能力
（比如用户说「发句话」，它就只会发消息，不会想到先查机器人状态、
不会想到先读插件源码）。能力宣言就是治这个的。

它是 `ai_assist_context` 的**默认返回**，也会出现在 MCP `initialize`
的 `instructions` 里 —— AI 一连上就能看到。

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
| `00_能力宣言.md` | ★ 告诉 AI「你有这一整套能力」的强提示（默认返回） |
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
