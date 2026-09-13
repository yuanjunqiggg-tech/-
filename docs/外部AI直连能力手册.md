# 外部 AI 直连能力手册（我就是执行者）

> 这份手册回答一个问题：**外部 AI Agent 拿到那个 MCP 网址之后，到底能干什么？**
> 所有内容来自实测与逆向，不是推测：
> - 端点表：从 `libprism.so` 抽出的 224 个本机 REST 端点
> - 调用格式：从 Prism 前端 JS 抽出的 107 个真实调用（方法 + 参数体）
> - 插件源码：`ds_ai_agent.lua` 7185 行（真机读回来的）

---

## 一、先搞清楚分层（这是理解一切的关键）

```
┌─────────────────────────────────────────────────────────┐
│  你的云手机                                              │
│                                                          │
│   ┌────────────────────────────────────────────┐        │
│   │ Prism APK (com.prismtool.box)              │        │
│   │                                            │        │
│   │  Go 引擎  libprism.so                     │        │
│   │    └─ 224 个本机 REST 端点 @127.0.0.1:8080 │  ← 外部 AI 打这里
│   │                                            │        │
│   │  Lua 插件  ds_ai_agent.lua (7185 行)      │        │
│   │    └─ 游戏内 AI帮写：ai 内容 / .指令       │  ← 玩家打这里
│   └────────────────────────────────────────────┘        │
│                        ▲                                 │
│                        │ 127.0.0.1 直连                  │
│   ┌────────────────────┴───────────────────────┐        │
│   │ 被控端 APK（我们做的）                     │        │
│   └────────────────────┬───────────────────────┘        │
└────────────────────────┼─────────────────────────────────┘
                         │ 主动外连长轮询（穿透 NAT）
                         ▼
              Cloudflare Worker  ai-api.youyuanqi.dpdns.org
                         │
                         ▼
              外部 AI Agent（Codex / Claude / 任意）
              https://ai-api.youyuanqi.dpdns.org/mcp?key=<密钥>
```

**结论**：AI帮写（Lua 插件）是**业务层**，Prism 引擎是**能力层**。
外部 AI 直接打能力层 —— 所以它**天然比 AI帮写 权限大**，而且不需要 AI帮写 同意。

---

## 二、AI帮写 的每个能力 → 外部 AI 怎么直接做

| AI帮写 的工具标记 | 作用 | 外部 AI 直连方式 |
|---|---|---|
| `[CMD]指令[/CMD]` | 执行任意 Minecraft 指令（OP 身份） | `POST /api/bot/console` |
| `[SHELL4]指令[/SHELL4]` | 同上（旧写法） | `POST /api/bot/console` |
| `[GETINFO]玩家名` | 玩家维度/坐标/OP/等级 | `GET /api/players/list` |
| `[LIST]` | 在线玩家列表 | `GET /api/players/list 或 GET /api/server/players` |
| `[GETSCORE]玩家名 记分板` | 读记分板 | `POST /api/bot/console` |
| `[GETTAG]玩家名 标签` | 读标签 | `POST /api/bot/console` |
| `[GETINVENTORY]self` | 读背包 | `POST /api/bot/console` |
| `[LOCATE]结构名` | 定位结构 | `POST /api/bot/console` |
| `[NBT]X Y Z` | 读方块 NBT | `POST /api/bot/console` |
| `[SEARCH_WEB]内容` | 联网搜索 | `外部 AI 自己就有联网，直接搜；或 ai_chat 工具` |
| `[TIME]` | 现实时间 | `外部 AI 本地时间即可` |
| `[PERSONA]设定` | 写人物设定 | `POST /api/files/write` |
| `[VOTE]time set day` | 时间/天气投票 | `POST /api/bot/console` |
| `[MUTE]玩家名 时长` | 禁言 | `POST /api/bot/console` |
| `[LOG]查询内容` | 读服务端日志 | `GET /api/plugin/file/read` |
| `[BUILD]开启建筑模式` | 建筑模式 | `外部 AI 自己规划 → POST /api/mcfunction/execute 批量执行` |

> 用法统一是 MCP 的 `prism_rest`：
> ```
> prism_rest(path="/api/bot/console", method="POST", body={"input":"say 你好"})
> ```
> ⚠ 需要被控端 **v1.3+**（v1.1/v1.2 的 prism_rest 只实现了 GET，POST 体被丢掉，Prism 回「无效JSON」）。

