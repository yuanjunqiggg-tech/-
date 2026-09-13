# Prism 工具箱 · 插件开发文档

本文档面向想要为 Prism 工具箱编写 Lua 插件的开发者。它从零讲清插件是什么、如何组织、能调用哪些 API，以及如何写出复杂且稳定的插件。**第四章是函数总参考**——每个函数都说明：它干什么、怎么调用、参数是什么类型、返回什么、会抛什么错、底层是怎么实现的。游戏操作类函数的"底层"会讲清它在游戏里**实际执行的指令/数据包**、以及如何从响应里取结果，而不只是内部函数名。

---

## 一、插件到底是什么

一个 Prism 插件就是一段 **Lua 脚本**，运行在工具箱内置的 Lua 解释器中。它通过一串全局对象（`game`、`system`、`api`、`plugin`、`util`、`bot`、`building`、`media`、`world`、`player`、`events`、`http`、`web`）与机器人、游戏、系统交互。

插件不是独立进程，也不是独立文件系统。它被打包成一个 **zip 压缩包**，由工具箱解包、扫描、加载。它运行的环境与宿主 Go 程序共享进程，因此能直接调用机器人连接、读写游戏数据、甚至经 Shizuku 执行系统命令——这是它强大的地方，也意味着你要对资源使用负责。

插件有两个层级的能力：
1. **游戏内能力**：发指令、读玩家数据、操作方块、控制机器人移动、播放音乐、放置建筑等。
2. **框架能力**：跨插件调用、事件监听、后台定时任务、持久化配置与数据、HTTP 网络请求、Shizuku 系统调用、网页。

---

## 二、插件的目录结构与打包格式

每个插件在工具箱里拥有**三个独立的目录**，互不混淆。插件的 id（唯一标识，如 `core_utils`、`territory`）决定这三个目录的名字。

- `插件文件` 目录存放**代码本体**。每个插件有一个以 id 命名的子目录，里面放着代码文件、元数据文件和说明文档。例如 `插件文件/territory/` 下有 `territory.lua`（代码）、`territory.manifest.json`（元数据）、`territory.docs.md`（说明）。
- `插件配置文件` 目录存放**设置**。每个插件有一个以 id 命名的子目录，里面是 `<id>.json` 这个配置文件。该文件由工具箱在插件运行时自动创建，初始为 `{}`。插件用 `game.getConfig` 读取、`game.setConfigDefault` 写入默认值。
- `插件数据文件` 目录存放**运行数据**——需要持久化的业务数据（金钱、领地、商店商品）。每个插件有一个以 id 命名的子目录，插件可自由在里面创建任意文件。

### 打包成 zip

zip 里的结构是扁平的三（或四）个文件：

- `manifest.json` —— 插件的元数据，必填。
- `main.lua` —— 插件的代码，必填（词库类插件则是 `词库.json`）。
- `docs.md` —— 插件的说明文档，可选。
- `config.json` —— 插件默认配置，可选；导入时写入配置文件。

`manifest.json` 字段（均用英文键名）：

- `id`：插件唯一标识，只允许用英文/数字/下划线，一旦确定不要更改。它决定三个目录的名字，也是跨插件调用时的名称。
- `name`：插件的展示名，中文可以。
- `version`：版本号，形如 `1.0.0`。其它插件可用它做前置版本校验。
- `type`：插件类型，写 `lua`。
- `author`：作者名。
- `description`：一句话功能简介。
- `pre_plugins`：前置依赖。一个对象，键是所依赖的插件 id，值是最低版本号。没有依赖写空对象 `{}`。

一个最小 manifest 示例：

```json
{
  "id": "my_plugin",
  "name": "我的插件",
  "version": "1.0.0",
  "type": "lua",
  "author": "me",
  "description": "一个示例插件",
  "pre_plugins": {}
}
```

依赖语义：**加载本插件之前，工具箱会先加载并运行被依赖的前置插件**。若前置插件不存在或版本不足，本插件加载失败并被标记为错误状态，不会拖垮整个框架。

### 安装与导入

把 zip 放到插件的 `插件文件` 目录，或在插件管理页选择该 zip 导入。导入后工具箱自动解包并把文件写入对应位置。之后在插件管理页点"运行"，插件就加载生效了。

---

## 三、插件的加载与生命周期

当你运行一个插件时，工具箱按顺序做了这些事：

1. **解析前置依赖**。若声明了 `pre_plugins`，先递归加载并运行每个前置插件，保证被依赖插件的代码与数据就绪。
2. **创建配置文件与数据目录**。确保 `插件配置文件/<id>/<id>.json` 存在（没有就写成 `{}`），确保 `插件数据文件/<id>/` 目录存在。
3. **读取代码**，把代码放进一个全新的 Lua 状态里执行。

关键概念：**插件源码会在多个场合被"重新执行"**。不仅仅加载时执行一次，每当有事件触发、定时任务到期、聊天触发词命中、或别的插件跨插件调用它时，工具箱都会**新建一个 Lua 状态、重新执行一遍插件源码**，再调用对应函数。

好处：每个执行上下文隔离，天然线程安全；插件源码是"无状态加载 + 每次重跑重建"，行为可预测。

代价：

- 每次重跑都会重新定义全局函数、重新执行顶层代码。**不要在顶层做昂贵或重复副作用的事情。**
- 顶层的注册调用（如 `game.registerTrigger`、`events.onChat`、`util.schedule`）在重跑时会被工具箱自动跳过，避免重复注册。内部用一个 `__RE_RUN__` 标记区分"首次加载"和"重跑执行"。**你不需要手动处理这个标记**。
- 持久化数据必须放文件里（配置文件或数据目录），不能指望全局变量跨调用存活——全局变量在每次重跑时都会重置。

### 运行时限制与保护

- **单次执行超时 2 分钟**。一次加载/触发/事件/定时回调，从进入 Lua 到返回最多 2 分钟，超时被强制中断并记日志。死循环不会卡死机器人，但会中断报错。
- **定时任务间隔必须在 0.001 秒 ~ 1 年之间**（`util.schedule`）；`util.setTimeout` 延时必须在 0 ~ 1 年之间。填 0 或负数会直接报错。
- **并发上限**：同一时刻最多 32 个触发词/事件 handler 在执行，超出排队。玩家刷屏时有背压。
- **HTTP 响应体上限 10MB**。`game.httpGet/httpPost` 与 `http.*` 拉取超过 10MB 的响应会报错。

---

## 四、全局 API 函数详解

**全局对象一览**：`game`（游戏操作）、`system`（系统/设备）、`api`（跨插件）、`plugin`（插件自身）、`util`（工具/定时）、`bot`（多机器人）、`building`（建筑）、`media`（媒体）、`world`（世界方块）、`player`（玩家数据）、`events`（事件）、`http`（网络）、`web`（网页）。

**通用约定（读前必看）**：

- **多数读操作在出错时会抛 Lua 异常**（不是返回 `nil`），要用 `pcall` 包裹才能容错。例外：`game.promptChoice` 超时/取消返回 `nil`；`player.get`/`player.getXUID` 等查不到的玩家返回空表/空串/`0`。
- 部分函数依赖全局 `__PLUGIN_ID__`（当前插件 id）。在"无插件上下文"的裸环境调用时它们会降级（返回默认值/空串/直接返回），正常插件加载时总可用。
- 机器人相关调用（`game.*`、`world.block`、`player.getInventory`）操作的是**当前活跃机器人**，用 `bot.select` 切换。
- 触发词、事件、定时、跨插件调用、网页动作，都是"**重跑插件源码后按函数名调用 handler**"。所以 handler 必须在全局作用域定义。
- **"底层"栏说的是游戏内实际发生的事**：对游戏操作类函数，它说明工具箱向游戏发了哪条指令/哪个数据包、服务器怎么响应、结果从响应的哪里读。据此你能预判副作用（如 `getBlockTile`/`getBlockData` 会传送机器人加载区块）、定位失败原因（指令需要 OP、区块未加载、网易服不返回结果），也可以自己在游戏里手动敲同样的指令复现。

---

### 4.1 game —— 游戏操作主入口

`game` 是使用最频繁的对象：发指令、读数据、菜单交互、配置、网络、控制机器人移动。下列方法多数操作"当前活跃机器人"。

#### 指令与消息

**`game.sendCommand(cmd)`**
- 作用：发送一条游戏指令（等价于游戏内执行 `/cmd`），只发不等待结果。
- 参数：`cmd` — string，必填。
- 返回：无。
- 报错：若 sendCommandHook 返回错误则抛 `sendCommand: <err>`。
- 底层：通过**网易 AI 命令通道**（PyRpc `ExecuteCommandEvent`，命令自动加 `execute run` 前缀）发送指令，不等响应。实际就是在游戏内敲了 `/cmd`。注意：需要 OP 的指令若机器人无 OP，指令会发出但**不生效也不报错**。

