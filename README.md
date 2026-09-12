# Ds Platform · AI 帮写 外部控制

把 Prism 工具箱的「AI 帮写」能力开放到公网，用手机 / 电脑网页操控。

## 这是什么

Prism 工具箱内置了一个叫 **「AI 帮写」** 的功能（在插件编辑器里），
它是一个能读写插件代码的 AI Agent，跑在你本机。

本项目给它套一层网关，让你能：
- 📱 **远程操控** —— 手机 / 电脑打开网页就能对话、下指令
- 🔍 **看到提示词** —— 每一次发给模型的完整提示词都被记录、可查看
- ✏️ **改提示词** —— 可以编辑提示词，让它按你的版本工作
- 📊 **用量统计** —— token 消耗、会话记录、任务状态

## 架构

```
┌──────────────────────┐
│  手机 APK / 电脑网页   │
└───────────┬──────────┘
            │ HTTPS
┌───────────▼──────────────────────────┐
│  ai-api.youyuanqi.dpdns.org          │
│  Cloudflare Workers 网关              │
│  · 密钥鉴权                           │
│  · SSE 流式透传                       │
│  · ★ 旁路捕获完整提示词 → D1          │
│  · ★ 提示词替换（可编辑）             │
└───────────┬──────────────────────────┘
            │ Cloudflare Tunnel
┌───────────▼──────────────────────────┐
│  prism.youyuanqi.dpdns.org           │
│  → 本机 Prism :PORT                   │
└───────────┬──────────────────────────┘
            │
┌───────────▼──────────────────────────┐
│  Prism /api/ai/chat  →  上游模型      │
└──────────────────────────────────────┘
```

## 目录结构

```
ds-platform-ai-assist/
├── workers/                 # Cloudflare Workers 网关
│   ├── src/index.ts         # 核心：SSE 透传 + 提示词捕获
│   ├── wrangler.toml        # 部署配置
│   └── package.json
├── sql/
│   └── schema.sql           # D1 建表语句（7 张表）
├── web/                     # 网页控制台前端
├── tunnel/
│   └── config.yml           # cloudflared 隧道配置
└── docs/
    ├── 部署文档.md           # 完整分步部署说明
    └── AI帮写_逆向分析.md     # Prism 功能逆向报告
```

## 快速开始

详见 [`docs/部署文档.md`](docs/部署文档.md)。

简要流程：

```bash
# 1. 初始化数据库
cd workers
npm install
npx wrangler login
npm run db:init:remote

# 2. 设置密钥
npx wrangler secret put PLATFORM_ACCESS_KEY

# 3. 部署网关
npm run deploy

# 4. 启动隧道（记得先改 tunnel/config.yml 里的端口）
cloudflared tunnel --config ../tunnel/config.yml run
```

## 密钥

所有接口（除健康检查）都需要：

```
Authorization: Bearer <PLATFORM_ACCESS_KEY>
```

## 核心接口

| 接口 | 用途 |
|---|---|
| `POST /api/v1/ai-assist/chat` | AI 对话（SSE 流式） |
| `GET /api/v1/ai-assist/prompts` | 查看捕获的提示词 |
| `POST /api/v1/ai-assist/templates` | 编辑并启用提示词 |
| `GET /api/v1/ai-assist/stats` | 用量统计 |

## 技术背景

关于 Prism「AI 帮写」的完整技术分析（接口契约、SSE 协议、工具集），
见 [`docs/AI帮写_逆向分析.md`](docs/AI帮写_逆向分析.md)。