---

## 三、★ 外部 AI 独有 —— AI帮写 根本做不到的事

| 能力 | 端点 | 说明 |
|---|---|---|
| **全盘文件读写** | `GET /api/files/scan、GET /api/files/read、POST /api/files/write` | 能读/写云手机上的任意文件 —— AI帮写 完全没这个能力 |
| **改写插件源码** | `GET /api/plugin/file/read、POST /api/plugin/file/write` | ★ 这就是用户说的「改写底层代码」：写完自动热重载 |
| **装/删/停插件** | `POST /api/plugin/create / import / delete / run / stop / reload / export` | 可以从插件市场装任意插件 |
| **AI 模型管理** | `GET /api/ai/models、POST /api/ai/models/fetch、DELETE /api/ai/models` | ★ 给 Prism 加任意 OpenAI 兼容模型（BaseURL+Key），AI帮写 只能用已配好的 |
| **会话快照** | `GET/POST/DELETE /api/ai/snapshot、POST /api/ai/snapshot/restore` | 给 AI帮写 会话打快照 / 回滚 |
| **寻路** | `POST /api/pathfinder/goto / follow / stop、GET /api/pathfinder/log` | 让机器人自动走到坐标 / 跟随玩家 |
| **飞行/移动** | `POST /api/fly/start / stop / jump / teleport / look / move / press …` | 精确控制机器人移动 |
| **指令工程** | `POST /api/mcfunction/execute / parse / stop、GET /api/mcfunction/status` | ★ 批量执行成千上万条指令（建筑模式的正规通道） |
| **命令方块导入导出** | `POST /api/cb/import/preview / start、/api/cb/export/scan / save` | 把 .mcfunction 铺成命令方块，或反向导出 |
| **建筑/预览** | `POST /api/building/voxel / analyze / stats、/api/preview/generate / zip / render-isometric` | 体素化、等距渲染、打包建筑 |
| **地图画** | `POST /api/mapart/preview、GET /api/mapart/preview` | 把图片铺成地图画 |
| **绘画** | `GET /api/draw/state / palette、POST /api/draw/stroke / apply / sync / undo / redo` | 在游戏里画画 |
| **相机/摄影** | `POST /api/camera/start / stop / generate / test、GET /api/camera/shots` | 自动给玩家拍分镜截图 |
| **音乐** | `POST /api/music/play / queue/add / note / loop、GET /api/music/status` | 让机器人演奏 MIDI |
| **皮肤** | `POST /api/skin/build、GET /api/skin/online-list / online-head / online-preview` | 皮肤相关 |
| **系统级** | `POST /api/system/restart、/api/cache/clear、/api/parse/cancel` | 重启 Prism、清缓存 |
| **多机编队** | `POST /api/fleet/connect / disconnect、GET /api/fleet/status` | 多台云手机协同 |

---

## 四、前端已验证的调用格式（照着填就行）

> 这些是从 Prism 自己的前端 JS 里逐条抽出来的，**参数名就是真名**，不是猜的。

### 账号 / 市场 / 系统

| 方法 | 路径 | 参数体 |
|---|---|---|
| `GET` | `/api/accounts` | `—` |
| `GET` | `/api/announcements` | `—` |
| `POST` | `/api/cache/clear` | `—` |
| `POST` | `/api/system/restart` | `—` |
| `GET` | `/api/toolbox/my-info` | `—` |
| `POST` | `/api/toolbox/my-info/update` | `{custom_prompt: val}` |
| `POST` | `/api/toolbox/purchase/name` | `—` |
| `POST` | `/api/toolbox/purchase/prompt` | `—` |
| `POST` | `/api/toolbox/start-trial` | `—` |
| `POST` | `/api/version/check` | `{}` |

### 其他

| 方法 | 路径 | 参数体 |
|---|---|---|
| `GET` | `/api/config` | `—` |
| `GET` | `/api/marquee/status` | `—` |
| `POST` | `/api/marquee/stop` | `{}` |
| `POST` | `/api/parse/cancel` | `—` |
| `POST` | `/api/push/ack` | `{ ids: [id] }` |
| `GET` | `/api/push/pending` | `—` |