**`game.sendTargeted(player, text)`**
- 作用：只给指定玩家发一条消息，不广播给其他人。`§` 前缀可带颜色（如 `"§a成功！"`）。
- 参数：`player` string 必填；`text` string 必填。
- 返回：无。
- 报错：无（底层错误被忽略）。
- 底层：通过**网易 AI 命令通道**（PyRpc `ExecuteCommandEvent`，命令自动加 `execute run` 前缀）发定向 tellraw：`tellraw @a[name="<玩家>"] {"rawtext":[{"text":"..."}]}`。只发给该玩家、绝不广播；用 `@a[name=...]` 选择器是为了兼容网易服（普通通道在网易不执行）。

**`game.sendChat(target, message)`**
- 作用：给指定玩家或选择器（如 `@a`）发一条聊天消息。
- 参数：`target` string 必填；`message` string 必填。
- 返回：无。
- 报错：失败抛 `sendChat: <err>`。
- 底层：通过网易 AI 命令通道发 `tellraw <target> {"rawtext":[{"text":"..."}]}`（target 为 `@a` 或玩家名），文本里的 `"` 会自动转义。

**`game.sendRichTellraw(msg)`**
- 作用：发送原生 tellraw 富文本（支持 JSON 样式），常用于公告。
- 参数：`msg` string 必填。
- 返回：无。
- 报错：失败抛 `sendRichTellraw: <err>`。
- 底层：通过网易 AI 命令通道发 `tellraw @a {"rawtext":[{"text":"..."}]}`，`msg` 里的 `"` 自动转义后嵌入 JSON。

**`game.sendLines(player, text, maxLines)`**
- 作用：把长文本**按换行逐条发送**，避免单条超长被截断、或某行含敏感词整段被拦。超行数时先提示"仅显示前 N 行"。空行跳过。
- 参数：`player` string 必填；`text` string 必填；`maxLines` number 可选，默认 50。
- 返回：无。
- 报错：无。
- 底层：把长文本按 `\n` 切分，逐行用 `sendTargeted` 的定向 tellraw 机制发送；超过 `maxLines` 先提示"仅显示前 N 行"，空行跳过。

**`game.sendPacket(typeNameOrId, fieldsTable)`**
- 作用：发送**任意数据包**（客户端→服务器），用于发起协议交互/测试协议。与 `events.subscribeAll` / AI `wait_packet` 监听形成闭环（发请求包 → 监听服务器响应）。
- 参数：`typeNameOrId` string（包类型名，如 `"RequestChunkRadius"`）**或** number（包协议 ID）；`fieldsTable` table 可选，snake_case 字段（如 `{chunk_radius=4, max_chunk_radius=8}`）。复合字段格式：数字数组（Vec3/BlockPos）、hex 字符串（UUID/字节数组）、Bitset 用比特位数组（如 `{input_data={1,2}}`）。发原始字节：`game.sendPacket(69, {payload_hex="0102ff"})`。
- 返回：无。
- 报错：失败抛 `sendPacket: <err>`（未知类型/未知字段/字段类型不符/未连接）。握手/生命周期专用包（Login、ClientToServerHandshake 等）已列入禁止，发送会报错。
- 底层：`mapToPacket`（packet_send.go，packetToMap 的逆反射填充）→ `abot(L).WritePacket(pk)` → `conn.WritePacket`（自动 header/批次/压缩加密）。字段结构可用 AI `list_packet_schema` 工具查询。

#### AI 组合工具（执行 + 等待）

AI 侧新增三个组合工具（用于"发指令后观察结果/包/聊天"的闭环；Lua 插件可自行用 `game.sendPacket` + `events.subscribeAll` 实现等价逻辑）：

- `send_command_wait_output`：执行指令并等待服务器响应（CommandOutput），返回 `{success,is_timeout,note,output_messages:[{success,message,parameters}],raw}`。参数 `command`（必填）、`channel`（ai/console/player，默认 ai）、`timeout` 秒（默认 8，上限 30）、`bot_index`。
- `run_and_watch_packet`：先执行指令（可选），再监听接下来一段时间的入站数据包（含 CommandOutput/未知包），返回事件数组。参数 `command`（可选）、`packet_type`/`packet_id`/`bot_index` 过滤、`seconds`(1-60)、`max_count`。
- `run_and_watch_chat`：先执行指令（可选），再监听接下来一段时间的聊天，返回 `[{player,message}]`。参数 `command`（可选）、`keyword`（可选过滤）、`seconds`、`max_count`。

**`game.sendTitle(target, title, subtitle)`**
- 作用：给玩家显示大标题 + 副标题。
- 参数：`target`/`title`/`subtitle` 均 string 必填。
- 返回：无。
- 报错：失败抛 `sendTitle: <err>`。
- 底层：通过网易 AI 命令通道发 `titleraw <target> title {"rawtext":[{"text":"..."}]}`；副标题非空时再追加一条 `titleraw <target> subtitle {"rawtext":[...]}`。

**`game.sendActionbar(target, text)`**
- 作用：给玩家显示动作栏消息（物品栏上方那行）。
- 参数：`target`/`text` string 必填。
- 返回：无。
- 报错：失败抛 `sendActionbar: <err>`。
- 底层：通过网易 AI 命令通道发 `titleraw <target> actionbar {"rawtext":[{"text":"..."}]}`。

**`game.isCmdSuccess(cmd)`**
- 作用：执行一条指令并判断是否成功，返回布尔。
- 参数：`cmd` string 必填。
- 返回：boolean（是否成功）。
- 报错：失败抛 `isCmdSuccess: <err>`。
- 底层：通过 **WS 自动化通道**执行指令并**等待 CommandOutput**，命令响应的 `SuccessCount > 0` 即视为成功。无 OP 或语法错误的指令，服务器返回失败输出，此函数返回 `false`。

#### 读取玩家与游戏数据

**`game.getScore(scoreboard, target)`**
- 作用：读某记分板里某个目标（玩家名）的分数。
- 参数：`scoreboard` string 必填；`target` string 必填。
- 返回：number（分数）。
- 报错：失败抛 `getScore: <err>`。
- 底层：通过 **WS 自动化通道**执行 `scoreboard players test <目标> <记分板> 0 0`（借用"分数是否在 0~0 之间"的判断把分数值带出来）并等待 CommandOutput，从响应的 `Parameters[0]` 读出分数。响应是 `commands.scoreboard.objectiveNotFound`（计分板不存在）、`...players.list.player.empty`（目标不存在）或 `...players.score.notFound`（目标在该记分板无分数）时，分别报对应错误。

**`game.getMultiScore(target)`**
- 作用：读某目标在所有记分板上的分数。
- 参数：`target` string 必填。
- 返回：table，结构 `{player = {记分板名 = 分数, ...}}`。
- 报错：失败抛 `getMultiScore: <err>`。
- 底层：通过 **WS 自动化通道**执行 `scoreboard players list <目标>` 并等待 CommandOutput，把响应里逐条输出的"玩家·记分板·分数"（`commands.scoreboard.players.list.player.entry` 行）解析成 `{玩家 = {记分板 = 分数}}`。

**`game.setScore(board, target, score)`**
- 作用：写入记分板，执行 `scoreboard players set`。
- 参数：`board` string、`target` string、`score` number 均必填。
- 返回：无。
- 报错：失败抛 `setScore: <err>`。
- 底层：拼指令 `scoreboard players set <target> <board> <score>`，通过**网易 AI 命令通道**发出，不等响应。

**`game.getPlayerPos(target)`**
- 作用：读玩家坐标与所在维度。
- 参数：`target` string 必填（可为玩家名或 `@a`/`@p` 选择器）。
- 返回：table `{x, y, z, dimension}`。
- 报错：失败抛 `getPlayerPos: <err>`。
- 底层：通过 **WS 自动化通道**执行只读命令 `querytarget <目标>` 并等待响应，解析返回的坐标（玩家脚部位置）并修正成可读值：正数向下取整到两位小数、负数先减 1、Y 再减 1.62（眼睛高度）；俯仰角 pitch 从工具箱维护的玩家缓存补取。`querytarget` 无副作用。

**`game.getPlayerPosXYZ(target)`**
- 作用：读玩家坐标，直接返回三个数字。
- 参数：`target` string 必填。
- 返回：三个 number，依次 x、y、z。
- 报错：失败抛 `getPlayerPosXYZ: <err>`。
- 底层：同 `getPlayerPos`——执行 `querytarget` 后只取返回坐标的 x、y、z 三个数。

**`game.getPlayerItem(target, item, specialID)`**
- 作用：统计玩家背包里某种物品的数量，可带特殊数据 ID。
- 参数：`target` string、`item` string 必填；`specialID` number 可选，默认 0。
- 返回：number（数量）。
- 报错：失败抛 `getPlayerItem: <err>`。
- 底层：通过 **WS 自动化通道**执行游戏指令 `clear <目标> <物品> <特殊值> 0` 并等待 CommandOutput。**第 4 个参数 `0` 是游戏的"只统计不清除"技巧**——`clear` 的数量参数为 0 时不会真的清空物品，只报告玩家拥有多少这种物品（标准做法，可放心用于查数量）。响应为 `commands.clear.success` 时从输出的数量参数得到该物品数量；`commands.clear.failure.no.items`（玩家根本没有这种物品）返回 0；`commands.generic.syntax`（物品 ID 非法）报错。

