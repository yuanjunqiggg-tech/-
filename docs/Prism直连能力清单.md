# Prism 直连能力清单（不经任何 AI）

> 从 `libprism.so` 里挖出来的 **193 个本机 REST 端点**。
> 外部 AI Agent 通过 MCP 的 `prism_rest` 工具**直接调用它们**，
> 自己就是执行者 —— 不经过 Prism 内置 AI，不需要它同意，也不受它"插件开发助手"身份的限制。

---

## 为什么要有这份清单

之前的做法是：外部 AI 把任务描述给 Prism 内置 AI，让它去调工具。
**这条路不可靠**，真机实测有两个问题：

1. Prism 内置 AI 的身份是「**插件开发助手**」（写 Lua 插件/词库），
   你让它"在游戏里说句话"，它根本不发起 tool_call → 返回 `executed: false`
2. 中间隔了一层 AI，它可能改写参数、加解释、或者干脆拒绝

**正确做法**：外部 AI 直接打 Prism 的 REST 端点。Prism 的能力本来就在那里，
只是之前没人把口子找出来。

---

## 怎么用

一个 MCP 工具就够了：

```
prism_rest(
  path   = "/api/bot/console",
  method = "POST",
  body   = { "input": "say 你好" }
)
```

> ⚠ 需要被控端 **v1.3 或更高**（v1.1/v1.2 的 prism_rest 只实现了 GET，
> POST body 会被丢掉，Prism 会回你「无效JSON」）。

---

## 一、机器人 / 游戏操作（最常用）

| 端点 | 方法 | 说明 |
|---|---|---|
| `/api/bot/status` | GET | 连没连、在哪个服、是不是 OP ✅ 真机验证 |
| `/api/bot/console` | POST | **给机器人发命令** `{"input":"say 你好"}` |
| `/api/bot/connect` | POST | 连机器人 `{token, server, use_new_protocol, auth, password}` |
| `/api/bot/disconnect` | POST | 断开 |
| `/api/players/list` | GET | 当前玩家列表 ✅ 真机验证 |
| ~~`/api/server/players`~~ | — | ❌ **真机验证不存在**（返回 WebView 的 HTML，见下方「路径猜测的坑」） |
| ~~`/api/server/detail`~~ | — | ❌ **真机验证不存在** |
| `/api/mcfunction/execute` | POST | **批量执行指令** `{content, global, groups, tests}` |
| `/api/mcfunction/status` / `stop` / `parse` | GET | 执行进度 / 中止 / 解析 ✅ status 真机验证 |

## 二、移动与飞行

```
/api/fly/start  /api/fly/stop   /api/fly/jump      /api/fly/jump-start  /api/fly/jump-stop
/api/fly/down   /api/fly/look   /api/fly/move      /api/fly/press       /api/fly/release
/api/fly/teleport  /api/fly/position  /api/fly/status
/api/fly/sneak-start /api/fly/sneak-stop /api/fly/sprint-start /api/fly/sprint-stop
```

## 三、插件（等于"改写底层"的入口）

| 端点 | 说明 |
|---|---|
| `GET /api/plugin/list` | 所有插件（id / 类型 / 是否运行 / 是否禁用） |
| `POST /api/plugin/run` `{id}` / `/api/plugin/stop` `{id}` | 启动 / 停止 |
| `POST /api/plugin/reload` / `delete` / `create` / `config` | 重载 / 删除 / 新建 / 配置 |
| `GET /api/plugin/file/read?id=&scope=code\|docs&file=` | **读插件源码** |
| `POST /api/plugin/file/write` | **写插件源码**（写完会自动热重载） |
| `POST /api/plugin/import` / `export` / `export-saf` | 导入 / 导出 |
| `GET /api/plugin/api-doc` / `wordbank-doc` | 插件 API 文档 / 词库文档 ✅ 真机验证 |
| `GET /api/plugin/data` | 数据 ✅ 真机验证 |
| `POST /api/plugin/meta` | 元信息（★ 真机验证是 **POST**，用 GET 会回「无效JSON」） |
| `POST /api/plugin/disabled` | 禁用列表（★ 同上，是 POST） |

## 四、文件

| 端点 | 说明 |
|---|---|
| `GET /api/files/scan` | 扫描目录（含建筑文件标记） |
| `GET /api/files/read` / `POST /api/files/write` | 读 / 写 |
| `POST /api/file/upload` | 上传 |

## 五、任务 / 节点

```
/api/task/list    GET      任务列表（导入导出、建筑分析等）
/api/task/start   POST     {"type":"export","params":{...}}
/api/task/stop / resume / delete
/api/node/status / start / stop        自动化节点
```

## 六、AI帮写 会话（存在 Prism 自己的存储里）