### AI / 模型 / 会话

| 方法 | 路径 | 参数体 |
|---|---|---|
| `POST` | `/api/ai/answer` | `{req_id:reqID,answer:answer}` |
| `GET` | `/api/ai/models` | `—` |
| `DELETE` | `/api/ai/models` | `{name:name}` |
| `POST` | `/api/ai/models/fetch` | `{provider:prov,base_url:base,api_key:key}` |
| `POST` | `/api/ai/sessions` | `{name:__ai.sessionName,plugin_id:__ai.pluginId,messages:__ai.messages}` |
| `DELETE` | `/api/ai/sessions` | `{name:name}` |
| `POST` | `/api/ai/sessions/load` | `{name:name}` |
| `POST` | `/api/ai/sessions/rename` | `{old_name:oldName,new_name:n}` |
| `GET` | `/api/ai/skills` | `—` |
| `DELETE` | `/api/ai/skills` | `{id:id}` |
| `POST` | `/api/ai/skills` | `{id:id}` |
| `POST` | `/api/ai/snapshot` | `{name:name}` |
| `GET` | `/api/ai/snapshot` | `—` |
| `DELETE` | `/api/ai/snapshot` | `{name:name}` |
| `POST` | `/api/ai/snapshot/restore` | `{name:name}` |

### 机器人 / 游戏

| 方法 | 路径 | 参数体 |
|---|---|---|
| `POST` | `/api/bot/connect` | `{token:document.getElementById('cfg-token').value,server:document.getElementById('bot-server').value,use_new_p…` |
| `POST` | `/api/bot/console` | `{input:text}` |
| `POST` | `/api/bot/disconnect` | `—` |
| `GET` | `/api/bot/status` | `—` |
| `POST` | `/api/fleet/connect` | `—` |
| `POST` | `/api/fleet/disconnect` | `—` |
| `GET` | `/api/fleet/status` | `—` |
| `POST` | `/api/mcfunction/execute` | `{"content":"say hi","global":{},"groups":[],"tests":[]}` ★ content 必须是**字符串**（多行用 \n 分隔），传数组会回「无效JSON」 |
| `POST` | `/api/mcfunction/parse` | `{"content":"say hi"}` ★ 同上，content 为字符串 |
| `GET` | `/api/mcfunction/status` | `—` |
| `POST` | `/api/mcfunction/stop` | `{}` |
| `GET` | `/api/players/list` | `—` |

### 建筑 / 预览 / 地图画

| 方法 | 路径 | 参数体 |
|---|---|---|
| `POST` | `/api/building/voxel` | `{path:impPath}` |
| `POST` | `/api/draw/apply` | `{}` |
| `POST` | `/api/draw/close` | `{}` |
| `GET` | `/api/draw/palette` | `—` |
| `POST` | `/api/draw/redo` | `{}` |
| `GET` | `/api/draw/state` | `—` |
| `POST` | `/api/draw/stroke` | `{ points: uniq }` |
| `POST` | `/api/draw/sync` | `{}` |
| `POST` | `/api/draw/undo` | `{}` |
| `POST` | `/api/itemmaker/generate` | `{     items: items,     x: pos.x, y: pos.y, z: pos.z   }` |
| `POST` | `/api/mapart/preview` | `{     path:path,targetW:tw,targetH:th,     orientation:document.getElementById('ma-ori').value,     use_relief…` |
| `POST` | `/api/preview/generate-gif` | `{       path: task.path,       frames: task.frames,       delay: 5     }` |
| `POST` | `/api/preview/save-image` | `{         path: imgPath,         data: base64data       }` |
| `POST` | `/api/preview/zip` | `{dir: previewState.output.dir}` |
| `POST` | `/api/preview/zip-building` | `{       dir: buildingDir,       name: buildingName     }` |

### 相机 / 皮肤 / 音乐