**`game.getBlockTile(x, y, z)`**
- 作用：读某坐标的方块名。用安全版：可能先把机器人传送过去加载区块再查，避免远处区块"未加载"报错，因此有移动副作用。
- 参数：`x`/`y`/`z` number 必填。
- 返回：string（方块名/方块 ID）。
- 报错：失败抛 `getBlockTile: <err>`。
- 底层：**有移动副作用**：机器人先 `tp` 到目标上方高空（y=150）把该 x,z 的区块加载出来（`testforblock` 只对已加载区块有效，远处直接查会返回 `outOfWorld`），等游戏刻 + 约 400ms 区块就绪后查询，最后传送回原位。查询本身通过 WS 自动化通道执行 `testforblock <x> <y> <z> air`：`SuccessCount > 0` → 该坐标是空气；否则从命令失败输出里解析实际方块名（兼容网易版的参数偏移）。应在独立后台协程中调用（会传送并等待）。

**`game.getBlockTileRaw(x, y, z)`**
- 作用：直接查询方块，不做传送加载（更快，但区块未加载可能报错）。
- 参数：`x`/`y`/`z` number 必填。
- 返回：string（方块名）。
- 报错：失败抛 `getBlockTileRaw: <err>`。
- 底层：通过 WS 自动化通道执行 `testforblock <x> <y> <z> air`：`SuccessCount > 0` → 空气；否则从失败输出解析实际方块名。**不做传送**，远区块可能因未加载返回 `outOfWorld` 报错。

**`game.getTickingAreaList()`**
- 作用：读当前加载的常驻区域（ticking area）列表。
- 参数：无。
- 返回：table `{区域名 = {dimension, start_x, start_z, end_x, end_z}}`。
- 报错：失败抛 `getTickingAreaList: <err>`。
- 底层：通过 **WS 自动化通道**执行 `tickingarea list all-dimensions` 并等待响应，把命令返回的多行文本输出（每维度一组，每组里 `- 名称: (startX, startZ) to (endX, endZ)`）解析成结构化表。

**`game.queryInventory(selector)`**
- 作用：查询玩家背包物品清单。
- 参数：`selector` string 必填。
- 返回：table `{items = {{name, count, slot, damage}, ...}}`。
- 报错：失败抛 `queryInventory: <err>`。
- 底层：通过 WS 自动化通道执行网易特有的 `codebuilder_actorinfo inventory <选择器>` 并等待响应，从命令响应的 DataSet（JSON）里解析出 `{name, count, slot, damage}` 物品清单。需要机器人具备网易 AI/指令权限。

**`game.getTarget(selector)`**
- 作用：解析选择器，返回匹配的玩家名数组。
- 参数：`selector` string 必填。
- 返回：table（玩家名字符串数组，1 起索引）。
- 报错：失败抛 `getTarget: <err>`。
- 底层：通过 **WS 自动化通道**执行 `testfor <选择器>` 并等待响应，把输出参数里逗号分隔的玩家名列表解析成数组。选择器语法错误（`commands.generic.syntax`）时报错；无匹配返回空表。

**`game.setEffect(player, effect, duration, level, particles)`**
- 作用：给玩家施加药水效果。
- 参数：`player` string、`effect` string、`duration` number、`level` number 必填；`particles` boolean 可选，默认 `true`。
- 返回：无。
- 报错：失败抛 `setEffect: <err>`。
- 底层：通过 **WS 自动化通道**执行 `effect <玩家> <效果> <时长秒> <等级> <是否显示粒子>` 并等待响应，响应 `commands.effect.success` 才算成功。`commands.generic.noTargetMatch`（没有匹配目标）时报错；等级上限 255、时长上限 1000000 秒，超出直接报错。

#### 方块 NBT / 方块状态 读写

> 这组函数让插件（和 AI）能**读取**与**写入**游戏内方块的完整数据，包括方块实体 NBT（命令方块指令、箱子物品、告示牌文字、旗帜图案）和方块状态（朝向/开关/是否点亮等）。
> 读取统一基于"结构保存"（structure save）机制，一次读取即可同时拿到 名称 + 状态 + NBT。
> 底层实现在 `nbt_world_api.go`；**AI 通过 `game_call` 工具也能调用同样的能力**（函数名一致）。

**`game.getBlockData(x, y, z)`**
- 作用：读某坐标方块的完整数据（名称 + 方块状态 + 方块实体 NBT）。读取命令方块指令、箱子物品、告示牌文字、旗帜图案等都从这里入手。会先把机器人传送过去加载区块（有移动副作用）。
- 参数：`x`/`y`/`z` number 必填。
- 返回：table `{name = 方块名, states = {状态键 = 值, ...}, nbt = {NBT 键 = 值, ...}}`（无 NBT 时 `nbt` 省略）。
- 报错：失败抛 `getBlockData: <err>`。
- 底层：传送加载区块后，用游戏的**结构保存**机制读取：先通过 WS 自动化通道执行 `structure save "<随机名>" <区域>` 把该方块连同方块实体 NBT 存成一个临时结构，再发 `StructureTemplateDataRequest`（ExportFromSave）把结构数据拉回来，解析 `block_palette`（名称+状态）与 `block_position_data`（NBT）得到完整数据。有移动副作用。

**`game.getBlockNBT(x, y, z)`**
- 作用：只读方块实体 NBT。命令方块指令在 `nbt.Command`，箱子物品在 `nbt.Items`，告示牌文字在 `nbt.FrontText.Text`。
- 参数：`x`/`y`/`z` number 必填。
- 返回：table，无 NBT 时返回 `nil`。
- 报错：失败抛 `getBlockNBT: <err>`。
- 底层：同 `getBlockData` 的结构保存机制（传送 + `structure save` + `StructureTemplateDataRequest`），只保留解析出的 NBT 部分。有移动副作用。

**`game.getBlockState(x, y, z)`**
- 作用：读方块名称与方块状态（朝向/是否点亮/开关等），不含 NBT。
- 参数：`x`/`y`/`z` number 必填。
- 返回：table `{name = 方块名, states = {...}}`。
- 报错：失败抛 `getBlockState: <err>`。
- 底层：同 `getBlockData` 的结构保存机制，只保留名称与方块状态，丢弃 NBT。有移动副作用。

**`game.getRegionBlockData(x, y, z, sx, sy, sz)`**
- 作用：读一块区域（起点 `x,y,z`，尺寸 `sx×sy×sz`）所有方块的名称+状态+NBT，一次结构保存返回，适合整片区域/区块探查。
- 参数：6 个 number 均必填，尺寸需为正。
- 返回：table，键为 `"x,y,z"` 绝对坐标，值为 `{name, states, nbt}`。
- 报错：失败抛 `getRegionBlockData: <err>`。
- 底层：机器人先传送到区域中心上方加载区块，再**一次结构保存**（`structure save` + `StructureTemplateDataRequest`）把整片区域拉回，按 `block_indices` 线性索引还原成 `"x,y,z"` → 方块数据的映射。有移动副作用。

**`game.setBlock(x, y, z, name, states)`**
- 作用：放置一个普通方块，可带方块状态字符串。
- 参数：`name` string 必填；`states` string 可选（如 `["facing_direction"=3]`，默认空）。
- 返回：无。
- 报错：失败抛 `setBlock: <err>`。
- 底层：通过**网易 AI 命令通道**发 `setblock <x> <y> <z> <方块> <states>`（PyRpc `ExecuteCommandEvent`，权限比普通命令通道高，在网易租赁服更可靠），发完稍等片刻返回。

**`game.placeNBTBlock(x, y, z, name, states, nbtTable)`**
- 作用：放置一个带 NBT 的特殊方块（命令方块/结构方块/告示牌/箱子/旗帜等），自动按方块类型选择最快可靠的放置方式：
  - 命令方块：`{Command = "say hi", Conditional = 1, TickDelay = 0}`；
  - 告示牌：`{FrontText = {Text = "你好", Color = "black"}, ...}`；
  - 箱子：`{Items = {{Count = 1, Name = "minecraft:diamond", Slot = 0}, ...}}`。
- 参数：`name` string 必填；`states` string 可选；`nbtTable` table 可选。
- 返回：无。
- 报错：失败抛 `placeNBTBlock: <err>`。
- 底层：按 `building.ClassifyBlock` 对方块分类后选择不同游戏机制：命令方块/结构方块 → **直接发 NBT 包**（快）；告示牌 → 直接发 `PlaceSign` 包（快）；重 NBT 方块（箱子/旗帜等）→ 机器人**放到远程工作台 + 结构复制**（慢，需要结构权限）；普通方块 → `setblock` 指令。