```
GET    /api/ai/sessions?plugin_id=xxx     会话列表
GET    /api/ai/sessions/recent            最近一个会话（含全部消息）
POST   /api/ai/sessions/load  {name}
POST   /api/ai/sessions       {name, plugin_id, messages}   保存
POST   /api/ai/sessions/rename {old_name,new_name}
DELETE /api/ai/sessions       {name}
GET    /api/ai/snapshot  /  POST /api/ai/snapshot/restore
GET    /api/ai/models  /  /api/ai/models/fetch
POST   /api/ai/chat          {model_name,plugin_id,mode,session_name,messages}  SSE 流
```

> 真机实测：列表返回的是对象数组，不是字符串数组 ——
> `[{name, created, messages, plugin_id}, ...]`

## 七、地图绘制

```
/api/draw/create / stroke / custom / apply / state / close / sync
/api/draw/undo / redo / mode / palette
/api/map/scan / play / stop / display / grid
/api/mapart/preview          /api/preview/scan / generate / status / cancel
/api/preview/save-image / zip / zip-building / generate-gif / render-isometric
/api/building/analyze / voxel
/api/cb/import/start / preview / export/scan / export/save     命令方块
```

## 八、音乐 / 皮肤 / 相机 / 其他

```
/api/music/play stop pause resume next prev loop note queue status actionbar upload
/api/skin/build voxel preview head online-list online-head online-build online-preview
/api/camera/start stop status shots shot/update shot/delete generate test test/all clear
/api/marquee/start stop status preview
/api/pathfinder/goto stop follow log
/api/itemmaker/generate
/api/social/search
/api/system/restart        重启（危险）
/api/cache/clear
/api/repair/start
```

## 九、账号 / 市场 / 工具箱（Prism 自己的业务）

```
/api/auth/login / nuts        /api/toolbox/my-info / nuts/balance
/api/market/*                      /api/plugin-market/*
/api/phoenix/*                     /api/fleet/connect / disconnect / status
/api/push/pending / ack            Prism 自己的指令队列
```

> ⚠ 真机验证：`GET /api/auth/me` **不存在**（返回 WebView 的 HTML）。
> `/api/toolbox/my-info` ✅ 可用。

---

## ★ 路径猜测的坑（真机踩出来的，必读）

**Prism 对不存在的路径不返回 404，而是把 WebView 的 `index.html` 回给你。**
所以你随手猜一个 `/api/xxx`，拿到一坨 `<!DOCTYPE html>`，
看起来像"接口返回了东西"，其实是**路径错了**。

判断办法：

| 回包长什么样 | 真实含义 |
|---|---|
| `<!DOCTYPE html>...` | 路径不存在，被 SPA 兜底了 |
| `{"error":"无效JSON"}` | 路径**存在**，但它是 POST 端点，你用了 GET |
| `{"error":"未连接到服务器"}` | 路径**存在**且正常，只是机器人没连 |
| 正常 JSON | 通 |

---

## 实测记录

### 全量巡检（2026-09-13 16:15，设备 `本机一号`）

只读 GET 端点巡检 29 个 → **23 个真实可用**。
完整逐项结果见 **[`docs/端点巡检报告.md`](./端点巡检报告.md)**，
可随时用 `python tools/probe_prism_endpoints.py` 重跑。

分类：`ok` 20 个 / `ok-pre` 3 个（端点活着，只是机器人没连）/
`needs-body` 2 个（其实是 POST）/ `not-found` 4 个（路径猜错）。

### 早期记录（2026-09-13 16:00）

| 端点 | 结果 |
|---|---|
| `GET /api/bot/status` | `{connected:false, server:"98014267", is_op:true}` |
| `GET /api/plugin/list` | 1 个插件 `ds_ai_agent`（lua，未运行） |
| `GET /api/ai/sessions` | 20 个历史会话（8-25 起，含 `ds_ai_agent`） |
| `GET /api/ai/sessions/recent` | 完整读回了 9-12 那段对话 |
| `GET /api/task/list` | 66 条任务（导入类） |
| `GET /api/files/scan` | 读到了 `/storage/emulated/0` 下的目录（112 项） |
| `GET /api/fly/status` | `{"error":"未连接到服务器"}` —— 端点正常，机器人没连 |
| `POST /api/bot/console` | `{"error":"无效JSON"}` —— **v1.3 之前的被控端丢了 body**，v1.3 已修 |

---

## 边界与风险

- **`/api/system/restart`** 会重启云手机上的 Prism —— 别乱调
- **`/api/plugin/file/write`** 能改插件源码 = 能改 Prism 的行为，等于"改写底层"
- **`/api/bot/connect`** 需要游戏账号 token，别外泄
- 所有端点在**本机 8080 上无鉴权**，密码只挡网页 UI。
  所以**那把 MCP 密钥就等于这些能力的全部**，别外传