| 方法 | 路径 | 参数体 |
|---|---|---|
| `POST` | `/api/camera/clear` | `{}` |
| `POST` | `/api/camera/generate` | `{ player: camState.player, format: 'text' }` |
| `POST` | `/api/camera/shot/delete` | `{ shot_id: shotId }` |
| `POST` | `/api/camera/shot/update` | `{ shot_id: shotId, updates: updates }` |
| `GET` | `/api/camera/shots` | `—` |
| `POST` | `/api/camera/start` | `{ player: camState.player }` |
| `GET` | `/api/camera/status` | `—` |
| `POST` | `/api/camera/stop` | `{}` |
| `POST` | `/api/camera/test` | `{ shot_id: shotId, player: camState.player }` |
| `POST` | `/api/camera/test/all` | `{}` |
| `POST` | `/api/music/actionbar` | `{msg:'§e§l▍人工演奏中 §r§f···'}` |
| `POST` | `/api/music/loop` | `{mode:next}` |
| `POST` | `/api/music/next` | `—` |
| `POST` | `/api/music/note` | `{instrument:pianoInstrument,pitch:pitch,volume:1.0}` |
| `POST` | `/api/music/pause` | `—` |
| `POST` | `/api/music/play` | `{cache_key:muPath,target:document.getElementById('mu-target').getAttribute('data-value'),speed:parseFloat(docu…` |
| `POST` | `/api/music/prev` | `—` |
| `POST` | `/api/music/queue/add` | `{cache_key:muPath}` |
| `POST` | `/api/music/queue/clear` | `—` |
| `POST` | `/api/music/queue/remove` | `{index:idx}` |
| `POST` | `/api/music/resume` | `—` |
| `GET` | `/api/music/status` | `—` |
| `POST` | `/api/music/stop` | `—` |

### 命令方块

| 方法 | 路径 | 参数体 |
|---|---|---|
| `POST` | `/api/cb/export/save` | `{content:content,file_name:name}` |
| `POST` | `/api/cb/export/scan` | `{x1:x1,y1:y1,z1:z1,x2:x2,y2:y2,z2:z2}` |
| `POST` | `/api/cb/import/preview` | `{content:c}` |
| `POST` | `/api/cb/import/start` | `{     content:cbState.content,     start_x:x,start_y:y,start_z:z   }` |

### 寻路 / 移动

| 方法 | 路径 | 参数体 |
|---|---|---|
| `GET` | `/api/fly/position` | `—` |
| `GET` | `/api/fly/status` | `—` |

### 任务 / 节点

| 方法 | 路径 | 参数体 |
|---|---|---|
| `POST` | `/api/node/start` | `—` |
| `GET` | `/api/node/status` | `—` |
| `POST` | `/api/node/stop` | `—` |
| `POST` | `/api/task/delete` | `{task_id:id}` |
| `GET` | `/api/task/list` | `—` |
| `POST` | `/api/task/resume` | `{task_id:id}` |
| `POST` | `/api/task/start` | `{     type: 'import',     params: {       path: gen.path,       x: pos.x, y: pos.y, z: pos.z,       rotation: …` |
| `POST` | `/api/task/stop` | `{}` |

### 插件

| 方法 | 路径 | 参数体 |
|---|---|---|
| `POST` | `/api/plugin-market/install` | `{ id: String(id) }` |
| `POST` | `/api/plugin/config` | `{id:id,config:cfg}` |
| `POST` | `/api/plugin/create` | `{type:ptype,name:name,description:desc}` |
| `POST` | `/api/plugin/delete` | `{id:id}` |
| `POST` | `/api/plugin/disabled` | `{id:id, disabled:true}` |
| `POST` | `/api/plugin/export` | `{id:id}` |
| `POST` | `/api/plugin/export-saf` | `{id:id}` |
| `POST` | `/api/plugin/file/write` | `{id:id,scope:'docs',file:'',content:st.content.docs\|\|''}` |
| `POST` | `/api/plugin/import` | `{path:path}` |
| `GET` | `/api/plugin/list` | `—` |
| `POST` | `/api/plugin/meta` | `{id:id,name:name,description:desc}` |
| `POST` | `/api/plugin/reload` | `{id:id}` |

---

## 五、全部端点按类别

### 账号 / 市场 / 系统（30 个）