**`game.setBlockState(x, y, z, statesTable)`**
- 作用：修改某方块的方块状态并保留原 NBT（如把命令方块设为条件模式、把方块朝向改朝北）。会先读当前方块，合并新状态后重新放置。
- 参数：`statesTable` table 必填，键 = 状态名，值 = 数值/布尔（如 `{conditional_bit = 1, facing_direction = 3}`）。
- 返回：无。
- 报错：失败抛 `setBlockState: <err>`。
- 底层：先按 `getBlockData` 的结构保存机制读回当前方块的名称、状态与 NBT，把新状态合并进去后，再按 `placeNBTBlock` 的方式**重新放置**该方块（保留原 NBT）。有移动副作用（需要传送读取）。

> **注意**：箱子/旗帜这类"重 NBT 方块"写入在网易下走远程工作台 + 结构复制，较慢且需要结构权限；命令方块/告示牌直接发包，快。读取和写入都会传送机器人加载区块，属正常副作用。

#### 玩家交互（菜单与输入）

**`game.showMenu(player, title, options)`**
- 作用：给玩家显示一个聊天栏菜单（标题 + 若干选项），只展示不等待。
- 参数：`player` string、`title` string 必填；`options` table（字符串数组）必填。
- 返回：无。
- 报错：无。
- 底层：通过网易 AI 命令通道给该玩家发**多条定向 tellraw**（绝不广播）：标题一条，每个选项一条 `§e序号. 选项文字`。

**`game.promptChoice(player, title, options, timeoutSec)`**
- 作用：显示菜单并**阻塞等待玩家选择**，返回所选选项下标。
- 参数：`player`/`title` string、`options` table 必填；`timeoutSec` number 可选，默认 30。
- 返回：number 或 nil。成功返回 **1 起** 下标（第一个是 1）；超时/取消/无效输入返回 `nil`。
- 报错：失败抛 `promptChoice: <err>`。
- 底层：先用 `showMenu` 把菜单发给玩家，再用 `waitMsg` 的机制**阻塞等待该玩家的下一条聊天消息**，把它解析成序号（支持 `1`、`1.`、`1、` 等写法）。超时或输入无效返回 `nil`。

**`game.waitMsg(player, timeoutSec)`**
- 作用：**阻塞等待玩家在聊天栏发一条消息**，返回内容。用于要输入（领地、数量等）。
- 参数：`player` string 必填；`timeoutSec` number 可选，默认 30。
- 返回：string（收到的消息）。超时返回 `nil`。
- 报错：失败抛 `waitMsg: <err>`。
- 底层：在机器人**收包循环**里为该玩家注册一个"等待通道"，玩家下一条聊天消息到达时投递给等待者。它**独占**该玩家的消息——同一玩家已有活跃等待会话时，新消息会被它消费掉，`onChat` 等其它 handler 收不到。

**`game.registerTrigger(wordsTable, handlerName)`**
- 作用：注册触发词。任一玩家发言命中任意词时，临时虚拟机**重跑插件源码**并调用全局函数 `handlerName(player, args)`。
- 参数：`wordsTable` table（字符串数组）必填；`handlerName` string（全局函数名）必填。
- 返回：无。
- 报错：无显式报错。
- 底层：在聊天触发注册表里登记触发词；此后任一玩家聊天消息命中触发词时，新建 Lua 状态重跑插件源码并调用 handler。重跑上下文自动跳过重复注册。

#### 配置与数据目录

**`game.getConfig(key, default)`**
- 作用：读本插件配置文件里某个键，缺失返回 `default`。
- 参数：`key` string 必填；`default` 任意类型可选。
- 返回：配置值（或 `default`）。
- 报错：无（读失败回退默认）。
- 底层：读取本插件配置文件 `插件配置文件/<id>/<id>.json`，命中则把值转成 Lua 返回，否则返回 `default`。依赖 `__PLUGIN_ID__`。

**`game.setConfigDefault(table)`**
- 作用：把配置文件中**缺失的键**写入默认值（已有的键不覆盖）。
- 参数：`table` 必填（键值任意类型）。
- 返回：无。
- 报错：无（写失败忽略）。
- 底层：先读 `插件配置文件/<id>/<id>.json`，把其中缺失的键补写进去（已存在的键不动）。依赖 `__PLUGIN_ID__`。

**`game.dataDir()`**
- 作用：返回本插件数据目录的完整路径，即 `插件数据文件/<id>/`。
- 参数：无。
- 返回：string。`__PLUGIN_ID__` 为空时返回空串。
- 报错：无。
- 底层：`pluginController.DataDir(id)`。

#### 网络与 JSON

**`game.httpGet(url)`**
- 作用：发起 HTTP GET 请求，返回响应体文本。
- 参数：`url` string 必填。
- 返回：string（响应体）。
- 报错：失败抛 `httpGet: <err>`。
- 底层：发起一次真实的 HTTP GET 请求，把响应体按 UTF-8 文本返回；网络错误或非 2xx 状态码都会抛错。

**`game.httpPost(url, body, headers)`**
- 作用：发起 HTTP POST 请求，可带自定义请求头。
- 参数：`url` string 必填；`body` string 可选，默认 `""`；`headers` table（键值均为 string）可选。
- 返回：string（响应体）。
- 报错：失败抛 `httpPost: <err>`。
- 底层：发起一次真实的 HTTP POST 请求（可带请求头与请求体），把响应体按 UTF-8 文本返回；网络错误或非 2xx 状态码都会抛错。

**`game.jsonEncode(v)`**
- 作用：把任意 Lua 值编码成 JSON 字符串。
- 参数：`v` 任意类型。
- 返回：string（JSON）。
- 报错：序列化失败抛 `jsonEncode: <err>`。
- 底层：把 Lua 值映射成对应的 JSON 类型（表→对象/数组、数字/字符串/布尔原样）后编码成字符串。

**`game.jsonDecode(s)`**
- 作用：把 JSON 字符串解析成 Lua 值。
- 参数：`s` string 必填。
- 返回：任意 Lua 值（表/数字/字符串/布尔）。
- 报错：解析失败抛 `jsonDecode: <err>`。
- 底层：把 JSON 解析成对应 Lua 类型（对象→表、数组→1 起索引的表、数字/字符串/布尔原样返回）。

> 这几个是挂在 `game` 上的轻量便捷方法；需要完整请求控制（超时、多种方法、错误码）时用 4.12 节的 `http` 模块。

#### 机器人移动与飞行（作用于当前活跃机器人）

**`game.teleport(x, y, z)`**
- 作用：传送机器人到绝对坐标。
- 参数：`x`/`y`/`z` number 必填。
- 返回：无。
- 报错：失败抛 `teleport: <err>`。
- 底层：发一个 `MovePlayer` 包（`MoveModeTeleport`）把机器人瞬间传送到目标坐标——**不是 `/tp` 指令**，是客户端传送包，服务器按传送处理。

**`game.move(dx, dy, dz)`**
- 作用：让机器人相对当前位置移动。
- 参数：`dx`/`dy`/`dz` number 必填。
- 返回：无。
- 报错：失败抛 `move: <err>`。
- 底层：在当前坐标上累加位移后发一个 `MovePlayer` 包（`MoveModeTeleport`），瞬间完成相对移动。

**`game.rotate(pitch, yaw, seconds?)`**
- 作用：设置机器人朝向。
- 参数：`pitch`/`yaw` number 必填；`seconds` number 可选——省略或 `0` 时**立即转到**目标角度，`>0` 时在 seconds 秒内**平滑转动**过去（yaw 走最短路径，如从 350° 转到 10° 只转 20°）。
- 返回：无。
- 报错：失败抛 `rotate: <err>`。
- 底层：只更新机器人本地视角状态，心跳（50ms）通过 `PlayerAuthInput` 包把新视角发送到服务器。秒数 `>0` 时先在本地逐帧插值，再由心跳带出中间帧。

**`game.jump()`**
- 作用：让机器人跳一下。
- 参数：无。
- 返回：无。
- 报错：失败抛 `jump: <err>`。
- 底层：模拟按一次跳跃键：置位跳跃标志让心跳携带跳跃输入，约 200ms 后自动松开。

**`game.sneakStart()` / `game.sneakStop()`**
- 作用：开始 / 停止潜行。
- 参数：无。
- 返回：无。
- 报错：失败抛 `sneakStart/sneakStop: <err>`。
- 底层：设置潜行标志，心跳持续携带潜行输入；`sneakStop` 额外发一个带 `StopSneaking` 标志的 `PlayerAuthInput` 包。

**`game.sprintStart()` / `game.sprintStop()`**
- 作用：开始 / 停止疾跑。
- 参数：无。
- 返回：无。
- 报错：失败抛 `sprintStart/sprintStop: <err>`。
- 底层：设置奔跑标志，心跳持续携带奔跑输入。