- `/api/accounts` ★已验证
- `/api/accounts/active`
- `/api/announcements` ★已验证
- `/api/cache/clear` ★已验证
- `/api/cache/clear/mcf-syntax`
- `/api/heartbeat/enable`
- `/api/integrity/check`
- `/api/market-proxy`
- `/api/market/categories`
- `/api/market/comments`
- `/api/market/contribute`
- `/api/market/download`
- `/api/market/files`
- `/api/market/my`
- `/api/market/parts`
- `/api/market/upload`
- `/api/market/upload/precheck`
- `/api/permission/storage`
- `/api/prism/aino`
- `/api/prism/login`
- `/api/prism/nuts`
- `/api/system/restart` ★已验证
- `/api/toolbox/my-info` ★已验证
- `/api/toolbox/my-info/update` ★已验证
- `/api/toolbox/nuts/balance`
- `/api/toolbox/purchase/extension`
- `/api/toolbox/purchase/name` ★已验证
- `/api/toolbox/purchase/prompt` ★已验证
- `/api/toolbox/start-trial` ★已验证
- `/api/version/check` ★已验证

### 其他（36 个）

- `/api/admin/nuts/adjustmissing`
- `/api/admin/nutsallow_anonymous`
- `/api/auth/login`
- `/api/auth/me`
- `/api/auth/nuts`
- `/api/config` ★已验证
- `/api/eventsx509`
- `/api/fly`
- `/api/map/display`
- `/api/map/grid`
- `/api/map/play`
- `/api/map/scan`
- `/api/map/stop`
- `/api/marquee/preview`
- `/api/marquee/start`
- `/api/marquee/status` ★已验证
- `/api/marquee/stop` ★已验证
- `/api/music-proxy`
- `/api/new`
- `/api/parse/cancel` ★已验证
- `/api/phoenix/login`
- `/api/phoenix/tan_lobby_create`
- `/api/phoenix/tan_lobby_loginenter`
- `/api/phoenix/transfer_check_num`
- `/api/phoenix/transfer_start_type`
- `/api/prism-proxy`
- `/api/push/ack` ★已验证
- `/api/push/pending` ★已验证
- `/api/repair/start`
- `/api/social/search`
- `/api/v1/harbor/mcrealms`
- `/api/v2/announcementsexec`
- `/api/v2/heartbeat/ackevents`
- `/api/v2/heartbeatcom`
- `/api/v2/version/check`
- `/api/world/enable`

### AI / 模型 / 会话（11 个）

- `/api/ai/answer` ★已验证
- `/api/ai/chat`
- `/api/ai/models` ★已验证
- `/api/ai/models/fetch` ★已验证
- `/api/ai/sessions` ★已验证
- `/api/ai/sessions/load` ★已验证
- `/api/ai/sessions/recent`
- `/api/ai/sessions/rename` ★已验证
- `/api/ai/skills` ★已验证
- `/api/ai/snapshot` ★已验证
- `/api/ai/snapshot/restore` ★已验证

### 机器人 / 游戏（17 个）

> ★ 2026-09-13 17:25 真机（本机一号 / v1.4）实测**写通道**：`POST /api/bot/console {"input":"say 你好"}` → `{ok:true,type:"chat"}`；
> `POST /api/mcfunction/execute {"content":"say test",...}` → `{ok:true}`。两条 POST 带 body 全部打通。

- `/api/bot/connect` ★已验证
- `/api/bot/console` ★已验证
- `/api/bot/disconnect` ★已验证
- `/api/bot/status` ★已验证
- `/api/fleet/connect` ★已验证
- `/api/fleet/disconnect` ★已验证
- `/api/fleet/status` ★已验证
- `/api/mcfunction/execute` ★已验证
- `/api/mcfunction/parse` ★已验证
- `/api/mcfunction/status` ★已验证
- `/api/mcfunction/stop` ★已验证
- `/api/mcfunction/syntax`
- `/api/players/list` ★已验证
- `/api/server/detail`
- `/api/server/find`
- `/api/server/owner`
- `/api/server/players`

### 建筑 / 预览 / 地图画（25 个）

- `/api/building/analyze`
- `/api/building/stats`
- `/api/building/voxel` ★已验证
- `/api/draw/apply` ★已验证
- `/api/draw/close` ★已验证
- `/api/draw/create`
- `/api/draw/custom`
- `/api/draw/mode`
- `/api/draw/palette` ★已验证
- `/api/draw/redo` ★已验证
- `/api/draw/state` ★已验证
- `/api/draw/stroke` ★已验证
- `/api/draw/sync` ★已验证
- `/api/draw/undo` ★已验证
- `/api/itemmaker/generate` ★已验证
- `/api/mapart/preview` ★已验证
- `/api/preview/cancel`
- `/api/preview/generate`
- `/api/preview/generate-gif` ★已验证
- `/api/preview/render-isometric`
- `/api/preview/save-image` ★已验证
- `/api/preview/scan`
- `/api/preview/status`
- `/api/preview/zip` ★已验证
- `/api/preview/zip-building` ★已验证