**`game.flyStart()` / `game.flyStop()`**
- 作用：开始 / 停止飞行。
- 参数：无。
- 返回：无。
- 报错：失败抛 `flyStart/flyStop: <err>`。
- 底层：把机器人切换为飞行/降落：优先走游戏接口的飞行控制（运动能力包），不可用时回退为发送带飞行标志的 `PlayerAuthInput` 包。

**`game.stopMove()`**
- 作用：停止机器人当前移动。
- 参数：无。
- 返回：无。
- 报错：失败抛 `stopMove: <err>`。
- 底层：关闭持续移动的本地循环并清空移动输入标志，心跳随之不再携带方向输入。

**`game.getBotPos()`**
- 作用：读取当前活跃机器人自身坐标。
- 参数：无。
- 返回：table `{x, y, z}`。
- 报错：无。
- 底层：通过 WS 自动化通道执行只读命令 `querytarget @s` 并解析坐标、朝向、维度；pitch 与飞行/疾跑状态取本地缓存。

---

### 4.2 system —— 系统与设备交互

`system` 的函数（除 `platform` 外）都通过 JNI 桥**同步**调用 Android 原生能力。桌面环境不支持，会返回错误 `"桌面环境不支持系统交互"`。`system.shell` 需要 Shizuku 授权。

**`system.platform()`**
- 作用：返回当前运行平台。
- 参数：无。
- 返回：string——`"android"` 或 `"desktop"`。
- 报错：无。
- 底层：`getPlatformName()`（不经 JNI 桥）。

**`system.call(method, paramsTable?)`**
- 作用：通用底层透传——把 `method` 和参数表交给 Java 分发执行，返回任意结果。已支持的方法：`shell`、`shizukuStatus`、`shizukuRequest`、`vibrate`、`notify`、`launchApp`；未知方法返回 `{"ok":false,"error":"unknown method: ..."}`。
- 参数：`method` string 必填；`paramsTable` table 可选。
- 返回：任意 Lua 值（Java 返回 JSON 解码结果）；无返回推 `nil`。
- 报错：参数序列化失败或桥调用失败抛 `system.call: <err>`。
- 底层：参数 `json.Marshal` → `callAndroidSystem` → JNI → Java `FloatingBridge.call` switch 分发。

**`system.shell(cmd)`**
- 作用：以 Shizuku(ADB) 身份执行一条 shell 命令。
- 参数：`cmd` string 必填。
- 返回：table `{ok=bool, exit=number, stdout=string, stderr=string, uid=number, error?=string}`。命令本身失败不抛异常，走 `ok=false`。
- 报错：仅桥调用失败抛 `system.shell: <err>`。
- 底层：参数 `{"command":cmd}` → JNI → Java `runShell`：空命令/Shizuku 未运行/未授权各有明确错误；否则经反射调 `Shizuku.newProcess` 执行 `/system/bin/sh -c <cmd>`，读 stdout/stderr、取退出码与 uid。

**`system.shizukuStatus()`**
- 作用：查询 Shizuku 运行状态与授权情况。
- 参数：无。
- 返回：table `{available=bool, granted=bool, uid=number}`（失败时 uid=-1）。
- 报错：桥调用失败抛 `system.shizukuStatus: <err>`。
- 底层：JNI → Java `shizukuStatusJson`：`Shizuku.pingBinder()`、`checkSelfPermission()==GRANTED`、`getUid()`。

**`system.shizukuRequest()`**
- 作用：弹出系统授权对话框，申请 Shizuku ADB 权限。
- 参数：无。
- 返回：table `{ok=bool, requested=bool, error?=string}`。
- 报错：桥调用失败抛 `system.shizukuRequest: <err>`。
- 底层：JNI → Java `requestShizukuPermission`：pingBinder 失败返回未运行；否则 `Shizuku.requestPermission()` 弹授权框。

**`system.vibrate(ms?)`**
- 作用：触发手机震动（**不需要** Shizuku/ADB 权限）。
- 参数：`ms` number 可选，默认 500（毫秒）。
- 返回：table `{ok=true}`；异常时 `{ok=false, error=...}`。
- 报错：桥调用失败抛 `system.vibrate: <err>`。
- 底层：参数 `{"ms":ms}` → JNI → Java `vibrate`（Vibrator）。

**`system.notify(title, body?)`**
- 作用：发系统状态栏通知（**不需要** Shizuku/ADB 权限）。
- 参数：`title` string 必填；`body` string 可选，默认 `""`。
- 返回：table `{ok=true}`；异常时 `{ok=false, error=...}`。
- 报错：桥调用失败抛 `system.notify: <err>`。
- 底层：参数 `{"title","body"}` → JNI → Java `postDirectNotification`。

---

### 4.3 api —— 跨插件调用

**`api.require(id)`**
- 作用：跨插件调用另一个插件导出的函数。返回一个带 `__index` 元方法的**表**；访问其任意键会懒生成一个调用 stub。
- 参数：`id` string 必填——目标插件 id。
- 返回：目标插件已加载 → 返回 stub 表；未加载 → 返回 `nil`。
- 报错：`id` 非 string 抛类型错误；调用 stub 时若目标插件未导出 `plugin_api` / 无该导出函数 / 重跑失败，抛对应错误。
- 底层：访问 `api.require(id).someFunc` 得到 stub；调用时参数 `luaToGo`+`json.Marshal` → `callPluginFunction`（新建 LState 重跑目标插件源码 → 取全局 `plugin_api.someFunc` → 调用）→ 结果 `jsonDecodeGo`+`goToLua` 回传。目标函数返回 nil/空时返回 `nil`。

**调用方式示例**：
```lua
local core = api.require("core_utils")  -- 依赖 core_utils 导出 plugin_api.money_get
local bal = core.money_get(player)      -- 调用它
```

---

### 4.4 plugin —— 插件自身上下文

**`plugin.id()`**
- 作用：返回当前插件的 id 字符串。
- 参数：无。
- 返回：string。
- 报错：无。
- 底层：读全局 `__PLUGIN_ID__`。

**`plugin.dependencies()`**
- 作用：返回当前插件的依赖声明（`pre_plugins`）。
- 参数：无。
- 返回：表（原样透传全局 `plugin_dependencies` 的值）。
- 报错：无。
- 底层：读全局 `plugin_dependencies`。

---

### 4.5 util —— 通用工具与后台定时任务

#### 时间

**`util.now()`**
- 作用：返回当前本地时间。
- 参数：无。
- 返回：string，格式固定 `"2006-01-02 15:04:05"`。
- 报错：无。
- 底层：`time.Now().Format("2006-01-02 15:04:05")`。

**`util.timestamp()`**
- 作用：返回当前 Unix 秒级时间戳。
- 参数：无。
- 返回：number。
- 报错：无。
- 底层：`time.Now().Unix()`。

**`util.time_fmt(ts?)`**
- 作用：把 Unix 时间戳格式化为可读的本地时间。
- 参数：`ts` number 可选，默认当前时间戳。
- 返回：string。
- 报错：无。
- 底层：`time.Unix(ts,0).Format("2006-01-02 15:04:05")`。

#### JSON 与文件

**`util.json_load(path)`**
- 作用：读取文件并解析为 JSON 对象。
- 参数：`path` string 必填。
- 返回：任意 Lua 值（表/数字/字符串…）。数字用 `UseNumber()` 解码避免精度损失。
- 报错：读文件失败或 JSON 解析失败抛 `json_load: <err>`。
- 底层：`os.ReadFile` + `json.Decoder`（`UseNumber`）→ `goToLua`。

**`util.json_write(path, data)`**
- 作用：把任意 Lua 值序列化为带缩进的 JSON 写入文件，自动建父目录。
- 参数：`path` string 必填；`data` 任意类型必填。
- 返回：boolean `true`。
- 报错：建目录/序列化/写文件失败抛 `json_write: <err>`。
- 底层：`os.MkdirAll` + `json.MarshalIndent(data,"","  ")` + `os.WriteFile`。

**`util.read_file(path)`**
- 作用：读取文件全部内容按字符串返回。
- 参数：`path` string 必填。
- 返回：string。
- 报错：读取失败抛 `read_file: <err>`。
- 底层：`os.ReadFile`。

**`util.write_file(path, content)`**
- 作用：把字符串写入文件，自动建父目录，权限 0644。
- 参数：`path` string、`content` string 必填。
- 返回：boolean `true`。
- 报错：建目录/写文件失败抛 `write_file: <err>`。
- 底层：`os.MkdirAll` + `os.WriteFile(path, []byte(content), 0644)`。

#### 字符串

**`util.strip_color(text)`**
- 作用：去掉文本里的 Minecraft 颜色/格式码（`§` 与 `&` 及其后一个字符）。
- 参数：`text` string 必填。
- 返回：string。
- 报错：无。
- 底层：手写循环用 `strings.Builder` 逐字节过滤。