### 相机 / 皮肤 / 音乐（39 个）

- `/api/camera/clear` ★已验证
- `/api/camera/generate` ★已验证
- `/api/camera/pivot`
- `/api/camera/shot/delete` ★已验证
- `/api/camera/shot/delete/tmp/prism_shutdown`
- `/api/camera/shot/update` ★已验证
- `/api/camera/shots` ★已验证
- `/api/camera/start` ★已验证
- `/api/camera/status` ★已验证
- `/api/camera/stop` ★已验证
- `/api/camera/test` ★已验证
- `/api/camera/test/all` ★已验证
- `/api/media/preview`
- `/api/music/actionbar` ★已验证
- `/api/music/download`
- `/api/music/hot`
- `/api/music/loop` ★已验证
- `/api/music/next` ★已验证
- `/api/music/note` ★已验证
- `/api/music/pause` ★已验证
- `/api/music/play` ★已验证
- `/api/music/prev` ★已验证
- `/api/music/queue`
- `/api/music/queue/add` ★已验证
- `/api/music/queue/clear` ★已验证
- `/api/music/queue/remove` ★已验证
- `/api/music/resume` ★已验证
- `/api/music/status` ★已验证
- `/api/music/stop` ★已验证
- `/api/music/upload`
- `/api/skin/build`
- `/api/skin/head`
- `/api/skin/online-build`
- `/api/skin/online-head`
- `/api/skin/online-list`
- `/api/skin/online-preview`
- `/api/skin/online-previewgame`
- `/api/skin/preview`
- `/api/skin/voxel`

### 命令方块（5 个）

- `/api/cb/export/save` ★已验证
- `/api/cb/export/scan` ★已验证
- `/api/cb/import/preview` ★已验证
- `/api/cb/import/start` ★已验证
- `/api/cb/stats/preview`

### 文件（4 个）

- `/api/file/upload`
- `/api/files/read`
- `/api/files/scan`
- `/api/files/write`

### 寻路 / 移动（21 个）

- `/api/fly/down`
- `/api/fly/jump`
- `/api/fly/jump-start`
- `/api/fly/jump-stop`
- `/api/fly/look`
- `/api/fly/move`
- `/api/fly/position` ★已验证
- `/api/fly/press`
- `/api/fly/release`
- `/api/fly/sneak-start`
- `/api/fly/sneak-stop`
- `/api/fly/sprint-start`
- `/api/fly/sprint-stop`
- `/api/fly/start`
- `/api/fly/status` ★已验证
- `/api/fly/stop`
- `/api/fly/teleport`
- `/api/pathfinder/follow`
- `/api/pathfinder/goto`
- `/api/pathfinder/log`
- `/api/pathfinder/stop`

### 任务 / 节点（10 个）

- `/api/node/heartbeatreflect`
- `/api/node/register`
- `/api/node/start` ★已验证
- `/api/node/status` ★已验证
- `/api/node/stop` ★已验证
- `/api/task/delete` ★已验证
- `/api/task/list` ★已验证
- `/api/task/resume` ★已验证
- `/api/task/start` ★已验证
- `/api/task/stop` ★已验证

### 插件（26 个）

- `/api/plugin-market-proxy`
- `/api/plugin-market/categories`
- `/api/plugin-market/comments`
- `/api/plugin-market/contribute`
- `/api/plugin-market/files`
- `/api/plugin-market/install` ★已验证
- `/api/plugin-market/installfill`
- `/api/plugin-market/my`
- `/api/plugin-market/upload/precheck`
- `/api/plugin/api-doc`
- `/api/plugin/config` ★已验证
- `/api/plugin/create` ★已验证
- `/api/plugin/data`
- `/api/plugin/delete` ★已验证
- `/api/plugin/disabled` ★已验证
- `/api/plugin/export` ★已验证
- `/api/plugin/export-saf` ★已验证
- `/api/plugin/file/read`
- `/api/plugin/file/write` ★已验证
- `/api/plugin/import` ★已验证
- `/api/plugin/list` ★已验证
- `/api/plugin/meta` ★已验证
- `/api/plugin/reload` ★已验证
- `/api/plugin/run`
- `/api/plugin/stop`
- `/api/plugin/wordbank-doc`