**`util.split(str, sep)`**
- 作用：按分隔符切分字符串为数组。
- 参数：`str` string、`sep` string 必填。
- 返回：table（字符串数组，1 起索引）。
- 报错：无。
- 底层：`strings.Split` + `RawSetInt`。

**`util.join(tbl, sep)`**
- 作用：把 table 的所有值转字符串后用分隔符拼接。注意：遍历整表，非数组顺序不一定与下标一致。
- 参数：`tbl` table、`sep` string 必填。
- 返回：string。
- 报错：无。
- 底层：`t.ForEach` + `LVAsString` + `strings.Join`。

**`util.trim(str)`**
- 作用：去除字符串两端空白。
- 参数：`str` string 必填。
- 返回：string。
- 报错：无。
- 底层：`strings.TrimSpace`。

#### 数值

**`util.floor(n)` / `util.ceil(n)` / `util.round(n)`**
- 作用：向下 / 向上 / 四舍五入取整。
- 参数：`n` number 必填。
- 返回：number。
- 报错：非数值抛类型错误。
- 底层：`math.Floor` / `math.Ceil` / `math.Round`（`round` 是 Go 的"四舍六入五成双"，对 0.5 特判）。

**`util.pos(str)`**
- 作用：把空格分隔的坐标字符串（如 `"100 64 200"`）解析成坐标表，最多取前 3 个 token，缺失项补 0。
- 参数：`str` string 必填。
- 返回：table `{x=number, y=number, z=number}`。
- 报错：无。
- 底层：`strings.Fields` + `strconv.ParseFloat`。

#### 定时任务

**`util.schedule(intervalSec, handlerName)`**
- 作用：注册一个按固定间隔重复调用的后台定时任务，每触发一次就重跑源码并调用 `handlerName`。
- 参数：`intervalSec` number 必填，钳制在 `[0.001, 31536000]`（1 年）；`handlerName` string 必填。
- 返回：number（任务 id，用于 `util.cancel`）。重跑上下文返回 0 且不注册。
- 报错：间隔超范围抛 `schedule: 间隔需在 0.001~... 秒之间`。
- 底层：`newSchedJob(oneshot=false)` + goroutine `runSchedLoop` 用 `time.NewTicker` 周期重跑 handler。

**`util.setTimeout(sec, handlerName)`**
- 作用：注册一个一次性定时任务，延时后调用 `handlerName` 一次。
- 参数：`sec` number 必填，允许 0（立即触发），上限 1 年；`handlerName` string 必填。
- 返回：number（任务 id）。重跑上下文返回 0 不注册。
- 报错：延时超出 `[0, 31536000]` 抛 `setTimeout: 延时需在 0~... 秒之间`。
- 底层：`newSchedJob(oneshot=true)` + goroutine 用 `time.NewTimer`。

**`util.cancel(id)`**
- 作用：取消一个已注册的定时任务（schedule/setTimeout）。
- 参数：`id` number 必填。
- 返回：boolean——`true` 找到并取消，`false` 不存在。
- 报错：无。
- 底层：`cancelSchedJob(int64(id))`，关闭任务的 cancel channel。

---

### 4.6 bot —— 多机器人舰队与路由

**`bot.select(nameOrIndex)`**
- 作用：切换后续 `game.*` / `world.*` 调用的目标机器人。
- 参数：`nameOrIndex` string 必填（机器人名或索引的字符串形式）。
- 返回：boolean `true`。
- 报错：未找到机器人抛 `bot.select: 未找到机器人 <名称>`。
- 底层：`selectBot(L, sel)`。

**`bot.current()`**
- 作用：返回当前活跃机器人的名字与坐标。
- 参数：无。
- 返回：table `{name, x, y, z}`；无活跃机器人返回空表；坐标查询失败省略 x/y/z。
- 报错：无。
- 底层：从舰队管理器读当前选中的机器人名，再通过 WS 自动化通道执行 `querytarget @s` 取该机器人的坐标。

**`bot.count()`**
- 作用：返回在线机器人数量。
- 参数：无。
- 返回：number。
- 报错：无。
- 底层：`GetFleetBots()`。

**`bot.list()`**
- 作用：列出在线机器人及坐标。
- 参数：无。
- 返回：table，1 起索引，每个元素 `{name, x, y, z}`（坐标查询失败省略坐标字段）。
- 报错：无。
- 底层：`GetFleetBots()` 遍历 + `QueryPosition()`。

**`bot.status()`**
- 作用：返回每个机器人的连接状态、是否 OP、错误信息。
- 参数：无。
- 返回：table，1 起索引，每个元素 `{index, name, connected, is_op, error?}`（error 仅非空时存在）。
- 报错：无。
- 底层：`FleetStatus()`。

---

### 4.7 building —— 建筑结构解析

**`building.detect(path)`**
- 作用：检测建筑文件的格式。
- 参数：`path` string 必填。
- 返回：string（格式名：`.mcstructure` / `.schematic` / `.mcworld` / `.bdx`）。
- 报错：非字符串抛类型错误。
- 底层：`building.DetectFormat(path)`。

**`building.parse(path)`**
- 作用：加载并解析建筑结构文件，返回尺寸、方块统计、NBT、是否含命令方块。
- 参数：`path` string 必填。
- 返回：table `{size={x,y,z}, blocks=number, nbt=number, has_command=boolean}`（`blocks` 为非空气方块数，`nbt` 为 NBT 方块数）。
- 报错：加载失败抛 `building.parse: <err>`。
- 底层：`building.LoadStructureFile(path)`，遍历方块计数，读 `NBTBlocks`/`HasCommand`。

**`building.isAir(name)` / `building.isWater(name)` / `building.isLava(name)` / `building.isCommandBlock(name)`**
- 作用：判断方块名是否为空气 / 水 / 岩浆 / 命令方块。
- 参数：`name` string 必填（方块名）。
- 返回：boolean。
- 报错：无。
- 底层：`building.IsAirBlock/IsWaterBlock/IsLavaBlock/IsCommandBlock(name)`。

**`building.closestColor(r, g, b)`**
- 作用：按 CIELAB 感知色差，匹配给定 RGB 最接近的颜色方块。
- 参数：`r`/`g`/`b` number 必填（0-255）。
- 返回：string（最接近的颜色方块名）。
- 报错：非数值抛类型错误。
- 底层：`media.ClosestBlockForColor(r, g, b)`。

---

### 4.8 media —— 媒体处理

**`media.imageToAscii(path, maxW?)`**
- 作用：把图片文件转成 ASCII 字符画行数组。
- 参数：`path` string 必填；`maxW` number 可选，默认 60。
- 返回：table（字符串数组，1 起索引，每行一个 ASCII 串）。
- 报错：打开/解码/转换失败抛 `media.imageToAscii: <err>`。
- 底层：`os.Open` + `image.Decode`（支持 gif/jpeg/png）→ `media.ImageToASCII(img, maxW)`。

**`media.noteToPitch(note)`**
- 作用：把 MIDI 音符号换算为频率（Hz）。
- 参数：`note` number 必填（强转 `uint8`）。
- 返回：number（音高频率）。
- 报错：非数值抛类型错误。
- 底层：`media.NoteToPitch(uint8(note))`。

**`media.parseMidi(path)`**
- 作用：解析 MIDI 文件，返回格式/轨道/分辨率/速度及音符列表。
- 参数：`path` string 必填。
- 返回：table `{format, tracks, division, tempo, notes={{tick, channel, note, velocity, duration, sound}}}`（`sound` 仅非空时出现）。
- 报错：读文件/解析失败抛 `media.parseMidi: <err>`。
- 底层：`os.ReadFile` → `media.ParseMIDIFile(data)`。

---

### 4.9 world —— 世界方块查询

**`world.block(x, y, z)`**
- 作用：查询世界某坐标的方块名（需要机器人连接，目标为当前活跃机器人）。
- 参数：`x`/`y`/`z` number 必填（整数坐标）。
- 返回：string（方块名）。
- 报错：查询失败抛 `world.block: <err>`；参数非整数抛类型错误。
- 底层：同 `game.getBlockTile`——机器人先传送加载区块，再执行 `testforblock <x> <y> <z> air` 判断方块名。**有移动副作用**（会把当前活跃机器人传送过去再传回）。

---

### 4.10 player —— 玩家数据

所有 `player.*` 读的是工具箱维护的**玩家信息缓存**，不向游戏发指令。缓存靠服务器下发的 `PlayerList`/`AddPlayer`/`UpdateAbilities` 等数据包实时维护；网易租赁服不发 PlayerList 包时，后台会用 `/list` + `querytarget` 命令**轮询**补齐（因此这类服上有数秒延迟）。

**`player.get(name)`**
- 作用：按名字查玩家信息。
- 参数：`name` string 必填。
- 返回：table `{name, xuid, unique_id, is_op, online, dimension, x, y, z, held_item?}`（`held_item` 仅非空时出现，为网络 ID）。玩家不存在返回**空表**（不是 nil）。
- 报错：`name` 非 string 抛类型错误。
- 底层：直接查玩家缓存表，不向游戏发指令。

**`player.getXUID(name)`**
- 作用：查玩家 XUID。
- 参数：`name` string 必填。
- 返回：string；玩家不存在返回**空串**。
- 报错：`name` 非 string 抛类型错误。
- 底层：直接查玩家缓存表的 XUID 字段。

**`player.getUniqueID(name)`**
- 作用：查玩家实体唯一 ID。
- 参数：`name` string 必填。
- 返回：number；玩家不存在返回 **0**。
- 报错：`name` 非 string 抛类型错误。
- 底层：直接查玩家缓存表的实体唯一 ID 字段。

**`player.isOP(name)`**
- 作用：判断玩家是否 OP。
- 参数：`name` string 必填。
- 返回：boolean（玩家存在且为 OP 才为 true，含不存在时返回 false）。
- 报错：`name` 非 string 抛类型错误。
- 底层：直接查玩家缓存表（`IsOP` 由 `UpdateAbilities`/`AddPlayer` 等数据包维护）。

**`player.list()`**
- 作用：列出全部在线玩家信息表。
- 参数：无。
- 返回：table（1 起索引，每个元素是 `player.get` 同款信息表）。
- 报错：无。
- 底层：遍历玩家缓存表。

**`player.count()`**
- 作用：返回在线玩家数量。
- 参数：无。
- 返回：number。
- 报错：无。
- 底层：玩家缓存表当前条数。

**`player.getInventory(name)`**
- 作用：走当前活跃机器人查询某玩家背包物品清单。
- 参数：`name` string 必填。
- 返回：table `{items = {{name, count, slot, damage}, ...}}`。
- 报错：失败抛 `player.getInventory: <err>`。
- 底层：同 `game.queryInventory`——通过 WS 自动化通道执行网易特有命令 `codebuilder_actorinfo inventory <玩家名>`，从响应 DataSet（JSON）解析物品清单。

---

### 4.11 events —— 事件系统

所有 `events.*` 都是**回调注册**：参数传一个**函数名（string）**，不是函数字面量。事件触发时新建临时 LState 重跑插件源码，再按函数名调用 handler。注册回调返回 0 个值。同插件同 handler 自动去重；重跑上下文跳过注册。

**`events.onChat(handlerName)`**
- 作用：注册聊天事件处理器。
- 参数：`handlerName` string 必填，回调签名 `onChat(player, msg)`——触发传 2 参：`player` string（玩家名）、`msg` string（聊天内容）。
- 返回：无。
- 报错：`handlerName` 非 string 抛类型错误。
- 底层：`registerEvent(&evChat, L)`；触发 `fireChatEvent` → `runEventHandlers`。实时。

**`events.onJoin(handlerName)`**
- 作用：注册玩家加入事件处理器。
- 参数：`handlerName` string 必填，回调签名 `onJoin(player)`——1 参 `player` string。
- 返回：无。
- 报错：`handlerName` 非 string 抛类型错误。
- 底层：`registerEvent(&evJoin, L)`；由后台 5 秒玩家列表轮询差量触发（有约几秒延迟）。

**`events.onLeave(handlerName)`**
- 作用：注册玩家离开事件处理器。
- 参数：`handlerName` string 必填，回调签名 `onLeave(player)`——1 参 `player` string。
- 返回：无。
- 报错：`handlerName` 非 string 抛类型错误。
- 底层：`registerEvent(&evLeave, L)`；由 5 秒轮询差量触发。

**`events.onBotReady(handlerName)`**
- 作用：注册机器人就绪事件处理器。
- 参数：`handlerName` string 必填，回调签名 `onBotReady()`——0 参。
- 返回：无。
- 报错：`handlerName` 非 string 抛类型错误。
- 底层：`registerEvent(&evBotReady, L)`。

**`events.onPacket(handlerName)`**
- 作用：注册数据包事件处理器。
- 参数：`handlerName` string 必填，回调签名 `onPacket(type, dataTable)`——2 参：`type` string（包类型）、`dataTable` table（数据）。
- 返回：无。
- 报错：`handlerName` 非 string 抛类型错误。
- 底层：`registerEvent(&evPacket, L)`；触发 `firePacketEvent`，数据经 `goToLua` 转表。实时。

**`events.subscribe(packetType, handlerName)`**
- 作用：**通用数据包订阅**。订阅任意一个数据包类型（按 Go 类型名，如 `"MovePlayer"`/`"SetTime"`/`"PlayerList"`/`"Text"`）。订阅后机器人只监听你订阅的包类型，收到就把**完整**数据包广播给该 handler。
- 参数：`packetType` string 必填（包类型名）；`handlerName` string 必填，回调签名 `onData(dataTable)`——1 参：`dataTable` table（包数据，字段名 snake_case；`[]byte` 给**完整 hex**，不截断）。
- 返回：无。同插件同类型同 handler 自动去重；重跑上下文跳过注册。
- 报错：参数非 string 抛类型错误；不在插件上下文调用报错。
- 底层：`registerPacketSub` → `packetHubSubscribe`（packet_hub.go）。想查有哪些包类型可订阅，可用 AI 的 `list_packets` 工具。清理：插件停止时 `RemovePluginEvents` 一并退订。
- 示例：
```lua
events.subscribe("MovePlayer", "onMove")
function onMove(data)
  -- data.entity_runtime_id, data.position={x,y,z}, data.yaw ...
  game.sendChat("玩家移动 x=" .. data.position[1])
end
```

**`events.subscribeAll(handlerName)`**
- 作用：**全量数据包订阅**。订阅**所有**入站数据包（含未知包、未在固定监听列表里的包），收到任意包就广播给该 handler。用于调试协议/服务器行为、观察未知包。
- 参数：`handlerName` string 必填，回调签名 `onData(dataTable)`——1 参：`dataTable` table，字段：`seq`（序号）、`at`（时间 HH:MM:SS.mmm）、`direction`（恒为 "inbound"）、`bot`（"BotIndex:display"）、`packet_type`（Go 类型名，未知包为 "Unknown"）、`packet_id`（协议 ID）、`fields`（包字段，未知包带 `payload_hex`）、`raw_len`（未知包原始字节数，有则给）。
- 返回：无。同插件同 handler 自动去重；重跑上下文跳过注册。
- 报错：参数非 string 抛类型错误；不在插件上下文调用报错。
- 底层：`registerCaptureSub` → `captureSubscribe`（packet_capture.go，进程级全量捕获 + 历史缓存）。清理：插件停止时 `RemovePluginEvents` 一并退订。
- 注意：`subscribeAll` 会收到**每个**包（含高频 SetTime/区块包），handler 内务必轻量、快速返回，避免拖慢插件执行队列。数据默认保留最近 60 秒（可让 AI 用 `query_packets` 回看）。

**公共机制**：事件派发是**异步**的（不阻塞收包循环，避免 `onChat` 里 `game.waitMsg/promptChoice` 死锁），每个 handler 串行执行；handler 为 nil 时跳过；执行出错仅记日志，不抛给调用方。

---

### 4.12 http —— 网络请求

`http.*` 返回完整响应对象（含状态码、响应头），非 2xx 也返回 body，不抛异常。默认超时 30 秒，响应体上限 10MB。

**`http.request(method, url, body?, opts?)`**
- 作用：发送任意 method 的 HTTP 请求，返回完整响应对象。
- 参数：`method` string 必填；`url` string 必填；`body` string 可选，默认 `""`；`opts` table 可选（含 `headers` 表、`timeout` 秒）。
- 返回：table。成功 `{ok=true, status=number, body=string, headers=table}`；传输错误 `{ok=false, error=string}`。
- 报错：无（错误放进 `error` 字段，不抛异常）。
- 底层：`httpRequestFull(method, u, body, headers, timeout)`。

**`http.get(url, opts?)` / `http.post(url, body?, opts?)` / `http.put(url, body?, opts?)` / `http.delete(url, opts?)`**
- 作用：对应方法的 HTTP 请求。
- 参数：同 `request`（get/delete 无 body）。
- 返回：同 `request` 的响应表。
- 报错：无（错误进 `error` 字段）。
- 底层：`pushHTTPResult(L, "GET/POST/PUT/DELETE", ...)` → `httpRequestFull`。

**`http.json_encode(v)`**
- 作用：把 Lua 值转成 JSON 字符串。
- 参数：`v` 任意 Lua 值。
- 返回：string。
- 报错：序列化失败抛 `http.json_encode: <err>`。
- 底层：同 `game.jsonEncode`——把 Lua 值映射成 JSON 类型后编码成字符串。

**`http.json_decode(s)`**
- 作用：把 JSON 字符串解析为 Lua 值。
- 参数：`s` string 必填。
- 返回：任意 Lua 值。
- 报错：解析失败抛 `http.json_decode: <err>`。
- 底层：同 `game.jsonDecode`——把 JSON 解析成对应 Lua 类型（对象→表、数组→1 起索引的表）。