---

## 六、怎么用（三种入口）

1. **MCP 网址**（外部 AI 用）

   **★ 强烈建议在末尾加上 `&agent=<你的名字>`，这样你会拿到一个编号，
   管理员就能在游戏里点名找你：**
   ```
   https://ai-api.youyuanqi.dpdns.org/mcp?key=<平台密钥>&agent=codex
   ```
   连上后 `initialize` 会直接告诉你「你是 N 号」以及现在谁在线。

   14 个工具：`prism_rest` 是主通道，`prism_status` 用来诊断，
   `bot_keeper` 管机器人连接（掉线自动重连），
   `ai_assist_context` 提供 AI帮写 的系统提示词和技能知识库（改插件必读），
   **`agent_inbox` 收游戏里的口信 + `agent_me` 查自己是几号**（见下面第七节），
   `prism_chat`/`prism_tool` 是走内置 AI 的旧通道（不推荐）。
2. **命令行**（我调试用）
   `python tools/mcp.py rest /api/bot/status`
   `python tools/mcp.py rest /api/bot/console POST '{"input":"你好"}'`
3. **控制台网页**：https://prism-console-7v1.pages.dev/
   页面：聊天 / 抓包 / 设备 / 模型 / AI接入 / **名单** / **电脑** / 提示词 / 设置

---

## 七、★ AI Agent 编号路由（多人协作不抢活）

可能同时有好几个 AI 连着，每个人一个**固定编号**（首次出现顺序，永久保留）。

| 游戏聊天框输入 | 谁收到 |
|---|---|
| `AI Agent 2 把钻石剑降到 50 积分` | **只有 2 号** |
| `AI Agent 把钻石剑降价` | 广播，所有在线的 |
| `.AIAgent列表` | 查看名单（编号/在线/类型/心跳） |

**云端 API**

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/agent/registry` | 列出全部，`?only=1` 只要在线 |
| POST | `/api/v1/agent/registry` | `{kind,name,label,meta}` 登记/心跳，返回编号 |
| POST | `/api/v1/agent/inbox` | 加 `agent_no` 字段就是点名 |
| GET | `/api/v1/agent/inbox?agent_no=2` | 只取广播 + 点名 2 号的 |

三类 agent：`mcp`（外部 AI，靠心跳，2 分钟判离线）、`model`（云端模型，常驻）、
`pc`（电脑上的 CLI，由 `tools/pc_agent.py` 注册）。

**真机验证过**：1 号能看到广播 + 点名自己的；2 号看不到点名 1 号的那条。
点名一个离线的号，插件会提示玩家而不是静默丢弃。

## 八、★ 手机遥控电脑（PC 桥）

电脑上跑 `python tools/pc_agent.py`（或双击 `启动电脑端.bat`），
手机控制台 →「电脑」页就能开会话让它跑 Codex / Claude Code / Gemini / shell，
输出实时回传，还能传文件过去。**电脑是拨出去的，不需要公网 IP、不用开端口。**

| 方法 | 路径 | 谁用 |
|---|---|---|
| GET/POST | `/api/v1/pc/sessions` | 手机列/开会话 |
| POST | `/api/v1/pc/poll` | **电脑**领活（长轮询） |
| POST | `/api/v1/pc/claim` | **电脑**领走会话 |
| POST | `/api/v1/pc/output` | **电脑**回传输出 |
| POST | `/api/v1/pc/input` | 手机追问 |
| POST | `/api/v1/pc/upload` | 手机传文件（≤1.5MB） |
| GET | `/api/v1/pc/messages?session_id=&since=` | 手机看输出 |

会话状态：`pending`（等电脑领）→ `running` → `done` / `error`。
一直是 `pending` = 电脑上 `pc_agent.py` 没在跑。

---

生成脚本：`tools/gen_capability_doc.py`（端点表变了重跑即可）