**`http.querify(paramsTable)`**
- 作用：把参数表编码成 URL query 字符串。
- 参数：`paramsTable` table 必填（键值都转字符串）。
- 返回：string，如 `"a=1&b=2"`（按键排序，同键累加）。
- 报错：非 table 抛类型错误。
- 底层：`url.Values` + `vals.Encode()`。

> 与 `game.httpGet/httpPost` 的区别：`game.*` 返回纯文本、非 200 直接抛错，适合简单场景；`http.*` 返回完整响应对象、携带状态码与响应头、非 2xx 也能拿 body，适合需要细粒度控制的场景。

---

### 4.13 web —— 网页页面

`web.*` 面向局域网把插件暴露成网页。页面/动作注册走 `/web/` 路由（8080 端口）；访问密码可配在插件配置的 `web_password` 字段。页面在插件停止/重载后自动下线。除 `web.emit` 外都是注册类调用，重跑上下文自动跳过。

**`web.page(name, desc?, controls?)`**
- 作用：声明一个**声明式页面**，在门户 `/web/` 显示卡片，点进由内置模板渲染控件页。
- 参数：`name` string 必填（插件内唯一，不含 `/ \ # ? %` 及控制字符）；`desc` string 可选，默认 `""`；`controls` table 可选（控件表，可读字段 `type`=text|button|input|table|switch、`key`、`label`、`action`、`placeholder`、`columns`）。
- 返回：无。
- 报错：空名/非法字符/同插件页面名重复注册抛异常。
- 底层：`registerWebPage(&webPage{Kind:"declarative",...})`，写入全局 `webPages` map。

**`web.serve(name, entry?)`**
- 作用：声明一个**自定义 HTML 页面**，直接服务 `www/` 目录下对应入口文件。
- 参数：`name` string 必填（规则同 `web.page`）；`entry` string 可选，默认 `"index.html"`（相对 `www/`）。
- 返回：无。
- 报错：同 `web.page`。
- 底层：`registerWebPage(&webPage{Kind:"html", Entry:entry})`；静态根目录 `插件文件/<id>/www`，经 `webStaticSafe` 防路径逃逸 + `serveWebStatic` 提供。

**`web.action(page, action, handler)`**
- 作用：绑定一个交互动作——浏览器对 `/web/api/<插件id>/<页面名>` 发请求时，重跑源码并调用 `handler` 处理。
- 参数：`page` string、`action` string 必填；`handler` **string 必填**（全局**函数名字符串**，不是函数引用）。
- 返回：无。
- 报错：缺插件上下文/空名/重复注册抛异常。
- 底层：`registerWebAction`；执行时新建 LState（2 分钟超时）重跑源码后 `CallByParam` 调 handler，返回值经 `luaToGo` 作为响应 `data` 回传。受独立并发信号量（容量 8）约束。

**`web.emit(page, event, data)`**
- 作用：把一条事件实时推送给该插件的全部 SSE 客户端。声明式页面内置 JS 按 key 更新控件；自定义页 JS 自行监听。用于后台状态/进度推送。
- 参数：`page` string 必填（作为 SSE 事件名）；`event` string 必填（会写入数据 map 的 `__event` 键）；`data` 任意 Lua 值必填。
- 返回：无。
- 报错：数据无法 JSON 序列化抛 `web.emit: <err>`。
- 底层：`pushWebEvent(plugin, page, dataJSON)`，构造 SSE 消息写入所有客户端通道（通道满则丢弃，不阻塞 Lua）。**此方法在重跑上下文不跳过**（供 handler 内推送用）。

---

## 五、综合示例：一个简单的管理插件

把上面的 API 串起来，写一个完整示例插件。它做两件事：玩家发 `菜单` 打开菜单（打招呼 / 查余额），并监听玩家进服发欢迎。

```lua
-- manifest 里 id = "example"，pre_plugins = { core_utils = "1.0.0" }

local core = api.require("core_utils")  -- 跨插件拿货币工具

-- 聊天入口
game.registerTrigger({"菜单", "caidan"}, "openMenu")

function openMenu(player)
    local opts = {"打个招呼", "查看我的余额"}
    local idx = game.promptChoice(player, "【示例菜单】请选择", opts, 20)
    if idx == 1 then
        game.sendTargeted(player, "§a你好，" .. player .. "！")
    elseif idx == 2 then
        local bal = core.money_get(player)
        game.sendTargeted(player, "§b你的余额: " .. bal)
    end
end

-- 进服欢迎
function onJoin(name)
    game.sendChat("@a", "§7[示例] " .. name .. " 进入了服务器")
end
events.onJoin("onJoin")
```

把它打包成 zip（`manifest.json` + `main.lua`），导入并运行。游戏里发 `菜单` 会出现菜单；每次有玩家进服会收到欢迎消息。

---

## 六、常见模式与最佳实践

### 6.1 数据持久化

插件需要保存的任何数据，都写到 `game.dataDir()` 下的文件里。推荐统一读写模式：

```lua
local function file() return game.dataDir() .. "/data.json" end
local function load()
    local ok, d = pcall(util.json_load, file())
    if ok and type(d) == "table" then return d end
    return {}
end
local function save(d)
    pcall(util.json_write, file(), d)
end
```

`pcall` 很重要：文件第一次读取时不存在，`util.json_load` 会抛错，`pcall` 捕获后回退到空表。

### 6.2 菜单的多步交互

`game.promptChoice` 返回 1 起的下标或 `nil`。用处理函数分发到具体分支，每个分支里再嵌套 `promptChoice` 或 `waitMsg` 完成多步输入。

```lua
function mainMenu(player)
    local idx = game.promptChoice(player, "主菜单", {"子菜单A", "直接操作"}, 20)
    if idx == 1 then
        subMenuA(player)   -- 二级菜单
    elseif idx == 2 then
        local name = game.waitMsg(player, 15)
        game.sendTargeted(player, "你输入了: " .. tostring(name))
    end
end
```

注意：`promptChoice` 和 `waitMsg` 是阻塞等待，在后台协程里运行，不会卡住机器人主循环；但同一时间一个玩家只能有一个活跃的等待会话。

### 6.3 后台轮询

用 `util.schedule` 做周期任务：

```lua
function onTick()
    local data = load()
    for _, pi in ipairs(player.list()) do
        -- 检查每个在线玩家
    end
end
util.schedule(2, "onTick")
```

### 6.4 跨插件拆分系统

把大系统拆成"底层库 + 功能插件"是推荐做法。底层库（如 `core_utils`）提供无状态纯函数和持久化，用 `plugin_api` 导出；功能插件（领地、商店、防挂）通过 `pre_plugins` 依赖它，用 `api.require` 调用。

### 6.5 错误处理

- 需要"出错但不中断"时，用 `pcall` 包住可能抛错的调用。
- `game.promptChoice` 超时会返回 `nil`，记得判断 `if not idx then return end`。
- `tonumber` 解析玩家输入时，非数字返回 `nil`，要先判断。
- 从 `util.json_load` 读到的字段可能是 nil，访问前用 `or 默认值` 兜底。

---

## 七、注意事项与常见坑

**1 起 vs 0 起**：`game.promptChoice` 返回 **1 起** 下标。拿到 `nil` 说明玩家取消或超时。

**保留字**：Lua 关键字（`until`、`end`、`local` 等）不能直接用作表键，除非写成 `["until"]`。

**顶层副作用**：源码会被反复重跑。不要在顶层做"每次重跑都想执行一次"的事（开文件、发消息、计数）。放进函数里，或依赖注册机制（已自动去重）。

**状态只在调用内有效**：全局变量每次重跑都重置。跨调用保存状态请用文件。

**系统能力需要授权**：`system.shell` 需要 Shizuku 授权；`system.vibrate`/`system.notify` 不需要。`system.platform()` 在桌面返回 `desktop`，系统能力在桌面不可用。

**指令需要 OP**：`kick`、`give`、`kill`、`gamemode`、`scoreboard` 等指令需要机器人有 OP。无 OP 时不生效但不报错。

**事件延迟**：进服/离服事件靠轮询，有几秒延迟；聊天、数据包事件是实时的。

**执行开销**：触发词、事件、定时、跨插件调用都会重跑源码。对高频路径（如每条聊天都触发 `onChat`）逻辑尽量精简，避免大量文件读写。

**数据目录结构**：一个插件 = `插件文件/<id>/`（代码）+ `插件配置文件/<id>/`（设置）+ `插件数据文件/<id>/`（数据）三处，不要混用。

**网页交互注意**：`web.action` 的 handler 是函数名字符串；页面/动作在插件停止后下线；数据表键若为连续整数 1..n 会被当作数组处理。

---

## 八、写在最后

本文档覆盖了当前插件的全部公开 API，并对每个函数说明了用途、参数、返回值、报错与底层实现。API 仍在演进，若发现某个方法行为与本文不符，或需要本文没有的能力，请反馈，文档会随之更新。

祝开发顺利。
