-- Ds AI Agent V9.4.68 · Prism 工具箱 
-- ===== 完整备份打包（插件文件 + 配置文件 + 数据文件 一起打包）=====
function pack_full_backup_zip()
    local base=plugin_base_dir()
    local cdir=base.."/插件文件/ds_ai_agent"
    local cfgdir=base.."/插件配置文件/ds_ai_agent"
    local ddir=tostring(game.dataDir() or "")
    local files={}
    local report={}
    local function add(zipname,path)
        local ok,data=pcall(util.read_file,path)
        if ok and type(data)=="string" and data~="" then
            files[#files+1]={name=zipname,data=data}
            report[#report+1]=zipname.."  ("..#data.." 字节)"
        end
    end
    add("plugin/ds_ai_agent.manifest.json", cdir.."/ds_ai_agent.manifest.json")
    add("plugin/ds_ai_agent.lua", cdir.."/ds_ai_agent.lua")
    add("plugin/ds_ai_agent.docs.md", cdir.."/ds_ai_agent.docs.md")
    add("plugin/defaults.json", cdir.."/defaults.json")
    add("config/ds_ai_agent.json", cfgdir.."/ds_ai_agent.json")
    local data_names={
        "ds_data.json","chat_rate.json","chat_logs.json","death_lastpos.json","ds_tpa.json",
        "edge_guard.json","fixed_shop.json","full_shop_items.json","item_names.json",
        "item_damage_names.json","sell_prices.json","nbt_regions.json","purchase_logs.json",
        "shop_logs.json","teleport_logs.json","territory_protection_logs.json","territories.json",
        "market.json","market_items_nbt.json","market_item_previews.json","market_storage.json",
        "market_wallet.json","market_offline_notices.json","server_seed.json","scoreboard_config.json",
        "ai_personas.json","ai_global_rules.json","ai_stop_flags.json","ai_last_trace.json",
        "runtime.log","runtime_pending.log","inv_request.json","defaults.json","qq_relay.py","qq_readme.md",
    }
    for _,n in ipairs(data_names) do add("data/"..n, ddir.."/"..n) end
    if #files==0 then return "打包失败：没有读到任何文件。" end
    local z=zip_build(files)
    local out="/storage/emulated/0/我的世界指令相关/ds_ai_agent_完整备份.zip"
    local ok,err=pcall(util.write_file,out,z)
    if not ok then return "写入失败："..tostring(err) end
    local vok,vdata=pcall(util.read_file,out)
    local vul=(vok and type(vdata)=="string" and #vdata==#z and vdata:sub(1,4)==string.char(80,75,3,4))
    report[#report+1]="-----"
    report[#report+1]="打包 "..#files.." 个文件，输出："..out
    report[#report+1]="大小："..#z.." 字节；回读校验："..(vul and "通过" or "异常")
    return table.concat(report,"\n")
end
-- AI: "ai 内容"（私聊） / "AI 内容"（公开）
-- 指令 Agent: "指令 内容"（独立窗口）
-- 传送点: .help / .回 / .传 / .home / .保存 / .保 / .删除 / .删
-- 玩家传送: .help → 5 或 ./tp 玩家；目标在聊天框输入 1 同意、0 拒绝
-- ============================================================

-- ════════════════════════════════════════════════════════════
--   【固定配置】
-- ════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════
--  AI 服务商：SenseNova（日日新）聚合网关
--  实测结论（已抓包/请求验证）：
--   * 接口：POST https://token.sensenova.cn/v1/chat/completions（OpenAI 兼容）
--   * 默认模型 sensenova-6.8-flash-lite 是"会思考"模型：思考放在 message.reasoning，
--     真正回答在 message.content。
--     ⚠️ 不关思考时，思考会把 max_tokens 吃光 → content 为空 → 插件报"AI没有返回内容"。
--        所以默认发 "thinking":{"type":"disabled"}（实测 reasoning_tokens=0、content 正常）。
--        想开思考：插件配置 ai_thinking = true（更慢、更费 token）。
--   * 该网关限速较紧（并发请求直接 429 rate_limit_error），已内置 3 次重试 + 友好提示。
--   * 该网关【没有】/v1/responses，也不支持 type=web_search 内置工具，
--     所以联网搜索 [SEARCH_WEB] 仍走 DeepSeek /responses（用独立的 web_search_key）。
-- ════════════════════════════════════════════════════════════
AI_URL = "https://token.sensenova.cn/v1/chat/completions"
-- Secrets and model settings are loaded from plugin config. Never commit API keys.
AI_KEY = tostring(game.getConfig("ai_key", ""))
-- DeepSeek 官方接口：模型 deepseek-flash（即 DeepSeek 4.1 Flash），实测 200 可用，
-- 且支持 thinking={type="disabled"} 关闭思考。密钥独立配置 deepseek_key。
DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_KEY = tostring(game.getConfig("deepseek_key", ""))
AI_MODEL = "sensenova-6.8-flash-lite"
AI_MODEL_LABEL = "SenseNova 6.8 Flash Lite"
-- 全部可选模型，供 .AI模型 切换（默认 sensenova-6.8-flash-lite）。
-- ⚠️ deepseek-flash 走 DeepSeek 官方接口（用 deepseek_key），其余走 SenseNova 网关（用 ai_key）。
AI_MODEL_CHOICES = {
    ["sensenova-6.8-flash-lite"]="SenseNova 6.8 Flash Lite",
    ["sensenova-6.7-flash-lite"]="SenseNova 6.7 Flash Lite",
    ["deepseek-flash"]="DeepSeek 4.1 Flash",
    ["deepseek-v4-pro"]="DeepSeek V4 Pro",
    ["glm-5.2"]="GLM 5.2",
    ["kimi-k3"]="Kimi K3",
}

-- 按模型选择服务商接口与密钥。返回：接口地址、密钥、服务商标识。
function ai_endpoint_for(model)
    local m=lower(trim(tostring(model or "")))
    if m=="deepseek-flash" then
        local k=trim(tostring(game.getConfig("deepseek_key","") or ""))
        if k=="" then k=trim(tostring(game.getConfig("web_search_key","") or "")) end
        if k=="" then k=DEEPSEEK_KEY end
        local u=trim(tostring(game.getConfig("deepseek_url","") or ""))
        if u=="" then u=DEEPSEEK_URL end
        return u,k,"deepseek"
    end
    return AI_URL, tostring(game.getConfig("ai_key", AI_KEY) or ""), "sensenova"
end
COMMAND_WORD = "指令 "
NORMAL_TRIGGER = "ai "
MAX_ROUNDS = 30  -- 单次任务最多30轮工具循环；普通对话记忆保持20轮
-- 兑换码专用：AI 兑换码只做"一问一答"——AI 理解兑换内容→执行→汇报→结束。
-- 不设长循环、不设多轮工具，避免 AI 反复 give 造成"看起来一直在发"。
REDEEM_MAX_ROUNDS = 2          -- 兑换码 AI 最多 2 轮（正常一次任务足够，AI 输出工具→插件直接执行完就结束）
REDEEM_MAX_CMDS_PER_ROUND = 20 -- 兑换码 AI 每轮最多 20 条指令
REDEEM_TIMEOUT = 180           -- 兑换码 AI 单次任务最长 3 分钟
TEMPERATURE = 1.0
MAX_REPLY = 1500
NORMAL_REPLY_MAX_CHARS = 1000
REDEEM_STOP_FILE = game.dataDir() .. "/ai_stop_flags.json"
-- 通用 AI 停止标志（落盘，不再用 RUNTIME.build_stop 内存变量）
-- 写入格式：{"玩家名": {at=秒时间戳, reason="..."}}；run_agent 每轮检查。
STOP_FLAG_TTL = 3600  -- 停止标志 1 小时内有效；到期自动清理
REDEEM_STOP_FILE = game.dataDir() .. "/ai_stop_flags.json"
-- 通用 AI 停止标志（落盘，不再用 RUNTIME.build_stop 内存变量）
-- 写入格式：{"玩家名": {at=秒时间戳, reason="..."}}；run_agent 每轮检查。
STOP_FLAG_TTL = 3600  -- 停止标志 1 小时内有效；到期自动清理

function ai_stop_load()
    local ok,d=pcall(util.json_load,REDEEM_STOP_FILE)
    if ok and type(d)=="table" then return d end
    return {}
end
function ai_stop_save(d) pcall(util.json_write,REDEEM_STOP_FILE,d) end

-- 检查某玩家是否处于停止状态；返回是否停止、附带原因
-- 每次调用会顺手清理过期标志（过期 1 小时），保证文件不膨胀。
function ai_stop_flagged(playerName)
    if not playerName or playerName=="" then return false,nil end
    local d=ai_stop_load()
    local now=util.timestamp()
    local changed=false
    for k,v in pairs(d) do
        if type(v)~="table" or (tonumber(v.at) or 0)<=0 or now-(tonumber(v.at) or 0)>STOP_FLAG_TTL then
            d[k]=nil; changed=true
        end
    end
    local st=d[playerName]
    if type(st)=="table" then
        if changed then ai_stop_save(d) end
        return true, tostring(st.reason or "手动停止")
    end
    if changed then ai_stop_save(d) end
    return false,nil
end

-- 设置/清除停止标志
function ai_stop_set(playerName, reason)
    local d=ai_stop_load()
    if reason==nil or reason=="" then
        d[playerName]=nil
    else
        d[playerName]={at=util.timestamp(), reason=reason}
    end
    ai_stop_save(d)
    return d
end

-- 通用停止检查：run_agent 主循环每轮、process_tools 每条指令前调用。
-- 命中就把标记清掉（一次消费），并返回是否应中止。
function ai_stop_check(playerName)
    local hit,reason=ai_stop_flagged(playerName)
    if hit then
        ai_stop_set(playerName,nil)  -- 一次性消费，避免下次 AI 被老标志误杀
        return true, reason
    end
    return false, nil
end
-- 所以联网搜索仍走 DeepSeek /responses，用独立密钥 web_search_key（填旧 DeepSeek key）。
WEB_SEARCH_URL = "https://api.deepseek.com/responses"
WEB_SEARCH_MODEL = "deepseek-flash"
-- runtime.log 时间严格使用 Prism 开发文档规定的本地时间格式：util.time_fmt(util.timestamp())
SUPERUSER = "疣螈"
DATA_FILE = game.dataDir() .. "/ds_data.json"
MARKET_FILE = game.dataDir() .. "/market.json"
TERRITORY_FILE = game.dataDir() .. "/territories.json"
SHOP_LOG_FILE = game.dataDir() .. "/shop_logs.json"
TERRITORY_PROTECTION_LOG_FILE = game.dataDir() .. "/territory_protection_logs.json"
PURCHASE_LOG_FILE = game.dataDir() .. "/purchase_logs.json"
CHAT_LOG_FILE = game.dataDir() .. "/chat_logs.json"
TELEPORT_LOG_FILE = game.dataDir() .. "/teleport_logs.json"
MARKET_NBT_FILE = game.dataDir() .. "/market_items_nbt.json"
MARKET_STORAGE_FILE = game.dataDir() .. "/market_storage.json"
MARKET_PREVIEW_FILE = game.dataDir() .. "/market_item_previews.json"
ITEM_NAMES_FILE = game.dataDir() .. "/item_names.json"
ITEM_DAMAGE_NAMES_FILE = game.dataDir() .. "/item_damage_names.json"
SELL_PRICES_FILE = game.dataDir() .. "/sell_prices.json"
FULL_SHOP_FILE = game.dataDir() .. "/full_shop_items.json"
OFFLINE_MARKET_NOTICE_FILE = game.dataDir() .. "/market_offline_notices.json"
NBT_REGION_FILE = game.dataDir() .. "/nbt_regions.json"
LEGACY_MARKET_NBT_FILE = game.dataDir() .. "/market_items.json"
-- 开发文档明确保证插件数据目录存在，但没有提供 mkdir API；因此 NBT 使用插件专用单文件持久化，避免写入不存在的子目录后被 pcall 静默吞掉。
MARKET_WALLET_FILE = game.dataDir() .. "/market_wallet.json"
FIXED_SHOP_FILE = game.dataDir() .. "/fixed_shop.json"
SCOREBOARD_CONFIG_FILE = game.dataDir() .. "/scoreboard_config.json"
SEED_FILE = game.dataDir() .. "/server_seed.json"
AI_TRACE_FILE = game.dataDir() .. "/ai_last_trace.json"
AI_PERSONA_FILE = game.dataDir() .. "/ai_personas.json"
CLOUD_BACKUP_INTERVAL = 300  -- 云备份间隔（原 60 秒；每次都会全量上传数据，1 分钟一次流量太大）
TPA_FILE = game.dataDir() .. "/ds_tpa.json"
HISTORY_ROUNDS = 20  -- 普通 AI 对话记忆20轮；工具结果按需加入近期上下文
SEED_FINDER_URL = "https://api.youyuanqi.dpdns.org/api/v1"  -- Ds Platform 真实结构查询器（旧的 mineseedfinder 已失效）
SEED_FINDER_TIMEOUT = 60
SEED_FINDER_RETRIES = 3
SEED_FINDER_DEFAULT_RADIUS = 100 -- 搜索半径（区块）
SEED_FINDER_MAX_RESULTS = 10
AI_GLOBAL_FILE = game.dataDir() .. "/ai_global_rules.json"

-- ════════════════════════════════════════════════════════════
--   【内置默认数据 —— 已外置到 JSON，不再写死在源码里】
--   物品名 / 药水名 / 收购价 / 全物品目录合计约 3100 项。以前直接写在源码中，
--   而插件源码在每条聊天、每个事件、每个定时任务都会被重新执行一遍，
--   这 3100 行字面量每次都要重新解析、重新分配表 —— 这是聊天/菜单/AI 变慢的主因之一。
--   现在搬进 JSON，只有真正用到（开商店 / 翻译物品名 / 收购）时才读取解析一次：
--     1) 插件文件/<id>/defaults.json          （推荐，随插件目录一起备份/拷贝）
--     2) 插件数据文件/<id>/defaults.json
--     3) 历史数据文件（首次运行会用到某个）：item_names.json /
--        item_damage_names.json / sell_prices.json / full_shop_items.json
--   ⚠️ 请勿删除这些 JSON，否则商品名会退回英文ID、收购价会为空。
--   （打包插件时会自动把 defaults.json 写进插件目录，见 pack_bundle_zip）
-- ════════════════════════════════════════════════════════════
local _DEF_CACHE = {}

function defaults_json_paths()
    local out={}
    local ok,cd=pcall(plugin_code_dir)
    if ok and type(cd)=="string" and cd~="" then out[#out+1]=cd.."/defaults.json" end
    out[#out+1]=game.dataDir().."/defaults.json"
    return out
end

function load_defaults_all()
    if _DEF_CACHE.__all~=nil then return _DEF_CACHE.__all end
    for _,p in ipairs(defaults_json_paths()) do
        local ok,raw=pcall(util.read_file,p)
        if ok and type(raw)=="string" and #raw>2 then
            local ok2,v=pcall(http.json_decode,raw)
            if ok2 and type(v)=="table" and next(v)~=nil then
                _DEF_CACHE.__all=v
                return v
            end
        end
    end
    _DEF_CACHE.__all=false
    return false
end

-- 取某张默认表：优先 defaults.json，其次该表自己的历史数据文件。
function default_table_of(key, data_file)
    local all=load_defaults_all()
    if type(all)=="table" and type(all[key])=="table" and next(all[key])~=nil then return all[key] end
    local ok,v=pcall(util.json_load,data_file)
    if ok and type(v)=="table" and next(v)~=nil then return v end
    log_event("DEFAULTS","无法读取默认数据："..tostring(key).." / "..tostring(data_file))
    return {}
end

function default_item_names()
    if not _DEF_CACHE.item_names then _DEF_CACHE.item_names=default_table_of("item_names",ITEM_NAMES_FILE) end
    return _DEF_CACHE.item_names
end
function default_item_damage_names()
    if not _DEF_CACHE.item_damage_names then _DEF_CACHE.item_damage_names=default_table_of("item_damage_names",ITEM_DAMAGE_NAMES_FILE) end
    return _DEF_CACHE.item_damage_names
end
function default_sell_prices()
    if not _DEF_CACHE.sell_prices then _DEF_CACHE.sell_prices=default_table_of("sell_prices",SELL_PRICES_FILE) end
    return _DEF_CACHE.sell_prices
end
function default_full_shop_prices()
    if not _DEF_CACHE.full_shop_prices then _DEF_CACHE.full_shop_prices=default_table_of("full_shop_prices",FULL_SHOP_FILE) end
    return _DEF_CACHE.full_shop_prices
end

-- 兼容旧调用名（源码内其它位置若还用到也不会报错）
function build_default_item_names() return default_item_names() end
function build_default_item_damage_names() return default_item_damage_names() end
function build_default_sell_prices() return default_sell_prices() end
function build_default_full_shop_prices() return default_full_shop_prices() end

-- 自愈：插件目录没有 defaults.json 时，用现有数据文件生成一份（不改变任何数据）。
function ensure_defaults_json()
    local ok,cd=pcall(plugin_code_dir)
    if not ok or type(cd)~="string" or cd=="" then return end
    local target=cd.."/defaults.json"
    local okr,raw=pcall(util.read_file,target)
    if okr and type(raw)=="string" and #raw>100 then return end
    local payload={
        item_names=default_table_of("item_names",ITEM_NAMES_FILE),
        item_damage_names=default_table_of("item_damage_names",ITEM_DAMAGE_NAMES_FILE),
        sell_prices=default_table_of("sell_prices",SELL_PRICES_FILE),
        full_shop_prices=default_table_of("full_shop_prices",FULL_SHOP_FILE),
    }
    local n=0; for _ in pairs(payload.item_names) do n=n+1 end
    if n<=0 then return end
    pcall(util.write_file,target,http.json_encode(payload))
end
-- 投票相关
VOTE_TIMEOUT = 60  -- 投票超时 60 秒
VOTE_CHECK_INTERVAL = 10  -- 投票超时检查周期（原 5 秒）
MENU_TIMEOUT = 60
TPA_TIMEOUT = 30
REPORT_REASON_TIMEOUT = 180
ANNOUNCEMENT_INTERVAL = 1800
COORD_TP_FIRST_DELAY = 7200
COORD_TP_INTERVAL = 86400
DAILY_SIGNIN_INTERVAL = 86400
SOUL_DURATION = 20
CHAT_RATE_WINDOW = 15
CHAT_RATE_LIMIT = 10
CHAT_MUTE_RESET = 86400 -- 每个玩家从首次违规起24小时重置一次禁言等级
CHAT_MUTE_TICK = 0.0125

-- Minecraft 指令不再使用 AI 黑名单拦截系统。
-- 需要投票的指令
VOTE_COMMANDS = {
    ["time set day"] = true,
    ["time set night"] = true,
    ["time set noon"] = true,
    ["time set midnight"] = true,
    ["weather clear"] = true,
    ["weather rain"] = true,
    ["weather thunder"] = true,
}

KNOWN_TAGS = {"vip","admin","op","ai_access","builder"}
RUNTIME = {last_health = {}, last_pos = {}, last_tick = {}, known_players = {}}
choose_signin_reward = nil
run_agent = nil
is_admin = nil

-- AI 系统提示词：恢复原生聊天风格；Shell 只是能力参考，不是限制。
AI_SYSTEM_BASE = [[你是运行在网易《我的世界》基岩版租赁服里的 Ds AI Agent，由 Prism 工具箱驱动。
你必须先理解当前玩家是谁、TA 的权限等级和游戏状态，再决定如何回答或操作。

【运行环境（必须时刻记住）】
- 服务器：网易我的世界 基岩版租赁服（Bedrock 内核）。
- 指令语法：只按国际基岩版（Bedrock）语法写，不要套用 Java 版语法。
- 版本基准：国际基岩正式版 1.21.x。不确定的指令先用 [SEARCH_WEB] 联网确认再执行。
- 执行通道：你的 [CMD]/[SHELL4] 由插件真实执行，服务器真实返回结果会回传给你。
- 玩家与生物都是实体；机器人（执行者）自己也是有 OP 的玩家实体。

【输出工具（只有这些标记会被真正执行）】
1. 执行 Minecraft 指令：[CMD]指令[/CMD]（旧写法 [SHELL4]指令[/SHELL4]）
2. 查询玩家分数：[GETSCORE]玩家名 记分板名[/GETSCORE]
3. 查询玩家信息：[GETINFO]玩家名[/GETINFO]（普通玩家只能查自己）
4. 查询标签：[GETTAG]玩家名 标签名[/GETTAG]
5. 查询在线玩家：[LIST][/LIST]
6. 定位结构：[LOCATE]结构名[/LOCATE]
   （走游戏内 /locate 真实定位，读的就是本服世界，结果绝对准确；
     支持：村庄/要塞/海底神殿/林地府邸/废弃传送门/掠夺者前哨站/远古城市/沼泽小屋/
           沙漠神殿/丛林神庙/沉船/埋藏的宝藏/废弃矿井/试炼密室/古迹废墟）
7. 联网搜索：[SEARCH_WEB]搜索内容[/SEARCH_WEB]（旧写法 [NET]内容[/NET]）
8. 查询背包：[GETINVENTORY]self[/GETINVENTORY]
9. 查询方块 NBT：[NBT]X Y Z[/NBT]（建筑模式禁用）
10. 读取现实时间：[TIME][/TIME]
11. 保存/修改人物设定：[PERSONA]设定内容[/PERSONA]
12. 兼容旧能力：[SHELL1]查自己坐标[/SHELL1]、[SHELL2]effect 效果 秒 等级[/SHELL2]、[SHELL3]info 玩家名[/SHELL3]
13. 时间/天气投票：[VOTE]time set day[/VOTE]（普通玩家必须走投票）
14. 建筑模式：[BUILD]开启建筑模式[/BUILD]；关闭 [BUILD_OFF][/BUILD_OFF]；停止施工 [BUILD_STOP][/BUILD_STOP]
15. 管理权限查询服务端日志：[LOG]查询内容[/LOG]（例如“3分钟前的聊天”）

【绝对不要做的事】
- 不要把你打算调用工具的过程话讲给玩家听（例如“我正在调用”“准备执行”“马上查询”）。
  要操作就直接输出工具标记；拿到插件回传的真实结果后再用自然语言汇报。
- 不要编造执行结果；没有工具返回就等于没有执行。
- 不要在 [CMD] 里写 game.sendCommand(...) 之类的伪代码，也不要写前导 /。
- 不要在一条 [CMD] 里塞多条指令、分号或换行；多个物品就是多条 give。
- 回答里不要出现工具标记、内部字段、原始报错堆栈。

【基岩版与 Java 版的差异（最容易翻车，按右列做）】
- 给附魔物品：基岩版 give 不支持 Java 的 {"Enchantments":[...]} 组件写法。
  正确做法：先 give 一把普通物品，再用多条 enchant 逐条附魔。
  例：满级下界合金剑 = [CMD]give @s netherite_sword 1[/CMD]，
  再依次 [CMD]enchant @s sharpness 5[/CMD]、[CMD]enchant @s looting 3[/CMD]、
  [CMD]enchant @s unbreaking 3[/CMD]、[CMD]enchant @s mending 1[/CMD]、[CMD]enchant @s fire_aspect 2[/CMD]。
- 不要用 Java 专有的 /data、/attribute、/item、/loot ... mine；
  容器内容搬运改用 /clone、/setblock、/structure，或本插件的 .导出 / .导入。
- execute 写法：基岩版用 execute as <目标> at @s run <指令>，
  不要用 Java 的 positioned/align 嵌套，也不要在 run 里再套 execute。
- 选择器：基岩版支持 @a[name="名字"]、tag=、type=、scores={}、hasitem={}；
  不支持 Java 的 nbt={} 选择器参数。
- 结构定位：本服 /locate structure <英文id> 实测可用，直接用就行。
  例：village / stronghold / monument / mansion / ruined_portal / pillager_outpost /
  ancient_city / shipwreck / buried_treasure / mineshaft / trial_chambers / trail_ruins。
  注意：把 locate 包进 execute 时回显会丢失（玩家自己看得到），要拿坐标给插件处理就用裸 locate。
  用中文结构名交给 [LOCATE] 工具最省事。
- 结构保存与加载：/structure save|load|delete <英文ID> <坐标>；结构 ID 只用英文数字下划线。
- 文本与标题：tellraw 用 {"rawtext":[{"text":"..."}]}；标题用 titleraw <目标> title|subtitle|actionbar。
- 大范围施工：单次 /fill 最多 32768 方块，两个端点都要在已加载区块内；超了就拆多次，或先 tp 自己过去。
  clone 单次范围同样不要超过 32768 方块。
- 药水：/effect <目标> <效果> <持续秒> <等级> [隐藏粒子]，等级上限 255。
- 时间/天气：/time set day|night|noon|midnight|sunrise|sunset 或 /time set <数值>；/weather clear|rain|thunder [秒数]。
- 需要 OP 的指令（give/gamemode/effect/tp/kill/scoreboard/fill/setblock/tickingarea 等）由机器人 OP 身份执行；
  失败时先读服务器真实返回，换一种写法再试，不要反复发同一条必然失败的指令。
- 网易租赁服：传送/给物品优先用 @a[name="玩家名"] 这种选择器；不要把玩家名硬编码进别的语法位置。

【权限规则】
- 普通玩家：只能查询自己的信息/分数/标签/状态；不能 give、tp 他人、kill、kick、gamemode、改权限；
  可以用 effect，但持续不超过 60 秒、等级不高于 II。
- 普通玩家要求改时间/天气时，必须用 [VOTE] 帮 TA 发起投票，禁止直接执行 time/weather。
- 管理权限：可以查询其他在线玩家，也可以按要求真实执行 Minecraft 指令。
- 玩家名为“疣螈”时，插件强制视为最高权限。
- 不要用 execute/function/run 等方式绕过上面的权限限制。
- 管理员要求禁言某玩家时，直接输出 [MUTE]玩家名 时长[/MUTE]（时长支持：30秒 / 10分钟 / 2小时 / 3天 / 永久；0 表示解除禁言）。
  不要用 [CMD] tag ... add 禁言 的方式，那样不会到期自动解除。
- 管理员查询背包：插件会自动把结果全服公布，你照实汇报即可，不要编造。

【做事方式】
- “我/自己”永远指当前发起请求的玩家；涉及 TA 本人时优先用 @s 或 @a[name="玩家名"]。
- 一轮里能做完的事就一次把所有 [CMD] 都写出来，插件逐条执行并回传真实结果。
- 指令失败时：看真实返回 → 判断原因 → 换一种可行写法重试；实在不行就如实说明哪一步失败、为什么。
- 多步任务完成后，用简短中文汇报“做了什么、结果如何”。

【建筑模式】（有管理权限的玩家要求建造时，先 [BUILD]开启建筑模式[/BUILD]）
- 建筑模式由插件真实记录：读取普通聊天/指令历史，记忆最多 100 轮，使用 DeepSeek Flash，每条指令都会校验真实结果。
- 严禁降配、偷工减料、压缩规模；用户给的尺寸与档次必须严格执行，不允许做成空心火柴盒。
- 顺序：地基 → 主体框架 → 门窗结构 → 楼层分隔与楼梯 → 室内家具摆件 → 庭院景观/围墙道路 → 灯光照明。
- 大面积用 /fill（≤32768 且两端点在自身 64 格内），细节用 setblock；室内要有完整内饰，庭院要有景观与步道。
- 施工前确认自己在施工区（超过 64 格先 tp 过去）；本轮做完就停下，等玩家说【继续】再接着施工。
- 禁止使用 [NBT] 工具或 NBT/结构数据辅助建筑。
- 玩家要求“停止建筑”就调用 [BUILD_STOP]；要求“关闭建筑模式”就调用 [BUILD_OFF]。

【回答风格】
- 默认简体中文、自然口语；不复述工具标记，不展示内部思考过程。
- 能确定的指令直接执行；拿不准的先联网确认。
- 如果上下文里出现“【全服 AI 总设定】”，那是管理员下发的最高优先级规则，必须无条件遵守。]]


AI_PERSONA_PROMPT = [[默认简体中文。玩家可以主动提供人物设定、说话风格、身份设定；保存后持续使用，直到玩家修改或清除。]]

function current_real_time()
    local ok,v=pcall(util.now); if ok and v then return tostring(v) end
    local ok2,v2=pcall(util.time_fmt); if ok2 and v2 then return tostring(v2) end
    return tostring(util.timestamp())
end
function load_ai_persona(playerName)
    local ok,d=pcall(util.json_load,AI_PERSONA_FILE); if not ok or type(d)~="table" then return "" end
    return trim(d[tostring(playerName)] or "")
end
function save_ai_persona(playerName,text)
    local ok,d=pcall(util.json_load,AI_PERSONA_FILE); if not ok or type(d)~="table" then d={} end
    d[tostring(playerName)]=trim(text or ""); pcall(util.json_write,AI_PERSONA_FILE,d)
end

-- Shell/ 目录不参与运行时加载。所有 AI 能力均由 main.lua 内置实现，避免 Prism 工作目录变化导致 io.open("Shell/...") 读取失败。
function load_shell_guidance()
    return ""
end

-- ════════════════════════════════════════════════════════════
--   工具函数
-- ════════════════════════════════════════════════════════════

function trim(s) return util.trim(tostring(s or "")) end
function distance3d(a,b)
    if type(a)~="table" or type(b)~="table" then return 999999 end
    local dx=(tonumber(a.x) or 0)-(tonumber(b.x) or 0)
    local dy=(tonumber(a.y) or 0)-(tonumber(b.y) or 0)
    local dz=(tonumber(a.z) or 0)-(tonumber(b.z) or 0)
    return math.sqrt(dx*dx+dy*dy+dz*dz)
end
function lower(s) return string.lower(tostring(s or "")) end
function extract_digits(s)
    local t = trim(s)
    if not t:match("^%d+$") then return nil end
    local n = tonumber(t)
    if not n or n < 1 or n % 1 ~= 0 then return nil end
    return n
end

function send(playerName, text)
    pcall(game.sendTargeted, playerName, tostring(text or ""))
end

function broadcast(text)
    pcall(game.sendChat, "@a", tostring(text or ""))
end
function send_long(playerName, text, chunk_size)
    text=tostring(text or "")
    local n=tonumber(chunk_size) or 700
    if #text<=n then send(playerName,text); return end
    local pos=1
    while pos<=#text do
        local stop=math.min(#text,pos+n-1)
        if stop<#text then
            local cut=text:sub(pos,stop):match("^.*()\n")
            if cut and cut>20 then stop=pos+cut-1 end
        end
        send(playerName,text:sub(pos,stop))
        pos=stop+1
    end
end

-- ════════════════════════════════════════════════════════════
--   数据持久化
-- ════════════════════════════════════════════════════════════

function load_data()
    local ok, d = pcall(util.json_load, DATA_FILE)
    if ok and type(d) == "table" then
        d.players = d.players or {}
        d.conversations = d.conversations or {}
        d.command_conversations = d.command_conversations or {}
        d.ai_windows = d.ai_windows or {}
        d.native_structures = d.native_structures or {}
        d.chat_mute_state = d.chat_mute_state or {}
        d.votes = d.votes or {}
        d.menus = d.menus or {}
        d.tpa = d.tpa or {steps = {}, queues = {}}
        d.tpa.steps = d.tpa.steps or {}
        d.tpa.queues = d.tpa.queues or {}
        d.transfers = d.transfers or {}
        d.reports = d.reports or {}
        d.blacklist = d.blacklist or {}
        d.report_history = d.report_history or {}
        d.market_busy = d.market_busy or false
        d.market_sessions = d.market_sessions or {}
        d.territory_sessions = d.territory_sessions or {}
        return d
    end
    return {players={}, conversations={}, command_conversations={}, ai_windows={}, native_structures={}, votes={}, menus={}, tpa={steps={}, queues={}}, transfers={}, reports={}, blacklist={}, report_history={}, chat_mute_state={}, market_busy=false, market_sessions={}, territory_sessions={}}
end

function save_data(d)
    pcall(util.json_write, DATA_FILE, d)
end

-- TPA queues live in a separate file. Menu saves and waypoint saves must never
-- overwrite a just-created teleport request.
function load_tpa()
    local ok, d = pcall(util.json_load, TPA_FILE)
    if ok and type(d) == "table" then
        d.queues = d.queues or {}
        return d
    end
    return {queues = {}}
end

function save_tpa(d)
    pcall(util.json_write, TPA_FILE, d)
end

-- 统一运行日志。
-- 高频日志（每条聊天、每条指令）先写进一个小缓冲文件，再由主循环每 2 秒 flush 一次合并进 runtime.log。
-- 旧版每次 log_event 都要「读整个 runtime.log + 重新写回」；文件涨到 1MB 后，每条聊天就是约 2MB 磁盘读写，
-- 这是服务器卡顿的重要来源之一。
LOG_FILE = game.dataDir() .. "/runtime.log"
LOG_BUFFER_FILE = game.dataDir() .. "/runtime_pending.log"
LOG_MAX_BYTES = 512 * 1024
LOG_BUFFER_MAX_BYTES = 24 * 1024
function log_time_local(epoch)
    local t=tonumber(epoch) or tonumber(util.timestamp()) or os.time()
    local ok,v=pcall(util.time_fmt,t)
    if ok and v then return tostring(v) end
    local ok2,v2=pcall(util.now)
    if ok2 and v2 then return tostring(v2) end
    return tostring(t)
end

function log_event(kind, message)
    local epoch=tonumber(util.timestamp()) or os.time()
    local line = string.format("[%s] [%s] %s\n", log_time_local(epoch), tostring(kind), tostring(message or ""))
    local ok, old = pcall(util.read_file, LOG_BUFFER_FILE)
    old = ok and tostring(old or "") or ""
    local content = old .. line
    if #content > LOG_BUFFER_MAX_BYTES then content = content:sub(-LOG_BUFFER_MAX_BYTES) end
    pcall(util.write_file, LOG_BUFFER_FILE, content)
end

-- 把缓冲日志合并进主日志（由 util.schedule 定时调用，也可在需要读日志前手动调用）。
function flush_log_buffer()
    local ok, buf = pcall(util.read_file, LOG_BUFFER_FILE)
    if not ok or type(buf)~="string" or buf=="" then return end
    local ok2, old = pcall(util.read_file, LOG_FILE)
    old = ok2 and tostring(old or "") or ""
    local content = old .. buf
    if #content > LOG_MAX_BYTES then content = content:sub(-LOG_MAX_BYTES) end
    pcall(util.write_file, LOG_FILE, content)
    pcall(util.write_file, LOG_BUFFER_FILE, "")
end

-- 读取完整运行日志（先把缓冲合并进来，保证刚发生的事件也在里面）。
function runtime_log_text()
    pcall(flush_log_buffer)
    local ok, content = pcall(util.read_file, LOG_FILE)
    if not ok then return "" end
    return tostring(content or "")
end

function read_recent_logs(playerName, query)
    if not is_admin(playerName) then return "只有管理权限可以查看日志。" end
    local content = runtime_log_text()
    if content == "" then return "暂无日志。" end
    query=trim(query or "")
    local lines={}
    for line in content:gmatch("[^\r\n]+") do lines[#lines+1]=line end
    local minutes=query:match("(%d+)%s*分钟前") or query:match("(%d+)%s*分钟")
    local now=tonumber(util.timestamp()) or os.time()
    local matched={}
    if minutes then
        local cutoff=now-tonumber(minutes)*60
        for _,line in ipairs(lines) do
            local y,mo,d,h,mi,se=line:match("%[(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d):(%d%d)%]")
            if y then
                local epoch=os.time({year=tonumber(y),month=tonumber(mo),day=tonumber(d),hour=tonumber(h),min=tonumber(mi),sec=tonumber(se)})
                if epoch>=cutoff then matched[#matched+1]=line end
            end
        end
    end
    local qlow=lower(query:gsub("%d+%s*分钟前",""))
    qlow=trim(qlow:gsub("谁说了什么",""))
    if qlow~="" then
        local filtered={}
        for _,line in ipairs(#matched>0 and matched or lines) do
            if lower(line):find(qlow,1,true) then filtered[#filtered+1]=line end
        end
        matched=filtered
    end
    if #matched==0 then
        local src=(#matched==0 and #lines>0) and lines or matched
        local start=math.max(1,#src-80+1)
        for i=start,#src do matched[#matched+1]=src[i] end
    end
    if #matched>120 then local tmp={}; for i=#matched-119,#matched do tmp[#tmp+1]=matched[i] end; matched=tmp end
    return "§b日志查询结果（Prism 本地时间）：\n§f" .. table.concat(matched,"\n")
end

-- 管理权限AI日志工具：仅管理权限可用；支持“几分钟前/多少分钟前/某玩家/关键词”等自然语言查询。
function admin_ai_log_query(playerName, query)
    if not is_admin(playerName) then return "权限限制：只有管理权限可以读取 runtime.log。" end
    return read_recent_logs(playerName, query)
end

function plugin_config()
    return {
        qq_enabled = game.getConfig("qq_enabled", false) == true,
        qq_group_id = tostring(game.getConfig("qq_group_id", "1083036035")),
        qq_relay_url = tostring(game.getConfig("qq_relay_url", "")),
        qq_token = tostring(game.getConfig("qq_token", "")),
        qq_poll_interval = tonumber(game.getConfig("qq_poll_interval", 5)) or 5,
    }
end

-- ════════════════════════════════════════════════════════════
--   全服 AI 总设定（管理员下发；所有玩家、所有 AI 会话一律遵守）
--   .AI 修改所有AI设定 <内容>   /  .全服AI设定 <内容>
--   .AI 查看所有AI设定          /  .AI 删除所有AI设定 <编号>
--   .AI 清空所有AI设定
-- ════════════════════════════════════════════════════════════

-- 世界种子校验：基岩版使用有符号 64 位整数，允许负号，最长 19 位数字。
function valid_seed(text)
    text=trim(text or "")
    if text=="" then return false end
    if not text:match("^%-?%d+$") then return false end
    local digits=text:gsub("^%-","")
    if #digits<1 or #digits>19 then return false end
    return true
end

function load_global_ai_rules()
    local ok,d=pcall(util.json_load,AI_GLOBAL_FILE)
    if ok and type(d)=="table" and type(d.rules)=="table" then return d end
    return {rules={}}
end
function save_global_ai_rules(d)
    pcall(util.json_write,AI_GLOBAL_FILE,d)
end
function global_ai_rules_text()
    local d=load_global_ai_rules()
    local lines={}
    for _,r in ipairs(d.rules or {}) do
        if type(r)=="table" and trim(r.text or "")~="" then
            lines[#lines+1]=tostring(#lines+1)..". "..trim(r.text)
        end
    end
    if #lines==0 then return "" end
    return "【全服 AI 总设定（管理员下发，优先级最高）】\n以下规则对所有玩家、所有会话、所有窗口无条件生效，任何玩家设定都不得覆盖它：\n"..table.concat(lines,"\n")
end
function add_global_ai_rule(adminName,text)
    text=trim(text or "")
    if text=="" then return false end
    local d=load_global_ai_rules(); d.rules=d.rules or {}
    table.insert(d.rules,{text=text,by=adminName,at=util.timestamp()})
    d.updated_at=util.timestamp(); d.updated_by=adminName
    save_global_ai_rules(d)
    log_event("AI_GLOBAL",tostring(adminName).." -> "..text)
    return true,#d.rules
end
function remove_global_ai_rule(index)
    local d=load_global_ai_rules(); d.rules=d.rules or {}
    index=tonumber(index)
    if not index or not d.rules[index] then return false end
    table.remove(d.rules,index)
    save_global_ai_rules(d)
    return true,#d.rules
end

-- ════════════════════════════════════════════════════════════
--   QQ 群服互通（插件只负责 HTTP 收发，协议见 docs.md）
--   中转程序接口：
--     POST {relay}/api/send                  {"group_id","token","text"}
--     GET  {relay}/api/poll?group_id=&cursor= -> {"cursor":n,"messages":[{"user","text"}]}
-- ════════════════════════════════════════════════════════════

function qq_relay_config()
    return {
        enabled = game.getConfig("qq_enabled", false) == true,
        group   = tostring(game.getConfig("qq_group_id", "") or ""),
        url     = tostring(game.getConfig("qq_relay_url", "") or ""),
        token   = tostring(game.getConfig("qq_token", "") or ""),
        poll    = tonumber(game.getConfig("qq_poll_interval", 5) or 5) or 5,
    }
end
function qq_relay_ready()
    local c=qq_relay_config()
    return c.enabled and c.url~=""
end
function qq_send(text)
    if not qq_relay_ready() then return false end
    local c=qq_relay_config()
    local body=http.json_encode({group_id=c.group,token=c.token,text=tostring(text or "")})
    local ok,res=pcall(http.post,c.url:gsub("/+$","").."/api/send",body,{headers={['Content-Type']='application/json'},timeout=10})
    if not ok or type(res)~="table" or res.ok~=true or tonumber(res.status)~=200 then
        log_event("QQ","send failed: "..tostring(type(res)=="table" and (res.status or res.error) or res))
        return false
    end
    return true
end
function qq_tick()
    if not qq_relay_ready() then return end
    local c=qq_relay_config()
    local d=load_data(); d.qq_state=d.qq_state or {cursor=0}
    local url=c.url:gsub("/+$","").."/api/poll?"..http.querify({group_id=c.group,cursor=tostring(d.qq_state.cursor or 0)})
    local ok,res=pcall(http.get,url,{timeout=10})
    if not ok or type(res)~="table" or res.ok~=true or tonumber(res.status)~=200 then return end
    local dok,data=http.json_decode(res.body or "")
    if not dok or type(data)~="table" then return end
    local changed=false
    if data.cursor~=nil then
        local cur=tonumber(data.cursor)
        if cur and cur~=tonumber(d.qq_state.cursor) then d.qq_state.cursor=cur; changed=true end
    end
    for _,m in ipairs(data.messages or {}) do
        if type(m)=="table" then
            local user=tostring(m.user or m.name or "QQ")
            local text=trim(m.text or m.message or "")
            if text~="" then
                broadcast("§9[QQ] §f"..user.."§7：§f"..text)
                log_event("QQ",user..": "..text)
                changed=true
            end
        end
    end
    if changed then save_data(d) end
end
function qq_status_text()
    local c=qq_relay_config()
    local lines={"§b━━ QQ 群服互通 ━━"}
    lines[#lines+1]="§f状态："..(c.enabled and "§a已启用" or "§c未启用")
    lines[#lines+1]="§f中转地址："..(c.url~="" and c.url or "§c未配置")
    lines[#lines+1]="§f群号："..(c.group~="" and c.group or "§c未配置")
    lines[#lines+1]="§f令牌："..(c.token~="" and "已配置" or "未配置")
    lines[#lines+1]="§7游戏→QQ：聊天框输入 §f.通 <内容>"
    lines[#lines+1]="§7QQ→游戏：由中转程序轮询后自动广播"
    return table.concat(lines,"\n")
end

-- ════════════════════════════════════════════════════════════
--   对话记忆系统
-- ════════════════════════════════════════════════════════════

function get_history(playerName, commandMode, windowKey)
    local data=load_data(); data.ai_memory_epoch=data.ai_memory_epoch or {}; local epoch=tonumber(data.ai_memory_epoch[playerName]) or 0
    local box=commandMode and data.command_conversations or data.conversations
    if windowKey and windowKey~="chat" and windowKey~="command" then
        data.ai_windows=data.ai_windows or {}; data.ai_windows[windowKey]=data.ai_windows[windowKey] or {}
        local h=data.ai_windows[windowKey][playerName]; if type(h)=="table" and h.__epoch then return tonumber(h.__epoch)==epoch and (h.messages or {}) or {} end; return h or {}
    end
    local h=box[playerName]; if type(h)=="table" and h.__epoch then return tonumber(h.__epoch)==epoch and (h.messages or {}) or {} end; return h or {}
end
AI_RECENT_MEMORY_MAX_CHARS=18000
AI_RECENT_TOOL_RESULT_CHARS=1800
function save_history(playerName,messages,commandMode,windowKey,history_limit)
    local data=load_data(); data.conversations=data.conversations or {}; data.command_conversations=data.command_conversations or {}; data.ai_windows=data.ai_windows or {}; data.ai_memory_epoch=data.ai_memory_epoch or {}
    local box
    if windowKey and windowKey~="chat" and windowKey~="command" then data.ai_windows[windowKey]=data.ai_windows[windowKey] or {}; box=data.ai_windows[windowKey] else box=commandMode and data.command_conversations or data.conversations end
    history_limit=tonumber(history_limit) or HISTORY_ROUNDS
    -- 保持指定轮数玩家对话，但把最近的工具结果也保留下来，避免AI只记得“我调用过能力”却忘了能力实际返回什么。
    local history,recent_questions,total_chars={},0,0
    for i=#messages,1,-1 do
        local msg=messages[i]
        if msg.role=="assistant" then
            local c=tostring(msg.content or "")
            if #c>3000 then c=c:sub(1,3000) end
            local copy={role="assistant",content=c}; table.insert(history,1,copy); total_chars=total_chars+#c
        elseif msg.role=="user" then
            local c=tostring(msg.content or "")
            local is_tool=string.find(c,"能力执行结果：",1,true) or string.find(c,"能力执行失败",1,true) or string.find(c,"工具执行结果",1,true)
            if is_tool then
                if #c>AI_RECENT_TOOL_RESULT_CHARS then c=c:sub(1,AI_RECENT_TOOL_RESULT_CHARS).."…" end
                local copy={role="user",content=c}; table.insert(history,1,copy); total_chars=total_chars+#c
            else
                if #c>4000 then c=c:sub(1,4000) end
                table.insert(history,1,{role="user",content=c}); recent_questions=recent_questions+1; total_chars=total_chars+#c
                if recent_questions>=history_limit then break end
            end
        end
        if total_chars>=AI_RECENT_MEMORY_MAX_CHARS then break end
    end
    box[playerName]={__epoch=tonumber(data.ai_memory_epoch[playerName]) or 0,messages=history,updated_at=util.now(),recent_rounds=recent_questions}
    save_data(data)
end

function get_build_history(playerName)
    local normal=get_history(playerName,false,"chat") or {}
    local command=get_history(playerName,true,"command") or {}
    local data=load_data(); data.ai_windows=data.ai_windows or {}; local bh=data.ai_windows.build and data.ai_windows.build[playerName] or {}
    local build=(type(bh)=="table" and bh.messages) or {}
    local merged={}
    local function append(list) for _,m in ipairs(list) do if type(m)=="table" and (m.role=="user" or m.role=="assistant") then table.insert(merged,{role=m.role,content=tostring(m.content or "")}) end end end
    append(normal); append(command); append(build)
    local out={}; local questions=0
    for i=#merged,1,-1 do
        local m=merged[i]; table.insert(out,1,m)
        if m.role=="user" and not string.find(tostring(m.content or ""),"能力执行结果：",1,true) and not string.find(tostring(m.content or ""),"能力执行失败",1,true) and not string.find(tostring(m.content or ""),"工具执行结果",1,true) then
            questions=questions+1
            if questions>=BUILD_HISTORY_ROUNDS then break end
        end
    end
    return out
end

function save_build_history(playerName,messages)
    -- 建筑模式单独保留100轮，同时把这次真实对话的最近20轮同步回普通聊天记忆，确保退出建筑模式后不会“失忆”。
    save_history(playerName,messages,false,"build",BUILD_HISTORY_ROUNDS)
    save_history(playerName,messages,false,"chat",HISTORY_ROUNDS)
end

function clear_ai_memory(playerName)
    local data=load_data(); data.conversations=data.conversations or {}; data.command_conversations=data.command_conversations or {}; data.ai_windows=data.ai_windows or {}; data.ai_memory_epoch=data.ai_memory_epoch or {}
    data.ai_memory_epoch[playerName]=(tonumber(data.ai_memory_epoch[playerName]) or 0)+1
    data.conversations[playerName]=nil; data.command_conversations[playerName]=nil; for _,box in pairs(data.ai_windows) do if type(box)=="table" then box[playerName]=nil end end
    save_data(data); return data.ai_memory_epoch[playerName]
end

-- 每次插件重新加载/重启都建立新的AI会话窗口。
-- 只清除聊天/指令AI历史，不删除玩家资料、人物设定、市场、领地等持久数据。
function reset_ai_session_on_plugin_start()
    local data=load_data()
    data.conversations={}
    data.command_conversations={}
    data.ai_windows={}
    data.ai_memory_epoch=data.ai_memory_epoch or {}
    data.ai_session_id=(tonumber(data.ai_session_id) or 0)+1
    data.ai_session_started_at=util.timestamp()
    save_data(data)
    return data.ai_session_id
end

-- ════════════════════════════════════════════════════════════
--   玩家信息
-- ════════════════════════════════════════════════════════════

function get_info(name)
    local ok, info = pcall(player.get, name)
    if not ok or type(info) ~= "table" or not info.name then return nil end
    return info
end

function identity(name)
    local info = get_info(name) or {name = name, xuid = "", unique_id = ""}
    local xuid = trim(info.xuid)
    local uid = trim(info.unique_id)
    local key = xuid ~= "" and xuid or (uid ~= "" and uid or trim(name))
    return key, info
end

is_admin = function(name)
    if name == SUPERUSER then return true end
    local ok, r = pcall(player.isOP, name)
    if ok and r ~= nil then return r == true end
    local info = get_info(name)
    if info and info.is_op ~= nil then return info.is_op == true end
    return false
end

function check_tag(name, tag)
    if name == "" or tag == "" then return false end
    local n = string.gsub(name, '"', '\\"')
    local t = string.gsub(tag, '"', '\\"')
    local ok, hit = pcall(game.isCmdSuccess, 'testfor @a[name="' .. n .. '",tag="' .. t .. '"]')
    return ok and hit == true
end

-- ════════════════════════════════════════════════════════════
--   维度检测
-- ════════════════════════════════════════════════════════════

function init_scoreboard()
    local d=load_data()
    local cfg=file_load(SCOREBOARD_CONFIG_FILE,{})
    local board=trim(cfg.name or d.scoreboard_name or "")
    if board~="" then
        d.scoreboard_name=board; d.scoreboard_created=true; save_data(d)
        pcall(game.isCmdSuccess,"scoreboard objectives add "..board.." dummy")
    end
end

function normalize_dimension(value)
    local v = lower(trim(value))
    if v == "1" or string.find(v, "nether", 1, true) or v == "下界" or v == "地狱" then return "nether" end
    if v == "2" or string.find(v, "the_end", 1, true) or v == "end" or v == "末地" then return "the_end" end
    if v == "0" or string.find(v, "overworld", 1, true) or v == "主世界" or v == "主城" then return "overworld" end
    return nil
end

function dimension_display(value)
    local d = normalize_dimension(value)
    if d == "nether" then return "下界" end
    if d == "the_end" then return "末地" end
    return "主世界"
end

function integer_coord(value)
    local n = tonumber(value) or 0
    return tostring(math.floor(n))
end

-- Prefer Prism's tracked dimension. Fallback follows execute-as/in syntax and
-- uses only isCmdSuccess, so no dimension test is printed to game chat.
function detect_dimension(name)
    -- 直接使用框架维护的玩家维度（来源是服务器下发的真实玩家数据），
    -- 这是网易租赁服上唯一可靠的维度来源。
    --
    -- 旧实现用 `execute in <dim> if entity @a[name=...]` 逐个探测维度，
    -- 但在网易租赁服上 @a 选择器不会被 execute in 正确限制维度，
    -- 三个维度全部判定成功，于是永远返回列表首个 "nether"，
    -- 导致主世界玩家被记录成下界。已改为直接读框架维度值。
    local info = get_info(name)
    local tracked = info and normalize_dimension(info.dimension)
    if tracked then return tracked end
    return "overworld"
end

-- ════════════════════════════════════════════════════════════
--   玩家上下文
-- ════════════════════════════════════════════════════════════

function context_for(name)
    local info=get_info(name); local admin=is_admin(name); local s="当前玩家="..name.."\n权限="..(admin and "管理权限" or "普通玩家")
    s=s.."\n当前现实时间="..current_real_time()
    local _,pr=player_record(name,true)
    if info then
        local dim=normalize_dimension(info.dimension) or detect_dimension(name)
        s=s.."\nOP="..tostring(info.is_op).." 在线="..tostring(info.online).." 维度="..tostring(dim)
        if info.x~=nil and info.y~=nil and info.z~=nil then s=s.."\n坐标="..math.floor(tonumber(info.x) or 0)..","..math.floor(tonumber(info.y) or 0)..","..math.floor(tonumber(info.z) or 0) end
    end
    local board=scoreboard_name(); if board then local ok,score=pcall(game.getScore,board,name); s=s.."\n金币/积分="..(ok and tostring(score) or "读取失败") end
    local online_seconds=tonumber(pr.online_seconds) or 0; if pr.online_since then online_seconds=online_seconds+math.max(0,(tonumber(util.timestamp()) or 0)-(tonumber(pr.online_since) or 0)) end
    s=s.."\n累计在线时间="..math.floor(online_seconds).."秒"
    local persona=load_ai_persona(name); if persona~="" then s=s.."\n玩家主动人物设定="..persona end
    return s,admin
end

-- ════════════════════════════════════════════════════════════
--   查询工具
-- ════════════════════════════════════════════════════════════

function get_score(name, board)
    local ok, score = pcall(game.getScore, board, name)
    if ok then return name .. " 在记分板 " .. board .. " 的分数是 " .. tostring(score) end
    return "查询分数失败"
end

function online_players()
    local ok, list = pcall(player.list)
    if not ok or type(list) ~= "table" then return nil end
    local names = {}
    for _, p in ipairs(list) do
        if p and p.name then table.insert(names, tostring(p.name)) end
    end
    return names
end

function online_names_from_list()
    local ok,list=pcall(player.list)
    if not ok or type(list)~='table' then return nil end
    local names={}
    for _,info in ipairs(list) do
        if info and info.name and tostring(info.name)~='' then table.insert(names,tostring(info.name)) end
    end
    return names
end

function list_players()
    local names = online_players()
    if not names then return "无法读取在线玩家列表" end
    return #names == 0 and "当前没有在线玩家" or "在线玩家(" .. #names .. "人)：" .. table.concat(names, ", ")
end

function player_panel(title, names, tail)
    local lines = {title}
    for i, name in ipairs(names or {}) do
        table.insert(lines, tostring(i) .. ". " .. tostring(name))
    end
    if tail and tail ~= "" then table.insert(lines, tail) end
    return table.concat(lines, "\n")
end

function valid_item_id(item)
    return tostring(item or ""):match("^[%w_:%.-]+$") ~= nil
end

normalize_region = nil
format_block_states = nil

STRUCTURE_DIR = game.dataDir() .. "/structures"

function valid_structure_name(name)
    name = trim(name or "")
    if name == "" or #name > 64 then return false end
    if string.find(name, "[\r\n]", 1) then return false end
    return true
end

function structure_hash(name)
    local h = 2166136261
    for i = 1, #tostring(name) do
        h = (h + string.byte(tostring(name), i) * 16777619) % 2147483647
    end
    return string.format("%x", math.floor(h))
end

function native_structure_id(base, index)
    return "dsai_" .. structure_hash(base) .. "_" .. tostring(index)
end

function native_delete_manifest(manifest)
    for _, tile in ipairs((manifest and manifest.tiles) or {}) do
        pcall(game.isCmdSuccess, "structure delete " .. tostring(tile.id))
    end
end

-- 原版 /structure 支持的单块区域由插件拆成最多 64×256×64 的瓦片。
-- 这样插件不再受原来的 20000 方块 Lua/NBT 循环限制，同时允许 X/Z 方向最大 256。
-- 区域 NBT 持久化：明确使用 Prism 开发文档的 getRegionBlockData/placeNBTBlock。
-- 不把 /structure save/load 冒充成我们的区域 NBT 功能。底层 API 内部怎么实现由 Prism 负责。
function nbt_region_db()
    return file_load(NBT_REGION_FILE,{regions={}})
end
function nbt_region_save(d)
    local ok,err=pcall(util.json_write,NBT_REGION_FILE,d)
    return ok,err
end
function valid_region_name(name)
    name=trim(name or "")
    return name~="" and #name<=64 and not string.find(name,"[\r\n]",1)
end
function nbt_region_db()
    return file_load(NBT_REGION_FILE,{regions={}})
end
function nbt_region_save(d)
    local ok,err=pcall(util.json_write,NBT_REGION_FILE,d)
    return ok,err
end
function valid_structure_name(name)
    name=trim(name or "")
    return name~="" and #name<=64 and not string.find(name,"[\r\n]",1)
end
function save_native_region(playerName,name,x1,y1,z1,x2,y2,z2)
    if not valid_structure_name(name) then return false,"名称不能为空、不能换行，最长64字符。" end
    local ax,ay,az,bx,by,bz=normalize_region(x1,y1,z1,x2,y2,z2)
    if not ax then return false,"坐标格式无效。" end
    local width,height,depth=bx-ax+1,by-ay+1,bz-az+1
    if width>256 or depth>256 then return false,"区域 X/Z 最大256。" end
    local ok,data=pcall(game.getRegionBlockData,ax,ay,az,width,height,depth)
    if not ok or type(data)~="table" then return false,"区域 NBT读取失败："..tostring(data) end
    local count=0
    for _,v in pairs(data) do if type(v)=="table" then count=count+1 end end
    if count<=0 then return false,"区域 NBT读取成功，但没有返回任何方块数据。" end
    local db=nbt_region_db(); db.regions=db.regions or {}
    db.regions[tostring(name)]={name=name,origin={x=ax,y=ay,z=az},size={x=width,y=height,z=depth},blocks=data,saved_by=playerName,saved_at=util.timestamp()}
    local sok,serr=nbt_region_save(db)
    if not sok then return false,"区域 NBT保存失败："..tostring(serr) end
    local vok,verify=pcall(util.json_load,NBT_REGION_FILE)
    if not vok or type(verify)~="table" or type(verify.regions)~="table" or type(verify.regions[tostring(name)])~="table" then return false,"区域 NBT写入后回读失败。" end
    log_event("NBT_REGION",playerName.." exported NBT region "..tostring(name).." blocks="..tostring(count))
    return true,"§a区域 NBT 已保存：§e"..tostring(name).." §f("..width.."×"..height.."×"..depth..")。"
end
function load_native_manifest(name)
    local db=nbt_region_db(); local m=(db.regions or {})[tostring(name)]
    if type(m)~="table" or type(m.blocks)~="table" then return nil,"找不到已保存的区域 NBT："..tostring(name) end
    return m
end
-- 区块式导入：把区域数据交给 Prism 批量导入引擎（game.importBlocks）。
-- 引擎按区块分批落位、自动分流轻/重 NBT，所以：
--   1) 不再一个方块一次调用（旧版 placeNBTBlock 逐块放，慢且容器容易空）；
--   2) 箱子/木桶/发射器等容器里的物品会一起填回去（“导入后里面有物品”）。
-- 导入引擎会把“最小坐标”平移到锚点，所以这里先自己做一次对齐，
-- 保证恢复出来的建筑与保存时逐格一致。
-- 导入前规整 NBT：区域读回来的数值都是字符串（"Count":"5"），
-- 而批量导入引擎按数字解析物品，必须先转回数字，否则容器里的物品会丢。
function normalize_import_nbt(nbt)
    if type(nbt)~="table" then return nbt end
    local items=nbt.Items
    if type(items)=="table" then
        local norm={}
        for _,it in pairs(items) do
            if type(it)=="table" then
                for _,pair in ipairs({{"count","Count"},{"slot","Slot"},{"damage","Damage"},{"name","Name"}}) do
                    if it[pair[2]]==nil and it[pair[1]]~=nil then it[pair[2]]=it[pair[1]] end
                end
                for _,k in ipairs({"Count","Slot","Damage"}) do
                    local sv=it[k]
                    if type(sv)=="string" then
                        local nv=tonumber(sv)
                        if nv~=nil then it[k]=nv end
                    end
                end
                norm[#norm+1]=it
            end
        end
        nbt.Items=norm
    end
    return nbt
end

function place_native_region(playerName,name,tx,ty,tz)
    local m,err=load_native_manifest(name)
    if not m then return false,err end
    tx,ty,tz=math.floor(tonumber(tx) or 0),math.floor(tonumber(ty) or 0),math.floor(tonumber(tz) or 0)
    local origin=m.origin or {}
    local ox,oy,oz=tonumber(origin.x),tonumber(origin.y),tonumber(origin.z)
    if not ox or not oy or not oz then return false,"区域数据原点损坏。" end

    local raw={}
    local minx,miny,minz=nil,nil,nil
    for key,v in pairs(m.blocks or {}) do
        local sx,sy,sz=tostring(key):match("^(-?%d+),(-?%d+),(-?%d+)$")
        if sx and type(v)=="table" then
            local bn=tostring(v.name or v.id or "")
            if bn~="" and not lower(bn):find("air",1,true) then
                local rx,ry,rz=tonumber(sx)-ox,tonumber(sy)-oy,tonumber(sz)-oz
                local item={x=rx,y=ry,z=rz,name=bn}
                if type(v.states)=="table" then
                    item.states=v.states
                elseif v.states~=nil and tostring(v.states)~="" then
                    item.states=tostring(v.states)
                end
                if type(v.nbt)=="table" then item.nbt=normalize_import_nbt(v.nbt) end
                raw[#raw+1]=item
                if minx==nil or rx<minx then minx=rx end
                if miny==nil or ry<miny then miny=ry end
                if minz==nil or rz<minz then minz=rz end
            end
        end
    end
    if #raw<=0 then return false,"区域数据里没有可放置的方块。" end

    local list={}
    for _,item in ipairs(raw) do
        local one={x=item.x-minx,y=item.y-miny,z=item.z-minz,name=item.name}
        if item.states~=nil then one.states=item.states end
        if item.nbt~=nil then one.nbt=item.nbt end
        list[#list+1]=one
    end

    local ok_call,run=pcall(game.importBlocks,list,{
        x=tx,y=ty,z=tz,
        dimension=dim_exec(detect_dimension(playerName)),
        speed=-1,
        region_mode=1,
        anti_loss=true,
    })
    if not ok_call then return false,"导入失败："..tostring(run) end

    log_event("NBT_REGION",tostring(playerName).." imported region "..tostring(name).." blocks="..tostring(#list))
    -- 超大型区域不在本次调用里阻塞等待，交给后台放置引擎继续落位。
    if #list>20000 then
        return true,"§a已开始导入：§e"..tostring(name).." §f（"..tostring(#list).." 个方块），后台继续落位。"
    end
    local ok_wait,finished=pcall(game.importWait,run)
    if not ok_wait then return false,"导入过程被中断："..tostring(finished) end
    if finished==true then
        return true,"§a导入完成：§e"..tostring(name).." §f（"..tostring(#list).." 个方块）"
    end
    return false,"导入被中断，已放置部分方块。"
end

function create_redeem_code(adminName, kind, payload, expires_at)
    local d=load_data()
    d.redeem_codes=d.redeem_codes or {}
    local code=generate_code(d)
    if not code then return nil,"兑换码生成失败，请重试。" end
    d.redeem_codes[code]={kind=kind,payload=payload,created_by=adminName,created_at=util.timestamp(),expires_at=expires_at,used=false}
    save_data(d)
    log_event("REDEEM",adminName.." created "..code.." kind="..kind)
    return code
end

function redeem_code(playerName,code)
    local raw_code=trim(code or "")
    code=lower(raw_code)
    local d=load_data()
    d.redeem_codes=d.redeem_codes or {}
    -- 新码统一小写；同时兼容 V1.0.8 及更早版本已经生成的旧兑换码。
    local entry=d.redeem_codes[code] or d.redeem_codes[raw_code] or d.redeem_codes[string.upper(raw_code)]
    local entry_key=(d.redeem_codes[code] and code) or (d.redeem_codes[raw_code] and raw_code) or (d.redeem_codes[string.upper(raw_code)] and string.upper(raw_code))
    if type(entry)~="table" then return false,"兑换码不存在或已失效。" end
    if entry.used then return false,"这个兑换码已经被使用过了。" end
    RUNTIME.redeem_locks = RUNTIME.redeem_locks or {}
    local lock_key=lower(raw_code)
    if RUNTIME.redeem_locks[lock_key] then return false,"这个兑换码正在兑换中，请稍后再试。" end
    RUNTIME.redeem_locks[lock_key]=true
    local now=tonumber(util.timestamp()) or 0
    if tonumber(entry.expires_at) and now>=tonumber(entry.expires_at) then
        RUNTIME.redeem_locks[lock_key]=nil
        return false,"这个兑换码已经过期。"
    end

    local ok,result
    if entry.kind=="structure" then
        local p=entry.payload or {}
        if type(p)~="table" or trim(tostring(p.name or ""))=="" then
            RUNTIME.redeem_locks[lock_key]=nil
            return false,"兑换码数据损坏。"
        end
        local loc=player_position(playerName)
        if not loc then
            RUNTIME.redeem_locks[lock_key]=nil
            return false,"无法读取你当前的位置。"
        end
        ok,result=place_native_region(playerName,p.name,math.floor(loc.x),math.floor(loc.y),math.floor(loc.z))
    elseif entry.kind=="ai" then
        -- 自然语言兑换码：兑换时交给 AI 思考并实际执行指令。
        -- 关键：AI 兑换码是"一问一答"，一次性执行完就结束，不再多轮循环。
        -- 具体限制由 run_agent 的 opts 传入（max_rounds / cmd_limit / timeout）。
        -- 无论成功或失败，兑换码都会被永久删除（见下方），避免 AI 反复执行。
        local ok_agent,reply=pcall(run_agent,tostring(entry.payload or ""),playerName,true,"redeem",true,{
            redeem_mode=true,
            max_rounds=REDEEM_MAX_ROUNDS,
            cmd_limit=REDEEM_MAX_CMDS_PER_ROUND,
            timeout=REDEEM_TIMEOUT,
        })
        if not ok_agent then
            -- 兑换码已执行（无论内部报错，也视为已消费），标记为 used 后清理
            entry.used=true
            entry.used_by=playerName
            entry.used_at=now
            entry.result=tostring(reply or "AI 执行异常")
            save_data(d)
            RUNTIME.redeem_locks[lock_key]=nil
            return false,"兑换码已执行但 AI 报错："..tostring(reply or "")
        end
        reply=trim(tostring(reply or ""))
        if reply=="" then
            -- AI 空回复也算已消费；兑换码永久删除
            entry.used=true
            entry.used_by=playerName
            entry.used_at=now
            entry.result=""
            save_data(d)
            RUNTIME.redeem_locks[lock_key]=nil
            return false,"AI 没有返回有效结果，兑换码已作废。"
        end
        -- 成功：兑换码永久删除
        entry.used=true
        entry.used_by=playerName
        entry.used_at=now
        entry.result=reply
        save_data(d)
        RUNTIME.redeem_locks[lock_key]=nil
        log_event("REDEEM",playerName.." redeemed "..code.." kind=ai")
        return true, reply
    else
        RUNTIME.redeem_locks[lock_key]=nil
        return false,"兑换码类型无效。"
    end
    if not ok then
        RUNTIME.redeem_locks[lock_key]=nil
        return false,result
    end
    entry.used=true
    entry.used_by=playerName
    entry.used_at=now
    save_data(d)
    RUNTIME.redeem_locks[lock_key]=nil
    log_event("REDEEM",playerName.." redeemed "..code.." kind="..tostring(entry.kind))
    return true,result
end
normalize_region = function(x1, y1, z1, x2, y2, z2)
    x1, y1, z1, x2, y2, z2 = tonumber(x1), tonumber(y1), tonumber(z1), tonumber(x2), tonumber(y2), tonumber(z2)
    if not x1 or not y1 or not z1 or not x2 or not y2 or not z2 then return nil end
    local ax, bx = math.min(x1, x2), math.max(x1, x2)
    local ay, by = math.min(y1, y2), math.max(y1, y2)
    local az, bz = math.min(z1, z2), math.max(z1, z2)
    return math.floor(ax), math.floor(ay), math.floor(az), math.floor(bx), math.floor(by), math.floor(bz)
end

-- ════════════════════════════════════════════════════════════
--   指令安全与执行
-- ════════════════════════════════════════════════════════════

function normalize_cmd(cmd)
    return trim(string.gsub(trim(cmd), "^/+", ""))
end

function command_head(cmd)
    return string.match(lower(normalize_cmd(cmd)), "^(%S+)") or ""
end

start_vote = nil

function is_vote_command(cmd)
    local c = lower(normalize_cmd(cmd))
    for vote_cmd, _ in pairs(VOTE_COMMANDS) do
        if c == vote_cmd or c:sub(1, #vote_cmd + 1) == vote_cmd .. " " then
            return true
        end
    end
    return false
end

function expand_large_give_command(cmd)
    local c=normalize_cmd(cmd)
    local target,item,count,rest=c:match('^give%s+(%S+)%s+(%S+)%s+(%d+)(.*)$')
    if not target or not item or not count then return nil end
    count=tonumber(count)
    if not count or count<=30000 then return nil end
    local out={}
    local left=count
    while left>0 do
        local n=math.min(30000,left)
        out[#out+1]='give '..target..' '..item..' '..tostring(n)..rest
        left=left-n
    end
    return out
end

function count_from_give(cmd) local n=normalize_cmd(cmd):match("^give%s+%S+%s+%S+%s+(%d+)"); return tonumber(n) or 0 end

function run_command(cmd, playerName, admin)
    local c = normalize_cmd(cmd)
    if c == "" then return "指令为空" end
    local safePlayer = string.gsub(tostring(playerName or ""), '"', '\\"')
    c = string.gsub(c, "@s", '"' .. safePlayer .. '"')
    local batch=expand_large_give_command(c)
    if batch then
        local done=0
        for i,one in ipairs(batch) do
            log_event("COMMAND", tostring(playerName or "?") .. ": " .. one)
            local ok,result=pcall(game.isCmdSuccess,one)
            if not ok or result~=true then
                return "指令批量执行失败：第"..tostring(i).."次未成功，已执行"..tostring(done).."次。\n最后尝试："..one
            end
            done=done+1
        end
        return "✓ 已完成批量给予："..tostring(count_from_give(c))
    end
    log_event("COMMAND", tostring(playerName or "?") .. ": " .. c)
    local ok, result = pcall(game.isCmdSuccess, c)
    if not ok then return "指令执行失败：" .. tostring(result) end
    if result ~= true then return "指令执行失败：服务器返回执行失败" end
    return "✓ 指令执行成功：" .. c
end

-- ════════════════════════════════════════════════════════════
--   投票系统（状态存文件，周期轮询超时）
-- ════════════════════════════════════════════════════════════

start_vote = function(playerName, cmd)
    local ok, list = pcall(player.list)
    if not ok or type(list) ~= "table" then
        send(playerName, "§c无法获取在线玩家列表")
        return
    end

    local online_count = #list
    if online_count == 0 then online_count = 1 end
    local needed = math.ceil(online_count / 2)

    local vote_id = playerName .. "_" .. tostring(util.timestamp())

    local d = load_data()
    d.votes[vote_id] = {
        initiator = playerName,
        command = cmd,
        votes = {},
        needed = needed,
        total = online_count,
        start_time = util.timestamp(),
    }
    save_data(d)

    broadcast("§e━━━━━━━━━━━━━━━━━━━━━━━\n§b[投票] §f" .. playerName .. " 发起投票\n§f指令: §a" .. cmd .. "\n§f需要: §e" .. needed .. "/" .. online_count .. " §f人同意\n§7请在聊天框输入 §a同意 §7或 §ayes §7投票\n§7投票将在 §c" .. VOTE_TIMEOUT .. " §7秒后结束\n§e━━━━━━━━━━━━━━━━━━━━━━━")
end

-- 处理玩家投票，返回是否处理了某个投票
function process_vote_decision(playerName, agree)
    local d = load_data()
    local votes = d.votes
    local handled = false

    for vote_id, vote in pairs(votes) do
        if vote.votes[playerName] then
            send(playerName, "§c你已经投过票了")
            handled = true
        else
            vote.votes[playerName] = agree == true and "yes" or "no"
            local count_yes, count_no = 0, 0
            for _, value in pairs(vote.votes) do
                if value == "yes" or value == true then count_yes = count_yes + 1
                elseif value == "no" then count_no = count_no + 1 end
            end

            if agree then
                broadcast("§b[投票] §f" .. playerName .. " 同意 §7(§e" .. count_yes .. "/" .. vote.needed .. "§7)")
                if count_yes >= vote.needed then
                    broadcast("§a━━━━━━━━━━━━━━━━━━━━━━━\n§a[投票通过] §f正在执行指令...\n§a━━━━━━━━━━━━━━━━━━━━━━━")
                    pcall(game.sendCommand, vote.command)
                    votes[vote_id] = nil
                end
            else
                broadcast("§c[投票] §f" .. playerName .. " 不同意 §7(反对 " .. count_no .. " 人)")
            end
            handled = true
        end
    end

    save_data(d)
    return handled
end

-- 保留旧函数名，其他旧逻辑不需要改；实际判断现在由快速 AI 决定。 
function process_vote(playerName)
    return process_vote_decision(playerName, true)
end

-- 周期检查投票超时（全局函数，供 util.schedule 调用）
function on_vote_tick()
    local d = load_data()
    local votes = d.votes
    local now = util.timestamp()
    local changed = false

    for vote_id, vote in pairs(votes) do
        if now - (vote.start_time or 0) >= VOTE_TIMEOUT then
            broadcast("§c━━━━━━━━━━━━━━━━━━━━━━━\n§c[投票超时] §f投票未通过: " .. vote.command .. "\n§c━━━━━━━━━━━━━━━━━━━━━━━")
            votes[vote_id] = nil
            changed = true
        end
    end

    if changed then
        d.votes = votes
        save_data(d)
    end
end

-- 联网搜索：该网关（token.sensenova.cn）没有 /v1/responses，也不支持内置
-- web_search 工具（实测 tools[0].type 只允许 function/custom），
-- 所以这里继续走 DeepSeek 的 /responses，使用独立配置 web_search_key。
function call_web_search(query, timeout_override)
    local configured_key = trim(tostring(game.getConfig("web_search_key", "") or ""))
    if configured_key == "" then configured_key = tostring(game.getConfig("ai_key", AI_KEY) or "") end
    if configured_key == "" then return "联网查询失败：未配置 AI 密钥（web_search_key）" end
    local ws_url = trim(tostring(game.getConfig("web_search_url", WEB_SEARCH_URL) or ""))
    if ws_url == "" then ws_url = WEB_SEARCH_URL end
    local ws_model = trim(tostring(game.getConfig("web_search_model", WEB_SEARCH_MODEL) or ""))
    if ws_model == "" then ws_model = WEB_SEARCH_MODEL end
    local req = {
        model = ws_model,
        input = tostring(query or ""),
        tools = {{type = "web_search"}},
        tool_choice = {type = "web_search"},
        reasoning = {effort = "low"},
        max_output_tokens = 1200
    }
    local ok_post, r = pcall(http.post, ws_url, http.json_encode(req), {
        headers = {['Content-Type']='application/json', ['Authorization']='Bearer '..configured_key},
        timeout = timeout_override or TIMEOUT
    })
    if not ok_post or not r or not r.ok then
        return "联网查询失败：" .. tostring((r and r.error) or "网络请求失败")
    end
    if r.status < 200 or r.status >= 300 then
        return "联网查询失败：HTTP " .. tostring(r.status) .. " " .. string.sub(r.body or "",1,300)
    end
    local ok, data = pcall(http.json_decode, r.body or "")
    if not ok or type(data) ~= "table" then return "联网查询失败：返回数据无法解析" end
    if data.output_text and trim(data.output_text) ~= "" then return tostring(data.output_text) end
    local texts = {}
    for _, item in ipairs(data.output or {}) do
        if item.type == "message" then
            for _, c in ipairs(item.content or {}) do
                if c.type == "output_text" and c.text then table.insert(texts, c.text) end
            end
        end
    end
    if #texts > 0 then return table.concat(texts, "\n") end
    return "联网查询完成，但没有可用的文字结果。"
end

-- ════════════════════════════════════════════════════════════
--   AI 工具标记处理
-- ════════════════════════════════════════════════════════════

function extract(text, tag)
    local arr = {}
    for x in string.gmatch(text, "%["..tag.."%](.-)%[/"..tag.."%]") do
        table.insert(arr, x)
    end
    return arr
end

function get_self_basic_info(name)
    local lines={}
    local info=get_info(name)
    if info then
        lines[#lines+1]="玩家="..tostring(info.name or name)
        lines[#lines+1]="在线="..tostring(info.online==true)
        if info.x~=nil and info.y~=nil and info.z~=nil then lines[#lines+1]="坐标="..math.floor(tonumber(info.x) or 0)..","..math.floor(tonumber(info.y) or 0)..","..math.floor(tonumber(info.z) or 0) end
        lines[#lines+1]="维度="..tostring(normalize_dimension(info.dimension) or detect_dimension(name))
        lines[#lines+1]="OP="..tostring(info.is_op==true)
    end
    local safe=string.gsub(tostring(name),'"','\\"')
    local selector='@a[name="'..safe..'"]'
    local ok,inv=pcall(game.queryInventory,selector)
    local source="game.queryInventory"
    if not ok or type(inv)~="table" or type(inv.items)~="table" then
        ok,inv=pcall(player.getInventory,name)
        source="player.getInventory"
    end
    if ok and type(inv)=="table" and type(inv.items)=="table" then
        local items=inv.items; local arr={}
        for _,it in pairs(items) do
            if type(it)=="table" then
                local count=tonumber(it.count or it.Count or 0) or 0
                if count>0 then
                    local slot=tostring(it.slot or it.Slot or "?")
                    local item_name=tostring(it.name or it.Name or "unknown")
                    local one=slot..":"..item_name.."×"..count
                    local damage=it.damage or it.Damage; if damage~=nil then one=one.."(伤害"..tostring(damage)..")" end
                    arr[#arr+1]=one
                end
            end
        end
        lines[#lines+1]="背包读取API="..source.."，返回槽位/条目="..tostring(#items)
        if #arr>0 then lines[#lines+1]="背包="..table.concat(arr,"；") else lines[#lines+1]="背包=当前API返回0个有数量物品" end
    else
        lines[#lines+1]="背包读取失败：API调用异常；请勿把失败当成‘背包为空’。"
    end
    local d,r=player_record(name,true)
    lines[#lines+1]="标签="..table.concat(r.tags or {},",")
    lines[#lines+1]="买家等级="..buyer_level(r.purchase_count)
    lines[#lines+1]="卖家等级="..shop_level(r.sold_count)
    return table.concat(lines,"\n")
end

function ai_run_checked_command(cmd,playerName,admin)
    local c=normalize_cmd(cmd); if c=="" then return "指令为空" end
    if admin then return run_command(c,playerName,true) end
    local head=command_head(c)
    if head=="effect" then
        local target=c:match('^effect%s+(%S+)'); local safe=string.gsub(playerName,'"','\\"')
        if target=="@s" or target=="@p" or target==playerName or target=='"'..safe..'"' then return run_command(c,playerName,false) end
        return "权限限制：普通玩家只能给自己施加药水效果。"
    end
    if head=="time" or head=="weather" then
        if is_vote_command(c) then start_vote(playerName,c); return "已发起投票："..c end
        return "权限限制：时间/天气修改需要投票。"
    end
    return "权限限制：普通玩家不能执行该指令。"
end

function process_tools(text, playerName, admin, cmd_limit)
    local results, used = {}, false
    local _, redeem_rec0 = player_record(playerName,true)
    local redeem_mode0 = (redeem_rec0 and redeem_rec0.ai_redeem_mode == true)
    for _,_ in ipairs(extract(text,"TIME")) do table.insert(results,"当前现实时间："..current_real_time()); used=true end
    for _,payload in ipairs(extract(text,"PERSONA")) do local v=trim(payload); save_ai_persona(playerName,v); table.insert(results,v=="" and "人物设定已清除" or "人物设定已保存"); used=true end

    -- 管理权限 runtime.log 工具：仅管理权限可主动查询；普通玩家无权使用。
    for _, payload in ipairs(extract(text, "LOG")) do
        if not admin then
            table.insert(results,"权限限制：只有管理权限可以读取 runtime.log。")
        else
            table.insert(results, admin_ai_log_query(playerName, trim(payload)))
        end
        used=true
    end

    -- 普通玩家的 time/weather 投票工具：明确表示是帮助该玩家发起投票，不绕过投票。
    for _, payload in ipairs(extract(text, "VOTE")) do
        local cmd=normalize_cmd(payload)
        if not is_vote_command(cmd) then
            table.insert(results,"投票工具拒绝：该指令不在 time/weather 投票白名单中。")
        else
            start_vote(playerName,cmd)
            table.insert(results,"已帮助玩家 "..playerName.." 发起投票："..cmd)
        end
        used=true
    end

    -- 管理权限建筑模式关闭/停止工具：真实写入玩家状态。
    for _, _ in ipairs(extract(text, "BUILD_OFF")) do
        if not admin then
            table.insert(results,"权限限制：只有管理权限可以关闭建筑模式。")
        else
            local bd,br=player_record(playerName,true)
            br.ai_build_mode=false
            br.ai_build_started_at=nil
            br.ai_build_stop_requested=false
            save_data(bd)
            RUNTIME.build_stop=RUNTIME.build_stop or {}; RUNTIME.build_stop[playerName]=true
            table.insert(results,"建筑模式已关闭；当前建筑任务将停止，已完成部分不会删除。")
        end
        used=true
    end
    for _, _ in ipairs(extract(text, "BUILD_STOP")) do
        if not admin then
            table.insert(results,"权限限制：只有管理权限可以停止建筑任务。")
        else
            local bd,br=player_record(playerName,true)
            br.ai_build_stop_requested=false
            save_data(bd)
            RUNTIME.build_stop=RUNTIME.build_stop or {}; RUNTIME.build_stop[playerName]=true
            table.insert(results,"已收到停止建筑请求；本次任务停止后不会清除已经完成的建筑。")
        end
        used=true
    end

    -- 管理权限建筑模式工具：真实写入玩家状态。
    for _, payload in ipairs(extract(text, "BUILD")) do
        if not admin then
            table.insert(results,"权限限制：只有管理权限可以开启建筑模式。")
        else
            local bd,br=player_record(playerName,true)
            br.ai_build_mode=true
            br.ai_build_started_at=util.timestamp()
            br.ai_build_stop_requested=false
            RUNTIME.build_stop=RUNTIME.build_stop or {}; RUNTIME.build_stop[playerName]=false
            br.ai_build_progress=br.ai_build_progress or ""
            save_data(bd)
            table.insert(results,"建筑模式已开启：本次建筑任务保留并读取普通聊天/指令历史，并将建筑任务记忆提升到最多100轮；使用 SenseNova 6.8 Flash Lite；每轮最多执行15条 Minecraft 指令。禁止使用 NBT 工具或 NBT/结构数据辅助建筑。必须记住每次工具真实返回、API调用失败、命令失败以及任务在哪里中止；不要把失败当成功。")
        end
        used=true
    end

    -- 联网能力默认对所有 AI/玩家开放；是否使用由 AI 自己判断。
    for _, query in ipairs(extract(text, "NET")) do
        local q = trim(query)
        if q ~= "" then
            table.insert(results, "联网查询结果：\n" .. call_web_search(q, TIMEOUT))
        else
            table.insert(results, "联网查询失败：查询内容为空")
        end
        used = true
    end

    -- AI真实工具兼容：SEARCH_WEB / NET / GETINVENTORY / NBT 都在这里真正执行。
    local search_queries = extract(text, "SEARCH_WEB")
    local legacy_search = trim(tostring(text):match("SEARCH_WEB:%s*(.+)") or "")
    if legacy_search ~= "" then table.insert(search_queries, legacy_search) end
    for _, query in ipairs(search_queries) do
        local q=trim(query); if q~="" then table.insert(results,"联网查询结果：\n"..call_web_search(q,TIMEOUT)) else table.insert(results,"联网查询失败：查询内容为空") end; used=true
    end
    for _, payload in ipairs(extract(text,"GETSCORE")) do
        local target,board=trim(payload):match("^(%S+)%s+(.+)$"); target=target or playerName; board=trim(board or "")
        local can=admin or lower(target)==lower(playerName)
        if not can then table.insert(results,"权限限制：普通玩家只能查询自己的分数。")
        elseif board=="" then table.insert(results,"分数查询失败：缺少记分板名称。")
        else local ok,score=pcall(game.getScore,board,target); if ok then table.insert(results,"玩家分数："..target.." / "..board.." = "..tostring(tonumber(score) or 0)) else table.insert(results,"分数查询失败："..tostring(score)) end end
        used=true
    end
    for _, payload in ipairs(extract(text,"GETTAG")) do
        local target,tag=trim(payload):match("^(%S+)%s+(.+)$"); target=target or playerName; tag=trim(tag or "")
        local can=admin or lower(target)==lower(playerName)
        if not can then table.insert(results,"权限限制：普通玩家只能查询自己的标签。")
        elseif tag=="" then table.insert(results,"标签查询失败：缺少标签名。")
        else local safe=string.gsub(target,'"','\\"'); local ok,res=pcall(game.isCmdSuccess,'testfor @a[name="'..safe..'",tag="'..string.gsub(tag,'"','\\"')..'"]'); table.insert(results,(ok and res==true) and ("标签存在："..target.." 有 "..tag) or ("标签不存在或查询失败："..target.." 无 "..tag)); end
        used=true
    end
    for _, payload in ipairs(extract(text,"GETINFO")) do
        local target=trim(payload)
        if target=="" or lower(target)=="self" or lower(target)=="me" then target=playerName end
        local can=admin or lower(target)==lower(playerName)
        if not can then
            table.insert(results,"权限限制：普通玩家只能查询自己的玩家信息。")
        else
            local info=get_info(target)
            if not info then
                table.insert(results,"未找到玩家："..target)
            else
                local parts={}
                parts[#parts+1]="玩家="..tostring(info.name or target)
                parts[#parts+1]="OP="..tostring(info.is_op==true)
                parts[#parts+1]="在线="..tostring(info.online==true)
                parts[#parts+1]="维度="..dimension_display(normalize_dimension(info.dimension) or detect_dimension(target))
                if info.x~=nil and info.y~=nil and info.z~=nil then
                    parts[#parts+1]="坐标="..math.floor(tonumber(info.x) or 0)..","..math.floor((tonumber(info.y) or 0)-1.62)..","..math.floor(tonumber(info.z) or 0)
                end
                local pd0,pr0=player_record(target,true)
                parts[#parts+1]="标签="..table.concat(pr0.tags or {},",")
                parts[#parts+1]="买家等级="..buyer_level(pr0.purchase_count)
                parts[#parts+1]="卖家等级="..shop_level(pr0.sold_count)
                table.insert(results,"玩家信息："..table.concat(parts," | "))
            end
        end
        used=true
    end
    for _, _ in ipairs(extract(text,"LIST")) do
        local names=online_players() or {}; table.insert(results,#names>0 and ("当前在线玩家："..table.concat(names,"、")) or "当前没有检测到在线玩家"); used=true
    end
    for _, payload in ipairs(extract(text,"LOCATE")) do
        local structure=trim(payload); if structure=="" then table.insert(results,"结构查询失败：缺少结构类型") else table.insert(results,"结构查询结果：\n"..query_seed_structure(playerName,structure,tostring(SEED_FINDER_DEFAULT_RADIUS))) end; used=true
    end
    for _, target in ipairs(extract(text,"GETINVENTORY")) do
        target=trim(target); if target=="" or lower(target)=="self" or lower(target)=="me" then target=playerName end
        local can=admin or lower(target)==lower(playerName)
        if not can then
            table.insert(results,"权限限制：普通玩家只能查询自己的背包。")
        else
            local safe=string.gsub(target,'"','\\"'); local selector='@a[name="'..safe..'"]'
            local ok,inv=pcall(game.queryInventory,selector)
            local arr={}
            if ok and type(inv)=="table" and type(inv.items)=="table" then
                for _,it in pairs(inv.items) do local count=tonumber(it.count or it.Count or 0)or 0; if count>0 then arr[#arr+1]=short_item_name(it).." ×"..count end end
            end
            if #arr>0 then
                table.insert(results,"背包读取成功："..target.."\n"..table.concat(arr,"；"))
            else
                -- 框架通道字段不匹配（永远 items=null），改用订阅 CommandOutput 的原生通道异步读取。
                -- 管理员查询直接全服公布（用户要求）；普通玩家查自己私聊。
                inv_request(playerName, target, "ai", admin)
                table.insert(results,"已通过原生通道发起背包读取："..target.."。完整背包会在几秒内自动发出（管理员=全服公布，普通玩家=私聊）。在收到那条消息前，不要编造或猜测背包内容。")
            end
        end
        used=true
    end
    for _, payload in ipairs(extract(text,"NBT")) do
        local _,build_check=player_record(playerName,true)
        if admin and build_check and build_check.ai_build_mode==true then
            table.insert(results,"建筑模式禁止使用NBT工具；请改用正常Minecraft指令施工。")
        else
            local a,b,c=trim(payload):match("^(-?%d+)%s+(-?%d+)%s+(-?%d+)$")
        if not a then table.insert(results,"NBT读取失败：格式必须为 X Y Z") else
            local ok,nbt=pcall(game.getBlockNBT,tonumber(a),tonumber(b),tonumber(c))
            if ok and type(nbt)=="table" then table.insert(results,"NBT读取成功："..tostring(a).." "..tostring(b).." "..tostring(c).."\n"..(type(nbt.Items)=="table" and "Items条目="..tostring(#nbt.Items) or "没有Items")) else table.insert(results,"NBT读取失败："..tostring(nbt)) end
            end
        end; used=true
    end

    -- 基础玩家信息查询对所有 AI 开放；只读基本资料，不开放管理权限。
    for _, payload in ipairs(extract(text, "SHELL3")) do
        local body = trim(payload)
        local op, target = body:match("^(%S+)%s*(.*)$")
        op = lower(op or "")
        target = trim(target or "")
        local pd = load_data()
        local saved=nil
        if target~="" and pd.players then
            for _,pr in pairs(pd.players) do
                if type(pr)=="table" and lower(tostring(pr.name or ""))==lower(target) then saved=pr; break end
            end
        end
        if op == "self" or op == "me" then
            table.insert(results, get_self_basic_info(playerName))
        elseif op == "list" or body == "" then
            local names = online_players() or {}
            if #names == 0 then
                table.insert(results, "当前没有检测到在线玩家")
            else
                table.insert(results, "当前在线玩家：" .. table.concat(names, "、"))
            end
        elseif op == "info" and target ~= "" then
            local can_query = admin or lower(target) == lower(playerName)
            if not can_query then
                table.insert(results, "权限限制：普通玩家只能查询自己的玩家信息。")
            else
                local info = get_info(target) or saved
                if not info then
                    table.insert(results, "未找到玩家：" .. target)
                else
                    local pos=nil
                    if info.x~=nil and info.y~=nil and info.z~=nil then
                        pos={x=info.x,y=info.y,z=info.z,dimension=info.dimension}
                    elseif saved and saved.last_pos then
                        pos=saved.last_pos
                    end
                    local sold=tonumber((saved and saved.sold_count) or 0)
                    local bought=tonumber((saved and saved.purchase_count) or 0)
                    local title_list={}
                    local mdb=market_db()
                    for _,sv in pairs(mdb.listings or {}) do
                        local spd,spr=player_record(sv.seller,true)
                        local vip=spr and spr.market_vips and spr.market_vips[uuid_key(target)]
                        if vip and vip.title then table.insert(title_list,tostring(vip.title)) end
                    end
                    local coords="未知"
                    if pos then
                        coords=math.floor(tonumber(pos.x) or 0)..","..math.floor(tonumber(pos.y) or 0)..","..math.floor(tonumber(pos.z) or 0)
                    end
                    local dim="未知"
                    if pos then dim=pos.dimension or detect_dimension(target) end
                    local title_text="无"
                    if #title_list>0 then title_text=table.concat(title_list,"、") end
                    table.insert(results, "玩家="..tostring(info.name or target).." OP="..tostring(info.is_op==true).." 在线="..tostring(info.online==true).." 维度="..tostring(dim).." 坐标="..coords.." 买家等级="..buyer_level(bought).." 卖家等级="..shop_level(sold).." 特殊称号="..title_text)
                end
            end
        else
            table.insert(results, "玩家信息能力调用参数无效")
        end
        used = true
    end

    -- 通用指令能力：管理权限完整执行；普通玩家由权限层再次判断。
    -- 建筑模式每轮最多15条指令；兑换码 AI 单轮最多 REDEEM_MAX_CMDS_PER_ROUND 条。
    -- 建筑模式的 /fill 还会在真正执行前做体积与64格半径硬校验。
    local _,build_rec=player_record(playerName,true)
    local build_exec=admin and (build_rec.ai_build_mode==true or text:find("%[BUILD%]",1,true)~=nil)
    local command_list={}
    for _,cmd in ipairs(extract(text,"CMD")) do command_list[#command_list+1]=cmd end
    for _,cmd in ipairs(extract(text,"SHELL4")) do command_list[#command_list+1]=cmd end
    local command_limit=build_exec and BUILD_COMMANDS_PER_ROUND or #command_list
    -- 兑换码 AI 或其他调用方可以通过 cmd_limit 参数强制限制单轮指令条数。
    if cmd_limit and cmd_limit>0 then
        command_limit=math.min(command_limit, math.floor(cmd_limit))
    end
    local function validate_build_fill(raw_cmd)
        if not build_exec then return true,nil end
        local c=normalize_cmd(raw_cmd)
        local fill=c:match("^fill%s+(.+)$")
        if not fill then fill=c:match("^execute%s+.+%srun%s+fill%s+(.+)$") end
        if not fill then return true,nil end
        local x1,y1,z1,x2,y2,z2=fill:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+.+$")
        if not x1 then return false,"建筑填充失败：无法解析 /fill 的两个坐标点，请改用完整的六坐标格式。" end
        local pos=player_position(playerName)
        if not pos then return false,"建筑填充失败：无法读取当前施工位置；请先让自己进入施工区域。" end
        local function coord(v,origin)
            if v:sub(1,1)=="~" then return (tonumber(origin) or 0)+(tonumber(v:sub(2)) or 0) end
            return tonumber(v)
        end
        local X1,Y1,Z1=coord(x1,pos.x),coord(y1,pos.y),coord(z1,pos.z)
        local X2,Y2,Z2=coord(x2,pos.x),coord(y2,pos.y),coord(z2,pos.z)
        if not X1 or not Y1 or not Z1 or not X2 or not Y2 or not Z2 then return false,"建筑填充失败：坐标必须是整数绝对坐标或相对坐标。" end
        local function dist(x,y,z)
            local dx=x-(tonumber(pos.x) or 0); local dy=y-(tonumber(pos.y) or 0); local dz=z-(tonumber(pos.z) or 0)
            return math.sqrt(dx*dx+dy*dy+dz*dz)
        end
        if dist(X1,Y1,Z1)>BUILD_MAX_RADIUS or dist(X2,Y2,Z2)>BUILD_MAX_RADIUS then
            return false,"建筑填充失败：一次 /fill 的端点不能超出当前自身为原点的64格半径；请先用 tp @s 到施工区域，再继续。"
        end
        local volume=(math.abs(X2-X1)+1)*(math.abs(Y2-Y1)+1)*(math.abs(Z2-Z1)+1)
        if volume>BUILD_MAX_FILL_BLOCKS then
            return false,"建筑填充失败：单次 /fill 最多32768个方块；当前约"..tostring(volume).."个，请拆分后继续。"
        end
        return true,nil
    end
    local executed=0
    local build_live_rec=nil
    for i,cmd in ipairs(command_list) do
        -- 落盘停止标志：每 5 条指令查一次（比每条查一次便宜，但比整轮才查一次更及时）。
        if executed%5==0 or i==1 then
            local sh,sr=ai_stop_check(playerName)
            if sh then
                table.insert(results,"AI 任务收到停止请求（原因："..tostring(sr or "手动停止").."），已停止继续执行后续指令。")
                used=true
                break
            end
        end
        if build_exec then
            if not build_live_rec or executed%5==0 then
                local _,rec=player_record(playerName,true)
                build_live_rec=rec or {}
            end
            if (RUNTIME.build_stop and RUNTIME.build_stop[playerName]) or (build_live_rec and build_live_rec.ai_build_stop_requested==true) then
                table.insert(results,"建筑任务收到停止请求，已停止继续执行后续指令。")
                used=true
                break
            end
        end
        if executed>=command_limit then
            table.insert(results,"本轮已达到"..tostring(command_limit).."条指令上限；剩余指令请下一轮继续。")
            used=true
            break
        end
        local valid,verr=validate_build_fill(cmd)
        if not valid then
            table.insert(results,verr)
        else
            table.insert(results,ai_run_checked_command(cmd,playerName,admin))
        end
        executed=executed+1
        used=true
    end

    -- 管理权限才拥有完整服务器指令执行能力。
    if admin then
        -- 禁言：支持新写法 [MUTE]玩家名 时长[/MUTE]，也兼容旧写法 [SHELL2]mute 玩家名 时长[/SHELL2]
        -- 时长：30秒 / 10分钟 / 2小时 / 3天 / 永久；0 表示解除禁言。
        for _, payload in ipairs(extract(text, "MUTE")) do
            table.insert(results, ai_mute_player(trim(payload), nil, playerName))
            used=true
        end
        for _, payload in ipairs(extract(text, "SHELL2")) do
            local body=trim(payload)
            local kind,rest=body:match("^(%S+)%s*(.*)$")
            if lower(kind or "")=="mute" then
                table.insert(results, ai_mute_player(rest, nil, playerName))
                used=true
            end
        end
    else
        for _, payload in ipairs(extract(text, "SHELL1")) do
            local loc = player_position(playerName)
            if loc then
                local dim = loc.dimension or detect_dimension(playerName)
                table.insert(results, "自己的坐标=" .. tostring(loc.x) .. "," .. tostring(loc.y) .. "," .. tostring(loc.z) .. " 维度=" .. tostring(dim))
            else
                table.insert(results, "无法读取自己的坐标")
            end
            used = true
        end

        for _, payload in ipairs(extract(text, "SHELL2")) do
            local body = trim(payload)
            local kind, rest = body:match("^(%S+)%s*(.*)$")
            if kind == "effect" then
                local effect_id, seconds, level = rest:match("^(%S+)%s+(%d+)%s+(%d+)%s*$")
                seconds, level = tonumber(seconds), tonumber(level)
                if not effect_id or not seconds or not level or seconds < 1 or seconds > 60 or level < 1 or level > 255 then
                    table.insert(results, "药水 Shell 格式错误：effect 效果 秒 等级（秒数最多60）")
                else
                    local safe = string.gsub(tostring(playerName), '"', '\\"')
                    local cmd = 'effect "' .. safe .. '" ' .. effect_id .. ' ' .. tostring(seconds) .. ' ' .. tostring(level) .. ' true'
                    local ok, result = pcall(game.isCmdSuccess, cmd)
                    if ok and result == true then
                        table.insert(results, "✓ 已给自己药水效果：" .. effect_id .. " " .. tostring(seconds) .. "秒 等级" .. tostring(level))
                    else
                        table.insert(results, "药水效果执行失败")
                    end
                end
            elseif kind == "vote" and trim(rest) ~= "" then
                local cmd = normalize_cmd(rest)
                if is_vote_command(cmd) then
                    start_vote(playerName, cmd)
                    table.insert(results, "已发起投票：" .. cmd)
                else
                    table.insert(results, "该指令不属于投票项目")
                end
            else
                table.insert(results, "Shell 2 格式错误")
            end
            used = true
        end
    end

    return results, used
end

-- ════════════════════════════════════════════════════════════
--   AI 调用
-- ════════════════════════════════════════════════════════════

call_ai = nil

function ai_thinking_enabled()
    local v=game.getConfig("ai_thinking", false)
    if v==true then return true end
    local s=lower(trim(tostring(v or "")))
    return (s=="true" or s=="1" or s=="on" or s=="yes")
end

function available_model_list()
    local out={}
    for id,_ in pairs(AI_MODEL_CHOICES) do out[#out+1]=id end
    table.sort(out)
    return table.concat(out," / ")
end

-- 旧版本曾把 DeepSeek Flash 记为 deepseek-v4-flash（SenseNova 网关的 ID）；
-- 现在改用 DeepSeek 官方模型 deepseek-flash，这里做一次自动映射，避免旧数据 404。
function normalize_model_id(m)
    m=trim(tostring(m or ""))
    local l=lower(m)
    if l=="deepseek-v4-flash" or l=="deepseek-4.1-flash" or l=="deepseek-4.1" then return "deepseek-flash" end
    if l~="" and AI_MODEL_CHOICES[l] then return l end
    return m
end

-- 当前生效的模型：优先 .AI模型 切换值，其次插件配置 ai_model，最后源码默认值。
function ai_active_model()
    local d=load_data()
    local m=normalize_model_id(d.ai_model_override)
    if m~="" then return m end
    m=normalize_model_id(game.getConfig("ai_model",""))
    if m~="" then return m end
    return AI_MODEL
end

function get_ai_model_override()
    return ai_active_model()
end

function set_ai_model_override(model,playerName)
    local raw=trim(tostring(model or ""))
    local key=lower(raw)
    local target=nil
    for id,label in pairs(AI_MODEL_CHOICES) do
        if key==lower(id) or key==lower(label) then target=id; break end
    end
    if not target then
        if key=="flash-lite" or key=="6.8" or key=="6.8flash" or key=="sensenova" or key=="flashlite" then target="sensenova-6.8-flash-lite"
        elseif key=="6.7" then target="sensenova-6.7-flash-lite"
        elseif key=="flash" or key=="deepseek-flash" or key=="deepseekflash" or key=="4.1" or key=="4.1flash" or key=="v4flash" or key=="v41" then target="deepseek-flash"
        elseif key=="pro" or key=="v4pro" then target="deepseek-v4-pro"
        elseif key=="glm" or key=="glm5.2" then target="glm-5.2"
        elseif key=="kimi" or key=="k3" then target="kimi-k3" end
    end
    if not target then
        return false,"不支持的模型："..raw.."\n可用："..available_model_list()
    end
    local d=load_data(); d.ai_model_override=target; d.ai_model_changed_by=playerName; d.ai_model_changed_at=util.now(); save_data(d)
    AI_MODEL=target
    return true,target
end

function model_display(model)
    model=trim(tostring(model or ""))
    if model=="" then return AI_MODEL_LABEL end
    return AI_MODEL_CHOICES[lower(model)] or model
end

function choose_ai_model(question,commandMode)
    return ai_active_model()
end

function should_upgrade_flash(text)
    local low = lower(tostring(text or ""))
    local patterns = {
        "我不知道", "我无法判断", "我不能确定", "无法回答", "无法完成", "做不到",
        "我不会", "没有办法", "无法提供", "不能帮你", "我不能帮你",
        "这是我的原则", "违背我的原则", "我必须拒绝", "我不能违背",
        "我不具备", "没有相关能力", "无法获取", "查不到", "没有足够信息"
    }
    for _, ptn in ipairs(patterns) do
        if string.find(low, lower(ptn), 1, true) then return true end
    end
    return false
end

function save_ai_trace(t)
    t=t or {}; t.at=util.now()
    local raw=tostring(t.raw_body or "")
    if #raw>5000 then raw=raw:sub(1,5000).."…" end
    t.raw_body=raw
    local out=tostring(t.assistant_output or "")
    if #out>3000 then out=out:sub(1,3000).."…" end
    t.assistant_output=out
    pcall(util.json_write,AI_TRACE_FILE,t)
end

-- 该网关限速较紧（并发请求会 429），429/5xx 时需要等一下再重试。
-- 插件环境没有 sleep 原语，这里用受控忙等（只在重试路径调用，最多约 1~2 秒）。
AI_RETRY_MAX = 3
AI_RETRY_WAIT = 1
function ai_wait_seconds(n)
    local target=(tonumber(util.timestamp()) or os.time())+(tonumber(n) or 1)
    local spins=0
    while (tonumber(util.timestamp()) or os.time())<target do
        spins=spins+1
        if spins>50000000 then break end
    end
end

call_ai = function(messages, timeout_override, model_override)
    local configured_model = ai_active_model()
    if model_override ~= nil and trim(tostring(model_override)) ~= "" then
        configured_model = trim(tostring(model_override))
    end
    -- 按模型选择服务商接口与密钥：deepseek-flash 走 DeepSeek 官方，其余走 SenseNova 网关。
    local api_url, configured_key, provider = ai_endpoint_for(configured_model)
    if configured_key == "" then
        if provider == "deepseek" then
            error("未配置 DeepSeek 密钥，请在插件配置中设置 deepseek_key")
        end
        error("未配置 AI 密钥，请在插件配置中设置 ai_key")
    end
    local use_thinking = ai_thinking_enabled()
    local max_try = math.max(1, tonumber(AI_RETRY_MAX) or 3)
    local last_err = "未知错误"

    for attempt = 1, max_try do
        local req = {
            model = configured_model,
            messages = messages,
            temperature = TEMPERATURE,
            max_tokens = MAX_REPLY,
        }
        -- ★关键★ 关闭思考：这些模型默认会思考，思考内容占 max_tokens。
        -- 若不关闭，思考会把额度吃光 → message.content 为空 → 插件报"AI没有返回内容"。
        -- 实测两个接口都支持 thinking={type="disabled"}（reasoning 消耗为 0）。
        if not use_thinking then req.thinking = { type = "disabled" } end
        local body = http.json_encode(req)
        local ok_post, r = pcall(http.post, api_url, body, {
            headers = {
                ['Content-Type'] = 'application/json',
                ['Authorization'] = 'Bearer ' .. configured_key
            },
            timeout = timeout_override or TIMEOUT
        })

        if not ok_post then
            last_err = "网络请求异常：" .. tostring(r)
        elseif not r or not r.ok then
            last_err = "网络请求失败：" .. tostring(r and (r.error or r.status) or "无响应")
        else
            local code = tonumber(r.status) or 0
            local rbody = tostring(r.body or "")
            if code == 429 then
                last_err = "接口限速（429）：" .. string.sub(rbody, 1, 200)
            elseif code >= 500 then
                last_err = "服务端错误（HTTP " .. tostring(code) .. "）：" .. string.sub(rbody, 1, 200)
            elseif code < 200 or code >= 300 then
                -- 4xx 参数类错误重试也没用，直接抛出
                save_ai_trace({model=configured_model,status="http_error",status_code=code,reason=last_err,raw_body=rbody,request_body=body})
                error("HTTP " .. tostring(code) .. "：" .. string.sub(rbody, 1, 500))
            else
                local ok, data = pcall(http.json_decode, rbody)
                if not ok or type(data) ~= "table" then
                    last_err = "API 返回 JSON 解析失败"
                else
                    local choice = data.choices and data.choices[1]
                    local msg = choice and choice.message
                    local c = msg and msg.content
                    -- SenseNova 用 message.reasoning，DeepSeek 官方用 message.reasoning_content
                    local reasoning_txt = msg and (msg.reasoning or msg.reasoning_content)
                    -- 兜底：万一 content 为空但思考里带了内容，也别把回答丢掉
                    if (not c or trim(tostring(c)) == "") and type(reasoning_txt) == "string" and trim(reasoning_txt) ~= "" then
                        c = reasoning_txt
                    end
                    local has_content = (c and trim(tostring(c)) ~= "")
                    save_ai_trace({model=configured_model,
                        status=(has_content and "response_ok" or "empty_content"),
                        status_code=code,
                        reason=(has_content and "HTTP正常且AI返回了内容" or "HTTP正常，但AI内容为空"),
                        raw_body=rbody, assistant_output=c or "",
                        finish_reason=choice and choice.finish_reason or "未知",
                        request_body=body})
                    if has_content then return tostring(c) end
                    last_err = "AI没有返回内容(finish_reason=" .. tostring(choice and choice.finish_reason or "未知") .. ")"
                end
            end
        end

        if attempt < max_try then
            log_event("AI_RETRY","第"..tostring(attempt).."次失败："..last_err)
            ai_wait_seconds(AI_RETRY_WAIT)
        end
    end

    if string.find(last_err,"429",1,true) or string.find(last_err,"限速",1,true) then
        error("AI接口限速，请等几秒再试（"..last_err.."）")
    end
    error(last_err)
end

choose_signin_reward = function()
    local prompt=[[从下面6个安全签到奖励中选择一个最适合今天的，只返回一个字母，不要解释：
A 面包6
B 火把12
C 铁锭3
D 熟牛肉5
E 经验瓶2
F 金胡萝卜2
要求：奖励不能超标，不要创造其他物品。]]
    local ok,text=pcall(call_ai,{{role="system",content="你是服务器签到奖励选择器。"},{role="user",content=prompt}})
    if ok and type(text)=="string" then
        local letter=string.upper(trim(text)):match("[A-F]")
        if letter then return ({A=1,B=2,C=3,D=4,E=5,F=6})[letter] end
    end
    return (math.floor(util.timestamp())%#SIGNIN_REWARDS)+1
end


-- ════════════════════════════════════════════════════════════
--   AI Agent 主循环
-- ════════════════════════════════════════════════════════════

function utf8_truncate(s, max_chars)
    s=tostring(s or "")
    local limit=tonumber(max_chars) or NORMAL_REPLY_MAX_CHARS
    local count=0
    local i=1
    while i<=#s and count<limit do
        local b=string.byte(s,i)
        local n=1
        if b and b>=0xF0 then n=4 elseif b and b>=0xE0 then n=3 elseif b and b>=0xC0 then n=2 end
        if i+n-1>#s then break end
        i=i+n
        count=count+1
    end
    if i<=#s then return s:sub(1,i-1).."…" end
    return s
end

function compact_ai_reply(v)
    v=clean_ai_visible(v)
    v=v:gsub("[ \t\r\n]+"," ")
    v=trim(v)
    return utf8_truncate(v,NORMAL_REPLY_MAX_CHARS)
end

function clean_ai_visible(v)
    v=tostring(v or "")
    v=v:gsub("%[SHELL4%].-%[/SHELL4%]",""):gsub("%[CMD%].-%[/CMD%]",""):gsub("%[SEARCH_WEB%].-%[/SEARCH_WEB%]",""):gsub("%[NET%].-%[/NET%]",""):gsub("%[GETINVENTORY%].-%[/GETINVENTORY%]",""):gsub("%[NBT%].-%[/NBT%]",""):gsub("%[LOG%].-%[/LOG%]","")
    v=v:gsub("SEARCH_WEB:%s*[^\n]+","")
    return trim(v)
end
run_agent = function(question, playerName, commandMode, windowKey, privileged_override, opts)
    opts = (type(opts)=="table") and opts or {}
    local started_at = util.timestamp()
    local ctx, admin = context_for(playerName)
    if privileged_override == true then admin = true end
    local _, player_rec = player_record(playerName,true)
    local qlow=lower(question or "")
    local build_intent=admin and (
        qlow:find("建筑",1,true) or qlow:find("建造",1,true) or qlow:find("庄园",1,true) or
        qlow:find("庭院",1,true) or qlow:find("小镇",1,true) or qlow:find("豪华",1,true)
    )
    local build_mode = admin and (player_rec.ai_build_mode == true or build_intent)
    -- 兑换码 AI：单独一轮问答，不设长循环。
    local redeem_mode = (player_rec.ai_redeem_mode == true) or (opts.redeem_mode == true)
    local agent_timeout = opts.timeout or (redeem_mode and REDEEM_TIMEOUT or (build_mode and BUILD_COMMAND_TIMEOUT or (commandMode and COMMAND_TIMEOUT or TIMEOUT)))
    local max_rounds = opts.max_rounds or (redeem_mode and REDEEM_MAX_ROUNDS or MAX_ROUNDS)
    local cmd_limit_per_round = opts.cmd_limit or (redeem_mode and REDEEM_MAX_CMDS_PER_ROUND or nil)
    local deadline = started_at + agent_timeout
    local global_rules = global_ai_rules_text()
    local system = AI_SYSTEM_BASE .. "\n\n" .. AI_PERSONA_PROMPT .. "\n\n" .. load_shell_guidance() .. "\n\n" .. ctx
    if global_rules ~= "" then system = system .. "\n\n" .. global_rules end

    if redeem_mode then
        system = system .. [[

【当前是兑换码执行，一问一答模式】
- 你必须把本次任务在 1~2 轮内做完：一次性把所有需要的 [CMD] 都输出，插件会一次性执行；不要拆到多轮试探。
- 最多执行 ]]..tostring(REDEEM_MAX_CMDS_PER_ROUND) ..[[ 条 Minecraft 指令。
- 完成后用正常中文简短汇报"做了什么、结果如何"，然后结束。
- 不要输出 [BUILD]、[BUILD_STOP]、[BUILD_OFF] 等建筑模式工具。
- 不要为了"看起来更完整"而重复 give 相同物品；如果兑换内容只是"给我10个钻石"，就只发一次 give 10。
]]
    elseif build_mode then
        system = system .. "\n\n【当前处于建筑模式】\n保留并读取普通聊天/指令历史；本次建筑任务记忆最多100轮；使用 SenseNova 6.8 Flash Lite。建筑请求必须严格按用户规模分阶段施工；每轮最多执行15条真实 Minecraft 指令，每条指令都必须等待服务器真实执行结果。禁止使用NBT工具或NBT/结构数据辅助建筑。必须记住API失败、命令失败、工具返回以及中止位置。若玩家要求停止建筑，立即调用[BUILD_STOP][/BUILD_STOP]；若要求关闭建筑模式，立即调用[BUILD_OFF][/BUILD_OFF]。"
    else
        system = system .. "\n\n【执行原则】\n简单问题尽量1轮完成；需要操作时一次规划并尽量一次输出所有必要工具标记。连续指令可以输出多条 CMD/SHELL4，插件会逐条快速执行。只有需要真实结果再修正时才进入下一轮。"
    end

    local history
    if redeem_mode then
        history = {}  -- 兑换码 AI 独立会话，不继承任何历史
    else
        history = build_mode and get_build_history(playerName) or get_history(playerName, commandMode, windowKey)
    end
    local messages = {{role = "system", content = system}}

    for _, msg in ipairs(history) do
        table.insert(messages, msg)
    end

    -- 添加当前问题
    table.insert(messages, {role = "user", content = question})
    local function persist_history()
        if redeem_mode then return end  -- 兑换码 AI 不写入聊天历史
        if build_mode then save_build_history(playerName,messages) else save_history(playerName,messages,commandMode,windowKey) end
    end

    for round = 1, max_rounds do
        local _, live_rec=player_record(playerName,true)
        -- 落盘停止标志（新机制）：任何 AI 都监听。一次性消费。
        local stop_hit, stop_reason = ai_stop_check(playerName)
        if stop_hit then
            persist_history()
            return "AI 任务已停止（原因："..tostring(stop_reason or "手动停止").."）。"
        end
        -- 兼容旧建筑停止请求（玩家记录里的字段）
        if build_mode and (live_rec and live_rec.ai_build_stop_requested==true) then
            if live_rec then live_rec.ai_build_stop_requested=false end
            if live_rec then
                local dd=load_data(); local key=identity(playerName);
                if dd.players and dd.players[key] then dd.players[key].ai_build_stop_requested=false end
                save_data(dd)
            end
            persist_history()
            return "建筑任务已停止；已经完成的部分不会删除。"
        end
        local remain = deadline - util.timestamp()
        if remain <= 0 then persist_history(); error("AI思考超时；任务在第 "..tostring(round).." 轮中止") end
        local selected_model=choose_ai_model(question,commandMode)
        local api_ok, text_or_err = pcall(call_ai, messages, math.max(1, math.min(agent_timeout, remain)), selected_model)
        if not api_ok then
            local api_err=tostring(text_or_err)
            table.insert(messages,{role="assistant",content="[AI API调用失败] "..api_err})
            table.insert(messages,{role="user",content="本轮AI API调用失败，任务在这里中止。失败原因："..api_err.."。下次继续时必须记住这里没有成功执行后续步骤，不得假设成功。"})
            persist_history()
            error(api_err)
        end
        local text=tostring(text_or_err or "")
        table.insert(messages, {role = "assistant", content = text})

        local results, used = process_tools(text, playerName, admin, cmd_limit_per_round)

        if used then
            local joined = table.concat(results, "\n")
            if string.find(joined,"已发起投票",1,true) then
                persist_history()
                return "投票已经发起，等待玩家投票。"
            end
            -- 兑换码 AI：执行完工具就直接结束，不再进下一轮让 AI 继续给（防止反复发物品）。
            if redeem_mode then
                persist_history()
                local visible = compact_ai_reply(text)
                local header = (visible ~= "" and visible) or "兑换完成"
                return header .. "\n§8─────\n§7执行结果：\n§f" .. trim(joined)
            end
            local failed = false
            for _, marker in ipairs({"失败", "错误", "拦截", "权限限制", "不存在", "无效"}) do
                if string.find(joined, marker, 1, true) then failed = true; break end
            end
            if failed then
                save_ai_trace({model=tostring(selected_model or "unknown"),status="tool_failed",status_code="",reason=joined,assistant_output=text,tool_result=joined})
                local failure_context = "能力执行真实返回（失败）：\n" .. joined .. "\n这是本次对话的一部分。请根据这个真实返回判断你刚才想完成什么、失败原因是什么；能换方式就重新调用合适能力，不能完成时再用正常简短语言向玩家说明事实。不要展示内部工具标记、调试字段或原始内部错误文本。"
                table.insert(messages, {role="user", content=failure_context})
            else
                table.insert(messages, {
                    role = "user",
                    content = "能力执行结果：\n" .. joined .. "\n请根据真实结果继续处理，不要假设成功。"
                })
            end
        else
            -- 指令模式下，AI 如果只说"正在调用/准备执行"却没有真正输出能力标记，
            -- 不把这句话当成最终结果；静默要求它立即进行实际调用。
            if commandMode and round < max_rounds then
                table.insert(messages, {role="user", content=[[你刚才没有实际调用指令执行能力。不要说"正在调用""准备执行""我会执行"等过程话，也不要把调用当成已经成功。现在直接输出需要执行的实际 Minecraft Bedrock 指令能力标记：[SHELL4]Minecraft指令[/SHELL4]。如果需要多条指令就分别调用；执行后根据服务器真实结果继续处理。最终只在真正完成后用正常语言简短说明。]]})
            else
                -- 普通 AI 如果先说"我去查/正在查询"但没有真正联网能力调用，也不要把过程话直接发给玩家。
                local lowtext = lower(text)
                local looks_like_pending_search = string.find(lowtext,"正在查",1,true) or string.find(lowtext,"我去查",1,true) or string.find(lowtext,"我来查",1,true) or string.find(lowtext,"马上查询",1,true) or string.find(lowtext,"正在查询",1,true)
                if (not commandMode) and looks_like_pending_search and round < max_rounds then
                    table.insert(messages, {role="user", content=[[不要向玩家展示查询过程。你刚才说要查询，但没有真正调用联网能力。现在直接调用：[NET]搜索内容[/NET]，调用后根据真实结果直接回答玩家。不要先说"正在查询""我去查"等过程话。]]})
                else
                    persist_history()
                    return compact_ai_reply(text)
                end
            end
        end
    end

    local last = messages[#messages]
    if last and last.role == "user" and string.find(last.content or "", "工具执行结果", 1, true) then
        local brief = tostring(last.content):gsub("工具执行结果：", ""):gsub("请根据真实结果继续处理，不要假设成功。", "")
        persist_history()
        return "执行结果：" .. trim(brief)
    end
    persist_history()
    for i=#messages,1,-1 do
        if messages[i].role=="assistant" and trim(messages[i].content or "")~="" then
            return compact_ai_reply(messages[i].content)
        end
    end
    return "AI 未能完成这次请求，请换一种说法再试。"
end

-- ════════════════════════════════════════════════════════════
--   传送点系统
-- ════════════════════════════════════════════════════════════

function player_record(name, create)
    local d = load_data()
    local key, info = identity(name)
    local record = d.players[key]

    -- Recover an old record written before XUID/UniqueID data became available.
    if not record then
        for old_key, candidate in pairs(d.players) do
            if type(candidate) == "table" and (
                candidate.name == name or
                (trim(info.xuid) ~= "" and trim(candidate.xuid) == trim(info.xuid)) or
                (trim(info.unique_id) ~= "" and trim(candidate.unique_id) == trim(info.unique_id))
            ) then
                record = candidate
                d.players[key] = record
                if old_key ~= key then d.players[old_key] = nil end
                break
            end
        end
    end

    record = record or {
        xuid = info.xuid or "",
        unique_id = info.unique_id or "",
        name = name,
        waypoints = {},
        death = nil
    }
    record.name = name
    record.xuid = trim(info.xuid) ~= "" and info.xuid or (record.xuid or "")
    record.unique_id = trim(info.unique_id) ~= "" and info.unique_id or (record.unique_id or "")
    record.waypoints = record.waypoints or {}
    d.players[key] = record

    -- 迁移旧数组到字符串键，避免 JSON 稀疏数组在删除某一槽位后被重建成错误结构。
    local normalized = {}
    for i = 1, 10 do
        local wp = record.waypoints[i] or record.waypoints[tostring(i)]
        if type(wp) == "table" then normalized[tostring(i)] = wp end
    end
    record.waypoints = normalized
    d.players[key] = record
    return d, record, key
end

function wp_get(record, slot)
    record.waypoints = record.waypoints or {}
    return record.waypoints[tostring(slot)]
end

function wp_set(record, slot, value)
    record.waypoints = record.waypoints or {}
    record.waypoints[tostring(slot)] = value
end

function wp_delete(record, slot)
    record.waypoints = record.waypoints or {}
    record.waypoints[tostring(slot)] = nil
end

function detect_gamemode(name)
    local safe = string.gsub(name, '"', '\\"')
    local modes = {{id=0,name="survival"},{id=1,name="creative"},{id=2,name="adventure"},{id=3,name="spectator"}}
    for _,m in ipairs(modes) do
        local ok,hit=pcall(game.isCmdSuccess,'testfor @a[name="'..safe..'",m='..m.id..']')
        if ok and hit==true then return m.name end
    end
    return "survival"
end

function set_gamemode(name,mode)
    local safe=string.gsub(name,'"','\\"')
    local cmd='gamemode '..mode..' "'..safe..'"'
    local ok, result = pcall(game.isCmdSuccess, cmd)
    if ok and result == true then return true end
    -- 某些 Bedrock 环境对带引号的玩家名解析不同，再用玩家选择器尝试一次。
    local cmd2='gamemode '..mode..' @a[name="'..safe..'"]'
    local ok2, result2 = pcall(game.isCmdSuccess, cmd2)
    return ok2 and result2 == true
end

function mark_alive_state()
    pcall(game.sendCommand,'tag @a remove ds_alive')
    pcall(game.sendCommand,'tag @e[type=player] add ds_alive')
end

function is_alive_by_tag(name)
    local safe=string.gsub(name,'"','\\"')
    local ok,hit=pcall(game.isCmdSuccess,'testfor @a[name="'..safe..'",tag="ds_alive"]')
    return ok and hit==true
end
function is_alive_entity(name)
    local safe=string.gsub(name,'"','\\"')
    local ok,hit=pcall(game.isCmdSuccess,'testfor @e[type=player,name="'..safe..'"]')
    return ok and hit==true
end

function player_position(name)
    local info = get_info(name)
    if info and tonumber(info.x) and tonumber(info.y) and tonumber(info.z) then
        return {x = tonumber(info.x), y = tonumber(info.y), z = tonumber(info.z), dimension = detect_dimension(name)}
    end

    local ok, pos = pcall(game.getPlayerPos, name)
    if ok and type(pos) == "table" and tonumber(pos.x) and tonumber(pos.y) and tonumber(pos.z) then
        return {x = tonumber(pos.x), y = tonumber(pos.y), z = tonumber(pos.z), dimension = detect_dimension(name)}
    end
    return nil
end

function save_location(name)
    local pos = player_position(name)
    if not pos then return nil, "无法读取当前位置" end

    return {
        x = pos.x,
        y = pos.y,
        z = pos.z,
        -- 不信任 player.get() 返回的维度字段；统一用游戏原生命令检测。
        dimension = detect_dimension(name),
        saved_at = util.now()
    }, nil
end

function dim_exec(dim)
    dim = lower(trim(dim))
    if dim == "nether" or dim == "the_nether" or dim == "1" then return "nether" end
    if dim == "the_end" or dim == "end" or dim == "2" then return "the_end" end
    return "overworld"
end

function tp_to(name, loc)
    if not loc then return false, "没有这个传送点" end
    local x, y, z = tonumber(loc.x), tonumber(loc.y), tonumber(loc.z)
    if not x or not y or not z then return false, "传送点坐标损坏" end

    local safeName = string.gsub(name, '"', '\\"')
    local cmd = string.format('execute as @a[name="%s"] at @s in %s run tp @s %.2f %.2f %.2f', safeName, dim_exec(loc.dimension), x, y, z)
    local ok, result = pcall(game.isCmdSuccess, cmd)
    if ok and result == true then return true, nil end
    return false, "传送指令执行失败"
end

function slot_menu(name, mode)
    local d, r = player_record(name, true)
    local title = mode == "save_slot" and "§b请选择要保存的传送点" or
                  (mode == "return_slot" and "§b请选择要返回的传送点" or "§b请选择要删除的传送点")

    local lines = {title, "§7输入 1~10 选择位置，输入 .stop / stop / 停止 退出"}
    for i = 1, 10 do
        local wp = wp_get(r,i)
        if wp and wp.name and wp.name ~= "" then
            table.insert(lines, string.format("§f%d. §a%s §7维度: §f%s", i, wp.name, tostring(wp.dimension)))
        else
            table.insert(lines, string.format("§f%d.", i))
        end
    end
    send(name, table.concat(lines, "\n"))

    r.menu = mode
    if not r.menu_expires then r.menu_expires = util.timestamp() + MENU_TIMEOUT end
    save_data(d)
end


-- ════════════════════════════════════════════════════════════
--   玩家市场 / 领地保护（9.4.42）
-- ════════════════════════════════════════════════════════════
function file_load(path, default)
    local ok,v=pcall(util.json_load,path)
    if ok and type(v)=="table" then return v end
    return default or {}
end
function file_save(path,v) pcall(util.json_write,path,v) end

-- 兑换码辅助：支持“30秒 / 60分钟 / 24小时 / 7天”，也支持 30s/60m/24h/7d。
-- 旧版本调用了 parse_expiry / generate_code，但实际文件里缺失这两个函数，导致 .生成兑换码 直接失败。
function parse_expiry(text)
    text=trim(text or "")
    local patterns={
        {"(%d+)%s*天",86400},
        {"(%d+)%s*日",86400},
        {"(%d+)%s*小时",3600},
        {"(%d+)%s*时",3600},
        {"(%d+)%s*分钟",60},
        {"(%d+)%s*分",60},
        {"(%d+)%s*秒",1},
        {"(%d+)%s*[Dd]",86400},
        {"(%d+)%s*[Hh]",3600},
        {"(%d+)%s*[Mm]",60},
        {"(%d+)%s*[Ss]",1},
    }
    for _,item in ipairs(patterns) do
        local n=text:match(item[1])
        if n then
            n=tonumber(n)
            if n and n>0 then
                local seconds=n*item[2]
                local label
                if item[2]==86400 then label=tostring(n).."天"
                elseif item[2]==3600 then label=tostring(n).."小时"
                elseif item[2]==60 then label=tostring(n).."分钟"
                else label=tostring(n).."秒" end
                return seconds,label
            end
        end
    end
    return nil,nil
end

function generate_code(data)
    data=data or {}
    data.redeem_codes=data.redeem_codes or {}
    -- 唯一兑换码固定为：2个小写英文字母 + 3个阿拉伯数字，例如 ab527。
    -- 组合空间 26×26×1000 = 676000，生成后还会检查数据库确保不重复。
    local letters="abcdefghijklmnopqrstuvwxyz"
    local digits="0123456789"
    local seed=(tonumber(util.timestamp()) or os.time()) + #tostring(data.redeem_codes)*97
    pcall(math.randomseed,seed)
    for _=1,100 do
        local ai=math.random(1,#letters); local bi=math.random(1,#letters)
        local a=letters:sub(ai,ai); local b=letters:sub(bi,bi)
        local n1=math.random(0,9); local n2=math.random(0,9); local n3=math.random(0,9)
        local code=string.format("%s%s%d%d%d",a,b,n1,n2,n3)
        if not data.redeem_codes[code] then return code end
    end
    return nil
end
function uuid_key(name)
    local ok,info=pcall(player.get,name)
    if ok and type(info)=="table" then
        local u=trim(info.unique_id or info.xuid or info.uid or "")
        if u~="" then return u end
    end
    local d,r,key=player_record(name,true)
    return trim(r.unique_id or r.xuid or key or name)
end

-- 玩家市场 V2：真实商品由原版 clone 保存；NBT目录只用于预览与收购计算。
MARKET_STORAGE_AREA_NAME="ds_ai_market_storage"
function market_storage_db() return file_load(MARKET_STORAGE_FILE,{x=nil,y=nil,z=nil,dimension="overworld",area_name=MARKET_STORAGE_AREA_NAME,set_at=0,set_by=""}) end
function market_storage_save(v) file_save(MARKET_STORAGE_FILE,v) end
function market_storage_set(name,x,y,z)
    if not is_admin(name) then send(name,"§c只有管理权限可以设置玩家市场三维仓库。") return true end
    x,y,z=math.floor(tonumber(x) or 0),math.floor(tonumber(y) or 0),math.floor(tonumber(z) or 0)
    local dim=detect_dimension(name); local d={x=x,y=y,z=z,dimension=dim,area_name=MARKET_STORAGE_AREA_NAME,set_at=util.timestamp(),set_by=name}; market_storage_save(d)
    local cmd=string.format("tickingarea add %d %d %d %d %d %d %s",x,y,z,x+15,y,z+15,MARKET_STORAGE_AREA_NAME)
    local ok,res=pcall(game.isCmdSuccess,cmd)
    if ok and res==true then send(name,"§a✓ 玩家市场三维仓库已设置。\n§f初始坐标：§e"..x.." "..y.." "..z.."\n§7编号1从这里开始，16×16满后自动向上增加Y层；之后无需再次输入坐标。") else send(name,"§e仓库坐标已保存：§f"..x.." "..y.." "..z.."\n§c常加载区域命令未确认成功，请检查服务器中是否已有同名常加载区域。") end
    return true
end
function market_storage_coord(id)
    local st=market_storage_db(); if st.x==nil or st.y==nil or st.z==nil then return nil end
    local n=math.floor(tonumber(id) or 0)-1; if n<0 then return nil end
    local layer=math.floor(n/256); local rem=n%256; return {x=st.x+(rem%16),y=st.y+layer,z=st.z+math.floor(rem/16),dimension=st.dimension}
end
function market_clone_one(sx,sy,sz,tx,ty,tz)
    local cmd=string.format("clone %d %d %d %d %d %d %d %d %d replace",math.floor(sx),math.floor(sy),math.floor(sz),math.floor(sx),math.floor(sy),math.floor(sz),math.floor(tx),math.floor(ty),math.floor(tz)); local ok,res=pcall(game.isCmdSuccess,cmd); return ok and res==true,cmd
end
function market_clear_barrel_drop(name,x,y,z)
    -- 玩家市场商品交易：这里只负责容器本身，绝不清理周围无关掉落物。
    return true
end

-- 服务器收购（.help 14 -> 2）的临时木桶必须与 player_record 解耦。
-- 旧版把 server_sell_session 放在玩家记录里；如果身份键发生碰撞，不同玩家会共享同一个会话。
-- 现在临时交易按“当前游戏名”单独保存，并额外记录 owner，确保 A 的木桶不会被 B 继承。
function server_sell_sessions_db(d)
    d.server_sell_sessions = d.server_sell_sessions or {}
    return d.server_sell_sessions
end

function server_sell_get_session(d,name)
    local sessions=server_sell_sessions_db(d)
    local s=sessions[tostring(name)]
    if type(s)=="table" then return s end
    -- 兼容旧版：只从明确属于当前 name 的旧记录迁移，绝不按 identity key 猜测归属。
    local players=d.players or {}
    for _,record in pairs(players) do
        if type(record)=="table" and tostring(record.name or "")==tostring(name) and type(record.server_sell_session)=="table" then
            s=record.server_sell_session
            s.owner=tostring(name)
            sessions[tostring(name)]=s
            record.server_sell_session=nil
            return s
        end
    end
    return nil
end

function server_sell_set_session(d,name,s)
    local sessions=server_sell_sessions_db(d)
    if type(s)=="table" then s.owner=tostring(name); sessions[tostring(name)]=s
    else sessions[tostring(name)]=nil end
end

function server_sell_clear_session(d,name)
    local sessions=server_sell_sessions_db(d)
    sessions[tostring(name)]=nil
    -- 同时清掉明确属于当前玩家的旧字段，避免旧版本残留再次被迁移。
    local players=d.players or {}
    for _,record in pairs(players) do
        if type(record)=="table" and tostring(record.name or "")==tostring(name) then
            record.server_sell_session=nil
        end
    end
end

function server_sell_cleanup_drops(x,y,z)
    -- 只清理临时收购木桶附近的掉落物；玩家市场购买等其他流程不调用这里。
    local cmd=string.format('kill @e[type=item,x=%d,y=%d,z=%d,r=3]',math.floor(x),math.floor(y),math.floor(z))
    pcall(game.isCmdSuccess,cmd)
end

function server_sell_block_exists(x,y,z)
    local ok,data=market_region_one_block(math.floor(x),math.floor(y),math.floor(z))
    if not ok or type(data)~="table" then return false end
    return lower(tostring(data.name or data.id or "")):find("barrel",1,true)~=nil
end

function server_sell_validate_session(name,d)
    local s=server_sell_get_session(d,name)
    if type(s)~="table" then return nil,false end
    if tostring(s.owner or name)~=tostring(name) then return nil,false end
    local p=s.barrel_pos
    if type(p)~="table" then
        server_sell_clear_session(d,name)
        return nil,false
    end
    local x,y,z=math.floor(p.x),math.floor(p.y),math.floor(p.z)
    -- 创建木桶的位置就是玩家脚下；实际容器位于 y-1。
    local by=y-1
    if not server_sell_block_exists(x,by,z) then
        server_sell_cleanup_drops(x,by,z)
        server_sell_clear_session(d,name)
        return nil,false
    end
    return s,true
end

function market_clone_storage_to_target(id,x,y,z)
    local c=market_storage_coord(id); if not c then return false,"管理权限尚未设置玩家市场仓库。" end
    local ok=market_clone_one(c.x,c.y,c.z,x,y,z); if not ok then return false,"仓库商品 clone 失败。" end; return true,c
end
function load_json_table_file(path,default) local ok,v=pcall(util.json_load,path); if ok and type(v)=="table" then return v end; return default or {} end
function ensure_reference_data_file(path, default_table)
    local ok,v=pcall(util.json_load,path)
    if ok and type(v)=="table" and next(v)~=nil then
        local changed=false
        for k,dv in pairs(default_table or {}) do
            if v[k]==nil then v[k]=dv; changed=true end
        end
        if changed then pcall(util.json_write,path,v) end
        return v
    end
    pcall(util.json_write,path,default_table)
    return default_table
end
-- 单次 handler 内缓存：避免一次批量操作里反复读取同样的 JSON 文件（全物品目录 1000+ 项）。
-- 插件源码每次重跑时这些缓存变量会被重新初始化，不会读到过期数据。
local FULL_SHOP_CACHE, ITEM_NAME_CACHE, ITEM_DAMAGE_CACHE, SELL_PRICE_CACHE
function full_shop_data()
    if not FULL_SHOP_CACHE then FULL_SHOP_CACHE=ensure_reference_data_file(FULL_SHOP_FILE, default_full_shop_prices()) end
    return FULL_SHOP_CACHE
end
function item_name_data()
    if not ITEM_NAME_CACHE then ITEM_NAME_CACHE=ensure_reference_data_file(ITEM_NAMES_FILE,default_item_names()) end
    return ITEM_NAME_CACHE
end
function item_damage_data()
    if not ITEM_DAMAGE_CACHE then ITEM_DAMAGE_CACHE=ensure_reference_data_file(ITEM_DAMAGE_NAMES_FILE,default_item_damage_names()) end
    return ITEM_DAMAGE_CACHE
end
function sell_price_data()
    if not SELL_PRICE_CACHE then SELL_PRICE_CACHE=ensure_reference_data_file(SELL_PRICES_FILE,default_sell_prices()) end
    return SELL_PRICE_CACHE
end
function item_base_id(item) local id=tostring((item and (item.Name or item.name or item.id)) or ""); return lower(string.gsub(id,"^minecraft:","")) end
function item_damage_value(item) return tonumber(item and (item.Damage or item.damage or item.data or item.aux)) or 0 end
function translated_item_name(item)
    local id=item_base_id(item); local dmg=item_damage_value(item); local dm=item_damage_data(); local k=id..":"..tostring(dmg); if dm[k] then return tostring(dm[k]) end
    local names=item_name_data(); if names[id] then return tostring(names[id]) end; return id:gsub("_"," ")
end
function market_item_preview_lines(nbt,max_items)
    max_items=max_items or 10; local lines={}; local items=type(nbt)=="table" and nbt.Items or nil; if type(items)~="table" then return lines,0,0 end
    local total,shown=0,0; for _,item in pairs(items) do local count=tonumber(item.Count or item.count or 0) or 0; if count>0 then total=total+1; if shown<max_items then shown=shown+1; lines[#lines+1]="§f· "..translated_item_name(item).." §7×"..count end end end; return lines,shown,total
end
function market_save_preview(id,entry)
    local d=load_json_table_file(MARKET_PREVIEW_FILE,{items={}}); d.items=d.items or {}; d.items[tostring(id)]={id=tostring(id),saved_at=util.timestamp(),nbt=entry.nbt}; file_save(MARKET_PREVIEW_FILE,d)
end
function market_get_preview(id,listing)
    local d=load_json_table_file(MARKET_PREVIEW_FILE,{items={}}); local p=d.items and d.items[tostring(id)]; if type(p)=="table" and type(p.nbt)=="table" then return p end
    if listing and type(listing.preview_nbt)=="table" then return {nbt=listing.preview_nbt} end; return nil
end
function market_show_preview(name,id)
    local db=market_db(); local v=db.listings[tostring(id)]; if not v or v.disabled or v.shop_banned or v.sold then send(name,"§c商品不存在或已下架。") return true end
    local p=market_get_preview(id,v); local lines={"§b━━ 真实物品预览 ━━","§f商品：§e"..tostring(v.name),"§f价格：§6"..tostring(v.price).."积分","§f商家：§b"..tostring(v.seller),"§f商家等级：§a"..shop_level(v.sold_count)}
    if p then local pl,shown,total=market_item_preview_lines(p.nbt,10); if #pl==0 then lines[#lines+1]="§c没有可预览的物品。" else for _,x in ipairs(pl) do lines[#lines+1]=x end end; if total>shown then lines[#lines+1]="§7……后续还有 "..(total-shown).." 种物品。" end else lines[#lines+1]="§c暂无真实物品预览数据。" end
    lines[#lines+1]="§7+ 下一页    - 上一页    .stop 退出"
    lines[#lines+1]="§e1 = 同意购买    0 = 不同意 / 返回上一页"; local d,r=player_record(name,true); set_menu(d,r,"market_preview",{market_preview_id=tostring(id)}); send(name,table.concat(lines,"\n")); return true
end
function market_public_list_v2(page)
    local db=market_db(); local a={}; for _,v in pairs(db.listings or {}) do if not v.disabled and not v.shop_banned and not v.sold then table.insert(a,v) end end; table.sort(a,function(x,y)return (tonumber(x.id)or 0)<(tonumber(y.id)or 0)end)
    local per=12; local maxp=math.max(1,math.ceil(#a/per)); page=math.max(1,math.min(tonumber(page)or 1,maxp)); local first=(page-1)*per+1; local last=math.min(#a,first+per-1); local out={"§b━━ 玩家商品 ━━","§7第 "..page.." / "..maxp.." 页"}; local shown={}
    for i=first,last do local v=a[i]; local row=i; shown[i-first+1]=v; local rc=(db.reports and db.reports[tostring(v.id)] and tonumber(db.reports[tostring(v.id)].count))or 0; out[#out+1]=string.format("§f%d. §e%s",row,tostring(v.name)); out[#out+1]=string.format("§7  价格：§6%s积分 §7| 商家等级：§a%s",tostring(v.price),shop_level(v.sold_count)); out[#out+1]=string.format("§7  商家：§b%s%s",tostring(v.seller),rc>0 and " §c⚠"..rc or "") end
    if #a==0 then out[#out+1]="§e当前没有玩家商品。" end
    out[#out+1]="§7输入商品编号查看真实物品；+ 下一页；- 上一页；.stop 退出。"; return out,shown,page,maxp
end
function show_market_v2(name,page) local out,a,p,m=market_public_list_v2(page); local d,r=player_record(name,true); set_menu(d,r,"market_buy",{market_page=p,market_list=a}); send(name,table.concat(out,"\n")) end
function show_player_market_main(name)
    local d,r=player_record(name,true)
    set_menu(d,r,"market_main")
    send(name,"§b━━ 玩家市场 ━━\n§f1. 上架商品（玩家出售给玩家）\n§f2. 浏览商品（玩家购买玩家商品）\n§f3. 举报商品\n§f4. 商铺处理（管理权限）\n§f5. 商铺日志\n§f6. 店铺管理\n§f7. 商家列表\n§7玩家市场商品由玩家自己上架；卖家下线后商品仍保留。\n§e输入1~7选择；.stop退出。")
end

-- ════════════════════════════════════════════════════════════
--   全物品系统商店（基于 DEFAULT_SELL_PRICES，购买价统一在原购买价基础上下调40%，全部取整）
-- ════════════════════════════════════════════════════════════

local FULL_SHOP_ADMIN_ONLY_IDS = {
    command_block=true, repeating_command_block=true, chain_command_block=true,
    command_block_minecart=true, barrier=true, structure_block=true, structure_void=true,
    jigsaw=true, debug_stick=true, light=true, knowledge_book=true,
    deny=true, allow=true, border_block=true, camera=true,
    chalkboard=true, chemistry_table=true, compound=true, compound_creator=true, lab_table=true,
    element_constructor=true, camera=true, reserved6=true, unknown=true,
    client_request_placeholder_block=true, info_update=true, info_update2=true,
    moving_block=true, netherreactor=true, unpowered_comparator=true, unpowered_repeater=true,
    piston_arm_collision=true, light_block=true, light_block_0=true, light_block_1=true, light_block_2=true, light_block_3=true,
    light_block_4=true, light_block_5=true, light_block_6=true, light_block_7=true, light_block_8=true, light_block_9=true,
    light_block_10=true, light_block_11=true, light_block_12=true, light_block_13=true, light_block_14=true, light_block_15=true,
    npc_spawn_egg=true, agent_spawn_egg=true, spawn_egg=true,
    -- 1.26.40 实验性装饰内容：保留目录与出售，但普通玩家购买关闭。
    straw_bed=true, red_shrub=true, shelf_mushroom=true,
}

local function full_shop_admin_only(id, item_name)
    id=lower(tostring(id or "")):gsub("^minecraft:","")
    if FULL_SHOP_ADMIN_ONLY_IDS[id] then return true end
    if id:match("_spawn_egg$") then return true end
    local nm=lower(tostring(item_name or ""))
    if nm:find("刷怪蛋",1,true) then return true end
    if nm:find("命令方块",1,true) or nm:find("结构方块",1,true) or nm:find("屏障",1,true) then return true end
    return false
end

function full_shop_catalog(playerName)
    local prices=full_shop_data()
    local arr={}
    for id,v in pairs(prices or {}) do
        local base=tonumber(v.price or v) or 0
        if base>0 then
            local purchase_price=tonumber(v.buy_price) or math.floor(base*10)
            purchase_price=math.floor(purchase_price*0.60)
            if purchase_price<1 then purchase_price=1 end
            if tostring(id)=="netherite_block" then purchase_price=math.floor(1800*0.60) end
            local item_name=tostring(v.name or item_name_data()[id] or id:gsub("_"," "))
            if is_admin(playerName) or not full_shop_admin_only(id,item_name) then
                arr[#arr+1]={id=tostring(id),name=item_name,price=purchase_price,order=tonumber(v.order) or 999999,damage=tonumber(v.damage or 0) or 0,category=tostring(v.category or "杂项"),admin_only=(v.admin_only==true)}
            end
        end
    end
    table.sort(arr,function(a,b)
        if a.order==b.order then return a.id<b.id end
        return a.order<b.order
    end)
    return arr
end

function full_shop_find(query, playerName)
    query=lower(trim(query or ""))
    query=query:gsub("^minecraft:","")
    if query=="" then return {} end
    local exact={}
    local fuzzy={}
    local catalog=full_shop_catalog(playerName)
    for _,v in ipairs(catalog) do
        local id=lower(v.id)
        local nm=lower(v.name)
        if id==query or nm==query then
            exact[#exact+1]=v
        elseif id:find(query,1,true) or nm:find(query,1,true) then
            fuzzy[#fuzzy+1]=v
        end
    end
    if #exact>0 then return exact end
    return fuzzy
end

function full_shop_payment(name,item)
    if type(item)~="table" then send(name,"§c商品数据无效。"); return true end
    if not is_admin(name) and full_shop_admin_only(item.id,item.name) then
        send(name,"§c该物品仅管理权限可购买。")
        return true
    end
    local d,r=player_record(name,true)
    set_menu(d,r,"full_shop_payment",{full_shop_item=item})
    send(name,"§6━━ 商品支付 ━━\n§f商品：§e"..tostring(item.name).."\n§f真实ID：§7"..tostring(item.id).."\n§f单价：§6"..tostring(item.price).." 积分\n\n§e输入 1 表示同意支付\n§7输入 0 表示不同意，直接关闭菜单。")
    return true
end

function full_shop_show_list(name,page)
    local arr=full_shop_catalog(name)
    -- 聊天栏可视高度有限；此菜单固定10项/页，确保当前页完整显示，不再塞满13项导致底部被截断。
    local per=10
    local maxp=math.max(1,math.ceil(#arr/per))
    page=math.max(1,math.min(tonumber(page) or 1,maxp))
    local first=(page-1)*per+1
    local last=math.min(#arr,first+per-1)
    local page_arr={}
    local lines={"§b━━ 全物品购买 ━━","§7第 "..page.." / "..maxp.." 页 §8| §7共 "..#arr.." 项"}
    for i=first,last do
        local v=arr[i]
        local row=i-first+1
        page_arr[row]=v
        lines[#lines+1]=string.format("§f%d. §e%s §7| §6%s积分",row,tostring(v.name),tostring(v.price))
    end
    lines[#lines+1]="§7+ 下一页    - 上一页 | 输入编号购买"
    local d,r=player_record(name,true)
    set_menu(d,r,"full_shop_list",{full_shop_page=page,full_shop_list=page_arr,full_shop_max_page=maxp})
    send(name,table.concat(lines,"\n"))
    send(name,"§6【操作提示】输入 1 表示同意购买，输入 0 表示拒绝。")
    return true
end

function full_shop_search_prompt(name)
    local d,r=player_record(name,true)
    set_menu(d,r,"full_shop_search")
    send(name,"§b━━ 商品搜索 ━━\n§f请输入商品真实ID或名称。\n§7支持：英文ID、中文名称、minecraft:ID；搜索成功后直接进入支付界面。")
    return true
end

function full_shop_buy_main(name)
    local d,r=player_record(name,true)
    set_menu(d,r,"full_shop_buy_main")
    send(name,"§b━━ 物品购买 ━━\n§f1. 商品搜索\n§f2. 商品选择\n§7输入1/2选择；.stop退出。\n§e提示：聊天框输入 .购物 可直接打开此界面。")
    return true
end

function full_shop_begin_quantity(name,item)
    local d,r=player_record(name,true)
    r.full_shop_item=item
    set_menu(d,r,"full_shop_quantity",{full_shop_item=item})
    send(name,"§b━━ 购买数量 ━━\n§f商品：§e"..tostring(item.name).."\n§f单价：§6"..tostring(item.price).."积分\n§f请输入购买数量：§e1 ~ 2500\n§7购买总价 = 单价 × 数量；积分不足将自动退出。")
    return true
end

function full_shop_execute(name,item,qty)
    qty=math.floor(tonumber(qty) or 0)
    if qty<1 or qty>2500 then send(name,"§c购买数量必须是 1 ~ 2500。"); return true end
    if type(item)~="table" or trim(item.id)=="" then send(name,"§c商品数据无效，购买取消。"); return true end
    if not is_admin(name) and full_shop_admin_only(item.id,item.name) then
        clear_menu(player_record(name,true))
        send(name,"§c该物品仅管理权限可购买，购买已取消。")
        return true
    end
    local board=scoreboard_name()
    if not board then
        local md,mr=player_record(name,true)
        clear_menu(md,mr)
        send(name,"§c服务器尚未设置积分版，无法购买。")
        return true
    end
    local unit=math.floor(tonumber(item.price) or 0)
    if unit<=0 then send(name,"§c商品价格无效。"); return true end
    local total=unit*qty
    local okb,balance=pcall(game.getScore,board,name)
    if not okb then send(name,"§c无法读取你的积分。"); return true end
    balance=tonumber(balance) or 0
    if balance<total then
        clear_menu(player_record(name,true))
        send(name,"§c货币不足。\n§f商品：§e"..tostring(item.name).."\n§f需要：§6"..total.." 积分\n§f当前：§a"..balance.." 积分")
        return true
    end

    -- 先扣款；若 give 执行失败则立即退款，避免玩家无货又丢积分。
    local safe=string.gsub(name,'"','\\"')
    local rem_ok,rem_res=pcall(game.isCmdSuccess,'scoreboard players remove "'..safe..'" '..board..' '..total)
    if not rem_ok or rem_res~=true then
        send(name,"§c扣款失败，购买未完成。")
        return true
    end

    local give_id, give_data = tostring(item.id):match("^([^:]+):([%-]?%d+)$")
    if not give_id then give_id=tostring(item.id) end
    local give_cmd='give "'..safe..'" '..give_id..' '..tostring(qty)..(give_data and (' '..give_data) or '')
    local give_ok,give_res=pcall(game.isCmdSuccess,give_cmd)
    if not give_ok or give_res~=true then
        local refund_ok,refund_res=pcall(game.isCmdSuccess,'scoreboard players add "'..safe..'" '..board..' '..total)
        if refund_ok and refund_res==true then
            send(name,"§c发货失败，已自动退回 "..total.." 积分。")
        else
            send(name,"§c发货失败，退款指令也失败，请立即联系管理权限。")
        end
        return true
    end

    append_json_log(PURCHASE_LOG_FILE,{at=util.timestamp(),type="全物品系统商店",buyer=name,buyer_uuid=uuid_key(name),item=item.name,item_id=item.id,unit_price=unit,quantity=qty,total=total})
    local d,r=player_record(name,true)
    r.purchase_count=(tonumber(r.purchase_count) or 0)+qty
    clear_menu(d,r)
    save_data(d)
    send(name,"§a购买成功！\n§f商品：§e"..tostring(item.name).."\n§f数量：§a"..qty.."\n§f单价：§6"..unit.." 积分\n§f共扣除：§6"..total.." 积分")
    return true
end

function show_market_14(name)
    local d,r=player_record(name,true)
    set_menu(d,r,"market14_main")
    send(name,"§b━━ 系统商店 ━━\n§f1. 购买物品\n§f2. 出售物品\n§f3. 物品购买\n§7购买物品：管理权限上架的系统商店商品。\n§7出售物品：把自己的物品按服务器固定收购价换成积分。\n§7物品购买：全物品目录，系统商店购买价统一下调40%，全部取整；下界合金块同样下调40%。\n§e输入1/2/3选择；.stop退出。\n§e提示：输入 .购物 可直接打开“物品购买”菜单。")
end
function show_sell_price_list(name,page)
    local prices=sell_price_data(); local arr={}; for id,v in pairs(prices) do table.insert(arr,{id=id,price=tonumber(v.price or v)or 0,name=v.name,order=tonumber(v.order) or 999999,damage=tonumber(v.damage or 0) or 0}) end
    table.sort(arr,function(a,b) if a.order==b.order then return tostring(a.id)<tostring(b.id) end return a.order<b.order end)
    -- 与全物品购买保持一致：10项/页，避免聊天栏底部截断。
    local per=10; local maxp=math.max(1,math.ceil(#arr/per)); page=math.max(1,math.min(tonumber(page)or 1,maxp)); local first=(page-1)*per+1; local last=math.min(#arr,first+per-1); local names=item_name_data()
    local lines={"§b━━ 玩家收购 ━━","§7第 "..page.." / "..maxp.." 页"}
    for i=first,last do local v=arr[i]; lines[#lines+1]=string.format("§f%d. §e%s §7[%s] %d积分",i-first+1,tostring(v.name or names[v.id] or v.id:gsub("_"," ")),tostring(v.category or "杂项"),v.price) end
    lines[#lines+1]="§7+ 下一页    - 上一页 | 1开始出售 | 0退出"
    local d,r=player_record(name,true); set_menu(d,r,"server_sell_list",{sell_page=page,sell_list=arr,sell_max_page=maxp}); send(name,table.concat(lines,"\n")); send(name,"§6【操作提示】输入 1 表示同意开始出售，输入 0 表示拒绝并退出。"); return true
end
function sell_table_lookup(item)
    local id=item_base_id(item); local damage=item_damage_value(item); local prices=sell_price_data(); local v=prices[id]; if not v then return nil,"该物品暂不收购："..translated_item_name(item) end
    if damage~=(tonumber(v.damage or 0)or 0) then return nil,"该物品特殊值不符合收购规则："..translated_item_name(item) end
    local ench=item.Enchantments or item.enchantments or item.enchant or item.Enchants; if type(ench)=="table" and next(ench)~=nil then return nil,"不收带附魔物品："..translated_item_name(item) end
    local custom=item.CustomName or item.custom_name or item.displayName; if custom and tostring(custom)~="" then return nil,"不收改名物品："..translated_item_name(item) end
    if (item.Damage or item.damage) and damage>0 then return nil,"仅收无损耗物品："..translated_item_name(item) end; return tonumber(v.price or v)or 0,nil
end
function cancel_server_sell_state(name, reason)
    local d,r=player_record(name,true)
    local sess=server_sell_get_session(d,name)
    if type(sess)=="table" and type(sess.barrel_pos)=="table" then
        local p=sess.barrel_pos
        local x,y,z=math.floor(p.x),math.floor(p.y),math.floor(p.z)
        local ry=y-1
        pcall(game.isCmdSuccess,string.format('setblock %d %d %d air replace',x,ry,z))
        server_sell_cleanup_drops(x,ry,z)
    end
    server_sell_clear_session(d,name)
    d.server_sell_pending=nil
    if r.menu=="server_sell_list" or r.menu=="server_sell_wait" then
        r.menu=nil; r.menu_expires=nil
    end
    save_data(d)
    if reason and reason~="" then send(name,reason) end
    return true
end

function server_sell_session_expired(name,d,r)
    local s=server_sell_get_session(d,name)
    if type(s)~="table" then return false end
    local expires=tonumber(s.expires_at) or ((tonumber(s.created_at) or 0)+180)
    if expires<=0 or util.timestamp()<expires then return false end
    cancel_server_sell_state(name,"§e出售时间已超过3分钟，木桶已清除，本次出售结束。")
    return true
end

function server_sell_begin(name)
    if not market_scoreboard_ready() then send(name,"§c服务器尚未设置积分版。") return true end
    local d,r=player_record(name,true)
    if server_sell_session_expired(name,d,r) then
        d,r=player_record(name,true)
    end
    local existing,exists=server_sell_validate_session(name,d)
    if exists then
        set_menu(d,r,"server_sell_wait")
        send(name,"§e你已经有一个待出售木桶。§f输入 §e1 §f正式结算，输入 §e0 §f取消。")
        save_data(d)
        return true
    end
    d.server_sell_pending=nil
    local pos=player_position(name); if not pos then send(name,"§c无法读取当前位置，无法放置出售木桶。") return true end
    local x,y,z=math.floor(pos.x),math.floor(pos.y),math.floor(pos.z)
    local safe=string.gsub(name,'"','\\"')
    local ok,res=pcall(game.isCmdSuccess,'execute as @a[name="'..safe..'"] at @s run setblock ~ ~ ~ barrel')
    if not ok or res~=true then send(name,"§c无法放置出售木桶，请确认脚下空间可用。") return true end
    local placed_at=util.timestamp()
    server_sell_set_session(d,name,{barrel_pos={x=x,y=y,z=z},created_at=placed_at,expires_at=placed_at+180,owner=tostring(name),status="waiting"})
    set_menu(d,r,"server_sell_wait")
    r.menu_expires=placed_at+180
    save_data(d)
    send(name,"§a木桶已放置。\n§f请把要出售的物品放入木桶。\n§e输入 1：确认出售并计算积分\n§7输入 0：取消出售")
    return true
end
function market_finish_server_sell(name)
    local d,r=player_record(name,true); if server_sell_session_expired(name,d,r) then return true end
    d,r=player_record(name,true)
    local s,valid=server_sell_validate_session(name,d)
    if not valid then save_data(d); send(name,"§c出售失败：你的收购木桶已经不存在，交易已结束。") return true end
    if s.status=="processing" or s.status=="completed" then send(name,"§c这笔出售已经处理过了，请勿重复确认。") return true end
    s.status="processing"
    local p=s.barrel_pos; local x,y,z=math.floor(p.x),math.floor(p.y),math.floor(p.z); local ry=y-1
    local ok,data,err=market_region_one_block(x,ry,z); if not ok or type(data)~="table" or lower(tostring(data.name or data.id or "")):find("barrel",1,true)==nil then s.status="waiting"; save_data(d); send(name,"§c出售失败：找不到指定木桶。") return true end
    local nbt=data.nbt or data.NBT or data.blockEntityNbt or data.block_entity_nbt; local items=type(nbt)=="table" and nbt.Items or nil; if type(items)~="table" then s.status="waiting"; save_data(d); send(name,"§c出售失败：木桶内没有可读取物品。") return true end
    local total=0; local detail={}; local bad={}; for _,item in pairs(items) do local count=tonumber(item.Count or item.count or 0)or 0; if count>0 then local unit,why=sell_table_lookup(item); if not unit then bad[#bad+1]=why else total=total+unit*count; detail[#detail+1]=translated_item_name(item).." ×"..count.." = "..(unit*count).."积分" end end end
    if #bad>0 then s.status="waiting"; save_data(d); send(name,"§c出售失败，以下物品不支持：\n§7"..table.concat(bad,"\n§7")); return true end; if total<=0 then s.status="waiting"; save_data(d); send(name,"§c木桶内没有支持出售的物品。"); return true end
    local board=market_scoreboard_ready(); if not board then s.status="waiting"; save_data(d); send(name,"§c服务器尚未设置积分版，无法结算。"); return true end; local safe=string.gsub(name,'"','\\"'); local okcmd,res=pcall(game.isCmdSuccess,'scoreboard players add "'..safe..'" '..board..' '..math.floor(total)); if not okcmd or res~=true then send(name,"§c积分发放失败，未清空你的物品。"); return true end
    pcall(game.isCmdSuccess,string.format('setblock %d %d %d air replace',x,ry,z)); server_sell_cleanup_drops(x,ry,z); append_json_log(PURCHASE_LOG_FILE,{at=util.timestamp(),type="服务器收购",seller=name,seller_uuid=uuid_key(name),total=total,items=detail}); server_sell_clear_session(d,name); clear_menu(d,r); save_data(d); send(name,"§a出售成功！\n§f"..table.concat(detail,"\n§f").."\n§6共获得 "..math.floor(total).." 积分。"); return true
end
function market_offline_notice_db() return file_load(OFFLINE_MARKET_NOTICE_FILE,{items={}}) end
function market_queue_offline_notice(uid,item,buyer,amount,id) local d=market_offline_notice_db(); d.items=d.items or {}; d.items[tostring(uid)]=d.items[tostring(uid)] or {}; table.insert(d.items[tostring(uid)],{item=item,buyer=buyer,amount=amount,id=tostring(id),at=util.timestamp()}); file_save(OFFLINE_MARKET_NOTICE_FILE,d) end
function market_credit_pending(uid,amount,name) local d=market_wallet_db(); d.balances=d.balances or {}; d.balances[tostring(uid)]=(tonumber(d.balances[tostring(uid)])or 0)+math.floor(tonumber(amount)or 0); d.last_names=d.last_names or {}; d.last_names[tostring(uid)]=name or d.last_names[tostring(uid)]; market_wallet_save(d) end
function market_settle_offline(name)
    local uid=uuid_key(name); local d=market_wallet_db(); local amount=tonumber((d.balances or {})[uid])or 0; local board=scoreboard_name()
    if amount>0 and board then local safe=string.gsub(name,'"','\\"'); local ok,res=pcall(game.isCmdSuccess,'scoreboard players add "'..safe..'" '..board..' '..math.floor(amount)); if ok and res==true then d.balances[uid]=0; market_wallet_save(d); send(name,"§a离线期间商品结算：§6+"..math.floor(amount).." 积分") end end
    local nd=market_offline_notice_db(); local arr=nd.items and nd.items[uid]; if type(arr)=="table" and #arr>0 then local lines={"§b━━ 离线期间商品交易 ━━"}; for _,v in ipairs(arr) do lines[#lines+1]="§f你的商品「§e"..tostring(v.item).."§f」已被「§b"..tostring(v.buyer).."§f」购买，获得 §6"..tostring(v.amount).." 积分。" end; send(name,table.concat(lines,"\n")); nd.items[uid]=nil; file_save(OFFLINE_MARKET_NOTICE_FILE,nd) end
end

function market_db() return file_load(MARKET_FILE,{next_id=1,listings={},shops={},reports={},logs={}}) end
function market_save(d) file_save(MARKET_FILE,d) end
function territory_db()
    local d=file_load(TERRITORY_FILE,{next_id=1,items={},deleted={},entry_state={}})
    d.next_id=tonumber(d.next_id) or 1; d.items=d.items or {}; d.deleted=d.deleted or {}; d.entry_state=d.entry_state or {}
    -- 每块领地固定保存一个维度；旧数据若缺失维度才补主世界，已有维度不擅自改写。
    for _,t in pairs(d.items) do if type(t)=="table" then t.dimension=normalize_dimension(t.dimension) or "overworld" end end
    for _,t in pairs(d.deleted) do if type(t)=="table" then t.dimension=normalize_dimension(t.dimension) or "overworld" end end
    return d
end
function territory_save(d) file_save(TERRITORY_FILE,d) end
function territory_protection_log(item) append_json_log(TERRITORY_PROTECTION_LOG_FILE,item) end
function shop_log_db() return file_load(SHOP_LOG_FILE,{logs={}}) end
function purchase_log_db() return file_load(PURCHASE_LOG_FILE,{logs={}}) end
function append_json_log(path,item)
    local d=file_load(path,{logs={}}); d.logs=d.logs or {}; table.insert(d.logs,item); if #d.logs>5000 then table.remove(d.logs,1) end; file_save(path,d)
end
function market_busy(d)
    return d.market_busy==true
end
function set_market_busy(value)
    local d=load_data(); d.market_busy=value==true; save_data(d)
end
function shop_level(sold)
    sold=tonumber(sold) or 0
    if sold>=3 then return "优秀商家" elseif sold>=1 then return "良好商家" end
    return "新商家"
end

-- 玩家市场的金币只读取管理权限通过 .积分版 设置的现有计分板。
-- 不创建第二套“金币”计分板，避免和服务器现有积分体系分叉。
function market_scoreboard_ready()
    local board=scoreboard_name()
    if not board or trim(board)=="" then return nil end
    return board
end

function market_wallet_db() return file_load(MARKET_WALLET_FILE,{balances={}}) end
function market_wallet_save(d) file_save(MARKET_WALLET_FILE,d) end
function market_credit(uuid,amount,playerName)
    amount=math.floor(tonumber(amount) or 0); if amount<=0 then return end
    local d=market_wallet_db(); d.balances=d.balances or {}; local k=tostring(uuid)
    d.balances[k]=(tonumber(d.balances[k]) or 0)+amount
    d.last_names=d.last_names or {}; d.last_names[k]=playerName or d.last_names[k]
    market_wallet_save(d)
end
function market_wallet_get(uuid)
    local d=market_wallet_db(); return tonumber((d.balances or {})[tostring(uuid)]) or 0 end

-- 玩家市场 NBT：严格使用开发文档提供的区域 NBT API。
-- 上架：记录的整数坐标 -> getRegionBlockData(x,y,z,1,1,1) 一次 -> 保存完整 name/states/nbt。
-- 购买：读取保存的 entry -> placeNBTBlock 到买家整数坐标 -> 再验证目标 NBT 有 Items -> 最后删除保存数据。
function market_nbt_db() return file_load(MARKET_NBT_FILE,{items={}}) end
function market_nbt_save(d)
    local ok,err=pcall(util.json_write,MARKET_NBT_FILE,d)
    return ok,err
end
function market_nbt_has_items(v)
    if type(v)~="table" then return false end
    local nbt=v.nbt or v.NBT or v.blockEntityNbt or v.block_entity_nbt
    if type(nbt)~="table" or type(nbt.Items)~="table" then return false end
    for _,item in pairs(nbt.Items) do
        if type(item)=="table" then
            local item_name=item.Name or item.name
            local count=tonumber(item.Count or item.count or 0) or 0
            if item_name and tostring(item_name)~="" and count>0 then return true end
        end
    end
    return false
end

function market_region_one_block(x,y,z)
    local ok,region=pcall(game.getRegionBlockData,x,y,z,1,1,1)
    if not ok or type(region)~="table" then return false,nil,"getRegionBlockData调用失败："..tostring(region) end
    local key=string.format("%d,%d,%d",x,y,z)
    local data=region[key]
    if type(data)~="table" then
        for k,v in pairs(region) do
            if tostring(k)==key then data=v; break end
        end
    end
    if type(data)~="table" then return false,nil,"指定区块数据中没有返回该坐标。" end
    return true,data,nil
end

function market_copy_table(v, seen)
    if type(v)~="table" then return v end
    seen=seen or {}
    if seen[v] then return seen[v] end
    local out={}; seen[v]=out
    for k,val in pairs(v) do out[market_copy_table(k,seen)]=market_copy_table(val,seen) end
    return out
end

function market_nbt_items_count(nbt)
    if type(nbt)~="table" or type(nbt.Items)~="table" then return 0 end
    local n=0
    for _,item in pairs(nbt.Items) do if type(item)=="table" and (item.Name or item.name) and (tonumber(item.Count or item.count or 0) or 0)>0 then n=n+1 end end
    return n
end

function market_read_target_nbt(x,y,z)
    local ok,nbt=pcall(game.getBlockNBT,x,y,z)
    if ok and type(nbt)=="table" then return true,nbt,nil end
    local ok2,data,err=market_region_one_block(x,y,z)
    if ok2 and type(data)=="table" then return true,(data.nbt or data.NBT or data.blockEntityNbt or data.block_entity_nbt),nil end
    return false,nil,"getBlockNBT失败；区域回读也失败："..tostring(err or nbt)
end

function market_place_and_verify(x,y,z,block_name,states,nbt)
    local attempts={states, ""}
    local last_err=""
    for i,st in ipairs(attempts) do
        pcall(game.isCmdSuccess,string.format('setblock %d %d %d air',x,y,z))
        local ok,err=pcall(game.placeNBTBlock,x,y,z,block_name,st,market_copy_table(nbt))
        if ok then
            -- placeNBTBlock 没有返回值；必须实际重新读取目标方块。
            local vok,vnbt,verr=market_read_target_nbt(x,y,z)
            if vok and market_nbt_items_count(vnbt)>0 then
                return true,vnbt,nil,i
            end
            last_err=tostring(verr or "目标 NBT 无有效 Items")
        else
            last_err=tostring(err)
        end
    end
    return false,nil,last_err
end

function market_save_nbt_item(id,x,y,z)
    x,y,z=math.floor(tonumber(x)),math.floor(tonumber(y)),math.floor(tonumber(z)); if not x or not y or not z then return false,"商品坐标无效。" end
    local use_y=y-1; local ok,data,err=market_region_one_block(x,use_y,z); if not ok or type(data)~="table" or lower(tostring(data.name or data.id or "")):find("barrel",1,true)==nil then return false,"指定位置脚下一格不是木桶。" end
    local nbt=data.nbt or data.NBT or data.blockEntityNbt or data.block_entity_nbt; if not market_nbt_has_items({nbt=nbt}) then return false,"商品木桶为空。" end
    local entry={id=tostring(id),block_name=tostring(data.name or data.id or "minecraft:barrel"),states=data.states or {},nbt=market_copy_table(nbt),saved_at=util.timestamp(),x=x,y=use_y,z=z}; local db=market_nbt_db(); db.items=db.items or {}; db.items[tostring(id)]=entry; local ok_save,save_err=market_nbt_save(db); if not ok_save then return false,"预览数据保存失败："..tostring(save_err) end; market_save_preview(id,entry); return true,entry
end
function market_load_nbt_item(id,x,y,z) return market_clone_storage_to_target(id,x,y,z) end

function market_delete_nbt_item(id)
    local db=market_nbt_db(); db.items=db.items or {}; db.items[tostring(id)]=nil
    local ok,err=market_nbt_save(db)
    return ok,err
end

function fixed_shop_db() return file_load(FIXED_SHOP_FILE,{next_id=1,items={}}) end
function fixed_shop_save(d)
    local ok,err=pcall(util.json_write,FIXED_SHOP_FILE,d)
    return ok,err
end
function fixed_shop_list()
    local d=fixed_shop_db(); local a={}; local changed=false
    for _,v in pairs(d.items or {}) do
        if not v.disabled then
            v.max_purchases=math.floor(tonumber(v.max_purchases or v.limit or v.remaining or 0) or 0)
            if v.remaining==nil then v.remaining=v.max_purchases; changed=true end
            if tonumber(v.remaining)<0 then v.remaining=0; changed=true end
            if v.remaining>0 then table.insert(a,v) end
        end
    end
    if changed then fixed_shop_save(d) end
    table.sort(a,function(x,y)return (tonumber(x.id) or 0)<(tonumber(y.id) or 0) end); return a
end
function fixed_shop_show(name,page)
    local a=fixed_shop_list(); local per=8; local maxp=math.max(1,math.ceil(#a/per)); page=math.max(1,math.min(tonumber(page) or 1,maxp))
    local first=(page-1)*per+1; local last=math.min(#a,first+per-1); local lines={"§b━━ 系统商店 ━━","§7第 "..page.." / "..maxp.." 页"}
    if #a==0 then table.insert(lines,"§e当前没有可购买商品。") else for i=first,last do local v=a[i]; table.insert(lines,string.format("§f%d. §e%s §7| §6%s积分 §7| 剩余§a%s",i-first+1,tostring(v.name),tostring(v.price),tostring(v.remaining or 0))) end end
    table.insert(lines,"§7输入序号选择；§f+/-§7翻页；.stop退出。")
    local d,r=player_record(name,true); set_menu(d,r,"fixed_shop_buy",{fixed_shop_list=a,fixed_shop_page=page,fixed_shop_max_page=maxp}); send(name,table.concat(lines,"\n"))
end
function fixed_shop_begin(name)
    if not is_admin(name) then send(name,"§c只有管理权限可以设置系统商店商品。"); return true end
    local d,r=player_record(name,true); r.fixed_shop_setup={step=1}; set_menu(d,r,"fixed_shop_name"); send(name,"§e请输入要出售的商品名称："); return true
end
function fixed_shop_finish(name,fx,fy,fz)
    local d,r=player_record(name,true); local st=r.fixed_shop_setup
    if type(st)~="table" then send(name,"§c系统商店创建状态丢失，商品创建取消。"); return true end
    if fx~=nil and fy~=nil and fz~=nil then st.x=tonumber(fx); st.y=tonumber(fy); st.z=tonumber(fz); st.dimension=detect_dimension(name); r.fixed_shop_setup=st; save_data(d) end
    if tonumber(st.x)==nil or tonumber(st.y)==nil or tonumber(st.z)==nil then send(name,"§c系统商店源坐标没有保存，商品创建取消。"); return true end
    local max_purchases=math.floor(tonumber(st.limit) or 0); if max_purchases<1 or max_purchases>114514 then send(name,"§c最大购买次数必须是1~114514。"); return true end
    st.x=math.floor(st.x); st.y=math.floor(st.y); st.z=math.floor(st.z)
    local db=fixed_shop_db(); local id=tostring(db.next_id or 1); db.next_id=(tonumber(db.next_id) or 1)+1
    db.items[id]={id=id,name=st.name,price=math.floor(tonumber(st.price) or 0),max_purchases=max_purchases,remaining=max_purchases,source={x=st.x,y=st.y,z=st.z,dimension=st.dimension},created_at=util.timestamp(),disabled=false}
    local ok,err=fixed_shop_save(db); if not ok then send(name,"§c系统商店保存失败："..tostring(err)); return true end
    local vok,vdb=pcall(util.json_load,FIXED_SHOP_FILE); local sv=vok and vdb and vdb.items and vdb.items[id]
    if type(sv)~="table" or type(sv.source)~="table" or tonumber(sv.source.x)~=st.x or tonumber(sv.source.y)~=st.y or tonumber(sv.source.z)~=st.z then send(name,"§c系统商店源坐标回读校验失败，创建取消。"); return true end
    r.fixed_shop_setup=nil; clear_menu(d,r); send(name,"§a系统商店商品已添加！\n§f商品：§e"..st.name.."\n§f价格：§6"..st.price.."积分\n§f最大购买次数：§b"..max_purchases.."\n§f编号：§b"..id); return true
end
function fixed_shop_buy(name,id)
    local db=fixed_shop_db(); local v=db.items[tostring(id)]; if not v or v.disabled then send(name,"§c商品不存在或已下架。"); return true end
    local remain=tonumber(v.remaining or v.max_purchases or 0) or 0; if remain<=0 then send(name,"§c这个系统商店商品已经售罄。"); return true end
    local d,r=player_record(name,true); set_menu(d,r,"fixed_shop_buy_confirm",{fixed_shop_buy_id=tostring(id)}); send(name,"§6━━ 购买确认 ━━\n§f商品：§e"..tostring(v.name).."\n§f单次价格：§6"..tostring(v.price).."积分\n§f剩余可购买：§a"..remain.."次\n§f1. 同意\n§f0. 取消"); return true
end
function fixed_shop_execute_buy(name,id,qty)
    local db=fixed_shop_db(); local v=db.items[tostring(id)]; if not v or v.disabled then send(name,"§c商品不存在或已下架。"); return true end
    qty=math.floor(tonumber(qty) or 0); local remaining=tonumber(v.remaining or v.max_purchases or 0) or 0
    if qty<=0 then send(name,"§e已取消购买。"); return true end
    if qty>64 then send(name,"§c一次最多购买64次。"); return true end
    if remaining<qty then send(name,"§c购买次数不足，当前剩余："..remaining.."次。"); return true end
    local src=v.source; if type(src)~="table" or tonumber(src.x)==nil or tonumber(src.y)==nil or tonumber(src.z)==nil then send(name,"§c系统商店源数据损坏，无法购买。"); return true end
    local board=scoreboard_name(); if not board then send(name,"§c服务器尚未设置积分版。"); return true end
    local okb,balance=pcall(game.getScore,board,name); if not okb then send(name,"§c无法读取你的积分。"); return true end
    balance=tonumber(balance) or 0; local price=math.floor(tonumber(v.price) or 0); local total=price*qty
    if balance<total then send(name,"§c积分不足。\n§f本次：§e"..qty.."次\n§f需要：§6"..total.."积分\n§f当前：§a"..balance.."积分"); return true end
    local pos=player_position(name); if not pos then send(name,"§c无法读取你的购买位置。"); return true end
    local tx,ty,tz=math.floor(pos.x),math.floor(pos.y),math.floor(pos.z); local sx,sy,sz=math.floor(src.x),math.floor(src.y),math.floor(src.z)
    local done=0; local destroy_fail=0
    for _=1,qty do
        local clone=string.format('clone %d %d %d %d %d %d %d %d %d replace',sx,sy,sz,sx,sy,sz,tx,ty,tz)
        local okc,res=pcall(game.isCmdSuccess,clone); if not okc or res~=true then break end
        done=done+1
        local okd,resd=pcall(game.isCmdSuccess,string.format('setblock %d %d %d air destroy',tx,ty,tz)); if not okd or resd~=true then destroy_fail=destroy_fail+1 end
    end
    if done<=0 then send(name,"§c系统商店复制失败，积分未扣除。"); return true end
    local charge=price*done; local safe=string.gsub(name,'"','\\"')
    local rem_ok,rem_res=pcall(game.isCmdSuccess,'scoreboard players remove "'..safe..'" '..board..' '..charge)
    if not rem_ok or rem_res~=true then send(name,"§c商品已复制，但积分扣除失败，请立即联系管理权限；已发放"..done.."次。"); return true end
    v.remaining=remaining-done; v.max_purchases=math.max(tonumber(v.max_purchases) or remaining,remaining); db.items[tostring(v.id)]=v; fixed_shop_save(db)
    append_json_log(PURCHASE_LOG_FILE,{at=util.timestamp(),type="系统商店",buyer=name,buyer_uuid=uuid_key(name),item=v.name,price=price,quantity=done,total=charge,id=tostring(v.id),remaining=v.remaining})
    local pd,pr=player_record(name,true); pr.purchase_count=(tonumber(pr.purchase_count) or 0)+done; clear_menu(pd,pr); save_data(pd)
    local out="§a购买成功！\n§f商品：§e"..tostring(v.name).."\n§f本次购买：§a"..done.."次\n§f花费：§6"..charge.."积分\n§f剩余购买次数：§b"..v.remaining
    if done<qty then out=out.."\n§e服务器只完成了"..done.."次复制，未完成部分未扣积分。" end
    if destroy_fail>0 then out=out.."\n§e有"..destroy_fail.."次目标木桶未自动破坏，请手动取出。" end
    send(name,out); return true
end

function buyer_level(count)
    count=tonumber(count) or 0
    if count>=10 then return "优秀买家" elseif count>=5 then return "良好买家" end
    return "新买家"
end
function market_public_list(page) return market_public_list_v2(page) end
function show_market(name,page) return show_market_v2(name,page) end
function show_market_main(name) return show_player_market_main(name) end
function market_sell_begin(name)
    if not market_scoreboard_ready() then send(name,"§c管理权限尚未设置积分版。请先使用 .积分版 <计分板名称>。") return true end
    if market_busy(load_data()) then send(name,"§e机器人正在忙碌中，请稍后再试。") return true end
    local d,r=player_record(name,true); r.market_sell_day=r.market_sell_day or {day=math.floor(util.timestamp()/86400),count=0,last_at=0}; local st=r.market_sell_day; local day=math.floor(util.timestamp()/86400); if st.day~=day then st.day=day; st.count=0 end
    if st.count>=5 then send(name,"§c你今天已经使用5次上架机会。明天再来。") return true end
    if util.timestamp()-(tonumber(st.last_at) or 0)<600 then send(name,"§c两次上架至少间隔10分钟。") return true end
    set_menu(d,r,"market_sell_price"); send(name,"§e请输入商品价格（使用当前积分版的分数作为金币）：") return true
end
function market_finish_sell(name)
    local d,r=player_record(name,true); local s=d.market_sessions and d.market_sessions[name]; if not s then send(name,"§c没有待确认商品。") return true end
    if market_busy(d) then send(name,"§e机器人正在忙碌中，请稍后再试。") return true end
    if market_storage_db().x==nil then send(name,"§c管理权限尚未设置玩家市场三维仓库，请先设置：.市场仓库 X Y Z"); return true end
    local id=tostring(s.id); set_market_busy(true); local ok,entry=market_save_nbt_item(id,s.barrel_pos.x,s.barrel_pos.y,s.barrel_pos.z); if not ok then set_market_busy(false); send(name,"§c商品保存失败："..tostring(entry)); return true end
    local c=market_storage_coord(id); local cloned=market_clone_one(s.barrel_pos.x,s.barrel_pos.y-1,s.barrel_pos.z,c.x,c.y,c.z); if not cloned then set_market_busy(false); send(name,"§c商品原版 clone 到三维仓库失败，商品未上架。"); return true end
    pcall(game.isCmdSuccess,string.format('setblock %d %d %d air destroy',math.floor(s.barrel_pos.x),math.floor(s.barrel_pos.y-1),math.floor(s.barrel_pos.z))); market_clear_barrel_drop(name,s.barrel_pos.x,s.barrel_pos.y-1,s.barrel_pos.z)
    local db=market_db(); db.listings[id]={id=id,name=s.name,price=s.price,seller=name,seller_uuid=uuid_key(name),storage_id=id,preview_nbt=entry.nbt,created_at=util.timestamp(),sold=false,sold_count=0,disabled=false,shop_banned=false,reports=0}; db.next_id=math.max(tonumber(db.next_id)or 1,tonumber(s.id)+1); market_save(db)
    r.market_sell_day.count=(tonumber(r.market_sell_day.count)or 0)+1; r.market_sell_day.last_at=util.timestamp(); d.market_sessions[name]=nil; clear_menu(d,r); save_data(d); set_market_busy(false); append_json_log(SHOP_LOG_FILE,{at=util.timestamp(),type="上架",seller=name,id=id,name=s.name,price=s.price,storage_id=id}); send(name,"§a商品已上架！\n§f商品名：§e"..s.name.."\n§f价格：§6"..s.price.."积分\n§f编号：§b"..id); return true
end
function market_claim(name,id)
    local db=market_db(); local v=db.listings[tostring(id)]; if not v or v.disabled or v.shop_banned or v.sold then send(name,"§c商品不存在或已下架。"); return true end
    local board=scoreboard_name(); if not board then send(name,"§c服务器尚未设置积分版。") return true end; local ok,balance=pcall(game.getScore,board,name); balance=ok and tonumber(balance)or 0; local price=tonumber(v.price)or 0; local d,r=player_record(name,true)
    if balance<price then clear_menu(d,r); send(name,"§c支付失败：积分不足。需要 "..price.."，当前 "..balance.."。"); return true end
    set_menu(d,r,"market_buy_confirm",{market_buy_id=tostring(id),market_buy_price=price}); send(name,"§6━━ 支付确认 ━━\n§f商品：§e"..v.name.."\n§f卖家：§b"..v.seller.."\n§f应付：§6"..price.."积分\n§f1. 确认支付\n§f0. 拒绝支付"); return true
end
function market_purchase_execute_clone(name,id,price)
    local d,r=player_record(name,true); local db=market_db(); local v=db.listings[tostring(id)]; if not v or v.sold or v.disabled or v.shop_banned then send(name,"§c商品已不可购买。") return true end
    local board=scoreboard_name(); if not board then send(name,"§c服务器尚未设置积分版。") return true end; local ok,balance=pcall(game.getScore,board,name); balance=ok and tonumber(balance)or 0; price=tonumber(price)or tonumber(v.price)or 0; if balance<price then send(name,"§c积分不足，购买取消。") return true end
    local pos=player_position(name); if not pos then send(name,"§c无法读取购买位置。") return true end; local x,y,z=math.floor(pos.x),math.floor(pos.y),math.floor(pos.z); set_market_busy(true); local cloned=market_clone_storage_to_target(v.id,x,y,z); if not cloned then set_market_busy(false); send(name,"§c仓库发货失败，未扣积分。"); return true end
    local safe=string.gsub(name,'"','\\"'); local rem_ok,rem_res=pcall(game.isCmdSuccess,'scoreboard players remove "'..safe..'" '..board..' '..math.floor(price)); if not rem_ok or rem_res~=true then set_market_busy(false); send(name,"§c扣分失败，购买取消。") return true end
    pcall(game.isCmdSuccess,string.format('setblock %d %d %d air destroy',x,y,z)); market_clear_barrel_drop(name,x,y,z); v.sold=true; v.sold_count=(tonumber(v.sold_count)or 0)+1; v.sold_at=util.timestamp(); v.buyer=name; v.buyer_uuid=uuid_key(name); db.listings[tostring(id)]=v; market_save(db)
    local seller=v.seller; local seller_online=false; for _,nm in ipairs(online_players()or {}) do if uuid_key(nm)==v.seller_uuid then seller=nm; seller_online=true; break end end
    if seller_online then
        local add_ok,add_res=pcall(game.isCmdSuccess,'scoreboard players add "'..string.gsub(seller,'"','\\"')..'" '..board..' '..math.floor(price))
        if not add_ok or add_res~=true then market_credit_pending(v.seller_uuid,price,seller); market_queue_offline_notice(v.seller_uuid,v.name,name,price,id) end
    else
        market_credit_pending(v.seller_uuid,price,seller); market_queue_offline_notice(v.seller_uuid,v.name,name,price,id)
    end
    append_json_log(PURCHASE_LOG_FILE,{at=util.timestamp(),type="玩家市场购买",buyer=name,buyer_uuid=uuid_key(name),seller=seller,seller_uuid=v.seller_uuid,item=v.name,price=price,id=id,offline=not seller_online}); append_json_log(SHOP_LOG_FILE,{at=util.timestamp(),type="出售",buyer=name,buyer_uuid=uuid_key(name),seller=seller,seller_uuid=v.seller_uuid,name=v.name,price=price,id=id,offline=not seller_online}); market_delete_nbt_item(v.id)
    local pd,pr=player_record(name,true); pr.purchase_count=(tonumber(pr.purchase_count)or 0)+1; clear_menu(pd,pr); save_data(pd); set_market_busy(false); send(name,"§a购买成功！商品已掉落在你身边。")
    local sd,sr=player_record(seller,true); sr.sold_count=(tonumber(sr.sold_count)or 0)+1; save_data(sd); if seller_online then send(seller,"§a你的商品「"..v.name.."」已被 "..name.." 购买，获得 "..price.." 积分。") end; return true
end
function market_purchase_finish_pending() return true end
function market_purchase_pending_tick() return true end
function market_execute_purchase(name,id,price,discount,vip_title) return market_purchase_execute_clone(name,id,price) end

function show_shop_management(name)
    local db=market_db(); local mine={}; local uid=uuid_key(name); for _,v in pairs(db.listings or {}) do if v.seller_uuid==uid and not v.sold then table.insert(mine,v) end end; table.sort(mine,function(a,b)return tostring(a.id)<tostring(b.id) end)
    local lines={"§b━━ 店铺管理 ━━","§f1. 商品改价","§f2. 设定VIP客户","§f3. 下架商品","§7当前在架商品："..#mine,"§7输入 .stop 退出。"}; local d,r=player_record(name,true); set_menu(d,r,"market_manage",{market_mine=mine}); send(name,table.concat(lines,"\n"))
end
function show_shop_logs(name)
    local d=shop_log_db(); local uid=uuid_key(name); local lines={"§b━━ 商铺日志 ━━"}; local count=0; local total=0
    for i=#(d.logs or {}),1,-1 do
        local x=d.logs[i]
        if x.seller_uuid==uid then
            count=count+1; total=total+(tonumber(x.price) or 0)
            if #lines<10 then table.insert(lines,"§f"..os.date("%Y-%m-%d %H:%M",tonumber(x.at) or 0).." §7| §b"..tostring(x.name).." §7| §6"..tostring(x.price).."金币") end
        end
    end
    table.insert(lines,"§7共售出 "..count.." 件，到账 "..total.." 金币。等级："..shop_level(count))
    local pd,pr=player_record(name,true); set_menu(pd,pr,"market_logs"); send(name,table.concat(lines,"\n"))
end

function show_sellers(name,page)
    local db=market_db(); local map={}; for _,v in pairs(db.listings or {}) do if not v.disabled and not v.shop_banned then map[v.seller_uuid]=map[v.seller_uuid] or {name=v.seller,level=shop_level(0),sold=0}; map[v.seller_uuid].sold=map[v.seller_uuid].sold+(v.sold and 1 or 0); map[v.seller_uuid].level=shop_level(map[v.seller_uuid].sold) end end
    local arr={}; for _,x in pairs(map) do table.insert(arr,x) end; table.sort(arr,function(a,b)return tostring(a.name)<tostring(b.name)end)
    local per=12; local maxp=math.max(1,math.ceil(#arr/per)); page=math.max(1,math.min(tonumber(page)or 1,maxp)); local first=(page-1)*per+1; local last=math.min(#arr,first+per-1); local page_arr={}; local lines={"§b━━ 查看商家 ━━","§7第 "..page.." / "..maxp.." 页",""}
    for i=first,last do local x=arr[i]; local row=i-first+1; page_arr[row]=x; lines[#lines+1]=string.format("§f%d. §b%s §7| %s | 售出%s件",row,x.name,x.level,tostring(x.sold)) end
    if #arr==0 then lines[#lines+1]="§e暂未有商家，希望你成为第一个在这里开店的人。" end
    lines[#lines+1]=""; lines[#lines+1]="§7+ 下一页    - 上一页"; lines[#lines+1]="§e输入编号查看商家；也可使用：.查看商家 玩家名"
    local d,r=player_record(name,true); set_menu(d,r,"market_sellers",{market_sellers=page_arr,market_seller_page=page,market_seller_max_page=maxp}); send(name,table.concat(lines,"\n"))
end
function show_seller_by_name(name,target)
    target=trim(target or ""); if target=="" then send(name,"§e用法：.查看商家 玩家名"); return true end
    local db=market_db(); local wanted=uuid_key(target); local seller_name=nil; local seller_uuid=nil; local sold=0; local goods={}
    for _,v in pairs(db.listings or {}) do
        if not v.disabled and not v.shop_banned and (uuid_key(v.seller)==wanted or lower(tostring(v.seller))==lower(target)) then seller_name=v.seller; seller_uuid=v.seller_uuid; sold=sold+(v.sold and 1 or 0); if not v.sold then table.insert(goods,v) end end
    end
    if not seller_name then send(name,"§c没有找到商家「"..target.."」。"); return true end
    table.sort(goods,function(a,b)return (tonumber(a.id)or 0)<(tonumber(b.id)or 0)end); local lines={"§b━━ 商家详情 ━━","§f商家：§e"..seller_name,"§f等级：§a"..shop_level(sold),"§f已售：§e"..sold.." 件","","§f在架商品："}
    if #goods==0 then lines[#lines+1]="§7暂无在架商品。" else for i,v in ipairs(goods) do if i>12 then break end; lines[#lines+1]=string.format("§f%d. §e%s §7| §6%s积分",i,v.name,v.price) end end
    local d,r=player_record(name,true); set_menu(d,r,"market_seller_detail",{market_seller_name=seller_name,market_seller_uuid=seller_uuid}); send(name,table.concat(lines,"\n")); return true
end
function territory_contains(t,pos,margin)
    if not t or not pos then return false end; if t.dimension and dim_exec(t.dimension)~=dim_exec(pos.dimension) then return false end; local m=tonumber(margin) or 0; local x1,x2=math.min(t.x1,t.x2)-m,math.max(t.x1,t.x2)+m; local z1,z2=math.min(t.z1,t.z2)-m,math.max(t.z1,t.z2)+m; return pos.x>=x1 and pos.x<=x2 and pos.z>=z1 and pos.z<=z2 and pos.y>=-99999 and pos.y<=99999 end
function territory_inside(t,pos) return territory_contains(t,pos,0) end
function territory_overlap(a,b)
    if dim_exec(a.dimension)~=dim_exec(b.dimension) then return false end
    return math.max(math.min(a.x1,a.x2),math.min(b.x1,b.x2))<=math.min(math.max(a.x1,a.x2),math.max(b.x1,b.x2)) and math.max(math.min(a.z1,a.z2),math.min(b.z1,b.z2))<=math.min(math.max(a.z1,a.z2),math.max(b.z1,b.z2))
end
function territory_too_close(a,b,min_gap)
    if dim_exec(a.dimension)~=dim_exec(b.dimension) then return false end
    local gap=tonumber(min_gap) or 20
    local ax1,ax2=math.min(a.x1,a.x2),math.max(a.x1,a.x2); local az1,az2=math.min(a.z1,a.z2),math.max(a.z1,a.z2)
    local bx1,bx2=math.min(b.x1,b.x2),math.max(b.x1,b.x2); local bz1,bz2=math.min(b.z1,b.z2),math.max(b.z1,b.z2)
    local dx=math.max(0, math.max(ax1,bx1)-math.min(ax2,bx2))
    local dz=math.max(0, math.max(az1,bz1)-math.min(az2,bz2))
    return math.sqrt(dx*dx+dz*dz) < gap
end
function territory_owned_list(name, mode, page)
    local db=territory_db(); local uid=uuid_key(name); local arr={}
    local source=(mode=="territory_restore_list") and (db.deleted or {}) or (db.items or {})
    local admin=is_admin(name)
    for _,t in pairs(source) do
        if t and (mode=="territory_restore_list" and t.deleted_at or not t.deleted) then
            local owner_ok=(t.owner_uuid==uid)
            -- 管理权限删除/公开管理可以查看所有人的领地；恢复仍只允许恢复自己的领地。
            if mode=="territory_delete_list" and admin then owner_ok=true end
            if mode=="territory_public_list" and admin then owner_ok=true end
            if owner_ok and (mode~="territory_restore_list" or util.timestamp()-(tonumber(t.deleted_at) or 0)<=86400) then table.insert(arr,t) end
        end
    end
    table.sort(arr,function(a,b) return tonumber(a.id or 0)<tonumber(b.id or 0) end)
    local per=8; local maxp=math.max(1,math.ceil(#arr/per)); page=math.max(1,math.min(page or 1,maxp))
    local first=(page-1)*per+1; local last=math.min(#arr,first+per-1)
    local lines={mode=="territory_public_list" and "§b━━ 公开领地 ━━" or "§b━━ 领地列表 ━━"}
    if #arr==0 then
        table.insert(lines, mode=="territory_restore_list" and "§e暂无可恢复领地。" or "§e暂无领地。")
    else
        for i=first,last do
            local t=arr[i]
            local public_label=(t.public==true and "§a公开" or "§7关闭公开")
            local owner_label=(admin and mode=="territory_public_list" or admin and mode=="territory_delete_list") and (" §7| 所有人：§f"..tostring(t.owner or "未知")) or ""
            table.insert(lines,string.format("§f%d. §e%s §7| 编号：§b%s%s",i-first+1,tostring(t.name or "未命名"),tostring(t.id),mode=="territory_public_list" and (" §7| "..public_label) or owner_label))
        end
        if maxp>1 then table.insert(lines,"§7第 "..page.." / "..maxp.." 页") end
        table.insert(lines,"§7输入编号选择；+ 下一页；- 上一页；.stop退出。")
    end
    local d,r=player_record(name,true); set_menu(d,r,mode,{territory_page=page,territory_list=arr}); send(name,table.concat(lines,"\n"))
end

function show_territory(name)
    local db=territory_db(); local uid=uuid_key(name); local mine={}; for _,t in pairs(db.items or {}) do if t.owner_uuid==uid and not t.deleted then table.insert(mine,t) end end; table.sort(mine,function(a,b)return tonumber(a.id)<tonumber(b.id)end); local lines={"§b━━ 我的领地 ━━","§f1. 创建领地","§f2. 删改密码","§f3. 删除领地","§f4. 增加领地次数","§f5. 恢复领地","§f6. 公开领地"}; if is_admin(name) then lines[4]="§f4. 增加领地次数"; lines[5]="§f5. 恢复领地"; lines[6]="§f6. 公开领地" end; lines[#lines+1]="§7输入编号进入对应操作；.stop退出。"; local d,r=player_record(name,true); set_menu(d,r,"territory_main",{territory_mine=mine}); send(name,table.concat(lines,"\n"))
end
function normalize_password_input(value)
    -- 领地密码只保存稳定的 ASCII 0~9；不再依赖 Lua %d 的字符类行为。
    local p=tostring(value or "")
    local full={{"０","0"},{"１","1"},{"２","2"},{"３","3"},{"４","4"},{"５","5"},{"６","6"},{"７","7"},{"８","8"},{"９","9"}}
    for _,pair in ipairs(full) do p=string.gsub(p,pair[1],pair[2]) end
    p=string.gsub(p,"[ \t\r\n]","")
    p=string.gsub(p,"^[%.：:%「」【】『』]+","")
    p=string.gsub(p,"[%.：:%「」【】『』]+$","")
    return p
end
function password_ascii_digit_count(value)
    local p=normalize_password_input(value); local n=0
    for i=1,#p do local b=string.byte(p,i); if b and b>=48 and b<=57 then n=n+1 end end
    return n,p
end
function valid_six_digit_password(value)
    local n,p=password_ascii_digit_count(value)
    if n~=6 or #p~=6 then return false end
    for i=1,6 do local b=string.byte(p,i); if not b or b<48 or b>57 then return false end end
    return true
end
function parse_territory_password_command(msg)
    -- 不使用 %d：某些 Lua/宿主字符类在中文聊天输入环境下表现不稳定。
    local raw=tostring(msg or "")
    local body=raw:match("^%.领地密码%s+(.+)%s*$")
    if not body then return nil end
    local normalized=normalize_password_input(body)
    if normalized=="" then return "" end
    return normalized
end

function territory_begin_create(name)
    local d,r=player_record(name,true); r.territory_create={step=1}; set_menu(d,r,"territory_create_name"); send(name,"§e请输入领地名称。\n§7然后按提示输入：起始X Z、结束X Z、密码。Y轴不限；普通玩家最大128×128，管理权限最大512×512。")
end
function territory_create_finish(name)
    local d,r=player_record(name,true); local s=r.territory_create; if not s then return true end; local db=territory_db(); local isadm=is_admin(name); local max=isadm and 512 or 128; local w=math.abs(s.x2-s.x1)+1; local l=math.abs(s.z2-s.z1)+1; if w>max or l>max then send(name,"§c创建失败：范围过大。最大 "..max.."×"..max.."，Y轴不限。"); r.territory_create=nil; clear_menu(d,r); return true end; local uid=uuid_key(name); local count=0; for _,t in pairs(db.items or {}) do if t.owner_uuid==uid and not t.deleted then count=count+1 end end; if not isadm and count>=1 then local extra=tonumber(r.territory_extra) or 0; if extra>0 then r.territory_extra=extra-1 else send(name,"§c普通玩家只能拥有1块领地。管理权限可通过增加领地次数授权。 "); r.territory_create=nil; clear_menu(d,r); return true end end; local pass_count,pass_value=password_ascii_digit_count(s.password); if pass_count~=6 or #pass_value~=6 then send(name,"§c创建失败：领地密码必须是6位数字。当前有效数字为 "..tostring(pass_count).." 位。"); return true end; s.password=pass_value; local candidate={x1=s.x1,z1=s.z1,x2=s.x2,z2=s.z2,dimension=s.dimension,owner_uuid=uid,owner=name,name=s.name,password=pass_value,password_digits=pass_value,public=false,created_at=util.timestamp(),deleted=false}; for _,t in pairs(db.items or {}) do if not t.deleted and territory_overlap(candidate,t) then send(name,"§c创建失败：该区域与已有领地重叠。"); r.territory_create=nil; clear_menu(d,r); return true elseif not t.deleted and territory_too_close(candidate,t,20) then send(name,"§c创建失败：领地之间至少需要间隔20米，请扩大间距后重试。"); r.territory_create=nil; clear_menu(d,r); return true end end; local id=tostring(db.next_id or 1); db.next_id=(tonumber(db.next_id)or 1)+1; candidate.id=id; db.items[id]=candidate; territory_save(db); territory_protection_log({at=util.timestamp(),type="领地创建",player=name,player_uuid=uid,territory_id=id,territory_name=s.name,dimension=s.dimension,x1=s.x1,z1=s.z1,x2=s.x2,z2=s.z2,public=false}); r.territory_create=nil; clear_menu(d,r); send(name,"§a领地创建成功！编号："..id.."\n§7密码已保存。")
    return true
end
function tick_territories()
    local db=territory_db(); db.entry_state=db.entry_state or {}
    local names=online_players() or {}; local changed=false
    -- uuid_key 会读一次玩家数据文件；先在本地建一次「名字 → 唯一ID」缓存，避免每个在线玩家都重复读盘。
    local uid_cache={}
    do
        local pd=load_data()
        for _,rec in pairs(pd.players or {}) do
            if type(rec)=="table" and rec.name then
                local u=trim(rec.unique_id or rec.xuid or "")
                if u~="" then uid_cache[rec.name]=u end
            end
        end
    end
    local function uid_of(nm)
        local u=uid_cache[nm]
        if u and u~="" then return u end
        local info=get_info(nm)
        if info and trim(info.unique_id or "")~="" then
            u=tostring(info.unique_id); uid_cache[nm]=u; return u
        end
        u=uuid_key(nm); uid_cache[nm]=u; return u
    end
    for _,name in ipairs(names) do
        local pos=player_position(name)
        if pos then
            local uid=uid_of(name)
            for _,t in pairs(db.items or {}) do
                if not t.deleted and t.owner_uuid~=uid and dim_exec(t.dimension)==dim_exec(pos.dimension) then
                    local key=uid..":"..tostring(t.id)
                    local st=db.entry_state[key] or {}
                    local now=util.timestamp()
                    -- 把旧版本仍在30分钟有效期内的授权升级为永久授权；已过期的旧授权继续要求密码。
                    if st.allowed~=true and st.allowed_until and now < tonumber(st.allowed_until) then
                        st.allowed=true; st.allowed_at=now; st.allowed_until=nil; db.entry_state[key]=st; changed=true
                    end
                    if t.public==true then
                        -- 公开领地：任何玩家都可以进入，不需要密码，也不触发保护传送。
                    elseif st.allowed==true then
                        -- 密码授权永久有效；离开再回来也不需要重新输入。
                    elseif st.allowed_until and now < tonumber(st.allowed_until) then
                        -- 兼容旧版本30分钟授权数据。
                    elseif territory_inside(t,pos) then
                        -- 每次真正进入他人领地都立即传送到领地外，并写入保护日志。
                        local x1,x2=math.min(t.x1,t.x2),math.max(t.x1,t.x2)
                        local z1,z2=math.min(t.z1,t.z2),math.max(t.z1,t.z2)
                        local last=RUNTIME.last_pos[name]
                        local escape=nil
                        if last and not territory_inside(t,last) then
                            escape={x=last.x,y=last.y,z=last.z,dimension=last.dimension or pos.dimension}
                        end
                        if not escape then
                            local dx=math.min(math.abs(pos.x-x1),math.abs(pos.x-x2))
                            local dz=math.min(math.abs(pos.z-z1),math.abs(pos.z-z2))
                            if dx<=dz then
                                escape={x=(math.abs(pos.x-x1)<math.abs(pos.x-x2) and x1-2 or x2+2),y=pos.y,z=math.min(math.max(pos.z,z1),z2),dimension=pos.dimension}
                            else
                                escape={x=math.min(math.max(pos.x,x1),x2),y=pos.y,z=(math.abs(pos.z-z1)<math.abs(pos.z-z2) and z1-2 or z2+2),dimension=pos.dimension}
                            end
                        end
                        st.count=(tonumber(st.count) or 0)+1
                        st.first_entry=escape
                        st.last_block_at=now
                        st.last_attempt_at=now
                        st.last_escape=escape
                        local safe=string.gsub(name,'"','\\"')
                        local cmd=string.format('execute as @a[name="%s"] in %s run tp @s %.2f %.2f %.2f',safe,dim_exec(escape.dimension),tonumber(escape.x),tonumber(escape.y),tonumber(escape.z))
                        local ok,res=pcall(game.isCmdSuccess,cmd)
                        if not (ok and res==true) then pcall(game.sendCommand,cmd) end
                        territory_protection_log({at=now,type="领地保护传送",player=name,player_uuid=uid,territory_id=t.id,territory_name=t.name,from={x=pos.x,y=pos.y,z=pos.z,dimension=pos.dimension},to=escape,reason="未经密码进入他人领地",attempt=st.count,command_ok=(ok and res==true)})
                        db.entry_state[key]=st; changed=true
                        send(name,"§c你已进入他人领地，已自动传送到领地外。")
                    elseif territory_contains(t,pos,5) then
                        -- 离开领地后重新进入，重新计数；避免历史闯入次数永久累积。
                        if st.count and st.count>0 then st.count=0; db.entry_state[key]=st; changed=true end
                        if not st.prompted_at or now-tonumber(st.prompted_at)>30 then
                            st.prompted_at=now; db.entry_state[key]=st; local pd,pr=player_record(name,true); pr.territory_pending_id=t.id; save_data(pd); changed=true
                            send(name,"§e你已接近「"..tostring(t.name).."」领地（5米范围）。如你拥有密码，请输入：.领地密码 6位数字")
                        end
                    else
                        if st.count and st.count>0 then st.count=0; db.entry_state[key]=st; changed=true end
                    end
                end
            end
        end
    end
    for id,t in pairs(db.deleted or {}) do
        if util.timestamp()-(tonumber(t.deleted_at) or 0)>86400 then db.deleted[id]=nil; changed=true end
    end
    if changed then territory_save(db) end
end

-- ════════════════════════════════════════════════════════════
--   世界种子 / 结构查询（接真实查询器：Ds Platform）
--   接口：GET  {base}/tools/seed/scan?seed=&structure=&radius=&x=&z
--         Header: Authorization: Bearer <token>
--         -> {results:[{name,x,z,distance}], cached}
--   登录：POST {base}/auth/login {account,password} -> {token,user}
--   旧的 mineseedfinder 已失效，这里会自动回落到真实查询器。
-- ════════════════════════════════════════════════════════════
SEED_TOKEN_FILE = game.dataDir() .. "/seed_engine_token.json"
SEED_CRED_FILE  = game.dataDir() .. "/seed_engine_cred.json"

function get_server_seed()
    local ok,v=pcall(util.json_load,SEED_FILE)
    if ok and type(v)=="table" and v.seed~=nil and trim(tostring(v.seed))~="" then return tostring(v.seed) end
    local d=load_data(); local s=d.server_seed
    if s~=nil and trim(tostring(s))~="" then return tostring(s) end
    return nil
end
function set_server_seed(playerName,seed)
    seed=trim(seed)
    local d=load_data(); d.server_seed=seed; d.server_seed_set_by=playerName; d.server_seed_set_at=util.now(); save_data(d)
    file_save(SEED_FILE,{seed=seed,set_by=playerName,set_at=util.now()})
end

-- 中文/英文结构名 -> 查询器的 structure 参数（英文 id）
SEED_STRUCTURE_IDS = {
    ["村庄"]="village", ["village"]="village",
    ["要塞"]="stronghold", ["stronghold"]="stronghold",
    ["海底神殿"]="monument", ["monument"]="monument", ["海底遗迹"]="monument",
    ["林地府邸"]="mansion", ["mansion"]="mansion",
    ["废弃传送门"]="ruined_portal", ["ruined_portal"]="ruined_portal", ["下界废弃传送门"]="ruined_portal",
    ["掠夺者前哨站"]="pillager_outpost", ["pillager_outpost"]="pillager_outpost",
    ["远古城市"]="ancient_city", ["ancient_city"]="ancient_city",
    ["沼泽小屋"]="swamp_hut", ["swamp_hut"]="swamp_hut",
    ["沙漠神殿"]="desert_pyramid", ["desert_pyramid"]="desert_pyramid",
    ["丛林神庙"]="jungle_pyramid", ["jungle_pyramid"]="jungle_pyramid",
}
SEED_STRUCTURE_LABELS = {
    ["village"]="村庄", ["stronghold"]="要塞", ["monument"]="海底神殿",
    ["mansion"]="林地府邸", ["ruined_portal"]="废弃传送门",
    ["pillager_outpost"]="掠夺者前哨站", ["ancient_city"]="远古城市",
    ["swamp_hut"]="沼泽小屋", ["desert_pyramid"]="沙漠神殿", ["jungle_pyramid"]="丛林神庙",
}

-- 查询器地址：忽略旧配置里已失效的地址，自动回落到真实查询器
function seed_engine_base()
    local base=trim(tostring(game.getConfig("seed_engine_url","") or ""))
    if base=="" or lower(base):find("mineseedfinder",1,true) then return SEED_FINDER_URL end
    return (base:gsub("/+$",""))
end

-- 账号密码：优先插件配置，其次数据目录凭据文件（.种子账号 会写到这里）
function seed_engine_cred()
    local acct=trim(tostring(game.getConfig("seed_engine_account","") or ""))
    local pwd=tostring(game.getConfig("seed_engine_password","") or "")
    if acct~="" and pwd~="" then return acct,pwd end
    local ok,d=pcall(util.json_load,SEED_CRED_FILE)
    if ok and type(d)=="table" then
        local a=trim(tostring(d.account or "")); local p=tostring(d.password or "")
        if a~="" and p~="" then return a,p end
    end
    return acct,pwd
end
function set_seed_engine_cred(account,password)
    pcall(util.json_write,SEED_CRED_FILE,{account=tostring(account or ""),password=tostring(password or ""),at=util.timestamp()})
    pcall(util.json_write,SEED_TOKEN_FILE,{})
end

function seed_engine_token()
    local t=trim(tostring(game.getConfig("seed_engine_token","") or ""))
    if t~="" then return t end
    local ok,d=pcall(util.json_load,SEED_TOKEN_FILE)
    if ok and type(d)=="table" then
        local tk=trim(tostring(d.token or ""))
        if tk~="" then
            local exp=tonumber(d.expires_at)
            if (not exp) or util.timestamp()<exp then return tk end
        end
    end
    return nil
end

-- 登录拿 token 并缓存到数据目录
function seed_engine_login()
    local acct,pwd=seed_engine_cred()
    if acct=="" or pwd=="" then
        return nil,"未配置查询器账号。请在插件配置填写 seed_engine_account / seed_engine_password，或在游戏内执行 .种子账号 <账号> <密码>"
    end
    local base=seed_engine_base()
    local r=http.post(base.."/auth/login",http.json_encode({account=acct,password=pwd}),
        {headers={['Content-Type']='application/json'},timeout=20})
    if not r or not r.ok then return nil,"登录请求失败："..tostring(r and (r.error or r.status) or "无响应") end
    if tonumber(r.status)<200 or tonumber(r.status)>=300 then
        return nil,"登录失败（HTTP "..tostring(r.status).."）："..trim(tostring(r.body or "")):sub(1,160)
    end
    local ok,data=pcall(http.json_decode,r.body or "")
    if not ok or type(data)~="table" then return nil,"登录返回格式异常" end
    -- Ds 平台把 token 放在 data.token 里；这里同时兼容顶层 token。
    local inner=type(data.data)=="table" and data.data or data
    local token=trim(tostring(inner.token or data.token or ""))
    if token=="" then return nil,"登录返回格式异常（没有拿到 token）" end
    pcall(util.json_write,SEED_TOKEN_FILE,{token=token,at=util.timestamp(),account=acct})
    return token
end

function query_seed_structure_engine(playerName,structure_name,radius)
    local seed=get_server_seed()
    if not seed then return "§c尚未设置世界种子，请管理权限先使用 .种子 <种子号>。" end
    local info=get_info(playerName)
    local x=(info and tonumber(info.x)) or 0
    local z=(info and tonumber(info.z)) or 0
    local key=trim(structure_name or "")
    local sid=SEED_STRUCTURE_IDS[key] or SEED_STRUCTURE_IDS[lower(key)] or "village"
    local label=SEED_STRUCTURE_LABELS[sid] or key
    local base=seed_engine_base()
    local params={seed=seed,structure=sid,radius=math.floor(tonumber(radius) or SEED_FINDER_DEFAULT_RADIUS),x=math.floor(x),z=math.floor(z)}
    local url=base.."/tools/seed/scan?"..http.querify(params)
    local last=""
    local relogged=false
    for _=1,SEED_FINDER_RETRIES do
        local token=seed_engine_token()
        if not token then
            local tk,err=seed_engine_login()
            if not tk then return "§c结构查询服务登录失败："..tostring(err) end
            token=tk
        end
        local r=http.get(url,{headers={['Authorization']='Bearer '..token},timeout=SEED_FINDER_TIMEOUT})
        if r and r.ok and tonumber(r.status)>=200 and tonumber(r.status)<300 then
            local ok,data=pcall(http.json_decode,r.body or "")
            if ok and type(data)=="table" then
                local results=data.results or {}
                if #results==0 then return "§e附近没有找到「"..label.."」。" end
                local lines={"§b[结构查询] §f种子 "..tostring(seed).." 附近的「"..label.."」："}
                for i,v in ipairs(results) do
                    local n=tostring(v.name or sid)
                    local cn=SEED_STRUCTURE_LABELS[n] or SEED_STRUCTURE_LABELS[sid] or n
                    local dist=tonumber(v.distance)
                    local dtext=dist and string.format("%.1f",dist) or "?"
                    table.insert(lines,string.format("§e%d. §f%s §7X=%d Z=%d §7距离=%s",i,cn,math.floor(tonumber(v.x) or 0),math.floor(tonumber(v.z) or 0),dtext))
                end
                if data.cached==true then lines[#lines+1]="§8（来自查询器缓存）" end
                return table.concat(lines,"\n")
            end
            last="返回数据解析失败"
        elseif r and tonumber(r.status)==401 then
            -- token 失效：清缓存，下一轮自动重新登录
            pcall(util.json_write,SEED_TOKEN_FILE,{})
            if relogged then last="登录状态失效（请确认账号密码正确）" else relogged=true; last="登录状态失效，正在重新登录" end
        else
            last="HTTP "..tostring(r and r.status or 0).." "..trim(tostring(r and (r.error or r.body) or "网络请求失败")):sub(1,160)
        end
    end
    return "§c结构查询服务失败："..last
end

-- ════════════════════════════════════════════════════════════
--   结构定位：以游戏内 /locate 为主（不需要外部账号，直接读本服真实世界）
--   回显：commands.locate.structure.success
--         parameters = [结构id, X, Z, 相对执行者距离]
--   注意：包进 execute 后回显会丢失，所以用裸 locate，
--   再由插件按玩家自己的坐标换算距离与方向。
-- ════════════════════════════════════════════════════════════
-- 说明：以下 ID 全部在本服 1.21 实测验证过。
-- ⚠️ 与 Java 版不同的地方：
--   * 沙漠神殿 / 丛林神庙 在基岩版统一是 temple（desert_pyramid / jungle_pyramid 无效）
--   * 下界要塞 是 fortress（nether_fortress 无效）
--   * 沼泽小屋 是 witch_hut（swamp_hut 也是别名，但以 witch_hut 为准）
BEDROCK_LOCATE_IDS = {
    ["村庄"]="village", ["village"]="village",
    ["要塞"]="stronghold", ["stronghold"]="stronghold",
    ["海底神殿"]="monument", ["海底遗迹"]="monument", ["海洋神殿"]="monument",
    ["神殿"]="monument", ["monument"]="monument", ["ocean_monument"]="monument",
    ["林地府邸"]="mansion", ["府邸"]="mansion", ["mansion"]="mansion",
    ["废弃传送门"]="ruined_portal", ["下界传送门"]="ruined_portal", ["ruined_portal"]="ruined_portal",
    ["掠夺者前哨站"]="pillager_outpost", ["前哨站"]="pillager_outpost", ["pillager_outpost"]="pillager_outpost",
    ["远古城市"]="ancient_city", ["ancient_city"]="ancient_city",
    ["沼泽小屋"]="witch_hut", ["女巫小屋"]="witch_hut", ["swamp_hut"]="witch_hut", ["witch_hut"]="witch_hut",
    ["沙漠神殿"]="temple", ["丛林神庙"]="temple", ["神庙"]="temple",
    ["temple"]="temple", ["desert_pyramid"]="temple", ["jungle_pyramid"]="temple",
    ["沉船"]="shipwreck", ["shipwreck"]="shipwreck",
    ["埋藏的宝藏"]="buried_treasure", ["埋藏宝藏"]="buried_treasure", ["宝藏"]="buried_treasure", ["buried_treasure"]="buried_treasure",
    ["废弃矿井"]="mineshaft", ["矿井"]="mineshaft", ["mineshaft"]="mineshaft",
    ["试炼密室"]="trial_chambers", ["trial_chambers"]="trial_chambers",
    ["古迹废墟"]="trail_ruins", ["trail_ruins"]="trail_ruins",
    ["海洋废墟"]="ocean_ruin", ["ocean_ruin"]="ocean_ruin",
    ["下界要塞"]="fortress", ["地狱要塞"]="fortress", ["fortress"]="fortress", ["nether_fortress"]="fortress",
    ["堡垒遗迹"]="bastion_remnant", ["bastion_remnant"]="bastion_remnant",
    ["末地城"]="end_city", ["end_city"]="end_city",
}
LOCATE_CN = {
    village="村庄", stronghold="要塞", monument="海底神殿", mansion="林地府邸",
    temple="神庙", witch_hut="女巫小屋", pillager_outpost="掠夺者前哨站",
    ruined_portal="废弃传送门", ancient_city="远古城市", shipwreck="沉船",
    buried_treasure="埋藏的宝藏", mineshaft="废弃矿井", trial_chambers="试炼密室",
    trail_ruins="古迹废墟", ocean_ruin="海洋废墟", fortress="下界要塞",
    bastion_remnant="堡垒遗迹", end_city="末地城",
}
-- 只生成在特定维度的结构（在主世界 locate 会返回“没找到”）
BEDROCK_DIMENSION_ONLY = {
    fortress="下界", bastion_remnant="下界", end_city="末地",
}

function bedrock_locate_id(name)
    local key=trim(name or "")
    if key=="" then return nil end
    local sid=BEDROCK_LOCATE_IDS[key] or BEDROCK_LOCATE_IDS[lower(key)]
    if sid then return sid end
    local lk=lower(key)
    if lk:match("^[a-z_]+$") then return lk end
    return nil
end

function atan2_safe(y,x)
    if math.atan2 then return math.atan2(y,x) end
    return math.atan(y,x)
end
-- 以“北 = -Z”为基准的八方向
function compass8(dx,dz)
    local ang=math.deg(atan2_safe(dx,-dz))
    local dirs={"北","东北","东","东南","南","西南","西","西北"}
    local idx=math.floor(((ang+22.5)%360)/45)+1
    return dirs[idx] or "?"
end

-- 取玩家最后已知位置：优先实时缓存，其次落盘记录
function player_record_last_pos(playerName)
    local info=get_info(playerName)
    if info and tonumber(info.x) and tonumber(info.z) then
        return {x=tonumber(info.x),y=tonumber(info.y) or 0,z=tonumber(info.z),dimension=normalize_dimension(info.dimension) or "overworld"}
    end
    local d,r=player_record(playerName,true)
    if r and type(r.last_pos)=="table" and tonumber(r.last_pos.x) then
        return {x=tonumber(r.last_pos.x),y=tonumber(r.last_pos.y) or 0,z=tonumber(r.last_pos.z),dimension=normalize_dimension(r.last_pos.dimension) or "overworld"}
    end
    return nil
end

-- 执行游戏内 /locate；成功返回 {id,x,z,dist}，失败返回 nil,错误码
-- 错误码：__raw__（取不到回显）、__notfound__
-- ⚠️ 关键修复：sendCommandWithResp 默认超时只有 1 秒，而 /locate 搜索较远的结构
-- （林地府邸、掠夺者前哨站、要塞等）经常需要 1 秒以上，会被误判为超时，
-- 于是插件走了 __raw__ 分支、玩家看不到任何坐标。这里显式把超时提到 5 秒。
LOCATE_TIMEOUT = 5
function locate_structure_ingame(structure_name)
    local sid=bedrock_locate_id(structure_name)
    if not sid then return nil,"__badid__" end
    local res=nil
    local ok=pcall(function() res=game.sendCommandWithResp("locate structure "..sid,"ai",LOCATE_TIMEOUT) end)
    if not ok or type(res)~="table" then
        pcall(game.sendCommand,"locate structure "..sid)
        return nil,"__raw__"
    end
    local msgs=res.messages or {}
    for _,m in ipairs(msgs) do
        if type(m)=="table" then
            local tag=tostring(m.message or "")
            if tag=="commands.locate.structure.success" then
                local p=m.parameters or {}
                local x=tonumber(p[2]); local z=tonumber(p[3]); local dist=tonumber(p[4])
                local real_id=tostring(p[1] or sid):gsub("^minecraft:","")
                if x and z then return {id=real_id,x=x,z=z,dist=dist} end
            elseif tag=="commands.locate.structure.fail.nostructurefound" then
                return nil,"__notfound__"
            end
        end
    end
    return nil,"__notfound__"
end

-- 对外统一入口：优先游戏内 /locate；只有它不可用时才回落到外部查询器
function query_seed_structure(playerName,structure_name,radius)
    local label=trim(structure_name or "")
    if label=="" then label="村庄" end
    local sid=bedrock_locate_id(label)
    if not sid then
        return "§c不认识的结构名：§f"..label.."\n§7可用：村庄/要塞/海底神殿/林地府邸/废弃传送门/掠夺者前哨站/远古城市/女巫小屋/沙漠神殿/丛林神庙/沉船/埋藏的宝藏/废弃矿井/试炼密室/古迹废墟/下界要塞/堡垒遗迹/末地城"
    end
    local found,err=locate_structure_ingame(label)
    if type(found)=="table" then
        local cn=label
        if cn:match("^[%a_]+$") then cn=LOCATE_CN[found.id] or found.id end
        local lines={"§b━━ 结构定位 ━━","§f结构：§e"..cn.." §7("..found.id..")"}
        lines[#lines+1]=string.format("§f坐标：§eX=%d §fZ=%d",math.floor(found.x),math.floor(found.z))
        -- 只有在玩家在线时才计算“距你”，避免拿历史坐标算出离谱的距离
        local live=get_info(playerName)
        local pos=nil
        if live and live.online==true then pos=player_record_last_pos(playerName) end
        if pos then
            local dx=found.x-pos.x; local dz=found.z-pos.z
            local dd=math.sqrt(dx*dx+dz*dz)
            lines[#lines+1]=string.format("§f距你：§a约 %d 格 §7（%s方向）",math.floor(dd+0.5),compass8(dx,dz))
            if pos.dimension~="overworld" then
                lines[#lines+1]="§7注意：坐标按主世界计算，你当前维度可能不同。"
            end
        else
            lines[#lines+1]="§7（你当前不在线，或取不到你的位置，未计算相对距离）"
        end
        lines[#lines+1]="§7前往：§f.tp 主世界 "..math.floor(found.x).." 100 "..math.floor(found.z)
        return table.concat(lines,"\n")
    end
    if err=="__raw__" then
        return "§e定位指令已发给服务器，但没取到回显。请再试一次；若一直如此，说明这条结构离得太远。"
    end
    -- 外部查询器兜底（需要 .种子 + Ds 平台账号；后端未部署该接口时不可用）
    local ext=query_seed_structure_engine(playerName,label,radius)
    if type(ext)=="string" and ext:find("[结构查询]",1,true) then return ext end
    local dim_hint=BEDROCK_DIMENSION_ONLY[sid]
    if dim_hint then
        return "§e没有搜到「"..label.."」。\n§7这个结构只生成在 §f"..dim_hint.."§7，请先把自己/机器人切到该维度再查。"
    end
    return "§e没有搜到「"..label.."」。\n§7可能原因：距离过远、该群系在本世界不存在，或名字/维度不对。\n§7可换名字再试，例如：§f.结构 要塞§7、§f.结构 沉船§7、§f.结构 试炼密室§7、§f.结构 村庄§7。"
end

function nbt_test_item_summary(items)
    local out={}
    if type(items)~="table" then return out end
    for _,it in pairs(items) do
        if type(it)=="table" then
            local name=tostring(it.name or it.Name or "unknown")
            local count=tonumber(it.count or it.Count or 0) or 0
            local slot=tostring(it.slot or it.Slot or "?")
            local damage=it.damage or it.Damage
            if count>0 then
                local line=slot..":"..name.." x"..tostring(count)
                if damage~=nil then line=line.." damage="..tostring(damage) end
                out[#out+1]=line
            end
        end
    end
    return out
end
function nbt_test_block(name,x,y,z)
    local result={player=name,x=x,y=y,z=z}
    local ok,data=pcall(game.getBlockData,x,y,z)
    result.getBlockData_ok=ok
    if ok and type(data)=="table" then
        result.block_name=tostring(data.name or data.id or "")
        result.states=data.states
        result.nbt=data.nbt or data.NBT or data.blockEntityNbt or data.block_entity_nbt
        local items=result.nbt and result.nbt.Items
        result.items_count=0
        if type(items)=="table" then for _ in pairs(items) do result.items_count=result.items_count+1 end end
        result.items_summary=nbt_test_item_summary(items)
    else
        result.error=tostring(data)
    end
    local ok2,nbt=pcall(game.getBlockNBT,x,y,z)
    result.getBlockNBT_ok=ok2
    if ok2 and type(nbt)=="table" then
        local items2=nbt.Items
        result.direct_items_count=0
        if type(items2)=="table" then for _ in pairs(items2) do result.direct_items_count=result.direct_items_count+1 end end
        result.direct_items_summary=nbt_test_item_summary(items2)
    else
        result.direct_error=tostring(nbt)
    end
    return result
end
function nbt_test_inventory(name)
    local safe=string.gsub(tostring(name),'"','\\"')
    local selector='@a[name="'..safe..'"]'
    local result={player=name,selector=selector,api="game.queryInventory"}
    local ok,inv=pcall(game.queryInventory,selector)
    result.ok=ok
    if ok and type(inv)=="table" then
        result.items_count=0
        if type(inv.items)=="table" then for _ in pairs(inv.items) do result.items_count=result.items_count+1 end end
        result.summary=nbt_test_item_summary(inv.items)
        result.sample_type=type(inv.items[1])
    else
        result.error=tostring(inv)
    end
    return result
end
function nbt_test_report(name,coord_text)
    local parts={}
    for n in string.gmatch(trim(coord_text),"[^%s]+") do parts[#parts+1]=n end
    if #parts~=3 then send(name,"§cNBT测试格式：.NBT测试 X Y Z"); return true end
    local x=tonumber(parts[1]); local y=tonumber(parts[2]); local z=tonumber(parts[3])
    if not x or not y or not z then send(name,"§c坐标必须是数字，例如：.NBT测试 114 5 14"); return true end
    x,y,z=math.floor(x),math.floor(y),math.floor(z)
    send(name,"§b[数据测试] §f开始测试指定坐标，并测试当前玩家背包。")
    local block=nbt_test_block(name,x,y,z)
    local inv=nbt_test_inventory(name)
    local lines={"§b━━ NBT / 背包测试结果 ━━"}
    lines[#lines+1]=string.format("§f坐标：§e%d %d %d",x,y,z)
    lines[#lines+1]="§fgetBlockData："..(block.getBlockData_ok and "§a成功" or "§c失败")
    lines[#lines+1]="§f方块：§e"..tostring(block.block_name or "未知")
    lines[#lines+1]="§fgetBlockNBT："..(block.getBlockNBT_ok and "§a成功" or "§c失败")
    lines[#lines+1]="§fNBT Items：§e"..tostring(block.items_count or 0)
    for _,v in ipairs(block.items_summary or {}) do lines[#lines+1]="§7"..v end
    if #(block.items_summary or {})==0 then lines[#lines+1]="§7没有解析到有数量的 Items" end
    if not block.getBlockData_ok then lines[#lines+1]="§cgetBlockData错误："..tostring(block.error) end
    if not block.getBlockNBT_ok then lines[#lines+1]="§cgetBlockNBT错误："..tostring(block.direct_error) end
    lines[#lines+1]="§f背包 queryInventory："..(inv.ok and "§a调用成功" or "§c调用失败")
    lines[#lines+1]="§f背包原始条目数：§e"..tostring(inv.items_count or 0)
    for _,v in ipairs(inv.summary or {}) do lines[#lines+1]="§7"..v end
    if #(inv.summary or {})==0 then lines[#lines+1]="§7没有解析到有数量的背包物品" end
    if not inv.ok then lines[#lines+1]="§cqueryInventory错误："..tostring(inv.error) end
    lines[#lines+1]="§8测试完成；未开启后台扫描。"
    send(name,table.concat(lines,"\n"))
    return true
end

function show_help(name)
    local d,r=player_record(name,true)
    r.menu="help"; r.menu_expires=util.timestamp()+MENU_TIMEOUT; save_data(d)
    send(name,"§b━━ Ds 功能菜单 ━━\n§f1 保存传送点   2 返回传送点   3 返回死亡点   4 删除存档点   5 选玩家传送\n§f6 玩家转账     7 反馈审核     8 选坐标传送   9 灵魂出窍   10 封禁菜单\n§f11 解除封禁    12 玩家市场   13 领地保护   14 系统商店   15 玩法介绍\n§e输入 1~15 选择；§f.stop §7退出。")
end

GAMEPLAY_CATEGORIES = {
 {title="1. 菜单与退出",body=".help 打开菜单；.stop 随时退出。"},
 {title="2. AI聊天",body="AI 内容公开聊天；ai 内容私聊。普通AI保留15轮记忆；.记忆清除直接切新窗口。"},
 {title="3. AI指令",body="指令 内容进入独立指令窗口。复杂任务可使用 V4 Pro；管理权限可用 .AI模型 Flash 或 .AI模型 V4 Pro 直接切换。"},
 {title="4. 传送点",body=".保存/.保 保存；.回/.home/.传 返回；.删除/.删 删除。"},
 {title="5. 玩家传送",body="选择玩家发送申请；对方输入1同意、0拒绝。./tp 是传送快捷指令，不是AI入口。"},
 {title="6. 坐标传送",body=".tp 输入维度 X Y Z；普通玩家按次数使用，管理权限不限。"},
 {title="7. 玩家转账",body="按提示输入金币数量并确认。"},
 {title="8. 举报系统",body="举报玩家并提交理由；多名独立举报达到条件后进入AI审查。"},
 {title="9. 死亡点",body="死亡后自动记录坐标与维度；.死亡点返回 可返回。"},
 {title="10. 灵魂出窍",body=".soul 进入旁观；.退出返回原位置与模式。"},
 {title="11. 封禁与解封",body="管理权限使用封禁/解封菜单。"},
 {title="12. 玩家市场",body="玩家之间交易：玩家上架商品后进入三维常加载仓库；卖家下线商品仍保留，其他玩家照常购买；交易写入日志，卖家收益持久化，卖家上线自动结算并通知。"},
 {title="13. 领地保护",body="1创建 2删改密码 3删除 4增加领地次数 5恢复领地 6公开领地。普通玩家只能管理自己的领地；管理权限删除与公开管理可选择所有人的领地。密码验证永久有效；公开后所有玩家无需密码即可进入。"},
 {title="14. 系统商店",body="进入后选择：1购买物品（管理权限上架的系统商店商品）、2出售物品（按服务器固定收购价目表把自己的物品换成积分）、3物品购买（全物品目录，售价按统一系统购买价计算）。输入.购物可直接打开3物品购买界面。"},
 {title="15. 玩法介绍",body="这里是完整玩法说明索引。输入1~15返回对应说明。"}
}
function show_gameplay_categories(name)
 local d,r=player_record(name,true); set_menu(d,r,"gameplay_index")
 send(name,"§b━━ Ds 玩法介绍 ━━\n§f1 菜单  2 AI聊天  3 AI指令  4 传送点  5 玩家传送\n§f6 坐标传送  7 转账  8 举报  9 死亡点  10 灵魂\n§f11 封禁  12 玩家市场  13 领地  14 购物  15 玩法介绍\n§e输入1~15查看详情；.stop退出。")
end
function show_gameplay_category(name,index)
 local item=GAMEPLAY_CATEGORIES[index]; if not item then send(name,"§c编号无效，请输入1~"..#GAMEPLAY_CATEGORIES); return end; local d,r=player_record(name,true); clear_menu(d,r); send(name,"§b━━ "..item.title.." ━━\n"..item.body)
end

function show_trigger_words(name,page)
    local all={
        ".help",".回",".传",".home",".保存",".保",".删除",".删",".死亡点返回",".tp",".soul",".签到",".传送机会",
        ".添加权限",".撤回权限",".种子",".种子账号 <账号> <密码>",".种子状态",".积分版",".scoreboard 计分板名称",".AI模型 Flash/V4 Pro",".AI切换 Flash/V4 Pro",".查结构",".结构",".一键查询",".通",".NBT测试 X Y Z","./tp 玩家","ai 内容","AI 内容","AI 清除记忆","ai 清除记忆","指令 内容",".记忆清除",".清除记忆",
        ".玩家市场",".查看商家 玩家名",".售卖物品",".售卖商品",".出售物品","领地密码 6位数字",".购物系统",".举报商品 编号",".查验 编号",".领地密码 6位数字",".生成兑换码 <自然语言> <有效期>",".生成兑换码 导出 <名称> X1 Y1 Z1 X2 Y2 Z2 <有效期> / 导入 <名称> <有效期>",".兑换 <兑换码>",".导入 <名称> X Y Z",".导出 <名称> X1 Y1 Z1 X2 Y2 Z2",".日志",".解除封禁",".触发词",".撤回传送",".撤销举报",".退出","+ / - 翻页"
    }
    local total=#all
    local per_page=10
    local max_page=math.max(1,math.ceil(total/per_page))
    page=math.max(1,math.min(page or 1,max_page))
    local first=(page-1)*per_page+1
    local last=math.min(total,first+per_page-1)
    local lines={"§b━━ Ds 触发词 ━━","§7第 "..page.." / "..max_page.." 页"}
    for i=first,last do table.insert(lines,"§f"..(i-first+1)..". §e"..all[i]) end
    table.insert(lines,"§e操作：§f+ 下一页，- 上一页，.stop 退出。")
    local d,r=player_record(name,true)
    set_menu(d,r,"trigger_words",{trigger_page=page})
    send(name,table.concat(lines,"\n"))
    return true
end

function ai_help(name)
    local admin = is_admin(name)
    local text = "§b━━ Ds AI 功能 ━━\n" ..
        "§f• §eAI 内容§7：与AI正常聊天；§eai 内容§7：私聊AI。\n" ..
        "§f• §e指令 内容§7：进入独立的AI指令窗口，让AI理解并执行基岩版指令；§e./§7不是AI入口。\n" ..
        "§f• §e.记忆清除§7：立即清空AI记忆并切换新窗口，不经过AI。\n" ..
        "§f• AI可以理解自然语言，查询玩家/坐标/维度/标签/分数/在线玩家，必要时联网查询资料。\n" ..
        "§f• 普通聊天、指令、投票、兑换码等使用独立的AI窗口，互不混淆。\n" ..
        (admin and
            "§a• 你是管理权限：AI可查询在线玩家信息，并可根据请求实际执行Minecraft指令。\n" ..
            "§a• 管理权限还可使用封禁、解封、传送机会、兑换码等管理功能。\n"
        or
            "§7• 你是普通玩家：AI可以正常聊天、查询与你有关的游戏信息，并执行插件允许的玩家级操作。\n" ..
            "§7• 普通玩家不能通过AI执行管理权限专属的封禁、解封、权限管理等操作。\n") ..
        "§e提示：§f不需要执行操作时，AI就是普通聊天；需要操作时会直接调用插件能力。"
    send(name,text)
end

set_menu = function(d, record, mode, extra)
    record.menu = mode
    -- 同一次菜单流程沿用第一次打开时的截止时间；切换子菜单不刷新倒计时。
    if not record.menu_expires then record.menu_expires = util.timestamp() + MENU_TIMEOUT end
    if extra then for key, value in pairs(extra) do record[key] = value end end
    save_data(d)
end

clear_menu = function(d, record)
    record.menu = nil
    record.menu_expires = nil
    record.pending_slot = nil
    record.pending_target = nil
    record.pending_amount = nil
    save_data(d)
end

function coordinate_tp_state(record)
    local now=util.timestamp(); record.coordinate_tp=record.coordinate_tp or {}; local st=record.coordinate_tp
    if not st.first_join_at then st.first_join_at=now; st.first_grant_at=now+COORD_TP_FIRST_DELAY; st.available=false; st.granted_once=false end
    if not st.granted_once and now >= (st.first_grant_at or math.huge) then st.available=true; st.granted_once=true; st.next_refresh_at=now+COORD_TP_INTERVAL; st.notified_available=false end
    if st.granted_once and not st.available and now >= (st.next_refresh_at or math.huge) then st.available=true; st.next_refresh_at=now+COORD_TP_INTERVAL; st.notified_available=false end
    return st
end
function coordinate_tp_use(name, dimname, x,y,z)
    local d,r=player_record(name,true); local st=coordinate_tp_state(r); local admin=is_admin(name)
    if not admin and not st.available then
        local extra=tonumber(st.extra_uses) or 0
        if extra>0 then st.extra_uses=extra-1; st.using_extra=true else
            pcall(game.sendCommand,'playsound random.anvil_land "'..string.gsub(name,'"','\\"')..'"')
            send(name,st.granted_once and "§c你当前没有坐标传送次数。§e现实24小时后刷新一次。" or "§c你还没有坐标传送机会。§e累计在线2小时后获得第一次机会。")
            save_data(d); return true
        end
    end
    local dim=normalize_dimension(dimname); x=tonumber(x); y=tonumber(y); z=tonumber(z)
    if not dim or not x or not y or not z then send(name,"§c格式无效。请输入：主世界 114 100 114\n§7也支持：下界/地狱、末地。") return true end
    local safe=string.gsub(name,'"','\\"')
    local cmd=string.format('execute as @a[name="%s"] at @s in %s run tp @s %.2f %.2f %.2f',safe,dim_exec(dim),x,y,z)
    local ok,result=pcall(game.isCmdSuccess,cmd)
    if not ok or result~=true then send(name,"§c坐标传送指令执行失败，请检查维度和坐标。"); append_json_log(TELEPORT_LOG_FILE,{at=util.timestamp(),type="坐标传送失败",player=name,player_uuid=uuid_key(name),dimension=dim,x=x,y=y,z=z}); return true end
    if not admin and not st.using_extra then st.available=false; st.next_refresh_at=util.timestamp()+COORD_TP_INTERVAL; st.notified_available=false end
    local used_extra=st.using_extra==true; st.using_extra=false; save_data(d)
    append_json_log(TELEPORT_LOG_FILE,{at=util.timestamp(),type="坐标传送",player=name,player_uuid=uuid_key(name),dimension=dim,x=x,y=y,z=z,admin=admin,used_extra=used_extra,remaining_extra=tonumber(st.extra_uses) or 0,next_refresh_at=st.next_refresh_at})
    send(name,admin and "§a✓ 坐标传送成功。§7管理权限次数无限。" or "§a✓ 坐标传送成功。§7下一次机会将在现实24小时后刷新。")
    return true
end

function start_soul(name)
    local d,r=player_record(name,true)
    local loc,err=save_location(name)
    if not loc then send(name,"§c灵魂出窍失败："..tostring(err)); return true end
    local original_mode=detect_gamemode(name)
    local mode_ok=set_gamemode(name,"spectator")
    if not mode_ok then
        send(name,"§c灵魂出窍失败：无法切换到旁观模式，本次没有启动倒计时。")
        return true
    end
    r.soul={location=loc,original_mode=original_mode,return_at=util.timestamp()+SOUL_DURATION,last_bar=-1}
    save_data(d)
    send(name,"§d✦ 灵魂出窍已启动！\n§f已进入旁观模式，20秒后返回。\n§e中途退出：聊天框输入 .退出\n§7原游戏模式："..original_mode)
    pcall(game.sendActionbar,name,"§d灵魂出窍 §f剩余 §e20 §f秒")
    return true
end

function tick_coordinate_and_soul()
    local d=load_data(); local changed=false; local now=util.timestamp()
    local names=online_names_from_list()
    if type(names)~="table" then return end

    for _,name in ipairs(names) do
        if name then
            local key,pinfo=identity(name); local r=d.players[key]
            if not r then r={xuid=pinfo.xuid or '',unique_id=pinfo.unique_id or '',name=name,waypoints={},death=nil}; d.players[key]=r; changed=true end
            r.name=name
            r.xuid=trim(pinfo.xuid or r.xuid or '')
            r.unique_id=trim(pinfo.unique_id or r.unique_id or '')
            local pos_cache=player_position(name)
            if pos_cache and tonumber(pos_cache.x) and tonumber(pos_cache.y) and tonumber(pos_cache.z) then
                RUNTIME.last_pos[name]={x=tonumber(pos_cache.x),y=tonumber(pos_cache.y),z=tonumber(pos_cache.z),dimension=pos_cache.dimension}
            end
            local st=coordinate_tp_state(r)
            if st.available and not st.notified_available then
                send(name,[[§a✦ 你的坐标传送机会已刷新！§f输入 .tp 使用。
§7管理权限不受次数限制。]])
                st.notified_available=true; changed=true
            end
            r.signin=r.signin or {available=false}
            local last=RUNTIME.last_tick[name] or now; local delta=math.max(0,math.min(now-last,30)); RUNTIME.last_tick[name]=now
            r.playtime_seconds=(tonumber(r.playtime_seconds) or 0)+delta
            if not r.signin.first_ready_at and r.playtime_seconds>=7200 then
                r.signin.first_ready_at=now; r.signin.available=true; r.signin.next_at=now+DAILY_SIGNIN_INTERVAL
                send(name,"§6✦ 签到已解锁！§f输入 .签到 领取今日奖励。"); changed=true
            elseif r.signin.first_ready_at and not r.signin.available and now >= (r.signin.next_at or math.huge) then
                r.signin.available=true; r.signin.next_at=now+DAILY_SIGNIN_INTERVAL
                send(name,"§6✦ 今日签到已刷新！§f输入 .签到 领取奖励。"); changed=true
            end

            if r.soul and r.soul.return_at then
                local remain=r.soul.return_at-now
                local shown=math.ceil(remain)
                if shown<0 then shown=0 end
                if shown ~= (tonumber(r.soul.last_bar) or -1) and remain>0 then
                    pcall(game.sendActionbar,name,string.format("§d灵魂出窍 §f剩余 §e%d §f秒",shown))
                    r.soul.last_bar=shown; changed=true
                end
                if remain<=0 then
                    local loc=r.soul.location; local original=r.soul.original_mode or "survival"; r.soul=nil
                    pcall(game.sendActionbar,name,"§a灵魂出窍结束")
                    local ok2,err2=tp_to(name,loc)
                    local mode_ok=set_gamemode(name,original)
                    if ok2 and mode_ok then send(name,"§a✓ 灵魂出窍结束，已返回原位置并恢复原模式。")
                    elseif ok2 then send(name,"§e✓ 已返回原位置，但恢复原游戏模式失败，请手动切换回："..original)
                    else send(name,"§c灵魂出窍返回失败："..tostring(err2).."；原游戏模式恢复："..(mode_ok and "成功" or "失败")) end
                    changed=true
                end
            end
        end
    end
    if changed then save_data(d) end
end

function scoreboard_name()
    local cfg=file_load(SCOREBOARD_CONFIG_FILE,{})
    local board=trim(cfg.name or "")
    if board~="" then return board end
    local d=load_data(); return d.scoreboard_name
end

function valid_scoreboard_name(name)
    return type(name) == "string" and name:match("^[A-Za-z0-9_%-]+$") ~= nil and #name <= 32
end

function save_scoreboard_name(name,board)
    board=trim(board)
    local d=load_data(); d.scoreboard_name=board; d.scoreboard_set_by=name; d.scoreboard_set_at=util.now(); d.scoreboard_created=true; save_data(d)
    file_save(SCOREBOARD_CONFIG_FILE,{name=board,set_by=name,set_at=util.now()})
    pcall(game.isCmdSuccess,"scoreboard objectives add "..board.." dummy")
end

function show_tpa_targets(name)
    local names = online_players() or {}
    local filtered = {}
    for _, target in ipairs(names) do if target ~= name then table.insert(filtered, target) end end
    local d, r = player_record(name, true)
    set_menu(d, r, "tpa_target", {target_list = filtered})
    send(name, player_panel("§a====在线玩家列表====", filtered, "§7请输入编号选择传送目标，申请有效期 30 秒。"))
end

function show_transfer_targets(name)
    local board = scoreboard_name()
    if not board then
        send(name, "§e管理权限还没有设置积分计分板名称。")
        return
    end
    local d, r = player_record(name, true)
    local names = online_players() or {}
    local filtered = {}
    for _, target in ipairs(names) do if target ~= name then table.insert(filtered, target) end end
    set_menu(d, r, "transfer_target", {target_list = filtered})
    send(name, player_panel("§6====选择转账玩家====", filtered, "§7请输入编号选择玩家。"))
end

function show_report_targets(name)
    local d, r = player_record(name, true)
    local names = online_players() or {}
    local filtered = {}
    for _, target in ipairs(names) do if target ~= name then table.insert(filtered, target) end end
    set_menu(d, r, "report_target", {target_list = filtered})
    send(name, player_panel("§c====选择举报玩家====", filtered, "§7请输入编号选择要举报的玩家。"))
end

function send_tpa_queue(target, queue)
    if not queue or #queue == 0 then return end
    local lines = {"§6===传送申请队列==="}
    for i, item in ipairs(queue) do
        table.insert(lines, i .. ". " .. item.sender .. " 申请传送")
    end
    table.insert(lines, "§7输入 1 表示同意；输入 0 表示拒绝。申请有效期 30 秒。")
    send(target, table.concat(lines, "\n"))
end

function submit_tpa(sender, target)
    local d = load_tpa()
    local queue = d.queues[target] or {}
    local now = util.timestamp()

    -- Remove only expired/duplicate entries for this sender before adding one.
    local fresh = {}
    for _, item in ipairs(queue) do
        if (tonumber(item.expire) or 0) > now and item.sender ~= sender then table.insert(fresh, item) end
    end
    table.insert(fresh, {sender = sender, expire = now + TPA_TIMEOUT})
    d.queues[target] = fresh
    save_tpa(d)
    append_json_log(TELEPORT_LOG_FILE,{at=now,type="玩家传送申请",sender=sender,sender_uuid=uuid_key(sender),target=target,target_uuid=uuid_key(target),expire=now+TPA_TIMEOUT})

    send(sender, "§a传送申请已发送，等待 " .. target .. " 同意。")
    send_tpa_queue(target, fresh)
end

function clean_tpa()
    local d = load_tpa()
    local changed = false
    local now = util.timestamp()
    for target, queue in pairs(d.queues) do
        local fresh = {}
        for _, item in ipairs(queue) do
            if (tonumber(item.expire) or 0) > now then
                table.insert(fresh, item)
            else
                send(item.sender, "§c你的传送申请已超时。")
                changed = true
            end
        end
        if #fresh == 0 then d.queues[target] = nil else d.queues[target] = fresh end
    end
    if changed then save_tpa(d) end
end

function handle_agree_tpa(name,msg)
    local a=lower(trim(msg)); local accept=(a=="1"); local reject=(a=="0")
    if not accept and not reject then return false end
    local d=load_tpa(); local q=d.queues[name]
    if type(q)~='table' or not q[1] then return false end
    local item=q[1]; table.remove(q,1); if #q==0 then d.queues[name]=nil else d.queues[name]=q end; save_tpa(d)
    if (tonumber(item.expire) or 0)<=util.timestamp() then send(name,"§c这个传送申请已超时。"); return true end
    local sender=tostring(item.sender or '')
    if reject then append_json_log(TELEPORT_LOG_FILE,{at=util.timestamp(),type="玩家传送申请拒绝",sender=sender,sender_uuid=uuid_key(sender),target=name,target_uuid=uuid_key(name)}); send(name,"§e已拒绝 "..sender.." 的传送申请。"); send(sender,"§c"..name.." 拒绝了你的传送申请。"); return true end
    local safeSender=string.gsub(sender,'"','\\"'); local safeTarget=string.gsub(name,'"','\\"')
    pcall(game.sendCommand,'execute as @a[name="'..safeSender..'"] at @a[name="'..safeTarget..'"] run tp @s ~ ~ ~')
    append_json_log(TELEPORT_LOG_FILE,{at=util.timestamp(),type="玩家传送申请同意",sender=sender,sender_uuid=uuid_key(sender),target=name,target_uuid=uuid_key(name)})
    send(sender,"§a✓ "..name.." 已同意你的传送申请。"); send(name,"§a✓ 已同意 "..sender.." 的传送申请。"); return true
end

finish_report = nil

-- 审查证据：从 runtime.log 提取最近聊天记录，让 AI 能看到举报对象及其上下文发言。
function report_runtime_chat_context(target)
    pcall(flush_log_buffer)
    local ok,content=pcall(util.read_file,LOG_FILE)
    if not ok or type(content)~="string" or content=="" then return "runtime.log：暂无可读取日志。" end
    local lines={}
    for line in content:gmatch("[^\\r\\n]+") do
        if line:find("%[CHAT%]",1,true) then lines[#lines+1]=line end
    end
    local max_lines=120
    local start=math.max(1,#lines-max_lines+1)
    local recent={}
    for i=start,#lines do recent[#recent+1]=lines[i] end
    if #recent==0 then return "runtime.log：最近没有 CHAT 日志。" end
    -- 举报审核还要跨越整个 runtime.log 搜索目标玩家的历史发言，避免长期辱骂/挑衅等行为被最近120条之外的日志覆盖掉。
    local target_hits={}
    for _,line in ipairs(lines) do
        if line:find(tostring(target),1,true) then target_hits[#target_hits+1]=line end
    end
    if #target_hits>200 then
        local tmp={}
        for i=#target_hits-199,#target_hits do tmp[#tmp+1]=target_hits[i] end
        target_hits=tmp
    end
    local out={"runtime.log 最近聊天记录（最近最多120条）：",table.concat(recent,"\\n")}
    if #target_hits>0 then
        out[#out+1]="\\n被举报玩家 "..tostring(target).." 的历史相关发言（最多200条）："
        out[#out+1]=table.concat(target_hits,"\\n")
    end
    local text=table.concat(out,"\\n")
    if #text>18000 then text=text:sub(-18000) end
    return text
end

function report_count(report)
    local n=0
    for _ in pairs((report and report.reporters) or {}) do n=n+1 end
    return n
end

function begin_report_review(target)
    local d=load_data(); d.reports=d.reports or {}
    local report=d.reports[target]
    if not report then return false end
    report.explain_deadline=util.timestamp()+REPORT_REASON_TIMEOUT
    report.review_started_at=util.timestamp()
    d.reports[target]=report
    local tkey=identity(target)
    local tr=d.players[tkey]
    if type(tr)~="table" then
        tr={name=target,waypoints={},death=nil}
        d.players[tkey]=tr
    end
    tr.menu="report_explain"
    tr.menu_expires=report.explain_deadline
    tr.report_target=target
    save_data(d)
    local count=report_count(report)
    send(target,"§c你已进入举报审查阶段。\n§7当前举报进度：§e"..count.."/5\n§f请在 §e3分钟 §f内说明情况。\n§e解释触发方式：聊天框输入 §f.解释 你的解释内容\n§7例如：§f.解释 当时我是正常使用服务器功能。\n§c逾期未解释将直接交由AI判定并可能执行封禁。\n§7处罚会根据历史次数和本次AI判定决定时长。")
    return true
end

function submit_report_reason(reporter,target,reason)
    local d=load_data(); d.reports=d.reports or {}; d.report_history=d.report_history or {}
    local report=d.reports[target] or {reporters={},reasons={},created_at=util.timestamp()}
    report.reporters=report.reporters or {}; report.reasons=report.reasons or {}
    report.reporters[reporter]=true; report.reasons[reporter]=reason
    local count=report_count(report)
    d.reports[target]=report
    table.insert(d.report_history,{reporter=reporter,target=target,reason=reason,at=util.timestamp()})
    save_data(d)
    send(reporter,"§c举报对象：§f"..target.."\n§7你的举报进度：§e"..count.."/5\n§7理由：§f"..reason.."\n§b后续将由AI审查。")
    send(target,"§c你已被举报\n§7举报人：§f"..reporter.."\n§7理由：§f"..reason.."\n§7当前举报进度：§e"..count.."/5\n§b达到审查条件后将由AI审查。")
    if count>=5 or is_admin(reporter) then begin_report_review(target) end
    return count
end

finish_report = function(target, explanation, timed_out)
    local d=load_data(); local report=d.reports and d.reports[target]
    if not report then return end
    if not timed_out and not explanation then return end

    local reasons={}
    for reporter,reason in pairs(report.reasons or {}) do
        table.insert(reasons,reporter..":"..reason)
    end
    local count=report_count(report)
    local previous=0
    for _,h in ipairs(d.report_history or {}) do
        if h.target==target and h.judgment then previous=previous+1 end
    end

    -- 3分钟未解释：按服务器规则直接视为本次作弊举报成立，不再等待 AI 重新裁决。
    if timed_out then
        local previous=0
        for _,h in ipairs(d.report_history or {}) do
            if h.target==target and h.judgment then previous=previous+1 end
        end
        table.insert(d.report_history,{target=target,count=count,judgment="TIMEOUT_YES",at=util.timestamp(),previous=previous,reason="3分钟内未解释，按规则自动认定成立"})
        d.reports[target]=nil
        save_data(d)
        local until_time=util.timestamp()+7200
        local fresh=load_data(); fresh.blacklist=fresh.blacklist or {}
        fresh.blacklist[target]={until_time=until_time,by="举报超时自动裁决",duration="2小时"}
        save_data(fresh)
        local safe=string.gsub(target,'"','\\"')
        pcall(game.sendCommand,'kick "'..safe..'" §c举报审查超时，3分钟内未解释，按规则认定作弊成立，已封禁2小时。')
        send(target,"§c[举报审查] 你在3分钟内未提交解释，本次举报按规则认定作弊成立。\\n§7本次处罚：§e封禁2小时。")
        broadcast("§c[举报审查] §f"..target.." §7超过3分钟未解释，本次举报按规则认定成立，已封禁2小时。")
        return
    end

    local prompt=[[你是 Minecraft 基岩版网易服务器的举报审查 AI。
你只能根据提供的举报理由、多人举报情况、被举报玩家解释和历史已确认处罚记录进行客观判断。

重要规则：
1. 被举报玩家说“我没有”“不知道”“不清楚”“不是我”等，只能视为【没有提供实质性解释】，绝对不能单独作为无罪证据。
2. 不得把“无法证明无罪”错误地转换成“举报无效”；应分别评估举报方提供的事实与被举报方的解释。
3. 单个举报人的主观指控也不能单独证明有罪。
4. 多名玩家分别提交、且内容相互独立并指向同一具体行为时，应显著提高可信度；如果多人的理由只是完全相同的复制文本，则降低独立性权重。
5. 重点判断举报理由是否具体、是否互相印证、是否存在明显矛盾、以及被举报方是否提出可验证的反证。
6. 如果被举报方只回答“我不知道”，但已有多名独立举报人提供一致且具体的事实，不得因此判定举报无效；应继续依据举报证据判断。
7. 如果举报理由过于空泛、互相矛盾、明显是恶意重复举报，且没有其他支持事实，才应判定证据不足。
8. 证据不足时不要处罚；但“被举报人没有有效解释”本身不是推翻举报证据的理由。
9. 不要因为举报人数多就机械认定成立，也不要因为被举报人解释很短就机械认定无罪。
10. 只判断本次举报是否成立，不自行决定处罚时长。
11. 最终只能输出一行：YES 或 NO。

被举报玩家：]]..target..[[
当前举报人数：]]..count..[[/5
历史已确认处罚次数：]]..previous..[[
举报理由：]]..table.concat(reasons," | ")..[[
被举报玩家解释：]]..tostring(explanation or "3分钟内未提交解释")..[[

【runtime.log 证据（系统在举报审查开始时自动读取，不是玩家工具）】
]]..report_runtime_chat_context(target)..[[

解释判定提示：如果解释仅为“我不知道/不知道/不清楚/没有”等，应视为未提供有效反证，不得仅凭这句话判定举报无效。]]

    local ok,judgment=pcall(call_ai,{{role="system",content="你是严格、证据导向的服务器举报审查AI。最终只允许输出 YES 或 NO。"},{role="user",content=prompt}})
    local result=ok and trim(judgment or "") or ""
    local decision=string.upper(result)
    local is_yes=(decision:match("^%s*YES%s*$") ~= nil)

    if not ok or result=="" or (not is_yes and decision:match("^%s*NO%s*$")==nil) then
        is_yes=false
        result="NO"
    end

    local audit_reason=is_yes and "AI审查认定举报成立" or "AI审查认定证据不足，举报无效"
    table.insert(d.report_history,{target=target,count=count,judgment=result,at=util.timestamp(),previous=previous})
    d.reports[target]=nil
    save_data(d)

    if is_yes then
        local until_time=util.timestamp()+7200
        local fresh=load_data(); fresh.blacklist=fresh.blacklist or {}
        fresh.blacklist[target]={until_time=until_time,by="AI审查",duration="2小时"}
        save_data(fresh)
        local safe=string.gsub(target,'"','\\"')
        pcall(game.sendCommand,'kick "'..safe..'" §c举报审查成立，已封禁2小时。')
        send(target,"§c[举报审查] AI判定：举报成立。\n§7本次处罚：§e封禁2小时。")
        broadcast("§c[举报审查] §f"..target.." §7AI判定举报成立，已加入2小时黑名单。")
    else
        send(target,"§a[举报审查] AI判定：举报无效。")
        broadcast("§a[举报审查] §f"..target.." §7本次举报无效。")
    end
end

function withdraw_report(name)
    local d = load_data()
    local removed = 0
    for target, report in pairs(d.reports or {}) do
        if type(report) == "table" and type(report.reporters) == "table" and report.reporters[name] then
            report.reporters[name] = nil
            if type(report.reasons) == "table" then report.reasons[name] = nil end
            removed = removed + 1
            if report_count(report) == 0 then d.reports[target] = nil end
        end
    end
    if removed > 0 then save_data(d) end
    return removed
end

function handle_report_menu(name, msg, d, r)
    if r.menu == "report_target" then
        local index = tonumber(msg)
        local target = index and r.target_list and r.target_list[index]
        if not target then send(name, "§c编号不存在，菜单已退出。") clear_menu(d, r) return true end
        local report = d.reports[target] or {reporters = {}, reasons = {}}
        if report.reporters[name] then send(name, "§c你已经举报过这个玩家。") clear_menu(d, r) return true end
        report.reporters[name] = true
        d.reports[target] = report
        clear_menu(d, r)
        set_menu(d, r, "report_reason", {report_target = target})
        save_data(d)
        send(name, "§e请直接输入举报原因，例如：刷物品、科技、客户端查人、恶意辱骂。\n§7输入 .stop 或 退出可离开举报菜单。")
        return true
    elseif r.menu == "report_reason" then
        local reason = trim(msg)
        if reason == "" then send(name, "§c举报原因不能为空。") return true end
        if reason == "撤销" or reason == "撤回" then
            local target = r.report_target
            clear_menu(d, r)
            withdraw_report(name)
            send(name, "§a已撤销你对 " .. tostring(target) .. " 的举报。")
            return true
        end
        local target = r.report_target
        clear_menu(d, r)
        local count = submit_report_reason(name, target, reason)
        send(name, "§a举报原因已提交，当前举报进度：" .. count .. "/5。\n§7后续将由AI审查；需要撤回可输入 .撤销举报。")
        return true
    elseif r.menu == "report_explain" then
        local target = r.report_target
        local explanation = trim(msg:match("^%.解释%s+(.+)$") or "")
        if explanation == "" then
            send(name, "§e请使用：§f.解释 你的解释内容\n§7例如：§f.解释 当时我是正常使用服务器功能。")
            return true
        end
        clear_menu(d, r)
        send(name, "§e解释已提交，正在审核。")
        finish_report(target, explanation, false)
        return true
    end
    return false
end

function handle_transfer_menu(name, msg, d, r)
    local board = scoreboard_name()
    if r.menu == "transfer_target" then
        local index = tonumber(msg)
        local target = index and r.target_list and r.target_list[index]
        if not target then send(name, "§c编号不存在，请重新输入 .help。") clear_menu(d, r) return true end
        set_menu(d, r, "transfer_amount", {pending_target = target})
        send(name, "§e请输入转账数量，只能输入阿拉伯数字，不要输入空格。")
        return true
    elseif r.menu == "transfer_amount" then
        local amount = extract_digits(msg)
        if not amount or amount <= 0 then send(name, "§c请输入有效的正整数，不要输入空格。") return true end
        set_menu(d, r, "transfer_confirm", {pending_amount = amount})
        send(name, "§e确定向 " .. r.pending_target .. " 转账 " .. amount .. " 吗？请输入 Y、确定、Yes，或 No、否、不、算了。")
        return true
    elseif r.menu == "transfer_confirm" then
        local answer = lower(trim(msg))
        local yes = answer == "y" or answer == "yes" or answer == "确定"
        local no = answer == "no" or answer == "否" or answer == "不" or answer == "算了"
        if not yes and not no then return true end
        if no then clear_menu(d, r) send(name, "§e已取消转账。") return true end
        local amount, target = r.pending_amount, r.pending_target
        local ok, balance = pcall(game.getScore, board, name)
        balance = ok and tonumber(balance) or 0
        if not ok then clear_menu(d,r); send(name,"§c无法读取你的金币余额，转账未执行。") return true end
        if balance < amount then clear_menu(d, r); send(name, "§c余额不足，转账未执行。") return true end
        local target_ok = pcall(game.getScore, board, target)
        if not target_ok then
            local init_ok=pcall(game.isCmdSuccess,"scoreboard players set "..target.." "..board.." 0")
            if not init_ok then clear_menu(d,r); send(name,"§c无法初始化收款玩家的金币，转账未执行。") return true end
        end
        local remove_ok,remove_result=pcall(game.isCmdSuccess, "scoreboard players remove " .. name .. " " .. board .. " " .. amount)
        if not remove_ok or remove_result~=true then clear_menu(d,r); send(name,"§c扣款失败，转账未执行。") return true end
        local add_ok,add_result=pcall(game.isCmdSuccess, "scoreboard players add " .. target .. " " .. board .. " " .. amount)
        if not add_ok or add_result~=true then
            pcall(game.isCmdSuccess,"scoreboard players add "..name.." "..board.." "..amount)
            clear_menu(d,r); send(name,"§c收款失败，已尝试退回金币；转账未完成。") return true
        end
        clear_menu(d, r)
        send(name, "§a已成功向 " .. target .. " 转账 " .. amount .. "。")
        send(target, "§a你收到来自 " .. name .. " 的转账：" .. amount .. "。")
        return true
    end
    return false
end

function enforce_blacklist(name)
    local d = load_data()
    local item = d.blacklist[name]
    if not item then return false end
    if item.until_time == -1 or (item.until_time or 0) > util.timestamp() then
        local duration = item.until_time == -1 and "永久" or "临时"
        local safe=string.gsub(name,'"','\\"')
        pcall(game.isCmdSuccess, 'kick "'..safe..'" 举报审核：' .. duration .. '处理。如有异议，请联系管理权限申诉。')
        return true
    end
    d.blacklist[name] = nil
    save_data(d)
    return false
end

function expire_system_state()
    local now = util.timestamp()
    clean_tpa()
    local d = load_data()
    local changed = false
    for _, record in pairs(d.players) do
        if record.menu and record.menu_expires and now >= record.menu_expires then
            local name = record.name
            record.menu = nil
            record.menu_expires = nil
            record.pending_slot = nil
            record.pending_target = nil
            record.pending_amount = nil
            if name then send(name, "§e菜单已超时，自动退出。") end
            changed = true
        end
    end
    for target, report in pairs(d.reports) do
        if report.explain_deadline and now >= report.explain_deadline then
            finish_report(target, nil, true)
            changed = true
        end
    end
    if type(d.market_pending_purchase)=="table" and now-(tonumber(d.market_pending_purchase.started_at) or now)>15 then
        local p=d.market_pending_purchase; pcall(game.isCmdSuccess,string.format('setblock %d %d %d air',math.floor(p.x),math.floor(p.y),math.floor(p.z))); d.market_pending_purchase=nil; d.market_busy=false; changed=true
        if p.name then send(p.name,"§c商品处理超时，购买已取消，未扣款。") end
    end
    -- 直接遍历「当前游戏名 → 会话」表。
    -- 旧版按 players 的身份键去查会话，基本永远查不到，等于每个玩家每轮白跑一次查询。
    d.server_sell_sessions=d.server_sell_sessions or {}
    for pname,ss in pairs(d.server_sell_sessions) do
        if type(ss)=="table" and util.timestamp()>=(tonumber(ss.expires_at) or ((tonumber(ss.created_at) or util.timestamp())+180)) then
            local p=ss.barrel_pos
            if type(p)=="table" then
                local x,y,z=math.floor(p.x),math.floor(p.y),math.floor(p.z)
                local ry=y-1
                pcall(game.isCmdSuccess,string.format('setblock %d %d %d air replace',x,ry,z))
                server_sell_cleanup_drops(x,ry,z)
            end
            server_sell_clear_session(d,pname)
            send(pname,"§e出售时间已超过3分钟，木桶已清除，本次出售结束。")
            changed=true
        end
    end
    d.market_sessions=d.market_sessions or {}
    for name,sess in pairs(d.market_sessions) do
        if type(sess)=="table" and util.timestamp()-(tonumber(sess.created_at) or 0)>180 then
            local p=sess.barrel_pos
            if p then pcall(game.isCmdSuccess,'setblock '..math.floor(p.x)..' '..(math.floor(p.y)-1)..' '..math.floor(p.z)..' air'); market_clear_barrel_drop(name,p.x,p.y-1,p.z) end
            d.market_sessions[name]=nil
            local pd,pr=player_record(name,true); if pr.menu=="market_sell_wait" then clear_menu(pd,pr) end
            send(name,"§e商品上架超时，木桶已清除，本次上架取消。")
            changed=true
        end
    end
    for name, item in pairs(d.blacklist) do
        if item.until_time and item.until_time > 0 and now >= item.until_time then
            d.blacklist[name] = nil
            changed = true
        end
    end
    if changed then save_data(d) end
end

SIGNIN_REWARDS={
    {cmd="give @s bread 6",text="面包 ×6",flavor="今天先把肚子照顾好，再去冒险。"},
    {cmd="give @s torch 12",text="火把 ×12",flavor="给黑暗留一盏灯，今晚的路会更亮。"},
    {cmd="give @s iron_ingot 3",text="铁锭 ×3",flavor="一点点铁，刚好够你把计划推进一步。"},
    {cmd="give @s cooked_beef 5",text="熟牛肉 ×5",flavor="补充体力，别让冒险家饿着回家。"},
    {cmd="give @s experience_bottle 2",text="经验瓶 ×2",flavor="小小经验，不喧宾夺主，但总有用。"},
    {cmd="give @s golden_carrot 2",text="金胡萝卜 ×2",flavor="今天运气不错，给你两根闪闪发光的胡萝卜。"}
}
function signin(name)
    local d,r=player_record(name,true); r.signin=r.signin or {available=false}
    if not r.signin.available then send(name,"§e今天还不能签到。§7累计在线满120分钟后解锁；之后每现实24小时刷新一次。") return true end
    local reward=SIGNIN_REWARDS[choose_signin_reward() or 1]
    pcall(game.sendCommand,reward.cmd)
    r.signin.available=false; r.signin.last_claim_at=util.timestamp(); r.signin.next_at=util.timestamp()+DAILY_SIGNIN_INTERVAL; save_data(d)
    send(name,"§6✦ 今日签到成功！\n§f获得：§e"..reward.text.."\n§7"..reward.flavor.."\n§7下一次签到：现实24小时后。")
    return true
end

BAN_DURATIONS={{label="10分钟",seconds=600},{label="20分钟",seconds=1200},{label="30分钟",seconds=1800},{label="1小时",seconds=3600},{label="2小时",seconds=7200},{label="5小时",seconds=18000},{label="8小时",seconds=28800},{label="12小时",seconds=43200},{label="24小时",seconds=86400},{label="1星期",seconds=604800},{label="1个月",seconds=2592000},{label="永久",seconds=-1}}
function show_ban_menu(name)
    if not is_admin(name) then send(name,"§c无法使用：封禁菜单仅管理权限可用。") return true end
    local names=online_players() or {}; local filtered={}; for _,n in ipairs(names) do if n~=name then table.insert(filtered,n) end end
    local d,r=player_record(name,true); set_menu(d,r,"ban_target",{target_list=filtered})
    send(name,player_panel("§c━━ 封禁玩家 ━━",filtered,"§7请输入编号选择玩家。")); return true
end
function show_unban_menu(name,page)
    if not is_admin(name) then send(name,"§c无法使用：解除封禁仅管理权限可用。") return true end
    local data=load_data(); local now=util.timestamp(); local changed=false; local names={}
    for target,item in pairs(data.blacklist or {}) do
        if item.until_time and item.until_time>0 and now>=item.until_time then
            data.blacklist[target]=nil; changed=true
        else
            table.insert(names,target)
        end
    end
    if changed then save_data(data) end
    table.sort(names)
    local max_page=math.max(1,math.ceil(#names/10)); page=math.max(1,math.min(page or 1,max_page))
    local first=(page-1)*10+1; local last=math.min(#names,first+9)
    if #names==0 then
        local d,r=player_record(name,true); clear_menu(d,r); send(name,"§e当前封禁名单为空。") return true
    end
    local list={}; for i=first,last do table.insert(list,names[i]) end
    local d,r=player_record(name,true); set_menu(d,r,"unban_target",{target_list=list,unban_page=page})
    local text=player_panel("§a━━ 解除封禁 ━━",list,"§7第 "..page.." / "..max_page.." 页；输入编号解除。")
    if max_page>1 then text=text.."\n§7输入 + 下一页，- 上一页。" end
    send(name,text); return true
end

function show_transfer_chances(name)
    if not is_admin(name) then send(name,"§c只有管理权限可以分配坐标传送次数。") return true end
    local names=online_players() or {}; local filtered={}; for _,n in ipairs(names) do if n~=name then table.insert(filtered,n) end end
    local d,r=player_record(name,true); set_menu(d,r,"coord_grant_target",{target_list=filtered})
    send(name,player_panel("§b━━ 分配坐标传送机会 ━━",filtered,"§7请输入编号选择玩家。")); return true
end
function show_permission_menu(name,mode)
    if name~=SUPERUSER then send(name,"§c只有最高权限账号可以使用权限管理。") return true end
    local names=online_players() or {}; local filtered={}
    for _,n in ipairs(names) do
        if mode=="grant" then if n~=name and not is_admin(n) then table.insert(filtered,n) end else if is_admin(n) then table.insert(filtered,n) end end
    end
    local d,r=player_record(name,true); set_menu(d,r,mode=="grant" and "grant_target" or "revoke_target",{target_list=filtered})
    send(name,player_panel(mode=="grant" and "§a━━ 添加管理权限 ━━" or "§e━━ 撤回管理权限 ━━",filtered,"§7请输入编号选择玩家。")); return true
end
function apply_ban(admin,target,index)
    local item=BAN_DURATIONS[index]; if not item then return false end
    local d=load_data(); d.blacklist=d.blacklist or {}
    d.blacklist[target]={until_time=item.seconds==-1 and -1 or util.timestamp()+item.seconds,by=admin,duration=item.label}
    save_data(d)
    local safe=string.gsub(target,'"','\\"')
    local ok,err=pcall(game.sendCommand,'kick "'..safe..'" §c你已被封禁：'..item.label..'。')
    local ad,ar=player_record(admin,true); clear_menu(ad,ar)
    if ok then
        send(admin,"§a✓ 已封禁 "..target.."，时长："..item.label.."。\n§7封禁菜单已自动关闭。")
    else
        send(admin,"§a✓ 已记录 "..target.." 的封禁，时长："..item.label.."。\n§e当前踢出失败，但他下次进入服务器仍会自动被踢出。")
    end
    return true
end

function handle_menu(name, msg)
    local d, r = player_record(name, true)
    local mode = r.menu
    if not mode then return false end

    msg = trim(msg)
    local low = lower(msg)

    -- .stop 优先于菜单超时检查：即使菜单显示已经超时，仍必须能够终止并清理未完成的出售状态。
    if msg == ".stop" or low == "stop" or msg == "停止" or msg == "退出" then
        local report_menu = mode == "report_target" or mode == "report_reason"
        local had_server_sell = type(server_sell_get_session(d,name))=="table" or type(d.server_sell_pending)=="table"
        if had_server_sell then
            cancel_server_sell_state(name,"§e已终止出售流程，待处理木桶已清除。")
            -- cancel_server_sell_state 已清理菜单与数据，不再执行 clear_menu 覆盖。
            if report_menu then withdraw_report(name) end
            return true
        end
        clear_menu(d, r)
        if report_menu then
            withdraw_report(name)
            send(name, "§e已退出举报菜单，本次举报已撤销。")
        else
            send(name, "§e已结束菜单。")
        end
        return true
    end

    if r.menu_expires and util.timestamp() >= r.menu_expires then
        -- 服务器收购流程的真实截止时间由木桶放置时间计算。
        if mode=="server_sell_wait" or mode=="server_sell_list" then
            if type(server_sell_get_session(d,name))=="table" then
                cancel_server_sell_state(name,"§e出售时间已超过3分钟，木桶已清除，本次出售结束。")
            elseif type(d.server_sell_pending)=="table" then
                d.server_sell_pending=nil
                clear_menu(d,r)
                send(name,"§e出售确认等待已超时，本次流程已结束。")
            else
                clear_menu(d,r)
                send(name,"§e菜单已超时，自动退出。")
            end
            return true
        end
        clear_menu(d, r)
        send(name, "§e菜单已超时，自动退出。")
        return true
    end

    if mode == "help" then
        if not msg:match("^%d+$") then
            send(name, "§c请输入 1~15 选择功能。")
            return true
        end
        local n = tonumber(msg)
        if n < 1 or n > 15 then send(name,"§c数字无效！请输入 1~15。"); return true end

        if n == 1 then
            slot_menu(name, "save_slot")
        elseif n == 2 then
            slot_menu(name, "return_slot")
        elseif n == 3 then
            r.menu = nil
            save_data(d)
            if not r.death then
                send(name, "§c你还没有记录到死亡点。")
            else
                local ok, err = tp_to(name, r.death)
                send(name, ok and "§a✓ 已返回死亡点。" or "§c返回死亡点失败：" .. tostring(err))
            end
        elseif n == 4 then
            slot_menu(name, "delete_slot")
        elseif n == 5 then
            show_tpa_targets(name)
        elseif n == 6 then
            show_transfer_targets(name)
        elseif n == 7 then
            show_report_targets(name)
        elseif n == 8 then
            clear_menu(d,r)
            local st=coordinate_tp_state(r)
            if is_admin(name) then
                r.menu="coord_tp_input"; r.menu_expires=util.timestamp()+MENU_TIMEOUT; save_data(d)
                send(name,"§b━━ 选坐标传送 ━━\n§a管理权限：次数无限。\n§f请在聊天框输入：维度 X Y Z\n§7例如：主世界 114 100 114")
            elseif st.available or (tonumber(st.extra_uses) or 0)>0 then
                r.menu="coord_tp_input"; r.menu_expires=util.timestamp()+MENU_TIMEOUT; save_data(d)
                send(name,"§b━━ 选坐标传送 ━━\n§a✓ 你有可用次数。\n§f请在聊天框输入：维度 X Y Z\n§7例如：主世界 114 100 114")
            else
                pcall(game.sendCommand,'playsound random.anvil_land "'..string.gsub(name,'"','\\"')..'"')
                send(name,"§c你没有坐标传送次数。\n§7每天现实24小时刷新一次；新玩家累计在线2小时后获得第一次机会。")
            end
        elseif n == 9 then
            clear_menu(d,r); start_soul(name)
        elseif n == 10 then
            show_ban_menu(name)
        elseif n == 11 then
            show_unban_menu(name)
        elseif n == 12 then
            show_player_market_main(name)
        elseif n == 13 then
            show_territory(name)
        elseif n == 14 then
            show_market_14(name)
        elseif n == 15 then
            show_gameplay_categories(name)
        end
        return true
    end

    if mode == "market14_main" then
        if msg=="1" then fixed_shop_show(name,1); return true end
        if msg=="2" then return show_sell_price_list(name,1) end
        if msg=="3" then return full_shop_buy_main(name) end
        send(name,"§c请输入1/2/3选择。"); return true
    end

    if mode == "full_shop_buy_main" then
        if msg=="1" then return full_shop_search_prompt(name) end
        if msg=="2" then return full_shop_show_list(name,1) end
        send(name,"§c请输入1商品搜索或2商品选择。"); return true
    end

    if mode == "full_shop_list" then
        if msg=="+" then return full_shop_show_list(name,(r.full_shop_page or 1)+1) end
        if msg=="-" then return full_shop_show_list(name,(r.full_shop_page or 1)-1) end
        local n=tonumber(msg)
        local item=n and r.full_shop_list and r.full_shop_list[n]
        if not item then send(name,"§c编号无效，请输入当前页1~10的编号。"); return true end
        return full_shop_payment(name,item)
    end

    if mode == "full_shop_search" then
        if msg==".stop" or low=="stop" or msg=="退出" then clear_menu(d,r); send(name,"§e已退出商品搜索。"); return true end
        local hits=full_shop_find(msg, name)
        if #hits==0 then send(name,"§c没有找到匹配的物品，请输入真实ID或中文/英文名称。"); return true end
        if #hits==1 then return full_shop_payment(name,hits[1]) end
        local lines={"§b━━ 搜索结果 ━━","§7找到 "..#hits.." 个匹配物品，请输入编号："}
        local shown={}
        for i,v in ipairs(hits) do
            if i<=13 then shown[i]=v; lines[#lines+1]=string.format("§f%d. §e%s §7| §6%s积分 §7| §b%s",i,v.name,v.price,v.id) end
        end
        if #hits>13 then lines[#lines+1]="§7结果过多，仅显示前13项。" end
        set_menu(d,r,"full_shop_search_results",{full_shop_search_list=shown})
        send(name,table.concat(lines,"\\n"))
        return true
    end

    if mode == "full_shop_search_results" then
        local n=tonumber(msg); local item=n and r.full_shop_search_list and r.full_shop_search_list[n]
        if not item then send(name,"§c编号无效，请输入搜索结果编号。"); return true end
        return full_shop_payment(name,item)
    end

    if mode == "full_shop_payment" then
        if msg=="1" then return full_shop_begin_quantity(name,r.full_shop_item) end
        if msg=="0" then clear_menu(d,r); send(name,"§e已取消支付，菜单已关闭。"); return true end
        send(name,"§e输入1表示同意支付，0表示不同意并关闭菜单。"); return true
    end

    if mode == "full_shop_quantity" then
        local qty=tonumber(msg)
        if not qty or qty%1~=0 or qty<1 or qty>2500 then send(name,"§c购买数量必须是1 ~ 2500的整数。"); return true end
        return full_shop_execute(name,r.full_shop_item,qty)
    end
    if mode == "market_preview" then
        if msg=="+" then show_market_v2(name,(r.market_page or 1)+1); return true end
        if msg=="-" then show_market_v2(name,(r.market_page or 1)-1); return true end
        if msg=="1" then return market_claim(name,r.market_preview_id) end
        if msg=="0" then show_market_v2(name,r.market_page or 1); return true end
        send(name,"§e1 = 同意购买；0 = 不同意/返回上一页；+ 下一页；- 上一页；.stop 退出。"); return true
    end
    if mode == "server_sell_list" then
        if msg=="+" then return show_sell_price_list(name,(r.sell_page or 1)+1) end
        if msg=="-" then return show_sell_price_list(name,(r.sell_page or 1)-1) end
        if msg=="1" then
            return server_sell_begin(name)
        end
        if msg=="0" then
            clear_menu(d,r)
            send(name,"§e已退出玩家收购价目表。")
            save_data(d)
            return true
        end
        send(name,"§e输入 1 开始出售，+/- 翻页，0 退出。")
        return true
    end
    if mode == "server_sell_wait" then
        if msg=="1" then return market_finish_server_sell(name) end
        if msg=="0" then return cancel_server_sell_state(name,"§e已取消出售，本次未结算积分。") end
        send(name,"§e请输入 1 确认出售并计算积分，或输入 0 取消出售。")
        return true
    end
    if mode == "market_main" then
        local n=tonumber(msg); if n==1 then market_sell_begin(name); elseif n==2 then show_market(name,1); elseif n==3 then show_market(name,1); local md,mr=player_record(name,true); set_menu(md,mr,"market_report",{market_page=1,market_list=mr.market_list}); elseif n==4 then if not is_admin(name) then send(name,"§c权限不够。"); else set_menu(d,r,"market_admin_shops"); local db=market_db(); local seen={}; local lines={"§b━━ 封禁商店 ━━"}; for _,v in pairs(db.listings or {}) do if not seen[v.seller_uuid] then seen[v.seller_uuid]=true; table.insert(lines,tostring(#lines)..". "..v.seller) end end; send(name,table.concat(lines,"\n")); end elseif n==5 then show_shop_logs(name); elseif n==6 then show_shop_management(name); elseif n==7 then show_sellers(name,1); else send(name,"§c请输入1~7。") end; return true
    end
    if mode == "market_sell_price" then
        local n=tonumber(msg); if not n or n<1 or n%1~=0 then send(name,"§c价格必须是正整数。"); return true end; r.market_session_price=n; set_menu(d,r,"market_sell_name"); send(name,"§e请输入商品名称（支持中文、字母、数字等）："); return true
    end
    if mode == "market_sell_name" then
        local nm=trim(msg); if nm=="" then send(name,"§c名称不能为空。"); return true end; if #nm>80 then send(name,"§c名称太长。"); return true end; local pos=player_position(name); if not pos then send(name,"§c无法读取当前位置。"); return true end; if market_busy(d) then send(name,"§e机器人正在忙碌中，请稍后再试。"); return true end; set_market_busy(true); local bx,by,bz=math.floor(pos.x),math.floor(pos.y),math.floor(pos.z); local ok,res=pcall(game.isCmdSuccess,'execute as @a[name="'..string.gsub(name,'"','\\"')..'"] at @s run setblock ~ ~ ~ barrel'); set_market_busy(false); if not ok or res~=true then send(name,"§c无法放置商品木桶。"); return true end; local id=(market_db().next_id or 1); d.market_sessions=d.market_sessions or {}; d.market_sessions[name]={id=id,name=nm,price=r.market_session_price,barrel_pos={x=bx,y=by,z=bz},created_at=util.timestamp()}; set_menu(d,r,"market_sell_wait",{}); save_data(d); send(name,"§a木桶已放置。请把要出售的物品放入木桶。\n§e放好后输入：确定商品\n§7你有3分钟完成；超时自动取消。") ; send(name,"§7[私信] 商品收取流程已开始，请勿移动木桶；确认后机器人会读取刚才记录的木桶位置，并直接检测脚下一格的木桶。") ; return true
    end
    if mode == "market_sell_wait" then local a=lower(msg); if a=="确定商品" or a=="确认商品" then return market_finish_sell(name) end; send(name,"§e请把物品放入木桶后输入：确定商品"); return true end
    if mode == "market_buy" then if msg=="+" then show_market(name,(r.market_page or 1)+1); return true elseif msg=="-" then show_market(name,(r.market_page or 1)-1); return true end; local n=tonumber(msg); local first=((r.market_page or 1)-1)*12+1; local idx=n and (n-first+1); local v=idx and r.market_list and r.market_list[idx]; if not v then send(name,"§c编号无效，请输入当前页显示的商品编号。"); return true end; return market_show_preview(name,v.id) end
    if mode == "market_buy_confirm" then if msg=="1" then return market_execute_purchase(name,r.market_buy_id,r.market_buy_price,r.market_buy_discount,r.market_buy_vip_title) elseif msg=="0" then clear_menu(d,r); send(name,"§e已取消支付。"); return true else send(name,"§e输入1确认，0拒绝。"); return true end end
    if mode == "market_report" then
        if msg=="+" or msg=="-" then local p=(r.market_page or 1)+(msg=="+" and 1 or -1); show_market(name,p); local md,mr=player_record(name,true); set_menu(md,mr,"market_report",{market_page=p,market_list=mr.market_list}); return true end
        local n=tonumber(msg); local first=((r.market_page or 1)-1)*12+1; local idx=n and (n-first+1); local v=idx and r.market_list and r.market_list[idx]; if not v then send(name,"§c编号无效，请输入当前页显示的商品编号。"); return true end; local id=tostring(v.id); local db=market_db(); v=db.listings[id]; if not v then send(name,"§c商品不存在。"); return true end; db.reports[id]=db.reports[id] or {count=0,users={}}; local q=db.reports[id]; q.users=q.users or {}; if q.users[uuid_key(name)] then send(name,"§c你已经举报过该商品。"); return true end; q.users[uuid_key(name)]=true; q.count=(tonumber(q.count)or 0)+1; if q.count>=5 then v.disabled=true; end; db.listings[id]=v; market_save(db); clear_menu(d,r); local label=q.count==1 and "已标记" or q.count==2 and "商品可能不对" or q.count==3 and "可能虚假宣传" or q.count>=5 and "已下架" or "已进入重点关注"; send(name,"§a举报已记录："..label.."；商品编号："..id); return true end
    if mode == "market_manage" then local n=tonumber(msg); if n==1 then local d2,r2=player_record(name,true); set_menu(d2,r2,"market_price_list",{market_mine=r.market_mine}); send(name,"§e请选择要改价的商品编号："); return true elseif n==2 then set_menu(d,r,"market_vip_menu"); send(name,"§f1. 在线玩家当中获取\n§f2. 输入玩家完整名称"); return true elseif n==3 then set_menu(d,r,"market_delist_list",{market_mine=r.market_mine}); send(name,"§e请输入要下架的商品编号。"); return true end; send(name,"§c请输入1~3。"); return true end
    if mode == "market_price_list" then local n=tonumber(msg); local v=r.market_mine and r.market_mine[n]; if not v then send(name,"§c编号无效。"); return true end; set_menu(d,r,"market_price_edit",{market_edit_id=v.id}); send(name,"§e请输入新价格（正整数）："); return true end
    if mode == "market_price_edit" then local n=tonumber(msg); if not n or n<1 then send(name,"§c价格无效。"); return true end; local db=market_db(); local v=db.listings[tostring(r.market_edit_id)]; if not v then send(name,"§c商品不存在。"); return true end; v.price=n; db.listings[tostring(v.id)]=v; market_save(db); clear_menu(d,r); send(name,"§a价格已写入商品数据库："..n); return true end
    if mode == "market_delist_list" then local n=tonumber(msg); local v=r.market_mine and r.market_mine[n]; if not v then send(name,"§c编号无效。"); return true end; if market_busy(load_data()) then send(name,"§e机器人正在忙碌中，请稍后再试。"); return true end; set_market_busy(true); local pos=player_position(name); local b=string.format('%d %d %d',math.floor(pos.x),math.floor(pos.y),math.floor(pos.z)); pcall(game.isCmdSuccess,'setblock '..b..' barrel'); local ok=market_load_nbt_item(v.id,math.floor(pos.x),math.floor(pos.y),math.floor(pos.z)); if ok then pcall(game.isCmdSuccess,'setblock '..b..' air') end; set_market_busy(false); local db=market_db(); db.listings[tostring(v.id)]=nil; market_save(db); market_delete_nbt_item(v.id); clear_menu(d,r); send(name,"§a商品已下架并从商品数据库移除。") ; return true end
    if mode == "market_vip_menu" then if msg=="1" then local names=online_players() or {}; local d2,r2=player_record(name,true); set_menu(d2,r2,"market_vip_player",{vip_candidates=names}); local lines={"§b在线玩家："}; for i,nm in ipairs(names) do if nm~=name then table.insert(lines,i..". "..nm) end end; send(name,table.concat(lines,"\n")); return true elseif msg=="2" then set_menu(d,r,"market_vip_name"); send(name,"§e请输入玩家完整名称："); return true end; send(name,"§c请输入1或2。"); return true end
    if mode == "market_vip_player" then local n=tonumber(msg); local target=r.vip_candidates and r.vip_candidates[n]; if not target then send(name,"§c编号无效。"); return true end; r.vip_target=target; set_menu(d,r,"market_vip_discount"); send(name,"§e请输入折扣（例如0.8=八折，1=原价，必须大于0且不超过1）："); return true end
    if mode == "market_vip_name" then r.vip_target=trim(msg); if r.vip_target=="" then send(name,"§c名称不能为空。"); return true end; set_menu(d,r,"market_vip_discount"); send(name,"§e请输入折扣，例如0.8=八折："); return true end
    if mode == "market_vip_discount" then local x=tonumber(msg); if not x or x<=0 or x>1 then send(name,"§c折扣必须大于0且不超过1。"); return true end; r.vip_discount=x; set_menu(d,r,"market_vip_title"); send(name,"§e请输入VIP称呼，例如：超级至尊VIP；也可以输入 VIP。"); return true end
    if mode == "market_vip_title" then local title=trim(msg); if title=="" then title="VIP" end; r.market_vips=r.market_vips or {}; r.market_vips[uuid_key(r.vip_target)]={discount=r.vip_discount,name=r.vip_target,title=title}; save_data(d); clear_menu(d,r); send(name,"§aVIP已设定："..r.vip_target.."，折扣"..r.vip_discount.."，称呼："..title); return true end
    if mode == "market_sellers" then
        if msg=="+" or msg=="-" then show_sellers(name,(r.market_seller_page or 1)+(msg=="+" and 1 or -1)); return true end
        local n=tonumber(msg); local x=r.market_sellers and r.market_sellers[n]; if not x then send(name,"§c编号无效。请输入当前页编号。"); return true end
        return show_seller_by_name(name,x.name)
    end
    if mode == "market_seller_detail" then
        send(name,"§e可使用 .查看商家 玩家名 重新查询；.stop退出。"); return true
    end
    if mode == "market_logs" then if msg=="+" or msg=="-" then return true end; send(name,"§7日志已在上方显示；.stop退出。"); return true end
    if mode == "market_admin_shops" then
        local n=tonumber(msg)
        local list=r.admin_shop_sellers or {}
        local seller=list[n]
        if not seller then
            -- 首次进入时兼容旧数据，重新生成卖家列表。
            local db=market_db(); local seen={}; list={}
            for _,v in pairs(db.listings or {}) do if v.seller_uuid and not seen[v.seller_uuid] then seen[v.seller_uuid]=true; table.insert(list,{uuid=v.seller_uuid,name=v.seller}) end end
            table.sort(list,function(a,b) return tostring(a.name)<tostring(b.name) end)
            seller=list[n]
            if not seller then send(name,"§c编号无效，请重新打开商铺处理。"); return true end
            set_menu(d,r,"market_admin_shops",{admin_shop_sellers=list})
        end
        if n and seller then
            r.admin_shop_seller_uuid=seller.uuid; r.admin_shop_seller_name=seller.name
            set_menu(d,r,"market_admin_shop_action")
            send(name,"§b━━ 商铺处理："..tostring(seller.name).." ━━\n§f1. 单个商品处理\n§f2. 整个商铺处理\n§7选择后再设置处理时长。")
            return true
        end
        return true
    end
    if mode == "market_admin_shop_action" then
        local n=tonumber(msg); if n==1 then
            local db=market_db(); local arr={}; for _,v in pairs(db.listings or {}) do if v.seller_uuid==r.admin_shop_seller_uuid and not v.sold then table.insert(arr,v) end end; table.sort(arr,function(a,b) return tonumber(a.id or 0)<tonumber(b.id or 0) end)
            r.admin_shop_items=arr; set_menu(d,r,"market_admin_item_list"); local lines={"§b━━ 商品列表 ━━"}; if #arr==0 then table.insert(lines,"§e暂无可处理商品。") else for i,v in ipairs(arr) do table.insert(lines,string.format("§f%d. §e%s §7| 编号：%s",i,tostring(v.name),tostring(v.id))) end end; send(name,table.concat(lines,"\n")); return true
        elseif n==2 then
            set_menu(d,r,"market_admin_duration"); send(name,"§e请输入处理时长：半天 / 一天 / 两天 / 一周 / 一月 / 三月 / 永久"); r.admin_shop_scope="shop"; save_data(d); return true
        else send(name,"§c请输入1或2。"); return true end
    end
    if mode == "market_admin_item_list" then
        local n=tonumber(msg); local v=r.admin_shop_items and r.admin_shop_items[n]; if not v then send(name,"§c编号无效。"); return true end
        r.admin_shop_item_id=tostring(v.id); r.admin_shop_scope="item"; set_menu(d,r,"market_admin_duration"); send(name,"§e请输入处理时长：半天 / 一天 / 两天 / 一周 / 一月 / 三月 / 永久"); return true
    end
    if mode == "market_admin_duration" then
        local txt=trim(msg); local days={ ["半天"]=0.5,["一天"]=1,["两天"]=2,["一周"]=7,["一月"]=30,["三月"]=90 }
        local db=market_db(); local scope=r.admin_shop_scope
        if txt=="永久" then
            if scope=="item" then local v=db.listings[tostring(r.admin_shop_item_id)]; if v then v.disabled=true; db.listings[tostring(v.id)]=v end else for _,v in pairs(db.listings or {}) do if v.seller_uuid==r.admin_shop_seller_uuid then v.shop_banned=true; db.listings[tostring(v.id)]=v end end end
            market_save(db); clear_menu(d,r); send(name,"§a处理已生效：永久。数据库保留，商品不再出现在购买列表。"); return true
        end
        local day=days[txt]
        if not day then send(name,"§c时长无效，请输入：半天、一天、两天、一周、一月、三月或永久。"); return true end
        local until_at=util.timestamp()+day*86400
        if scope=="item" then local v=db.listings[tostring(r.admin_shop_item_id)]; if v then v.disabled_until=until_at; v.disabled=true; db.listings[tostring(v.id)]=v end else for _,v in pairs(db.listings or {}) do if v.seller_uuid==r.admin_shop_seller_uuid then v.shop_banned_until=until_at; v.shop_banned=true; db.listings[tostring(v.id)]=v end end end
        market_save(db); clear_menu(d,r); send(name,"§a处理已生效，时长："..txt.."。到期后可重新显示。"); return true
    end

    if mode == "fixed_shop_buy" then
        if msg=="+" or msg=="-" then fixed_shop_show(name,(r.fixed_shop_page or 1)+(msg=="+" and 1 or -1)); return true end
        local n=tonumber(msg); local v=r.fixed_shop_list and r.fixed_shop_list[n]; if not v then send(name,"§c编号无效，请输入当前页商品序号。"); return true end
        return fixed_shop_buy(name,v.id)
    end
    if mode == "fixed_shop_buy_confirm" then
        if msg=="0" then clear_menu(d,r); send(name,"§e已取消购买。"); return true end
        if msg=="1" then local id=tostring(r.fixed_shop_buy_id or ""); local v=fixed_shop_db().items[id]; if not v then clear_menu(d,r); send(name,"§c商品不存在。"); return true end; set_menu(d,r,"fixed_shop_buy_quantity",{fixed_shop_buy_id=id}); send(name,"§e请输入一次性购买多少次：0~64\n§70 = 取消"); return true end
        send(name,"§c请输入1同意，0取消。"); return true
    end
    if mode == "fixed_shop_buy_quantity" then
        local q=tonumber(msg); if not q or q%1~=0 or q<0 or q>64 then send(name,"§c购买数量必须是0~64的整数。"); return true end
        if q==0 then clear_menu(d,r); send(name,"§e已取消购买。"); return true end
        return fixed_shop_execute_buy(name,tostring(r.fixed_shop_buy_id or ""),q)
    end
    if mode == "fixed_shop_name" then
        local nm=trim(msg); if nm=="" then send(name,"§c名称不能为空。"); return true end
        r.fixed_shop_setup={name=nm}; set_menu(d,r,"fixed_shop_price"); send(name,"§e请输入售价（积分版分数）："); return true
    end
    if mode == "fixed_shop_price" then
        local n=tonumber(msg); if not n or n<1 or n%1~=0 then send(name,"§c价格必须是正整数。"); return true end
        r.fixed_shop_setup.price=math.floor(n); set_menu(d,r,"fixed_shop_limit"); send(name,"§e请输入最大购买次数（1~114514）："); return true
    end
    if mode == "fixed_shop_limit" then
        local n=tonumber(msg); if not n or n<1 or n>114514 or n%1~=0 then send(name,"§c购买次数必须是1~114514的整数。"); return true end
        r.fixed_shop_setup.limit=math.floor(n); set_menu(d,r,"fixed_shop_coord"); send(name,"§e请输入存放商品木桶的坐标：X Y Z"); return true
    end
    if mode == "fixed_shop_coord" then
        local raw=tostring(msg or "")
        -- 允许普通空格、多个空格、Tab；坐标仍必须一次输入完整的整数 XYZ。
        raw=string.gsub(raw,"，"," "); raw=string.gsub(raw,"[，,]"," "); raw=string.gsub(raw,"\t"," ")
        local x,y,z=raw:match("^%s*(-?%d+)%s+(-?%d+)%s+(-?%d+)%s*$")
        if not x then send(name,"§c请一次输入完整坐标，例如：114 5 14"); return true end
        r.fixed_shop_setup.x=tonumber(x); r.fixed_shop_setup.y=tonumber(y); r.fixed_shop_setup.z=tonumber(z); r.fixed_shop_setup.dimension=detect_dimension(name)
        -- 坐标输入后立即持久化，再创建商品；即使事件上下文重跑，也不会丢坐标。
        save_data(d)
        return fixed_shop_finish(name,tonumber(x),tonumber(y),tonumber(z))
    end

    if mode == "territory_main" then local n=tonumber(msg); if n==1 then territory_begin_create(name); elseif n==2 then territory_owned_list(name,"territory_password_list",1); elseif n==3 then territory_owned_list(name,"territory_delete_list",1); elseif n==4 then if not is_admin(name) then send(name,"§c只有管理权限可以增加领地次数。") else set_menu(d,r,"territory_grant_player"); send(name,"§e请输入玩家完整名称：") end; elseif n==5 then territory_owned_list(name,"territory_restore_list",1); elseif n==6 then territory_owned_list(name,"territory_public_list",1); else send(name,"§c请输入1~6。"); end; return true end
    if mode == "territory_create_name" then local nm=trim(msg); if nm=="" then send(name,"§c名称不能为空。"); return true end; r.territory_create={name=nm}; set_menu(d,r,"territory_create_start"); send(name,"§e输入起始坐标：X Z"); return true end
    if mode == "territory_create_start" then local x,z=msg:match("^(-?%d+)%s+(-?%d+)$"); if not x then send(name,"§c格式：X Z"); return true end; r.territory_create.x1=tonumber(x); r.territory_create.z1=tonumber(z); set_menu(d,r,"territory_create_end"); send(name,"§e输入结束坐标：X Z"); return true end
    if mode == "territory_create_end" then local x,z=msg:match("^(-?%d+)%s+(-?%d+)$"); if not x then send(name,"§c格式：X Z"); return true end; r.territory_create.x2=tonumber(x); r.territory_create.z2=tonumber(z); local pos=player_position(name); r.territory_create.dimension=pos and pos.dimension or "overworld"; set_menu(d,r,"territory_create_password"); send(name,"§e请输入6位数字领地密码："); return true end
    if mode == "territory_create_password" then
        local count,pass=password_ascii_digit_count(msg)
        if count~=6 or #pass~=6 then
            send(name,"§c密码长度不正确：当前有效数字为 "..tostring(count).." 位，需要正好6位。示例：114514")
            return true
        end
        -- 只保存稳定的 ASCII 数字字符串，避免宿主对聊天字符的二次转换。
        r.territory_create.password=pass
        save_data(d)
        return territory_create_finish(name)
    end
    if mode == "territory_password_list" then if msg=="+" or msg=="-" then territory_owned_list(name,mode,(r.territory_page or 1)+(msg=="+" and 1 or -1)); return true end; local n=tonumber(msg); local t=r.territory_list and r.territory_list[n]; if not t then send(name,"§c编号无效，请输入当前页编号。"); return true end; r.territory_edit_id=tostring(t.id); set_menu(d,r,"territory_password_edit"); send(name,"§e请输入新的6位数字密码："); return true end
    if mode == "territory_password_edit" then local db=territory_db(); local t=db.items[tostring(r.territory_edit_id)]; local pass=normalize_password_input(msg); if not t then send(name,"§c领地不存在。"); return true end; if not valid_six_digit_password(pass) then send(name,"§c密码必须正好6位数字。你输入的长度为 "..tostring(#pass).."。"); return true end; t.password=pass; t.password_digits=pass; for k,st in pairs(db.entry_state or {}) do if type(st)=="table" and tostring(k):match(":"..tostring(t.id).."$") then st.allowed=nil; st.allowed_until=nil; db.entry_state[k]=st end end; db.items[tostring(t.id)]=t; territory_save(db); territory_protection_log({at=util.timestamp(),type="领地密码修改",player=name,player_uuid=uuid_key(name),territory_id=t.id,territory_name=t.name}); clear_menu(d,r); send(name,"§a密码已修改并保存。之前的密码授权已失效，请重新输入新密码。"); return true end
    if mode == "territory_delete_list" then if msg=="+" or msg=="-" then territory_owned_list(name,mode,(r.territory_page or 1)+(msg=="+" and 1 or -1)); return true end; local n=tonumber(msg); local t=r.territory_list and r.territory_list[n]; if not t then send(name,"§c编号无效，请输入当前页编号。"); return true end; r.territory_edit_id=tostring(t.id); set_menu(d,r,"territory_delete_confirm"); send(name,"§c确定删除「"..tostring(t.name).."」吗？\n§7所有人："..tostring(t.owner or "未知").."\n§f1 同意\n§f0 不同意"); return true end
    if mode == "territory_delete_confirm" then if msg~="1" and msg~="0" then send(name,"§c请输入1或0。"); return true end; if msg=="0" then clear_menu(d,r); send(name,"§e已取消删除。"); return true end; local db=territory_db(); local t=db.items[tostring(r.territory_edit_id)]; if t then t.deleted=true; t.deleted_at=util.timestamp(); db.deleted[tostring(t.id)]=t; db.items[tostring(t.id)]=nil; territory_save(db); territory_protection_log({at=util.timestamp(),type="领地删除",player=name,player_uuid=uuid_key(name),territory_id=t.id,territory_name=t.name,owner=t.owner,owner_uuid=t.owner_uuid,admin=is_admin(name)}) end; clear_menu(d,r); send(name,"§a领地已删除。24小时内可从恢复菜单找回。"); return true end
    if mode == "territory_restore_list" then if msg=="+" or msg=="-" then territory_owned_list(name,mode,(r.territory_page or 1)+(msg=="+" and 1 or -1)); return true end; local n=tonumber(msg); local t=r.territory_list and r.territory_list[n]; if not t then send(name,"§c编号无效，请输入当前页编号。"); return true end; r.territory_edit_id=tostring(t.id); set_menu(d,r,"territory_restore_confirm"); send(name,"§e是否恢复「"..tostring(t.name).."」？输入1恢复，0取消。"); return true end
    if mode == "territory_restore_confirm" then if msg=="1" then local db=territory_db(); local t=db.deleted[tostring(r.territory_edit_id)]; if t then t.deleted=false; db.items[tostring(t.id)]=t; db.deleted[tostring(t.id)]=nil; territory_save(db); territory_protection_log({at=util.timestamp(),type="领地恢复",player=name,player_uuid=uuid_key(name),territory_id=t.id,territory_name=t.name,owner=t.owner,owner_uuid=t.owner_uuid,admin=is_admin(name)}) end; clear_menu(d,r); send(name,"§a领地已恢复。"); return true elseif msg=="0" then clear_menu(d,r); send(name,"§e已取消恢复。"); return true end; send(name,"§c请输入1或0。"); return true end
    if mode == "territory_public_list" then
        if msg=="+" or msg=="-" then territory_owned_list(name,mode,(r.territory_page or 1)+(msg=="+" and 1 or -1)); return true end
        local n=tonumber(msg); local t=r.territory_list and r.territory_list[n]
        if not t then send(name,"§c编号无效，请输入当前页编号。"); return true end
        if not is_admin(name) and t.owner_uuid~=uuid_key(name) then send(name,"§c这不是你的领地。"); return true end
        r.territory_edit_id=tostring(t.id); set_menu(d,r,"territory_public_confirm")
        send(name,"§b领地：§f"..tostring(t.name).."\n§7所有人："..tostring(t.owner or "未知").."\n§7当前状态："..(t.public==true and "§a公开" or "§c关闭公开").."\n§f输入 1 公开\n§f输入 0 关闭公开")
        return true
    end
    if mode == "territory_public_confirm" then
        if msg~="1" and msg~="0" then send(name,"§c请输入1或0。"); return true end
        local db=territory_db(); local t=db.items[tostring(r.territory_edit_id)]
        if not t or t.deleted then clear_menu(d,r); send(name,"§c领地不存在。"); return true end
        if not is_admin(name) and t.owner_uuid~=uuid_key(name) then clear_menu(d,r); send(name,"§c你没有权限修改这块领地。"); return true end
        t.public=(msg=="1"); t.public_changed_at=util.timestamp(); t.public_changed_by=name; db.items[tostring(t.id)]=t; territory_save(db); territory_protection_log({at=util.timestamp(),type=t.public and "领地设为公开" or "领地关闭公开",player=name,player_uuid=uuid_key(name),territory_id=t.id,territory_name=t.name,owner=t.owner,owner_uuid=t.owner_uuid,admin=is_admin(name)}); clear_menu(d,r)
        send(name,t.public and "§a「"..tostring(t.name).."」已设为公开领地，所有玩家均可进入。" or "§e「"..tostring(t.name).."」已关闭公开，恢复密码保护。")
        return true
    end
    if mode == "territory_grant_player" then if not is_admin(name) then clear_menu(d,r); return true end; r.territory_grant_target=trim(msg); set_menu(d,r,"territory_grant_amount"); send(name,"§e请输入增加的领地次数："); return true end
    if mode == "territory_grant_amount" then local n=tonumber(msg); if not n or n<1 then send(name,"§c请输入正整数。"); return true end; local td,tr=player_record(r.territory_grant_target,true); tr.territory_extra=(tonumber(tr.territory_extra)or 0)+math.floor(n); save_data(td); clear_menu(d,r); send(name,"§a已给 "..r.territory_grant_target.." 增加 "..math.floor(n).." 次领地创建机会。"); return true end
    if mode == "territory_password_entry" then return true end
    if mode == "gameplay_index" then
        local index=tonumber(msg)
        if not index or index%1~=0 or index<1 or index>#GAMEPLAY_CATEGORIES then
            send(name,"§c编号无效，请输入 1~"..#GAMEPLAY_CATEGORIES.."。")
        else
            show_gameplay_category(name,index)
        end
        return true
    end
    if mode == "trigger_words" then
        local page=r.trigger_page or 1
        if msg=="+" then show_trigger_words(name,page+1); return true end
        if msg=="-" then show_trigger_words(name,page-1); return true end
        send(name,"§7这里仅支持 + / - 翻页，.stop 退出。")
        return true
    end
    if mode == "unban_target" then
        if msg=="+" then show_unban_menu(name,(r.unban_page or 1)+1); return true end
        if msg=="-" then show_unban_menu(name,(r.unban_page or 1)-1); return true end
        local index=tonumber(msg); local target=index and r.target_list and r.target_list[index]
        if not target then send(name,"§c编号无效，请重新输入。") return true end
        -- 解除封禁必须同时清除插件黑名单与旧版本可能留下的原生 ban。
        local data=load_data(); data.blacklist=data.blacklist or {}
        local removed=false
        for banned_name,_ in pairs(data.blacklist) do
            if banned_name==target or lower(banned_name)==lower(target) then
                data.blacklist[banned_name]=nil; removed=true
            end
        end
        -- 某些旧版本曾经使用过原生 ban；pardon 不存在时安全忽略。
        local safe=string.gsub(target,'"','\\"')
        pcall(game.isCmdSuccess,'pardon "'..safe..'"')
        save_data(data)
        -- 写入后立即重新读取确认，避免菜单内旧表/并发写入把解除操作覆盖。
        local verify=load_data(); verify.blacklist=verify.blacklist or {}
        local still=false
        for banned_name,_ in pairs(verify.blacklist) do
            if banned_name==target or lower(banned_name)==lower(target) then still=true; break end
        end
        if not still then
            local fresh=load_data(); local fr=fresh.players and fresh.players[identity(name)] or r
            clear_menu(fresh,fr)
            send(name,"§a✓ 已解除 "..target.." 的封禁。")
        else
            send(name,"§c解除封禁写入失败，请稍后重试；封禁记录仍存在。")
        end
        return true
    end

    if mode == "coord_tp_input" then
        local dim,x,y,z=msg:match("^(%S+)%s+(-?[%d%.]+)%s+(-?[%d%.]+)%s+(-?[%d%.]+)%s*$")
        if not dim then send(name,"§c格式无效。请输入：维度 X Y Z，例如：主世界 114 100 114。") return true end
        clear_menu(d,r); coordinate_tp_use(name,dim,x,y,z); return true
    end
    if mode == "ban_target" then
        local index=tonumber(msg); local target=index and r.target_list and r.target_list[index]
        if not target then send(name,"§c编号无效，请重新输入。") return true end
        set_menu(d,r,"ban_duration",{pending_target=target})
        local lines={"§c━━ 选择封禁时长 ━━"}; for i,item in ipairs(BAN_DURATIONS) do table.insert(lines,i..". "..item.label) end; table.insert(lines,"§7请输入 1~12，.stop 退出。"); send(name,table.concat(lines,"\n")); return true
    end
    if mode == "ban_duration" then
        local index=tonumber(msg); if not index or not BAN_DURATIONS[index] then send(name,"§c数字无效！请输入 1~12。") return true end
        local target=r.pending_target; clear_menu(d,r); apply_ban(name,target,index); return true
    end
    if mode == "coord_grant_target" then
        local index=tonumber(msg); local target=index and r.target_list and r.target_list[index]
        if not target then send(name,"§c编号无效，请重新输入。") return true end
        set_menu(d,r,"coord_grant_amount",{pending_target=target})
        send(name,"§e请输入给 §f"..target.." §e增加多少次坐标传送机会（正整数）："); return true
    end
    if mode == "coord_grant_amount" then
        local amount=tonumber(trim(msg)); if not amount or amount<1 or amount%1~=0 then send(name,"§c请输入正整数次数。") return true end
        local target=r.pending_target
        -- 先清理管理权限自己的菜单，再写入目标玩家的数据。
        -- 旧逻辑先 save_data(td) 再 clear_menu(d,r)，会用管理权限的旧数据快照覆盖目标玩家刚增加的次数。
        clear_menu(d,r)
        local td,tr=player_record(target,true)
        tr.coordinate_tp=tr.coordinate_tp or {}
        tr.coordinate_tp.extra_uses=(tonumber(tr.coordinate_tp.extra_uses) or 0)+amount
        save_data(td)
        -- 重新读取验证，确保次数已经真正落盘。
        local verify=load_data()
        local vk=identity(target)
        local vr=verify.players and verify.players[vk]
        local actual=vr and vr.coordinate_tp and (tonumber(vr.coordinate_tp.extra_uses) or 0) or 0
        if actual < amount and not (vr and vr.coordinate_tp and vr.coordinate_tp.extra_uses) then
            send(name,"§c次数写入失败，请重新操作。")
            return true
        end
        append_json_log(TELEPORT_LOG_FILE,{at=util.timestamp(),type="分配坐标传送机会",admin=name,admin_uuid=uuid_key(name),target=target,target_uuid=uuid_key(target),amount=amount,actual=actual})
        send(name,"§a✓ 已给 "..target.." 增加 "..amount.." 次坐标传送机会。\n§7次数已保存，可直接使用 .tp。")
        send(target,"§a✦ 管理权限给你增加了 "..amount.." 次坐标传送机会！")
        return true
    end
    if mode == "grant_target" or mode == "revoke_target" then
        local index=tonumber(msg); local target=index and r.target_list and r.target_list[index]
        if not target then send(name,"§c编号无效，请重新输入。") return true end
        clear_menu(d,r)
        local safe=string.gsub(target,'"','\\"')
        if mode=="grant_target" then
            pcall(game.sendCommand,'op "'..safe..'"'); send(name,"§a✓ 已添加 "..target.." 的管理权限。"); send(target,"§a✦ 你已获得管理权限。")
        else
            pcall(game.sendCommand,'deop "'..safe..'"'); pcall(game.sendCommand,'gamemode survival "'..safe..'"'); send(name,"§e✓ 已撤回 "..target.." 的管理权限，并切换为生存模式。"); send(target,"§e你的管理权限已被最高权限账号撤回，当前为生存模式。")
        end
        return true
    end

    if mode == "tpa_target" then
        local index = tonumber(msg)
        local target = index and r.target_list and r.target_list[index]
        if not target then send(name, "§c编号不存在，菜单已退出。") clear_menu(d, r) return true end
        if target == name then send(name, "§c不能传送到自己。") clear_menu(d, r) return true end
        clear_menu(d, r)
        submit_tpa(name, target)
        return true
    end

    if handle_transfer_menu(name, msg, d, r) then return true end
    if handle_report_menu(name, msg, d, r) then return true end

    if mode == "save_name" then
        if msg == "" then
            send(name, "§c名称不能为空，请重新输入。")
            return true
        end

        local slot = r.pending_slot
        local loc, err = save_location(name)
        if not loc then
            send(name, "§c获取位置失败：" .. err)
            r.menu = nil
            r.pending_slot = nil
            save_data(d)
            return true
        end

        wp_set(r, slot, {
            name = msg,
            x = loc.x,
            y = loc.y,
            z = loc.z,
            dimension = loc.dimension,
            saved_at = loc.saved_at
        })
        r.menu = nil
        r.pending_slot = nil
        save_data(d)
        send(name, "§a✓ 传送点「" .. msg .. "」创建成功！维度：" .. loc.dimension)
        return true
    end

    if mode == "save_slot" or mode == "return_slot" or mode == "delete_slot" then
        if not msg:match("^%d+$") then
            send(name, "§c数字无效！请输入 1~10 之间的数字。")
            return true
        end
        local n = tonumber(msg)
        if n < 1 or n > 10 then
            send(name, "§c数字无效！请输入 1~10 之间的数字。")
            return true
        end

        local wp = wp_get(r,n)

        if mode == "save_slot" then
            r.menu = "save_name"
            r.pending_slot = n
            save_data(d)
            send(name, "§e请输入第 " .. n .. " 个传送点的名称：")
        elseif mode == "return_slot" then
            r.menu = nil
            save_data(d)
            if not wp or not wp.name then
                send(name, "§c第 " .. n .. " 个传送点还没有创建。")
            else
                send(name, "§e正在传送到「" .. wp.name .. "」……")
                local ok, err = tp_to(name, wp)
                send(name, ok and "§a✓ 传送成功！" or "§c传送失败：" .. tostring(err))
            end
        else
            r.menu = nil
            save_data(d)
            if not wp or not wp.name then
                send(name, "§c第 " .. n .. " 个传送点为空，无法删除。")
            else
                local old = wp.name
                wp_delete(r,n)
                save_data(d)
                send(name, "§a✓ 已删除传送点「" .. old .. "」。")
            end
        end
        return true
    end

    return false
end

-- ════════════════════════════════════════════════════════════
--   死亡点捕获：PyRpc 事件 + 最后已知坐标（DeepSeek 思路改造）
--
-- 原理：
-- 1) 周期记录在线玩家坐标到 RUNTIME.last_pos（死亡瞬间坐标常归零，用最后已知坐标）
-- 2) 通过 events.subscribe("PyRpc") 捕获死亡/重生相关事件
-- 3) 死亡时仅私信通知该玩家并写入 r.death，绝不向全服广播坐标
-- 4) 重生事件可感知，但不公开播报
-- 5) 存储结构与原先一致：d.players[key].death = {x,y,z,dimension,saved_at,reason}
-- 注意：网易版不使用 name="@s" 这种选择器写法。
-- ════════════════════════════════════════════════════════════

local function death_position_valid_light(pos)
    if type(pos)~="table" then return false end
    local x,y,z=tonumber(pos.x),tonumber(pos.y),tonumber(pos.z)
    return x~=nil and y~=nil and z~=nil and not (x==0 and y==0 and z==0)
end

-- ════════════════════════════════════════════════════════════
-- 最后已知坐标跟踪（磁盘持久化）
--
-- 为什么必须单独落盘：
--   1) 插件每次触发 handler 都会新建 Lua 状态重跑源码，全局变量每次都被重置，
--      所以 RUNTIME.last_pos 无法跨调用保存坐标；
--   2) 玩家死亡瞬间服务器会下发 PlayerLocation [0,0,0]，把在线坐标清零，
--      此时读 player.get() 只能拿到 0。
--   因此必须在玩家活着的时候把坐标写进磁盘，死亡时再读出来当死亡点。
-- 单独用一个小文件，避免每 2 秒写 ds_data.json 与其它功能并发互相覆盖。
-- ════════════════════════════════════════════════════════════
DEATH_TRACK_FILE = game.dataDir() .. "/death_lastpos.json"

local function load_death_track()
    local ok, d = pcall(util.json_load, DEATH_TRACK_FILE)
    if not ok or type(d) ~= "table" then d = {} end
    d.pos = d.pos or {}        -- key(xuid 或玩家名) -> {x,y,z,dimension,name,at}
    d.pid2name = d.pid2name or {} -- pid(unique_id) -> 玩家名
    return d
end

local function save_death_track(d)
    pcall(util.json_write, DEATH_TRACK_FILE, d)
end

-- 从多个候选坐标里挑“最新且有效”的一个（按 at 时间戳比大小）
local function choose_death_pos(list)
    local best, best_at = nil, -1
    for _, p in ipairs(list) do
        if death_position_valid_light(p) then
            local at = tonumber(p.at) or 0
            if at >= best_at then best, best_at = p, at end
        end
    end
    return best
end

local function save_death_point_light(name,loc,reason)
    if not death_position_valid_light(loc) then return false end
    local d=load_data(); local key,info=identity(name); d.players=d.players or {}
    local r=d.players[key]
    if not r then
        r={xuid=info.xuid or "",unique_id=info.unique_id or "",name=name,waypoints={},death=nil}
        d.players[key]=r
    end
    r.name=name
    local dim=normalize_dimension(loc.dimension) or normalize_dimension((get_info(name) or {}).dimension) or "overworld"
    r.death={x=math.floor(tonumber(loc.x)),y=math.floor(tonumber(loc.y)),z=math.floor(tonumber(loc.z)),dimension=dim,saved_at=util.now(),reason=reason or "pyrpc"}
    r.last_death_capture=util.timestamp()
    r.death_count=(tonumber(r.death_count) or 0)+1
    -- 最后已知坐标一并落盘，供下次死亡判定 / 其它模块调用
    r.last_pos={x=r.death.x,y=r.death.y,z=r.death.z,dimension=dim,at=util.timestamp()}
    -- 历史死亡点：每个玩家最多保留最近 10 条
    r.death_history=r.death_history or {}
    table.insert(r.death_history,{x=r.death.x,y=r.death.y,z=r.death.z,dimension=dim,saved_at=r.death.saved_at,reason=r.death.reason})
    while #r.death_history>10 do table.remove(r.death_history,1) end
    d.death_capture_pending=d.death_capture_pending or {}
    d.death_capture_pending[name]=nil
    save_data(d)
    -- 仅私信死亡玩家，绝不向全服暴露坐标
    send(name,string.format("§6[死亡] §f死亡点已记录 §7| §e坐标：§f%d, %d, %d §7| §b维度：§f%s §7| §f第%d次死亡",
        r.death.x,r.death.y,r.death.z,dimension_display(dim),r.death_count))
    send(name,"§7输入 §e.死亡点 §7可随时查看；§e.help §7→§e3 §7可直接返回死亡点。")
    return true
end

-- 网易租赁服 PyRpc 结构（2026-09 实测验证，kill 抓包确认）：
--   value = ["c", [code, payload], null]
--   code 32 = 死亡/重生：payload = {die=true|false, pid="<玩家unique_id>"}
--             die=true  → 该玩家死亡（全服广播，插件靠这个抓死亡点）
--             die=false → 该玩家重生
--   code 43 = 位置广播：payload = {pid="...", pos={__type__="tuple", value=[x,y,z]}}
--   code 11 = 指令 executeResult（每秒约 10 条噪音，必须忽略）
--   code 18 = 通用状态刷新（忽略）
-- 死亡瞬间坐标会被服务器清零：getPlayerPos/querytarget 会报“目标不存在”，
-- 所以死亡点的来源是【玩家活着时落盘的最后已知坐标】+【框架玩家缓存】。
local PYRPC_CODE_DEATH = 32
local PYRPC_CODE_POS = 43
local PYRPC_CODE_NOISE = 11
local EYE_HEIGHT = 1.62   -- 框架缓存的 y 是眼睛高度，脚部坐标 = y - 1.62

local function pyrpc_inner(data)
    if type(data) ~= "table" then return nil, nil end
    local v = data.value
    if type(v) ~= "table" then return nil, nil end
    local inner = v[2]
    if type(inner) ~= "table" then return nil, nil end
    return inner[1], inner[2]
end

local function pyrpc_pid(payload)
    if type(payload) ~= "table" then return nil end
    local pid = payload.pid
    if pid == nil then pid = payload.id end
    if pid == nil then pid = payload.uuid end
    return pid
end

-- 通过 unique_id / xuid / 名字 把 pid 映射回玩家名：先查在线缓存，再查磁盘映射。
local function resolve_player_by_pid(pid)
    if pid == nil then return nil end
    local pid_str = tostring(pid)
    local ok, list = pcall(player.list)
    if ok and type(list) == "table" then
        for _, p in ipairs(list) do
            if type(p) == "table" then
                if tostring(p.unique_id or "") == pid_str then return p.name end
                if tostring(p.xuid or "") == pid_str then return p.name end
                if tostring(p.name or "") == pid_str then return p.name end
            end
        end
    end
    local track = load_death_track()
    local nm = (track.pid2name or {})[pid_str]
    if nm and nm ~= "" then return nm end
    return nil
end

-- 玩家“活着”时的坐标落盘（y 统一换算成脚部坐标，死亡点可直接站着传送过去）。
-- feet_already=true 表示传入的 y 已经是脚部坐标。
local function note_player_pos(name, pid, x, y, z, dimension, feet_already)
    if not name or name == "" then return end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y or not z or (x == 0 and y == 0 and z == 0) then return end
    if not feet_already then y = math.floor(y - EYE_HEIGHT) end
    local track = load_death_track()
    track.pos = track.pos or {}
    track.pid2name = track.pid2name or {}
    local info = get_info(name)
    local xuid = (info and type(info.xuid) == "string" and info.xuid ~= "") and info.xuid or name
    local dim = normalize_dimension(dimension) or "overworld"
    local changed = false
    local old = track.pos[xuid]
    if (not old)
        or math.abs((tonumber(old.x) or 0) - x) >= 0.5
        or math.abs((tonumber(old.y) or 0) - y) >= 0.5
        or math.abs((tonumber(old.z) or 0) - z) >= 0.5
        or normalize_dimension(old.dimension) ~= dim then
        track.pos[xuid] = {x = x, y = y, z = z, dimension = dim, name = name, at = util.timestamp()}
        changed = true
    end
    if pid ~= nil and track.pid2name[tostring(pid)] ~= name then
        track.pid2name[tostring(pid)] = name
        changed = true
    end
    if changed then save_death_track(track) end
end

function on_pyrpc(data)
    if type(data) ~= "table" then return end
    if type(RUNTIME) ~= "table" then RUNTIME = {} end
    RUNTIME.last_pos = RUNTIME.last_pos or {}
    local code, payload = pyrpc_inner(data)

    -- code 43：位置广播（高频包），只更新内存里的“最后已知坐标”。
    -- 不再每条位置包都读写磁盘：落盘统一交给 tick_death_fallback 每 5 秒做一次，
    -- 死亡瞬间的实际坐标仍以框架玩家缓存（get_info）为准。
    if code == PYRPC_CODE_POS then
        local pid = pyrpc_pid(payload)
        local pos = type(payload) == "table" and payload.pos or nil
        local xyz = type(pos) == "table" and pos.value or nil
        if pid ~= nil and type(xyz) == "table" then
            local nm = resolve_player_by_pid(pid)
            if nm and nm ~= "" then
                local px, py, pz = tonumber(xyz[1]), tonumber(xyz[2]), tonumber(xyz[3])
                if px and py and pz and not (px == 0 and py == 0 and pz == 0) then
                    local info = get_info(nm)
                    local dim = normalize_dimension(info and info.dimension) or "overworld"
                    RUNTIME.last_pos[nm] = {x = px, y = math.floor(py - EYE_HEIGHT), z = pz, dimension = dim, at = util.timestamp()}
                end
            end
        end
        return
    end
    if code == PYRPC_CODE_NOISE then return end
    if code ~= PYRPC_CODE_DEATH then return end
    if type(payload) ~= "table" or payload.die == nil then return end

    local pid = pyrpc_pid(payload)
    local name = resolve_player_by_pid(pid)

    if payload.die == true then
        if not name or name == "" then
            log_event("DEATH", "检测到死亡事件但无法解析玩家 pid=" .. tostring(pid))
            return
        end
        local track = load_death_track()
        local info = get_info(name)
        local xuid = (info and type(info.xuid) == "string" and info.xuid ~= "") and info.xuid or name
        local cands = {}
        -- 首选：框架玩家缓存。由 MovePlayer 实时维护，死亡瞬间仍保留死亡前坐标。
        if info then
            local x, y, z = tonumber(info.x), tonumber(info.y), tonumber(info.z)
            if x and y and z and not (x == 0 and y == 0 and z == 0) then
                cands[#cands+1] = {
                    x = math.floor(x), y = math.floor(y - EYE_HEIGHT), z = math.floor(z),
                    dimension = normalize_dimension(info.dimension) or "overworld",
                    at = util.timestamp(), src = "player_cache",
                }
            end
        end
        -- 次选：磁盘上“活着时”记录的最后已知坐标（xuid 键 / 名字键 / pid 映射键）。
        cands[#cands+1] = track.pos[xuid]
        cands[#cands+1] = track.pos[name]
        if pid ~= nil then
            local pn = (track.pid2name or {})[tostring(pid)]
            if pn then cands[#cands+1] = track.pos[pn] end
        end
        cands[#cands+1] = RUNTIME.last_pos[name]
        local pos = nil
        for _, c in ipairs(cands) do
            if death_position_valid_light(c) then pos = c; break end
        end
        if death_position_valid_light(pos) then
            save_death_point_light(name, pos, "pyrpc32")
            -- 死亡数据交给定时云备份（默认 5 分钟一次），不再每次死亡都立刻全量上传。
        else
            log_event("DEATH", "检测到死亡玩家但无法取得死亡前坐标：" .. tostring(name) .. " pid=" .. tostring(pid))
            send(name, "§6[死亡] §f已检测到死亡，但未能记录有效坐标。")
        end
    else
        -- 重生：只记日志，绝不全服广播。
        if name and name ~= "" then log_event("DEATH", name .. " 重生") end
    end
end

-- 兜底：定时把在线玩家坐标写盘（玩家活着时记录），并用实体存在性做二次确认。
-- 插件每次触发 handler 都会新建 Lua 状态重跑源码，全局变量会被重置，
-- 所以坐标必须落盘，不能只放内存。
-- 原来 2 秒一次、每次还要对每个在线玩家发一条 testfor（命令往返很重）；
-- 现在整体 5 秒一次，实体存在性兜底再单独节流到 30 秒一次。
DEATH_FALLBACK_INTERVAL = 5
local last_alive_state = {}

function tick_death_fallback()
    if type(RUNTIME) ~= "table" then RUNTIME = {} end
    RUNTIME.last_pos = RUNTIME.last_pos or {}
    local track = load_death_track()
    local changed = false
    local ok_list, list = pcall(player.list)
    if ok_list and type(list) == "table" then
        for _, p in ipairs(list) do
            if type(p) == "table" and p.name and p.x ~= nil and p.y ~= nil and p.z ~= nil then
                local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
                if x and y and z and not (x == 0 and y == 0 and z == 0) then
                    -- 框架缓存的 y 是眼睛高度，脚部坐标 = y - 1.62
                    local feet = math.floor(y - EYE_HEIGHT)
                    local dim = normalize_dimension(p.dimension) or "overworld"
                    RUNTIME.last_pos[p.name] = {x = x, y = feet, z = z, dimension = dim, at = util.timestamp()}
                    local key = (type(p.xuid) == "string" and p.xuid ~= "") and p.xuid or p.name
                    local old = track.pos[key]
                    if (not old)
                        or math.abs((tonumber(old.x) or 0) - x) >= 0.5
                        or (tonumber(old.y) == nil)
                        or math.floor(tonumber(old.y) or -99999) ~= feet
                        or math.abs((tonumber(old.z) or 0) - z) >= 0.5
                        or normalize_dimension(old.dimension) ~= dim then
                        track.pos[key] = {x = x, y = feet, z = z, dimension = dim, name = p.name, at = util.timestamp()}
                        changed = true
                    end
                    if p.unique_id ~= nil then
                        local pk = tostring(p.unique_id)
                        if track.pid2name[pk] ~= p.name then
                            track.pid2name[pk] = p.name
                            changed = true
                        end
                    end
                end
            end
        end
    end

    -- 实体存在性兜底：从“存在”变为“不存在”，可能是死亡（坐标用最后已知）。
    -- 这里要对每个在线玩家发 testfor，开销大，单独节流到 30 秒一次。
    local now = util.timestamp()
    if (now - (tonumber(track.alive_check_at) or 0)) >= 30 then
        track.alive_check_at = now
        changed = true
        local names = online_names_from_list() or {}
        for _, name in ipairs(names) do
            if name then
                local alive = is_alive_entity(name)
                local prev = last_alive_state[name]
                if prev == true and alive == false then
                    local pos = RUNTIME.last_pos[name]
                    if death_position_valid_light(pos) then
                        local d = load_data()
                        local r = d.players and d.players[identity(name)]
                        local recent = r and tonumber(r.last_death_capture) or 0
                        if (now - recent) > 8 then
                            save_death_point_light(name, pos, "entity_fallback")
                        end
                    end
                end
                last_alive_state[name] = alive
            end
        end
    end

    if changed then save_death_track(track) end
end

-- ════════════════════════════════════════════════════════════
--   聊天入口
-- ════════════════════════════════════════════════════════════

-- .AI停止 / .AI停止全部：写落盘停止标志，所有 AI 会话（含兑换码 AI）都会在下一轮 / 下一条指令前中止。
-- 与"停止建筑"不同：这里停止的是任意 AI 任务，且标志落盘，插件重载也不丢。
-- 管理员可用 .AI停止全部 <玩家名> 停止他人的 AI 任务。
function ai_stop_chat(name, msg)
    msg=trim(msg or "")
    local low=lower(msg)
    if low==".AI停止全部" or low==".ai停止全部" then
        if not is_admin(name) then send(name,"§c只有管理权限可以停止他人 AI 任务。"); return true end
        local target=trim(msg:match("^%.AI停止全部%s+(.+)$") or msg:match("^%.ai停止全部%s+(.+)$") or "")
        if target=="" then
            send(name,"§c用法：.AI停止全部 <玩家名>")
        else
            ai_stop_set(target,"管理权限强制停止")
            send(name,"§a已停止 "..target.." 的 AI 任务。")
            send(target,"§c管理权限已强制停止你的 AI 任务。")
        end
        return true
    end
    if low==".AI停止" or low==".ai停止" then
        ai_stop_set(name,"玩家手动停止")
        send(name,"§a已请求停止你的 AI 任务；当前任务将在下一轮或下一条指令前中止。")
        return true
    end
    return false
end

-- 聊天频率/禁言状态单独放在小文件里。
-- 旧版把它们存在 ds_data.json（体积大），导致每条聊天都要全量读+写一遍玩家数据文件。
CHAT_RATE_FILE = game.dataDir() .. "/chat_rate.json"
function chat_rate_db()
    local ok,d=pcall(util.json_load,CHAT_RATE_FILE)
    if ok and type(d)=="table" then
        d.rate=d.rate or {}; d.mutes=d.mutes or {}; d.state=d.state or {}
        return d
    end
    -- 首次运行时从旧版 ds_data.json 迁移一次，之后只读写这个小文件。
    local old=load_data()
    local fresh={rate=old.chat_rate or {},mutes=old.chat_mutes or {},state=old.chat_mute_state or {}}
    pcall(util.json_write,CHAT_RATE_FILE,fresh)
    return fresh
end
function chat_rate_save(d) pcall(util.json_write,CHAT_RATE_FILE,d) end

function chat_rate_record(playerName)
    local d=chat_rate_db()
    local now=util.timestamp()

    local state=d.state[playerName]
    if type(state)~="table" or now-(tonumber(state.window_start) or 0)>=CHAT_MUTE_RESET then
        state={window_start=now, level=0}
        d.state[playerName]=state
    end

    local muted_until=tonumber(d.mutes[playerName] or 0) or 0
    if muted_until<0 or muted_until>now then
        chat_rate_save(d)
        return true
    end
    if muted_until>0 then d.mutes[playerName]=nil end

    local list=d.rate[playerName] or {}
    local kept={}
    for _,t in ipairs(list) do
        if now-t < CHAT_RATE_WINDOW then table.insert(kept,t) end
    end
    table.insert(kept,now)
    d.rate[playerName]=kept

    if #kept > CHAT_RATE_LIMIT then
        state.level=math.min((tonumber(state.level) or 0)+1, #MUTE_LEVELS+1)
        local seconds=MUTE_LEVELS[state.level] or 18000 -- 第6次起封顶5小时
        d.mutes[playerName]=now+seconds
        d.rate[playerName]={}
        chat_rate_save(d)
        pcall(game.sendCommand,'tag "'..string.gsub(playerName,'"','\\"')..'" add 禁言')
        local mins=math.floor(seconds/60)
        local label=mins<60 and (tostring(seconds).."秒") or (tostring(math.floor(mins/60)).."小时")
        send(playerName,"§c频率过快，已禁言 "..label.."。第"..tostring(state.level).."次违规；24小时后等级重置。")
        pcall(game.sendActionbar,playerName,"§c频率过快，已禁言 "..label)
        return true
    end
    chat_rate_save(d)
    return false
end

function tick_chat_mute()
    local d=chat_rate_db()
    local now=util.timestamp()
    local changed=false

    for name,state in pairs(d.state) do
        if type(state)=="table" and now-(tonumber(state.window_start) or 0)>=CHAT_MUTE_RESET then
            d.state[name]=nil
            d.rate[name]=nil
            changed=true
        end
    end

    for name,until_at in pairs(d.mutes) do
        until_at=tonumber(until_at) or 0
        if until_at>=0 and until_at<=now then
            d.mutes[name]=nil
            d.rate[name]=nil
            pcall(game.sendCommand,'tag "'..string.gsub(name,'"','\\"')..'" remove 禁言')
            send(name,"§a禁言已解除，可以正常发言。")
            changed=true
        end
    end
    if changed then chat_rate_save(d) end
end

-- 禁言高频约束：保持原有 0.0125 秒设定，但只在"确实有人被禁言"时才发那条空 tellraw。
-- 原因：这条命令走的是网易 AI 命令通道，而且整条通道是串行的。
--      原来无论有没有人禁言，每秒都固定发 80 条，把聊天、.help、AI 全都排在后面，
--      表现为"发一条消息要等 1~2 秒"。现在空跑不再发包，禁言行为完全不变。
function muted_anyone()
    local ok,d=pcall(util.json_load,CHAT_RATE_FILE)
    if not ok or type(d)~="table" then return true end -- 读不到就按老行为发包（fail-safe）
    local m=d.mutes
    if type(m)~="table" then return false end
    local now=util.timestamp()
    for _,v in pairs(m) do
        local t=tonumber(v) or 0
        if t<0 or t>now then return true end
    end
    return false
end

function tick_chat_mute_fast()
    if not muted_anyone() then return end
    -- 单一原版高频循环：所有禁言玩家同一条有序指令统一处理。
    pcall(game.sendCommand,'execute as @a[tag=禁言] run tellraw @s {"rawtext":[]}')
end

AI_HOURLY_LIMIT = 10
AI_HOURLY_WINDOW = 3600

function ai_hourly_quota_check(playerName)
    if is_admin(playerName) then return true end
    local d=load_data()
    d.ai_hourly_rate=d.ai_hourly_rate or {}
    local now=util.timestamp()
    local list=d.ai_hourly_rate[playerName] or {}
    local kept={}
    for _,t in ipairs(list) do
        if now-(tonumber(t) or 0) < AI_HOURLY_WINDOW then kept[#kept+1]=tonumber(t) end
    end
    if #kept >= AI_HOURLY_LIMIT then
        d.ai_hourly_rate[playerName]=kept
        save_data(d)
        local remain=AI_HOURLY_WINDOW-(now-(kept[1] or now))
        local mins=math.max(1,math.ceil(remain/60))
        send(playerName,"§c普通玩家每小时最多向AI发送10条消息。你本小时额度已用完，请约"..mins.."分钟后再试。")
        return false
    end
    kept[#kept+1]=now
    d.ai_hourly_rate[playerName]=kept
    save_data(d)
    return true
end

function on_chat(playerName, msg)
    msg = trim(msg)
    local low = lower(msg)
    if chat_rate_record(playerName) then return end
    -- 聊天日志只写一次：log_event 进小缓冲文件，由 flush_log_buffer 定期合并进 runtime.log。
    -- 原来这里还会 append_json_log(CHAT_LOG_FILE)，等于每条聊天都全量读+写一遍 chat_logs.json，重复且极重。
    log_event("CHAT", playerName .. ": " .. msg)

    -- .help/.触发词统一从 on_chat 进入，避免前缀触发器把“.help 12”提前截断。
    if low == ".help" or low == "help" then
        show_help(playerName)
        return
    end
    if low == ".触发词" then
        show_trigger_words(playerName, 1)
        return
    end
    local nbt_args=msg:match("^%.NBT测试%s+(.+)$") or msg:match("^%.nbt测试%s+(.+)$")
    if nbt_args then nbt_test_report(playerName,nbt_args); return end
    if low==".nbt测试" then send(playerName,"§e用法：.NBT测试 X Y Z，例如 .NBT测试 114 5 14"); return end

    -- AI 模型切换：这是管理权限级的服务器模型开关，直接执行，不交给 AI 猜。
    local model_req = msg:match("^%.AI模型%s+(.+)$") or msg:match("^%.ai模型%s+(.+)$") or msg:match("^%.AI切换%s+(.+)$") or msg:match("^%.ai切换%s+(.+)$")
    if not model_req and (low=="ai切换模型到 deepseek-flash" or low=="ai切换到 deepseek-flash" or low=="ai切换模型到 flash") then model_req="deepseek-flash" end
    if low==".ai模型" or low==".ai模型当前" or low==".ai状态" then
        local current=get_ai_model_override() or tostring(game.getConfig("ai_model",AI_MODEL) or AI_MODEL)
        local _,_,prov=ai_endpoint_for(current)
        send(playerName,"§b当前 AI 模型：§e"..model_display(current)..
            "\n§7接口："..(prov=="deepseek" and "§aDeepSeek 官方" or "§7SenseNova 网关")..
            "\n§7思考模式："..(ai_thinking_enabled() and "§a开启（更慢更费token）" or "§7关闭（推荐）")..
            "\n§7可用模型："..available_model_list()..
            "\n§8deepseek-flash = DeepSeek 4.1 Flash（走 DeepSeek 官方接口）"..
            "\n§7切换：§f.AI模型 <模型ID或简称>，例如 §e.AI模型 4.1")
        return
    end
    if model_req then
        if not is_admin(playerName) then
            send(playerName,"§c只有管理权限可以切换 AI 模型。")
        else
            local ok,m=set_ai_model_override(model_req,playerName)
            if ok then
                local _,_,prov=ai_endpoint_for(m)
                send(playerName,"§aAI 模型已立即切换为：§e"..model_display(m).." §7("..m..")"..
                    "\n§7接口："..(prov=="deepseek" and "§aDeepSeek 官方" or "§7SenseNova 网关")..
                    "\n§7之后 AI 请求将优先使用这个模型，直到再次切换。")
            else send(playerName,"§c"..tostring(m)) end
        end
        return
    end

    if low == "停止建筑" or low == "停止建造" or low == "停止建筑模式" or low == ".停止建筑" or low == ".停止建造" then
        if not is_admin(playerName) then
            send(playerName,"§c只有管理权限可以停止建筑任务。")
        else
            -- 聊天停止是一次性 runtime 信号：只打断当前正在运行的建筑任务，不写入永久状态。
            RUNTIME.build_stop=RUNTIME.build_stop or {}; RUNTIME.build_stop[playerName]=true
            send(playerName,"§e已要求AI停止继续建筑；本次任务结束后停止信号会自动清除，已经完成的建筑不会删除。")
        end
        return
    end

    if low == ".建筑模式关闭" or low == ".关闭建筑模式" then
        if not is_admin(playerName) then
            send(playerName,"§c只有管理权限可以关闭建筑模式。")
        else
            local dd,rr=player_record(playerName,true)
            rr.ai_build_mode=false
            rr.ai_build_started_at=nil
            rr.ai_build_stop_requested=false
            save_data(dd)
            -- 关闭模式仍需让正在运行的一次任务尽快结束，但这个信号只存在于本次 runtime。
            RUNTIME.build_stop=RUNTIME.build_stop or {}; RUNTIME.build_stop[playerName]=true
            send(playerName,"§e建筑模式已关闭；当前任务会停止，后续AI可正常使用，正常聊天记忆不会清除。")
        end
        return
    end

    -- 记忆清除：不经过 AI，直接清空该玩家所有 AI 窗口并开始新会话。
    if low == ".记忆清除" or low == ".清除记忆" then
        clear_ai_memory(playerName)
        send(playerName,"§b[Ds] §f已切换新窗口")
        return
    end

    -- .通 将玩家消息发送到配置的 QQ 中转服务。
    local qq_trigger = ".通 "
    if low == ".通" or low:sub(1, #qq_trigger) == qq_trigger then
        local body = trim(msg:sub(#qq_trigger + 1))
        if body == "" then
            send(playerName, "§e用法：.通 你要发送到QQ群的内容")
        elseif qq_send("[游戏] " .. playerName .. "：" .. body) then
            send(playerName, "§a已发送到QQ群。")
            log_event("QQ", playerName .. " -> group: " .. body)
        else
            send(playerName, "§cQQ群互通尚未配置，请管理权限设置 qq_relay_url 并启用 qq_enabled。")
        end
        return
    end
    if low == ".日志" then
        send(playerName, read_recent_logs(playerName))
        return
    end
    if low == ".qq状态" or low == ".qq群" or low == ".qq互通" then
        send(playerName, qq_status_text())
        return
    end

    -- 兑换码系统：两类一次性代码
    -- 1) AI 自然语言：.生成兑换码 给我10个钻石 有效期24小时
    -- 2) 区域 NBT：.生成兑换码 导入 城堡 100 64 100 120 80 120 7天
    local redeem_args = msg:match("^%.生成兑换码%s+(.+)$")
    if redeem_args then
        if not is_admin(playerName) then
            send(playerName,"§c只有管理权限可以生成兑换码。")
            return
        end
        local seconds=select(1,parse_expiry(redeem_args))
        if not seconds or seconds<=0 then
            send(playerName,"§c请在最后写有效期，例如：24小时、7天、60分钟。")
            return
        end
        local expires_at=(tonumber(util.timestamp()) or 0)+seconds
        local body=trim(redeem_args)
        body=body:gsub("%s*有效期%s*%d+%s*秒%s*$","")
        body=body:gsub("%s*有效期%s*%d+%s*分钟%s*$","")
        body=body:gsub("%s*有效期%s*%d+%s*小时%s*$","")
        body=body:gsub("%s*有效期%s*%d+%s*天%s*$","")
        body=body:gsub("%s*有效期%s*%d+%s*[Ss]%s*$","")
        body=body:gsub("%s*有效期%s*%d+%s*[Mm]%s*$","")
        body=body:gsub("%s*有效期%s*%d+%s*[Hh]%s*$","")
        body=body:gsub("%s*有效期%s*%d+%s*[Dd]%s*$","")
        body=trim(body)

        local mode,name,x1,y1,z1,x2,y2,z2 = body:match("^(导出|导入)%s+(.+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)%s*$")
        if mode then
            name=trim(name):gsub('^"(.*)"$','%1')
            if mode=="导出" then
                local ok,result=save_native_region(playerName,name,x1,y1,z1,x2,y2,z2)
                if not ok then send(playerName,"§c"..result); return end
            else
                local manifest,err=load_native_manifest(name)
                if not manifest then send(playerName,"§c"..err); return end
            end
            local code,err=create_redeem_code(playerName,"structure",{name=name},expires_at)
            send(playerName,code and ("§a区域 NBT 兑换码：§e"..code.."\n§f结构："..name.."\n§f有效期："..select(2,parse_expiry(redeem_args)).."\n§7兑换一次后永久失效。") or "§c"..err)
            return
        end

        local existing=body:match("^导入%s+(.+)$")
        if existing then
            existing=trim(existing):gsub('^"(.*)"$','%1')
            local manifest,err=load_native_manifest(existing)
            if not manifest then send(playerName,"§c"..err); return end
            local code,cerr=create_redeem_code(playerName,"structure",{name=existing},expires_at)
            send(playerName,code and ("§a区域 NBT 兑换码：§e"..code.."\n§f结构："..existing.."\n§7兑换后会加载到玩家当前位置；一次性使用。") or "§c"..cerr)
            return
        end

        if body=="" then
            send(playerName,"§c自然语言不能为空。示例：.生成兑换码 给我10个钻石 有效期24小时")
            return
        end
        local code,err=create_redeem_code(playerName,"ai",body,expires_at)
        send(playerName,code and ("§aAI兑换码：§e"..code.."\n§f内容："..body.."\n§7兑换时由AI根据内容执行；一次性使用。") or "§c"..err)
        return
    end

    local redeem_input=msg:match("^%.兑换%s+(.+)$")
    if redeem_input then
        -- 只有“自然语言兑换码”需要现场让 AI 执行，耗时较长才给提示；
        -- 区域导入类兑换码是区块式静默导入，不再弹多余提示。
        local rawcode=trim(redeem_input)
        local dd0=load_data(); local ee0=(dd0.redeem_codes or {})[lower(rawcode)]
        if type(ee0)=="table" and ee0.kind=="ai" then
            send(playerName,"§b[Ds] §f正在兑换……")
        end
        local ok,result=redeem_code(playerName,redeem_input)
        send(playerName,ok and "§a"..result or "§c"..result)
        return
    end

    -- 区域 NBT 系统：.导出 名称 X1 Y1 Z1 X2 Y2 Z2；.导入 名称 X Y Z。
    -- 名称允许中文；插件内部自动生成安全的原版 structure ID。
    local in_name,ix1,iy1,iz1=msg:match("^%.导入%s+(.+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)%s*$")
    if in_name then
        if not is_admin(playerName) then send(playerName,"§c只有管理权限可以导入区域。")
        else
            in_name=trim(in_name):gsub('^"(.*)"$','%1')
            local ok,result=place_native_region(playerName,in_name,ix1,iy1,iz1)
            send(playerName,(ok and "§a" or "§c")..result)
        end
        return
    end

    local out_name,ox1,oy1,oz1,ox2,oy2,oz2=msg:match("^%.导出%s+(.+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)%s*$")
    if out_name then
        if not is_admin(playerName) then send(playerName,"§c只有管理权限可以导出区域。")
        else
            out_name=trim(out_name):gsub('^"(.*)"$','%1')
            local ok,result=save_native_region(playerName,out_name,ox1,oy1,oz1,ox2,oy2,oz2)
            send(playerName,(ok and "§a" or "§c")..result)
        end
        return
    end
    if low == ".一键查询" then
        local seed = get_server_seed()
        local info = get_info(playerName)
        if not seed or not info then
            send(playerName, "§e请先设置种子（管理权限使用 .种子 <种子号>），并确保能读取当前位置。")
        else
            send(playerName, "§b[一键查询] §fSeed=" .. seed .. " 位置=" .. math.floor(info.x) .. "," .. math.floor(info.y) .. "," .. math.floor(info.z))
            send_long(playerName, query_seed_structure(playerName, "村庄", SEED_FINDER_DEFAULT_RADIUS), 650)
        end
        return
    end

    if enforce_blacklist(playerName) then return end

    -- .help / .触发词 在 on_chat 顶部显式处理，避免前缀触发器截断“.help 12”等带参数输入。

    -- 玩法介绍/触发词页是独立子菜单：在这里先消费玩家输入，
    -- 防止 .home、.回 等同级快捷入口绕过菜单状态。
    do
        local menu_d, menu_r = player_record(playerName, true)
        if menu_r.menu == "gameplay_index" or menu_r.menu == "trigger_words" then
            if handle_menu(playerName, msg) then return end
        end
    end

    -- AI input must not be consumed by an old menu.
    -- 普通AI只认 ai / AI 前缀；./ 不再是AI入口，./tp 仍保留为玩家传送。
    local is_ai_input =
        msg:sub(1, #COMMAND_WORD) == COMMAND_WORD or
        low:sub(1, #NORMAL_TRIGGER) == NORMAL_TRIGGER
    if is_ai_input then
        local menu_d, menu_r = player_record(playerName, true)
        if menu_r.menu and menu_r.menu ~= "report_explain" then
            clear_menu(menu_d, menu_r)
        end
    end

    if msg == ".撤销举报" or msg == ".撤销" then
        local removed = withdraw_report(playerName)
        send(playerName, removed > 0 and ("§a已撤销 " .. removed .. " 条举报。") or "§e你没有可撤销的举报。")
        return
    end

    -- 管理权限设置或覆盖积分计分板名称
    local board_input = msg:match("^%.积分版%s+(.+)$") or msg:match("^%.积分%s+(.+)$") or msg:match("^%.scoreboard%s+(.+)$")
    if board_input then
        if not is_admin(playerName) then
            send(playerName, "§c只有管理权限可以设置积分计分板名称。")
        elseif not valid_scoreboard_name(trim(board_input)) then
            send(playerName, "§c名称无效，只能使用英文、数字、下划线或短横线，且不能有空格。")
        else
            save_scoreboard_name(playerName, trim(board_input))
            send(playerName, "§a积分计分板名称已保存并覆盖为：" .. trim(board_input))
        end
        return
    end

    if low == ".解除封禁" then show_unban_menu(playerName,1); return end
    if low == ".soul" or low == "soul" then start_soul(playerName); return end
    if low == ".退出" then
        local d,r=player_record(playerName,true)
        if not r.soul then send(playerName,"§e你当前不在灵魂出窍状态。")
        else
            local loc=r.soul.location; local original=r.soul.original_mode or "survival"; r.soul=nil
            local ok2,err2=tp_to(playerName,loc); local mode_ok=set_gamemode(playerName,original); save_data(d)
            pcall(game.sendActionbar,playerName,"§a灵魂出窍已退出")
            if ok2 and mode_ok then send(playerName,"§a✓ 已退出灵魂出窍并返回原位置。") else send(playerName,"§e已退出灵魂出窍；返回位置："..(ok2 and "成功" or "失败").."，恢复模式："..(mode_ok and "成功" or "失败")) end
        end
        return
    end
    if low == ".签到" or low == "签到" then signin(playerName); return end
    if low == ".传送机会" then show_transfer_chances(playerName); return end
    if low == ".撤回权限" then show_permission_menu(playerName,"revoke"); return end
    if low == ".添加权限" then show_permission_menu(playerName,"grant"); return end
    local add_target=trim(msg:match("^%.添加权限%s+(.+)$") or "")
    if add_target~="" and playerName==SUPERUSER then pcall(game.sendCommand,'op "'..string.gsub(add_target,'"','\\"')..'"'); send(playerName,"§a✓ 已授予 "..add_target.." 管理权限。"); return end
    if low == "./tp" or low == "./tp 玩家" then show_tpa_targets(playerName); return end
    local tpa_target = msg:match("^%./tp%s+(.+)$")
    if tpa_target and trim(tpa_target) ~= "玩家" then submit_tpa(playerName, trim(tpa_target)); return end
    local tp_dim,tp_x,tp_y,tp_z=msg:match("^%.tp%s+(%S+)%s+(-?[%d%.]+)%s+(-?[%d%.]+)%s+(-?[%d%.]+)%s*$")
    if tp_dim then coordinate_tp_use(playerName,tp_dim,tp_x,tp_y,tp_z); return end
    if low==".tp" or low=="tp" then
        local d,r=player_record(playerName,true); local st=coordinate_tp_state(r)
        if is_admin(playerName) then
            r.menu="coord_tp_input"; r.menu_expires=util.timestamp()+MENU_TIMEOUT; save_data(d)
            send(playerName,"§b━━ 选坐标传送 ━━\n§a管理权限：次数无限。\n§f请在聊天框输入：维度 X Y Z\n§7例如：主世界 114 100 114")
        elseif st.available or (tonumber(st.extra_uses) or 0)>0 then
            r.menu="coord_tp_input"; r.menu_expires=util.timestamp()+MENU_TIMEOUT; save_data(d)
            send(playerName,"§b━━ 选坐标传送 ━━\n§a✓ 你有可用次数。\n§f请在聊天框输入：维度 X Y Z\n§7例如：主世界 114 100 114")
        else
            pcall(game.sendCommand,'playsound random.anvil_land "'..string.gsub(playerName,'"','\\"')..'"')
            send(playerName,"§c你没有坐标传送次数。\n§7每天现实24小时刷新一次；新玩家累计在线2小时后获得第一次机会。")
        end
        return
    end
    local tp_input_dim,tp_input_x,tp_input_y,tp_input_z=msg:match("^(%S+)%s+(-?[%d%.]+)%s+(-?[%d%.]+)%s+(-?[%d%.]+)%s*$")
    local d0,r0=player_record(playerName,true)
    if r0.menu=="coord_tp_input" and tp_input_dim then
        clear_menu(d0,r0); coordinate_tp_use(playerName,tp_input_dim,tp_input_x,tp_input_y,tp_input_z); return
    end

    -- .help 永远重新打开主菜单，避免旧菜单状态吞掉 .help。

    -- 全局快捷查询必须优先于菜单状态，避免旧菜单把命令吞掉。
    local seller_query=msg:match("^%.查看商家%s+(.+)$")
    if seller_query then show_seller_by_name(playerName,seller_query); return end
    local terr_raw=parse_territory_password_command(msg)
    if terr_raw then
        local pd,pr=player_record(playerName,true); local pending=pr.territory_pending_id; local t=pending and territory_db().items[tostring(pending)] or nil
        if t and not t.deleted and t.owner_uuid~=uuid_key(playerName) then
            local pass=normalize_password_input(terr_raw)
            local pcnt=select(1,password_ascii_digit_count(pass)); if not valid_six_digit_password(pass) then send(playerName,"§c领地密码必须是6位数字。你输入的有效数字为 "..tostring(pcnt).." 位。示例：.领地密码 114514"); return end
            local db=territory_db(); local key=uuid_key(playerName)..":"..tostring(t.id); db.entry_state=db.entry_state or {}; local st=db.entry_state[key] or {}
            local saved_pass=normalize_password_input(t.password_digits or t.password or "")
            if pass==saved_pass then st.allowed=true; st.allowed_at=util.timestamp(); st.allowed_until=nil; db.entry_state[key]=st; pr.territory_pending_id=nil; save_data(pd); territory_save(db); territory_protection_log({at=util.timestamp(),type="领地密码验证成功",player=playerName,player_uuid=uuid_key(playerName),territory_id=t.id,territory_name=t.name,permanent=true}); send(playerName,"§a密码正确，已永久允许你进入「"..tostring(t.name).."」领地。") else send(playerName,"§c密码错误，请重新输入6位数字密码。") end
        else
            -- 创建流程中的密码输入仍交给 territory_create_password 菜单。
            if pr.menu=="territory_create_password" or pr.menu=="territory_password_edit" then
                if handle_menu(playerName,msg) then return end
            else send(playerName,"§e当前没有等待密码验证的他人领地，请先靠近领地边界5米内。"); end
        end
        return
    end

    -- 其他菜单处理
    if handle_menu(playerName, msg) then return end

    -- 传送点指令
    if low == ".回" or low == ".传" or low == ".home" then slot_menu(playerName, "return_slot"); return end
    if low == ".保存" or low == ".保" then slot_menu(playerName, "save_slot"); return end
    if low == ".删除" or low == ".删" then slot_menu(playerName, "delete_slot"); return end
    if low == "./tp 玩家" or low == "./tp" then show_tpa_targets(playerName); return end
    if handle_agree_tpa(playerName, msg) then return end
    if msg == ".死亡点返回" then
        local d, r = player_record(playerName, true)
        r.menu = nil
        save_data(d)
        if not r.death then
            send(playerName, "§c你还没有记录到死亡点。")
        else
            local ok, err = tp_to(playerName, r.death)
            send(playerName, ok and "§a✓ 已返回死亡点。" or "§c返回死亡点失败：" .. tostring(err))
        end
        return
    end

    -- ═══ 世界种子 / 真实结构查询器 ═══
    -- .种子                 查看当前种子
    -- .种子 <种子号>         设置/覆盖世界种子（管理权限）
    -- .种子账号 <账号> <密码> 绑定真实查询器账号（管理权限）
    -- .种子状态             查看查询器登录/连通状态
    if msg:match("^%.种子账号") then
        if not is_admin(playerName) then send(playerName,"§c只有管理权限可以设置查询器账号。"); return end
        local acct,pwd = msg:match("^%.种子账号%s+(%S+)%s+(%S+)%s*$")
        if not acct then
            send(playerName,"§e用法：.种子账号 <账号> <密码>\n§7账号填你登录 Ds 平台（youyuanqi.dpdns.org）用的账号。")
            return
        end
        set_seed_engine_cred(acct,pwd)
        local tk,err=seed_engine_login()
        if tk then send(playerName,"§a✓ 查询器账号已保存并登录成功。\n§7现在可直接用 §f.结构 村庄§7 查询。")
        else send(playerName,"§e账号已保存，但登录失败：§f"..tostring(err)) end
        return
    end
    if msg:match("^%.种子状态") then
        local base=seed_engine_base()
        local acct=select(1,seed_engine_cred())
        -- 先做一次登录测试，再用测试结果决定“令牌”那一行，避免显示与实际不符。
        local test_line=nil
        if is_admin(playerName) and acct~="" then
            local tk,err=seed_engine_login()
            test_line= tk and "§a✓ 登录测试通过（令牌已缓存）" or ("§c登录测试失败："..tostring(err))
        end
        local tok=seed_engine_token()
        local lines={"§b━━ 结构查询器状态 ━━","§f地址：§e"..base,
            "§f账号：§e"..(acct~="" and acct or "§c未配置"),
            "§f令牌：§e"..(tok and "已登录/有效" or "§c未登录"),
            "§f世界种子：§e"..(get_server_seed() or "§c未设置"),
            "§8说明：.结构 走游戏内 /locate，不需要这里的账号；"..
            "\n§8这些配置只在外部查询器可用时作兜底。"}
        if test_line then lines[#lines+1]=test_line end
        send(playerName,table.concat(lines,"\n"))
        return
    end
    local seed_value = trim(msg:match("^%.种子%s+(.+)$") or "")
    if low == ".种子" then
        local cur=get_server_seed()
        send(playerName,"§b━━ 世界种子 ━━\n§f当前种子：§e"..(cur or "§c未设置")..
            "\n§f设置：§e.种子 <种子号>§7（管理权限）\n§f查询结构：§e.结构 村庄§7（游戏内定位，不需要账号）\n§f查询器状态：§e.种子状态")
        return
    end
    if seed_value ~= "" then
        if not is_admin(playerName) then
            send(playerName, "§c只有管理权限可以设置世界种子。")
        elseif not valid_seed(seed_value) then
            send(playerName, "§c种子号无效，请输入基岩版的有符号整数后重新使用 .种子。")
        else
            set_server_seed(playerName, seed_value)
            send(playerName, "§a✓ 世界种子已保存：§e"..seed_value.."\n§7结构查询将按该种子进行。可输入 §f.结构 村庄§7 试查。")
        end
        return
    end

    local structure_name, structure_radius
    if low == ".结构" or low == ".查结构" then
        -- 不带参数时默认查询最近村庄，降低首次使用门槛。
        structure_name = "村庄"
        structure_radius = tostring(SEED_FINDER_DEFAULT_RADIUS)
    else
        structure_name, structure_radius = msg:match("^%.查结构%s+([^%s]+)%s*(%d*)$")
        if not structure_name then
            structure_name, structure_radius = msg:match("^%.结构%s+([^%s]+)%s*(%d*)$")
        end
    end
    if structure_name then
        send(playerName,"§b[结构定位] §f正在定位，请稍候……")
        send(playerName, query_seed_structure(playerName, structure_name, structure_radius))
        return
    end

    -- 投票表决只接受两个明确输入：同意/1，或者不同意/0。
    -- 不再调用任何额外模型；原有半数、超时和执行机制保持不变。
    if next(load_data().votes or {}) ~= nil then
        local vote_text = trim(msg)
        if vote_text == "同意" or vote_text == "1" then
            if process_vote_decision(playerName, true) then return end
        elseif vote_text == "不同意" or vote_text == "0" then
            if process_vote_decision(playerName, false) then return end
        end
    end

    if low:sub(1,9)==".封禁商店" and is_admin(playerName) then local arg=trim(msg:sub(10)); local id=tonumber(arg); local db=market_db(); if id then local v=db.listings[tostring(id)]; if v then v.disabled=true; db.listings[tostring(id)]=v; market_save(db); send(playerName,"§a已封禁商品 "..id.."。数据库保留，购买界面不再显示。") else send(playerName,"§c商品编号不存在。"); end else send(playerName,"§e管理权限可使用 .封禁商店 商品编号 暂时下架单件商品。\n§7完整商铺封禁可在 .help → 12 → 8 中处理。") end; return end
    if low==".购物日志" then local pd,pr=player_record(playerName,true); local pl=purchase_log_db(); local lines={"§b━━ 我的购物日志 ━━"}; local count=0; for i=#(pl.logs or {}),1,-1 do local x=pl.logs[i]; if x.buyer_uuid==uuid_key(playerName) then count=count+1; if #lines<12 then table.insert(lines,"§f"..os.date("%Y-%m-%d %H:%M",tonumber(x.at) or 0).." §7| §e"..tostring(x.item).." §7| §6"..tostring(x.price).."金币") end end end; if count==0 then table.insert(lines,"§e暂未购物，期待你的第一次购物。"); else table.insert(lines,"§7共购买 "..count.." 件商品。"); end; send(playerName,table.concat(lines,"\n")); return end
    if low==".出售物品" then fixed_shop_begin(playerName); return end
    if low==".售卖物品" or low==".售卖商品" then market_sell_begin(playerName); return end
    if low==".购物" then full_shop_buy_main(playerName); return end
    if low==".购物系统" or low==".购买物品" then fixed_shop_show(playerName); return end
    if low==".玩家市场" or low==".市场" then show_player_market_main(playerName); return end
    local storage_arg=msg:match("^%.市场仓库%s+(.+)$"); if storage_arg then local a,b,c=storage_arg:match("^%s*(-?%d+)%s+(-?%d+)%s+(-?%d+)%s*$"); if not a then send(playerName,"§c格式：.市场仓库 X Y Z") else market_storage_set(playerName,tonumber(a),tonumber(b),tonumber(c)) end; return end
    if low==".市场仓库" then send(playerName,"§e管理权限用法：.市场仓库 X Y Z（只需设置一次）"); return end
    local report_id=msg:match("^%.举报商品%s+(%d+)$") or msg:match("^%.商品举报%s+(%d+)$")
    if report_id then local db=market_db(); local v=db.listings[tostring(report_id)]; if not v then send(playerName,"§c商品编号不存在。"); return end; db.reports[tostring(report_id)]=db.reports[tostring(report_id)] or {count=0,users={}}; local q=db.reports[tostring(report_id)]; q.users=q.users or {}; local uid=uuid_key(playerName); if q.users[uid] then send(playerName,"§c你已经举报过这个商品。"); return end; q.users[uid]=true; q.count=(tonumber(q.count)or 0)+1; if q.count>=5 then v.disabled=true; db.listings[tostring(report_id)]=v end; market_save(db); send(playerName,"§a商品举报已记录。当前举报数："..q.count.."；"..(q.count>=5 and "商品已自动下架。" or "感谢反馈。")); return end
    local inspect_id=msg:match("^%.查验%s+(%d+)$")
    if inspect_id then return market_show_preview(playerName,inspect_id) end
    if low==".领地保护" or low==".领地" then show_territory(playerName); return end

    -- ═══ 全服 AI 总设定：管理员下发后，所有玩家、所有 AI 会话一律遵守 ═══
    do
        local gclear = msg:match("^%.AI%s+清空所有AI设定%s*$") or msg:match("^%.AI%s+清除所有AI设定%s*$")
        local gdel = msg:match("^%.AI%s+删除所有AI设定%s*(%d+)$")
            or msg:match("^%.AI%s+移除所有AI设定%s*(%d+)$")
            or msg:match("^%.全服AI设定%s+删除%s*(%d+)$")
            or msg:match("^%.全服AI设定%s+移除%s*(%d+)$")
        local gbody = nil
        if not gclear and not gdel then
            gbody = msg:match("^%.AI%s+修改所有AI设定%s*(.*)$")
                or msg:match("^%.全服AI设定%s*(.*)$")
                or msg:match("^%.全局AI设定%s*(.*)$")
        end
        if gclear or gdel or gbody ~= nil then
            if not is_admin(playerName) then
                send(playerName,"§c只有管理权限可以修改全服 AI 总设定。")
                return
            end
            if gdel then
                local okd, left = remove_global_ai_rule(gdel)
                if okd then send(playerName, "§a已删除第 " .. tostring(gdel) .. " 条；剩余 " .. tostring(left) .. " 条。")
                else send(playerName, "§c编号不存在。") end
                return
            end
            local body = trim(gbody or "")
            if body == "清空" or body == "清除" or body == "全部清空" or body == "全部清除" then
                gclear = true
            end
            if gclear then
                save_global_ai_rules({rules={},updated_at=util.timestamp(),updated_by=playerName})
                broadcast("§e[AI] 管理权限已清空全服 AI 总设定。")
                return
            end
            if body == "" or body == "查看" or body == "列表" or body == "查询" then
                local gd = load_global_ai_rules()
                local lines = {"§b━━ 全服 AI 总设定 ━━"}
                if #(gd.rules or {}) == 0 then
                    lines[#lines+1] = "§7当前没有任何全服设定。"
                else
                    for i, r in ipairs(gd.rules) do
                        lines[#lines+1] = string.format("§f%d. §7%s §8(%s)", i, tostring(r.text), tostring(r.by or "?"))
                    end
                end
                lines[#lines+1] = "§e添加：§f.AI 修改所有AI设定 <内容>"
                lines[#lines+1] = "§e删除：§f.AI 删除所有AI设定 <编号>   §e清空：§f.AI 清空所有AI设定"
                lines[#lines+1] = "§7设定对所有玩家、所有 AI 窗口立即生效。"
                send(playerName, table.concat(lines, "\n"))
                return
            end
            local del = body:match("^删除%s*(%d+)$") or body:match("^移除%s*(%d+)$")
            if del then
                local okd, left = remove_global_ai_rule(del)
                if okd then send(playerName, "§a已删除第 " .. tostring(del) .. " 条；剩余 " .. tostring(left) .. " 条。")
                else send(playerName, "§c编号不存在。") end
                return
            end
            local added, total = add_global_ai_rule(playerName, body)
            if added then
                broadcast("§a[AI] 全服 AI 总设定已更新（第 " .. tostring(total) .. " 条），对所有玩家立即生效。")
            else
                send(playerName, "§c内容不能为空。")
            end
            return
        end
    end

    -- ═══ 死亡点查看：只显示最近 5 条 ═══
    if low == ".死亡点" or low == ".我的死亡点" then
        local d, r = player_record(playerName, true)
        if not r.death then
            send(playerName, "§e你还没有记录到死亡点。§7死亡后会自动记录最后一次死亡坐标，只私信给你本人。")
            return
        end
        local lines = {
            "§b━━ 我的死亡点 ━━",
            string.format("§f最近死亡：§e%d, %d, %d §7| §b%s",
                math.floor(tonumber(r.death.x) or 0), math.floor(tonumber(r.death.y) or 0), math.floor(tonumber(r.death.z) or 0),
                dimension_display(r.death.dimension)),
            "§f记录时间：§7" .. tostring(r.death.saved_at or "未知"),
            "§f返回：§e.死亡点返回",
            "§b── 最近 5 条死亡记录 ──",
        }
        local hist = r.death_history or {}
        local shown = 0
        for i = #hist, 1, -1 do
            shown = shown + 1
            if shown > 5 then break end
            local h = hist[i]
            lines[#lines+1] = string.format("§7%d. §f%d, %d, %d §8%s §7%s", shown,
                math.floor(tonumber(h.x) or 0), math.floor(tonumber(h.y) or 0), math.floor(tonumber(h.z) or 0),
                dimension_display(h.dimension), tostring(h.saved_at or ""))
        end
        if shown == 0 then lines[#lines+1] = "§7暂无历史记录。" end
        lines[#lines+1] = "§7累计死亡：§e" .. tostring(r.death_count or shown) .. "§7 次"
        send(playerName, table.concat(lines, "\n"))
        return
    end

    -- ═══ 背包查看：走原生 codebuilder_actorinfo inventory 通道 ═══
    -- 框架 game.queryInventory 字段不匹配（永远 items=null），
    -- 这里改用订阅 CommandOutput 的方式读取真实背包。
    -- 管理员查询 = 全服公布；普通玩家只能查自己（私聊）。
    local bag_target = nil
    if low == ".背包" or low == "背包" then
        bag_target = ""
    else
        bag_target = msg:match("^%.背包%s+(.+)$")
    end
    if bag_target ~= nil then
        bag_target = trim(bag_target or "")
        if bag_target == "" then bag_target = playerName end
        if not is_admin(playerName) and lower(bag_target) ~= lower(playerName) then
            send(playerName, "§c只有管理权限可以查看其他玩家的背包。")
            return
        end
        local to_all = is_admin(playerName)
        if not to_all then send(playerName, "§b[背包] §f正在读取 §e" .. bag_target .. " §f的背包……") end
        inv_request(playerName, bag_target, "chat", to_all)
        return
    end

    -- ═══ 管理员禁言：.禁言 玩家名 时长（秒/分钟/小时/天/永久；0=解除）═══
    local mute_arg = msg:match("^%.禁言%s+(.+)$") or msg:match("^%.mute%s+(.+)$")
    if mute_arg then
        if not is_admin(playerName) then
            send(playerName,"§c只有管理权限可以使用禁言。")
            return
        end
        send(playerName, ai_mute_player(mute_arg, nil, playerName))
        return
    end

    -- ═══ 区块边缘容器保护：状态 / 开关 / 校准（管理权限）═══
    if low==".区块保护" or low==".边缘保护" or low==".区块保护状态" then
        if not is_admin(playerName) then send(playerName,"§c只有管理权限可以查看区块保护状态。"); return end
        local d=edge_guard_db()
        local calib=(d.calib and d.calib.done==true) and "校准完成" or "正在校准…"
        send(playerName,"§b区块边缘容器保护：§f"..(edge_guard_enabled() and "§a已开启" or "§c已关闭")..
            "\n§7容器识别表：§e"..tostring(edge_map_count()).."§7/§e"..#EDGE_CONTAINER_LIST.."§7（"..calib.."）"..
            "\n§7拦截范围：§e区块边缘 "..tostring(EDGE_GUARD_WIDTH).." 格宽§7（%16 为 0/1/14/15）"..
            "\n§7开关：.区块保护 开 / .区块保护 关"..
            "\n§7重校：.区块保护 校准"..
            "\n§7作用：落在区块边缘 2 格内的箱子/木桶会被立即清除，防止刷物品。")
        return
    end
    local edge_sw = msg:match("^%.区块保护%s+(%S+)$") or msg:match("^%.边缘保护%s+(%S+)$")
    if edge_sw then
        if not is_admin(playerName) then send(playerName,"§c只有管理权限可以切换区块保护。"); return end
        local v=lower(trim(edge_sw))
        if v=="开" or v=="开启" or v=="on" or v=="1" then
            set_edge_guard(true)
            send(playerName,"§a✓ 区块边缘容器保护已开启。")
        elseif v=="关" or v=="关闭" or v=="off" or v=="0" then
            set_edge_guard(false)
            send(playerName,"§e区块边缘容器保护已关闭。")
        elseif v=="校准" or v=="重新校准" or v=="recalib" then
            local d=edge_guard_db()
            d.map={}
            d.calib={index=0,pending="",retry=0,done=false}
            edge_guard_save(d)
            send(playerName,"§b已开始重新校准容器识别表（箱子+木桶，约 3 秒）；校准完成前拦截可能不生效。")
        else
            send(playerName,"§c用法：.区块保护 开 / .区块保护 关 / .区块保护 校准")
        end
        return
    end
    if low==".ai设定 清除" then save_ai_persona(playerName,""); send(playerName,"§e人物设定已清除。"); return end
    local persona_cmd=msg:match("^%.AI设定%s+(.+)$") or msg:match("^%.ai设定%s+(.+)$")
    if persona_cmd then save_ai_persona(playerName,trim(persona_cmd)); send(playerName,"§a人物设定已保存。之后AI会持续采用，直到你修改或清除。"); return end

    if low==".ai诊断" then
        local ok,t=pcall(util.json_load,AI_TRACE_FILE)
        if ok and type(t)=="table" then send(playerName,"§b━━ AI最近诊断 ━━\n§f模型："..tostring(t.model or "未知").."\n§f状态："..tostring(t.status or "未知").."\n§fHTTP："..tostring(t.status_code or "无").."\n§f原因："..tostring(t.reason or "无").."\n§f结束原因："..tostring(t.finish_reason or "无").."\n§fAI实际输出：\n§7"..(tostring(t.assistant_output or "")=="" and "<空>" or tostring(t.assistant_output)).."\n§f服务器工具结果：\n§7"..(tostring(t.tool_result or "")=="" and "<无>" or tostring(t.tool_result)).."\n§f原始HTTP返回：\n§7"..(tostring(t.raw_body or "")=="" and "<无>" or tostring(t.raw_body):sub(1,1200)).."\n§7不显示模型隐藏思维链，只显示真实API返回、工具结果和错误。") else send(playerName,"§e暂无AI诊断记录。") end
        return
    end

    -- AI入口：普通聊天统一使用 ai / AI；“指令 ”仍是独立的指令AI入口。
    -- ./ 不再触发AI，./tp 只作为原有玩家传送入口。
    local question, commandMode, publicReply = nil, false, false

    if msg:sub(1, #COMMAND_WORD) == COMMAND_WORD then
        question = trim(msg:sub(#COMMAND_WORD + 1))
        commandMode = true
    elseif low:sub(1, 3) == "ai " then
        question = trim(msg:sub(4))
        publicReply = (msg:sub(1, 3) == "AI ")
    end

    if not question or question == "" then return end

    local memory_cmd = lower(trim(question))
    if memory_cmd == "清除记忆" or memory_cmd == "清空记忆" or memory_cmd == "清除聊天记忆" or memory_cmd == "忘记之前的聊天" then
        clear_ai_memory(playerName)
        if publicReply then broadcast("§b[Ds] §f已切换新窗口") else send(playerName,"§b[Ds] §f已切换新窗口") end
        return
    end

    local function ai_notice(text)
        if publicReply then broadcast(text) else send(playerName, text) end
    end

    -- 普通玩家每小时最多10次真正的AI请求；管理员无上限。
    -- 只有确定进入AI请求后才计数，菜单、普通聊天、记忆清除等不占额度。
    if not ai_hourly_quota_check(playerName) then return end

    -- One thinking notice only; multi-round tool processing stays out of chat.
    ai_notice("§b[Ds] §f正在思考中……")
    local ok, reply = pcall(run_agent, question, playerName, commandMode, commandMode and "command" or "chat")

    if not ok then
        local err=tostring(reply)
        save_ai_trace({model=tostring(choose_ai_model(question,commandMode) or "unknown"),status="exception",status_code="",reason=err,assistant_output=""})
        if string.find(lower(err),"timeout",1,true) or string.find(lower(err),"timed out",1,true) or string.find(err,"超时",1,true) then
            ai_notice("§c[Ds] 思考超时 已断开")
        else
            ai_notice("§c[Ds] 本次请求暂时未完成，请稍后重试。")
        end
        return
    end
    if not reply or trim(reply)=="" then
        ai_notice("§c[Ds] 本次请求没有得到有效结果，请换一种说法再试。")
    else
        ai_notice("§b[Ds] §f" .. reply)
    end
end


-- （云备份 cloud_backup_tick / cloud_read_text / cloud_trim_logs 已按需求移除，不再向公网定时上传数据）
function on_join(name)
    if enforce_blacklist(name) then return end
    log_event("PLAYER", tostring(name) .. " joined")
    local d,r=player_record(name,true); r.name=name; r.online_since=util.timestamp()
    coordinate_tp_state(r); save_data(d)
    market_settle_offline(name)
end
function on_leave(name)
    local d,r=player_record(name,true); local now=util.timestamp(); local since=tonumber(r.online_since)
    if since and now>=since then r.online_seconds=(tonumber(r.online_seconds) or 0)+(now-since) end
    r.online_since=nil; r.last_offline_at=now; save_data(d)
end

function on_announcement_tick()
    broadcast("§6━━━━━━━━━━━━━━━━━━━━\n§eDs 服务器功能提示\n§f输入 .help 查看玩法；菜单、传送申请和转账都有时间限制。\n§b聊天框输入 .help 可能会有惊喜！\n§6━━━━━━━━━━━━━━━━━━━━")
end

function on_init()
    pcall(game.setConfigDefault, {
        ai_key = "",
        ai_model = AI_MODEL,
        ai_thinking = false,
        deepseek_key = "",
        deepseek_url = DEEPSEEK_URL,
        web_search_key = "",
        web_search_url = WEB_SEARCH_URL,
        web_search_model = WEB_SEARCH_MODEL,
        seed_engine_url = SEED_FINDER_URL,
        seed_engine_account = "",
        seed_engine_password = "",
        seed_engine_token = "",
        qq_enabled = false,
        qq_group_id = "1083036035",
        qq_relay_url = "",
        qq_token = "",
        qq_admin_ids = "",
        qq_poll_interval = 5,
    })
    -- 插件每次重新启动/替换后都开启新的AI窗口，避免继续读取上一次运行遗留的20轮上下文。
    local session_id=reset_ai_session_on_plugin_start()
    init_scoreboard()
    -- 自愈：插件目录若还没有 defaults.json，用现有数据文件生成一份（方便随插件一起备份/拷贝）。
    pcall(ensure_defaults_json)
    log_event("SYSTEM", "plugin initialized; new AI session="..tostring(session_id))
end

-- ════════════════════════════════════════════════════════════
--   事件注册
-- ════════════════════════════════════════════════════════════

events.onChat("on_chat")
events.onBotReady("on_init")
events.onJoin("on_join")
events.onLeave("on_leave")
events.subscribe("PyRpc", "on_pyrpc")
events.subscribe("CommandOutput", "on_command_output")
events.subscribe("BlockActorData", "on_block_actor")
events.subscribe("UpdateBlock", "on_update_block")
util.schedule(VOTE_CHECK_INTERVAL, "on_vote_tick")           -- 投票超时检查
util.schedule(10, "expire_system_state")                     -- 菜单/会话超时
util.schedule(3, "tick_territories")                         -- 领地保护
util.schedule(2, "tick_coordinate_and_soul")                 -- 灵魂出窍/传送次数
util.schedule(DEATH_FALLBACK_INTERVAL, "tick_death_fallback")-- 死亡点兜底
util.schedule(CHAT_MUTE_TICK, "tick_chat_mute_fast")         -- 禁言高频约束（保持原有 0.0125 秒设定）
util.schedule(2, "tick_chat_mute")                           -- 禁言解除
util.schedule(10, "qq_tick")                                 -- QQ 轮询
util.schedule(2, "flush_log_buffer")                         -- 日志缓冲合并
util.schedule(ANNOUNCEMENT_INTERVAL, "on_announcement_tick")
util.schedule(0.7, "edge_calib_tick")                         -- 区块保护：容器运行时ID自动校准

-- （文件桥 / 云文件桥已按需求移除：插件不再周期向 /storage/emulated/0/ds_bridge 写任何文件）

-- ════════════════════════════════════════════════════════════
--   远程控制桥（可选功能；默认关闭，配置 remote_token 后启用）
--   供外部程序（Codex / 脚本）通过工具箱网页服务驱动游戏：
--     POST http://<设备IP>:8080/web/api/ds_ai_agent/remote?action=cmd&token=XXX&command=list
--   动作：cmd / players / logs / call / info
-- ════════════════════════════════════════════════════════════
function remote_token()
    return tostring(game.getConfig("remote_token", "") or "")
end
function remote_enabled()
    return remote_token() ~= ""
end
function remote_guard(payload)
    if not remote_enabled() then return false, "远程控制未启用：请在插件配置里设置 remote_token" end
    local t = (type(payload) == "table") and tostring(payload.token or "") or ""
    if t ~= remote_token() then return false, "口令错误" end
    return true, nil
end

function remote_cmd(payload)
    local ok, err = remote_guard(payload); if not ok then return {ok=false, error=err} end
    local cmd = (type(payload) == "table") and tostring(payload.command or "") or ""
    if cmd == "" then return {ok=false, error="缺少 command 参数"} end
    local to = (type(payload) == "table") and tonumber(payload.timeout) or 8
    local pok, res = pcall(game.sendCommandWithResp, cmd, "ai", to or 8)
    if not pok then return {ok=false, error=tostring(res)} end
    log_event("REMOTE", "cmd: " .. cmd)
    return {ok=true, command=cmd, success=res and res.success, messages=(res and res.messages) or {}}
end

function remote_players(payload)
    local ok, err = remote_guard(payload); if not ok then return {ok=false, error=err} end
    return {ok=true, names=online_players() or {}, list=player.list()}
end

function remote_logs(payload)
    local ok, err = remote_guard(payload); if not ok then return {ok=false, error=err} end
    local n = (type(payload) == "table") and tonumber(payload.lines) or 80
    n = n or 80
    local pok, txt = pcall(util.read_file, LOG_FILE)
    if not pok or type(txt) ~= "string" then return {ok=false, error="读取 runtime.log 失败"} end
    local arr = {}
    for line in txt:gmatch("[^\r\n]+") do arr[#arr+1] = line end
    local out = {}
    for i = math.max(1, #arr - n + 1), #arr do out[#out+1] = arr[i] end
    return {ok=true, lines=out}
end

function remote_call(payload)
    local ok, err = remote_guard(payload); if not ok then return {ok=false, error=err} end
    if type(payload) ~= "table" then return {ok=false, error="缺少参数"} end
    local fn = tostring(payload.func or "")
    if fn == "" then return {ok=false, error="缺少 func 参数"} end
    local f = _G[fn]
    if type(f) ~= "function" and plugin_api then
        local pa = plugin_api[fn]
        if type(pa) == "function" then f = pa end
    end
    if type(f) ~= "function" then return {ok=false, error="没有这个函数：" .. fn} end
    local up = table.unpack or unpack
    local a = (type(payload.args) == "table") and payload.args or {}
    local pok, r = pcall(f, up(a))
    if not pok then return {ok=false, error=tostring(r)} end
    if type(r) ~= "table" then return {ok=true, result=r} end
    return {ok=true, result=r}
end

function remote_info(payload)
    return {ok=true, plugin="ds_ai_agent", bridge="v1", enabled=remote_enabled(),
            time=util.now(), players=online_players() or {},
            seed=get_server_seed(), area=SEED_STRUCTURE_IDS and "ok" or "noload"}
end

-- 注册网页接口。包 pcall 是为了兼容"同插件页面名重复注册会抛异常"的行为，
-- 避免某次加载时因为页面已存在而中断整个插件脚本。
pcall(web.page, "remote", "远程控制桥")
pcall(web.action, "remote", "cmd", "remote_cmd")
pcall(web.action, "remote", "players", "remote_players")
pcall(web.action, "remote", "logs", "remote_logs")
pcall(web.action, "remote", "call", "remote_call")
pcall(web.action, "remote", "info", "remote_info")


-- ════════════════════════════════════════════════════════════
--   跨插件 / 查询模块接口（死亡点）
--   放在文件末尾，确保不会被其它 plugin_api 定义覆盖。
--   调用示例：
--     local agent = api.require("ds_ai_agent")
--     agent.get_death_point("玩家名")   -- {x,y,z,dimension,saved_at,reason}
--     agent.get_death_count("玩家名")   -- 死亡次数
--     agent.get_death_history("玩家名", 10)
--     agent.get_last_position("玩家名") -- 最后已知坐标
-- ════════════════════════════════════════════════════════════
plugin_api = plugin_api or {}
plugin_api.get_death_point = function(name)
    local d=load_data(); local key=identity(name); local r=d.players and d.players[key]
    return r and r.death or nil
end
plugin_api.get_death_count = function(name)
    local d=load_data(); local key=identity(name); local r=d.players and d.players[key]
    return (r and tonumber(r.death_count)) or 0
end
plugin_api.get_death_history = function(name, limit)
    local d=load_data(); local key=identity(name); local r=d.players and d.players[key]
    local arr=(r and r.death_history) or {}
    limit=tonumber(limit) or 10
    local out={}
    for i=#arr,1,-1 do out[#out+1]=arr[i]; if #out>=limit then break end end
    return out
end
plugin_api.get_last_position = function(name)
    local d=load_data(); local key=identity(name); local r=d.players and d.players[key]
    return r and r.last_pos or nil
end

-- ════════════════════════════════════════════════════════════
--   打包工具：把插件本体 + 配套文件打成 zip（纯 Lua 生成，不依赖系统 zip）
--   只生成「存储」方式（无压缩）的 ZIP：本地头 + 中央目录 + EOCD，规范可解压。
-- ════════════════════════════════════════════════════════════
function zip_u16(n)
    n=math.floor(tonumber(n) or 0)%65536
    return string.char(n%256, math.floor(n/256)%256)
end
function zip_u32(n)
    n=math.floor(tonumber(n) or 0)%4294967296
    return string.char(n%256, math.floor(n/256)%256, math.floor(n/65536)%256, math.floor(n/16777216)%256)
end
function zip_bxor(a,b)
    a=math.floor(tonumber(a) or 0); b=math.floor(tonumber(b) or 0)
    local r,bit=0,1
    for _=1,32 do
        local x=a%2; local y=b%2
        if x~=y then r=r+bit end
        a=(a-x)/2; b=(b-y)/2; bit=bit*2
    end
    return r
end
ZIP_CRC_TABLE=nil
function zip_crc32(s)
    if not ZIP_CRC_TABLE then
        local t={}
        for i=0,255 do
            local c=i
            for _=1,8 do
                if c%2==1 then c=zip_bxor(3988292384, math.floor(c/2)) else c=math.floor(c/2) end
            end
            t[i]=c
        end
        ZIP_CRC_TABLE=t
    end
    local crc=4294967295
    for i=1,#s do
        local idx=zip_bxor(crc, s:byte(i))%256
        crc=zip_bxor(ZIP_CRC_TABLE[math.floor(idx)], math.floor(crc/256))
    end
    return zip_bxor(crc,4294967295)
end
function zip_build(files)
    local locals_parts,central_parts={},{}
    local offset=0
    for _,f in ipairs(files) do
        local name=tostring(f.name or "")
        local data=tostring(f.data or "")
        local crc=zip_crc32(data)
        local size=#data
        local lh=string.char(80,75,3,4)..zip_u16(20)..zip_u16(2048)..zip_u16(0)..zip_u16(0)..zip_u16(33)
            ..zip_u32(crc)..zip_u32(size)..zip_u32(size)..zip_u16(#name)..zip_u16(0)..name
        locals_parts[#locals_parts+1]=lh
        locals_parts[#locals_parts+1]=data
        central_parts[#central_parts+1]=string.char(80,75,1,2)..zip_u16(20)..zip_u16(20)..zip_u16(2048)..zip_u16(0)..zip_u16(0)..zip_u16(33)
            ..zip_u32(crc)..zip_u32(size)..zip_u32(size)..zip_u16(#name)..zip_u16(0)..zip_u16(0)..zip_u16(0)..zip_u16(0)..zip_u32(0)..zip_u32(offset)..name
        offset=offset+#lh+size
    end
    local cd=table.concat(central_parts)
    local eocd=string.char(80,75,5,6)..zip_u16(0)..zip_u16(0)..zip_u16(#files)..zip_u16(#files)..zip_u32(#cd)..zip_u32(offset)..zip_u16(0)
    return table.concat(locals_parts)..cd..eocd
end
function pack_read_first(paths)
    for _,p in ipairs(paths or {}) do
        local ok,data=pcall(util.read_file,p)
        if ok and type(data)=="string" and data~="" then return data,p end
    end
    return nil,nil
end
function pack_bundle_zip()
    local ddir=tostring(game.dataDir() or "")
    local base=ddir:gsub("/插件数据文件/[^/]*$","")
    if base==ddir or base=="" then base="/data/user/0/com.prismtool.box/files" end
    local pdir=base.."/插件文件/ds_ai_agent"
    local outdir="/storage/emulated/0/我的世界指令相关"
    local report={}

    local lua_data,lua_path=pack_read_first({pdir.."/ds_ai_agent.lua"})
    local man_data=pack_read_first({pdir.."/ds_ai_agent.manifest.json",pdir.."/manifest.json"})
    local docs_data=pack_read_first({pdir.."/ds_ai_agent.docs.md",pdir.."/docs.md"})
    local cfg_data=pack_read_first({ddir.."/pack_config.json",base.."/插件配置文件/ds_ai_agent/ds_ai_agent.json"})
    report[#report+1]="main.lua <- "..tostring(lua_path or "未找到").." ("..tostring(lua_data and #lua_data or 0).." 字节)"
    report[#report+1]="manifest.json ("..tostring(man_data and #man_data or 0).." 字节)"
    report[#report+1]="docs.md ("..tostring(docs_data and #docs_data or 0).." 字节)"
    report[#report+1]="config.json ("..tostring(cfg_data and #cfg_data or 0).." 字节)"
    if not lua_data then return "打包失败：读不到插件源码（"..pdir.."）" end
    man_data=man_data or "{\n  \"id\": \"ds_ai_agent\",\n  \"name\": \"多功能插件\",\n  \"version\": \"1.0.14\",\n  \"type\": \"lua\",\n  \"author\": \"\",\n  \"description\": \"Ds 多功能插件\",\n  \"pre_plugins\": {}\n}\n"
    docs_data=docs_data or "# 多功能插件\n\n详见插件说明。\n"
    cfg_data=cfg_data or "{\n  \"ai_model\": \"deepseek-flash\"\n}\n"

    -- 把 4 张内置数据表导出成 defaults.json，放进插件文件目录（源码里不再含这 3000+ 行）。
    local def_payload = {
        item_names = default_item_names(),
        item_damage_names = default_item_damage_names(),
        sell_prices = default_sell_prices(),
        full_shop_prices = default_full_shop_prices(),
    }
    local def_json = http.json_encode(def_payload)
    local wok,werr = pcall(util.write_file, pdir.."/defaults.json", def_json)
    report[#report+1]="defaults.json ("..#def_json.." 字节, 写入插件目录="..tostring(wok)..")"
    if not wok then log_event("PACK","write defaults.json failed: "..tostring(werr)) end

    local z1=zip_build({
        {name="manifest.json",data=man_data},
        {name="main.lua",data=lua_data},
        {name="docs.md",data=docs_data},
        {name="config.json",data=cfg_data},
    })
    local ok1,err1=pcall(util.write_file,outdir.."/ds_ai_agent.zip",z1)
    if ok1 then report[#report+1]="已写出 "..outdir.."/ds_ai_agent.zip ("..#z1.." 字节)"
    else report[#report+1]="写 ds_ai_agent.zip 失败："..tostring(err1) end

    local py=pack_read_first({ddir.."/qq_relay.py"})
    local pyreadme=pack_read_first({ddir.."/qq_readme.md"})
    if py then
        local z2=zip_build({
            {name="qq_relay.py",data=py},
            {name="README.md",data=pyreadme or "# QQ 群服互通中转程序\n"},
        })
        local ok2,err2=pcall(util.write_file,outdir.."/QQ群服互通.zip",z2)
        if ok2 then report[#report+1]="已写出 "..outdir.."/QQ群服互通.zip ("..#z2.." 字节)"
        else report[#report+1]="写 QQ群服互通.zip 失败："..tostring(err2) end
    else
        report[#report+1]="未找到 qq_relay.py，跳过 QQ 包"
    end

    -- 回读校验：确认落盘内容和签名正确
    local vok,vdata=pcall(util.read_file,outdir.."/ds_ai_agent.zip")
    if vok and type(vdata)=="string" and #vdata==#z1 and vdata:sub(1,4)==string.char(80,75,3,4) then
        report[#report+1]="回读校验通过：zip 大小/签名正确"
    else
        report[#report+1]="回读校验异常："..tostring(vok and (type(vdata)=="string" and #vdata or "非法数据") or vdata)
    end
    return table.concat(report,"\n")
end

-- ════════════════════════════════════════════════════════════
--   自检：确认默认大表惰性构造正常，并扫描源码里是否还有旧大表引用。
-- ════════════════════════════════════════════════════════════
function plugin_base_dir()
    local ddir=tostring(game.dataDir() or "")
    local base=ddir:gsub("/插件数据文件/[^/]*$","")
    if base==ddir or base=="" then base="/data/user/0/com.prismtool.box/files" end
    return base
end
function plugin_code_dir()
    return plugin_base_dir() .. "/插件文件/ds_ai_agent"
end

function _selftest_defaults()
    local out={}
    local function count(fn,label)
        local ok,v=pcall(fn)
        local n=0
        if ok and type(v)=="table" then for _ in pairs(v) do n=n+1 end end
        out[#out+1]=label.."="..n.." ok="..tostring(ok)
    end
    count(default_item_names,"item_names")
    count(default_item_damage_names,"damage_names")
    count(default_sell_prices,"sell_prices")
    count(default_full_shop_prices,"full_shop_prices")
    local ok5,c5=pcall(full_shop_catalog,"测试玩家")
    if ok5 and type(c5)=="table" then out[#out+1]="catalog="..#c5 else out[#out+1]="catalog_err="..tostring(c5) end
    local ok6,t6=pcall(translated_item_name,{Name="oak_log",Count=1})
    out[#out+1]="translate="..tostring(t6)
    local ok7,src=pcall(util.read_file, plugin_code_dir().."/ds_ai_agent.lua")
    if ok7 and type(src)=="string" then
        local lineno=0; local hits={}
        for raw in (src.."\n"):gmatch("([^\n]*)\n") do
            local line=raw:gsub("\r","")
            lineno=lineno+1
            if line:find("DEFAULT_ITEM_NAMES",1,true) or line:find("DEFAULT_SELL_PRICES",1,true) or line:find("DEFAULT_FULL_SHOP_PRICES",1,true) or line:find("DEFAULT_ITEM_DAMAGE_NAMES",1,true) then
                if #hits<40 then hits[#hits+1]=lineno..": "..line:sub(1,80) end
            end
        end
        out[#out+1]="source_lines="..lineno
        out[#out+1]="leftover_old_refs="..#hits
        for _,h in ipairs(hits) do out[#out+1]=h end
    else
        out[#out+1]="source_read_failed"
    end
    return table.concat(out,"\n")
end

-- ════════════════════════════════════════════════════════════
--   背包读取（修复框架 game.queryInventory 永远返回 items=null 的问题）
--
--   实测抓包结论（本服真实返回）：
--     codebuilder_actorinfo inventory <选择器>
--     → CommandOutput.data_set =
--       {"inventory":{"first":0,"last":35,"slotCount":36,
--          "slots":[{"aux":0,"id":"diamond","stackSize":57,"namespace":"minecraft",
--                    "maxStackSize":64,"freeStackSize":7,
--                    "enchantments":[{"level":4,"name":"保护 IV","type":0}]}, ...]},
--        "statusCode":0}
--
--   问题原因：
--     1) 框架 game.queryInventory 找的字段名和实际返回不一致 → 永远是 items=null；
--     2) game.sendCommandWithResp 只回传 messages，不回传 data_set → 同步调用也拿不到。
--   解决办法：订阅 CommandOutput 数据包，自己解析 data_set.inventory.slots。
-- ════════════════════════════════════════════════════════════
INV_REQ_FILE = game.dataDir() .. "/inv_request.json"
INV_REQ_TIMEOUT = 8

function inv_selector_of(target)
    local safe=string.gsub(tostring(target or ""),'"','\\"')
    return '@a[name="'..safe..'"]'
end

-- 发起一次背包读取：写等待标记 + 发命令。结果由 on_command_output 异步回发。
-- to_all=true 时结果全服公布（管理员查物品默认公布）。
function inv_request(playerName, target, tag, to_all)
    target=trim(target or "")
    if target=="" or lower(target)=="self" or lower(target)=="me" then target=playerName end
    pcall(util.json_write, INV_REQ_FILE, {
        player=tostring(playerName), target=tostring(target), tag=tostring(tag or "chat"),
        to_all=(to_all==true), selector=inv_selector_of(target), at=util.timestamp()
    })
    pcall(game.sendCommand, "codebuilder_actorinfo inventory " .. inv_selector_of(target))
    -- 兜底：3 秒后若仍没收到结果就自动重发一次（该命令偶发不返回）。
    pcall(util.setTimeout, 3, "inv_retry")
end

function inv_retry()
    local req=inv_pending()
    if not req then return end
    if (tonumber(req.retried) or 0) >= 1 then return end
    req.retried=1
    pcall(util.json_write, INV_REQ_FILE, req)
    pcall(game.sendCommand, "codebuilder_actorinfo inventory " .. (req.selector or inv_selector_of(req.target)))
end

function inv_pending()
    local ok,d=pcall(util.json_load, INV_REQ_FILE)
    if not ok or type(d)~="table" then return nil end
    if type(d.player)~="string" or d.player=="" then return nil end
    if (util.timestamp() - (tonumber(d.at) or 0)) > INV_REQ_TIMEOUT then return nil end
    return d
end

function inv_clear_pending()
    pcall(util.write_file, INV_REQ_FILE, "{}")
end

function inv_parse_slots(raw)
    local ok,d=pcall(http.json_decode, raw or "")
    if not ok or type(d)~="table" then return nil end
    local inv=d.inventory
    if type(inv)~="table" or type(inv.slots)~="table" then return nil end
    local items={}
    for idx,s in ipairs(inv.slots) do
        if type(s)=="table" then
            local id=tostring(s.id or "")
            local n=tonumber(s.stackSize) or 0
            if id~="" and n>0 then
                items[#items+1]={
                    slot=idx-1,
                    id=id,
                    name=(tostring(s.namespace or "minecraft")..":"..id),
                    count=n,
                    damage=tonumber(s.aux) or 0,
                    enchantments=s.enchantments,
                }
            end
        end
    end
    return items
end

function inv_ench_text(it)
    local e=it and it.enchantments
    if type(e)~="table" or #e==0 then return "" end
    local names={}
    for _,one in ipairs(e) do
        if type(one)=="table" and one.name then names[#names+1]=tostring(one.name) end
    end
    if #names==0 then return "" end
    return " §b["..table.concat(names,"，").."]"
end

-- 只取中文部分：物品名表里的格式是「中文 / English」，这里砍掉英文。
function short_item_name(item)
    local full=tostring(translated_item_name(item) or "")
    local cn=full:match("^(.-)%s*/%s*[%a]")
    if cn and trim(cn)~="" then return trim(cn) end
    return full
end

-- 排版：每行 3 个、最多 10 行（= 30 个），只显示中文，避免聊天框被截断。
function inv_format_items(items,per_line,max_lines)
    per_line=tonumber(per_line) or 3
    max_lines=tonumber(max_lines) or 10
    local max_items=per_line*max_lines
    local lines,row={},{}
    for i,it in ipairs(items or {}) do
        if i>max_items then break end
        local nm=short_item_name({name=it.name, damage=it.damage})
        local mark=""
        if (tonumber(it.damage) or 0)>0 then mark="§8*" end
        row[#row+1]=string.format("§f%s§7×§e%s%s",nm,tostring(it.count),mark)
        if #row>=per_line then lines[#lines+1]=table.concat(row,"   "); row={} end
    end
    if #row>0 then lines[#lines+1]=table.concat(row,"   ") end
    if #items>max_items then
        lines[#lines+1]="§7……另有 "..tostring(#items-max_items).." 种未显示"
    end
    return lines
end

function inv_send_result(player, target, items, to_all)
    local lines={"§b━━ "..tostring(target).." 的背包 ━━"}
    if type(items)~="table" or #items==0 then
        lines[#lines+1]="§7背包为空，或该玩家当前不在线。"
    else
        lines[#lines+1]="§7共 §e"..tostring(#items).." §7种物品"
        for _,l in ipairs(inv_format_items(items,3,10)) do lines[#lines+1]=l end
    end
    local text=table.concat(lines,"\n")
    if to_all==true then
        pcall(game.sendChat,"@a",text)
    else
        pcall(game.sendTargeted, player, text)
    end
end

-- CommandOutput 订阅：data_set 里不含 inventory 的高频响应（querytarget 等）立刻返回。
function on_command_output(data)
    if type(data)~="table" then return end
    local raw=data.data_set
    if type(raw)~="string" or raw=="" then return end
    if not string.find(raw,"inventory",1,true) then return end
    local req=inv_pending()
    if not req then inv_clear_pending(); return end
    local items=inv_parse_slots(raw)
    if not items then return end
    inv_clear_pending()
    inv_send_result(req.player, req.target, items, req.to_all==true)
    log_event("INVENTORY", tostring(req.player).." read "..tostring(req.target).." items="..tostring(#items))
end

-- ════════════════════════════════════════════════════════════
--   区块边缘容器拦截（防刷物品）
--
--   ⚠️ 本服实测结论（抓包验证）：
--     * 放置容器、往容器里放东西、离开区块再回来，服务器都【不】下发 BlockActorData，
--       所以"只订阅 BlockActorData"的旧实现永远不触发（实测：放在区块边缘的木桶不会被清）。
--     * 放置方块时服务器【一定】下发 UpdateBlock（含 position 与 new_block_runtime_id）。
--   因此改成：
--     1) 主触发 = UpdateBlock：运行时ID 命中容器 且坐标落在【区块边缘 2 格内】
--        （%16 为 0/1/14/15，宽度见 EDGE_GUARD_WIDTH）→ 立即 setblock air replace 清除；
--     2) 运行时ID 随游戏版本变化，插件启动后【自动校准】：在机器人脚下逐格放一遍容器，
--        抓 UpdateBlock 得到「运行时ID → 方块名」映射，写入 edge_guard.json，之后直接复用；
--     3) BlockActorData 保留为补充触发（部分服务器/容器会下发）。
--
--   命令：.区块保护           查看状态
--         .区块保护 开 / 关    开关
--         .区块保护 校准       重新校准运行时ID
-- ════════════════════════════════════════════════════════════
EDGE_GUARD_FILE = game.dataDir() .. "/edge_guard.json"
CONTAINER_BLOCK_IDS = {
    Chest=true, TrappedChest=true, Barrel=true, Hopper=true,
    Dispenser=true, Dropper=true, Crafter=true, Furnace=true,
    BlastFurnace=true, Smoker=true, BrewingStand=true,
    UndyedShulkerBox=true, EnderChest=true,
}

-- 需要校准/拦截的容器名单：按需求只保留 箱子 + 木桶（29 种太多，校准也慢）。
-- 想恢复更多容器，把方块名加回这个列表即可（校准会自动识别它们的运行时ID）。
EDGE_CONTAINER_LIST = {
    "chest","barrel",
}

function edge_guard_db()
    local ok,d=pcall(util.json_load,EDGE_GUARD_FILE)
    if ok and type(d)=="table" then
        d.map=d.map or {}
        d.calib=d.calib or {}
        return d
    end
    return {enabled=true,map={},calib={}}
end
function edge_guard_save(d) pcall(util.json_write,EDGE_GUARD_FILE,d) end
function edge_guard_enabled()
    local d=edge_guard_db()
    return d.enabled~=false
end
function set_edge_guard(v)
    local d=edge_guard_db(); d.enabled=(v==true); edge_guard_save(d)
end
function edge_map_count()
    local d=edge_guard_db(); local n=0
    for _ in pairs(d.map or {}) do n=n+1 end
    return n
end
-- 区块边缘判定：坐标距区块边界 EDGE_GUARD_WIDTH 格以内即算边缘（默认 2 格）。
-- 区块是 16×16；w=2 时命中的是 %16 为 0/1/14/15 的格子，也就是最外两圈。
-- Lua 的 % 对负坐标也返回非负值（例如 -1 % 16 == 15），所以负坐标同样判定正确。
EDGE_GUARD_WIDTH = 2
function edge_is_border(x,z)
    local w=EDGE_GUARD_WIDTH
    local mx,mz=x%16,z%16
    return (mx<w or mx>=(16-w) or mz<w or mz>=(16-w))
end
function edge_clear(x,y,z,why)
    pcall(game.sendCommand,string.format("setblock %d %d %d air replace",x,y,z))
    log_event("EDGE_GUARD","cleared "..tostring(why or "?").." at "..x.." "..y.." "..z)
end

-- 补充触发：BlockActorData（本服基本不发，保留兼容）
function on_block_actor(data)
    if type(data)~="table" then return end
    if not edge_guard_enabled() then return end
    local nbt=data.nbtdata
    if type(nbt)~="table" then return end
    local bid=tostring(nbt.id or "")
    if bid=="" then return end
    if not (CONTAINER_BLOCK_IDS[bid] or bid:find("ShulkerBox",1,true)) then return end
    local pos=data.position
    if type(pos)~="table" then return end
    local x,y,z=tonumber(pos[1]),tonumber(pos[2]),tonumber(pos[3])
    if not x or not y or not z then return end
    x,y,z=math.floor(x),math.floor(y),math.floor(z)
    if not edge_is_border(x,z) then return end
    edge_clear(x,y,z,bid)
end

-- 主触发：UpdateBlock {position={x,y,z}, new_block_runtime_id=N, flags=..}
function on_update_block(data)
    if type(data)~="table" then return end
    local pos=data.position
    if type(pos)~="table" then return end
    local x,y,z=tonumber(pos[1]),tonumber(pos[2]),tonumber(pos[3])
    if not x or not y or not z then return end
    x,y,z=math.floor(x),math.floor(y),math.floor(z)
    local rid=tostring(data.new_block_runtime_id or "")
    if rid=="" then return end
    local d=edge_guard_db()

    -- ① 校准进行中：把本次变化当作刚放下的校准方块
    local c=d.calib or {}
    if type(c.pending)=="string" and c.pending~="" then
        local age=(util.timestamp()-(tonumber(c.at) or 0))
        if age<=3 then
            local lx,ly,lz=tonumber(c.lx),tonumber(c.ly),tonumber(c.lz)
            local near=true
            if lx and ly and lz then
                near=(math.abs(x-lx)<=16 and math.abs(z-lz)<=16 and math.abs(y-ly)<=80)
            end
            if near then
                d.map[rid]=c.pending
                c.index=(tonumber(c.index) or 0)+1
                c.pending=""; c.at=util.timestamp(); c.retry=0
                c.lx,c.ly,c.lz=x,y,z
                d.calib=c
                edge_guard_save(d)
                pcall(game.sendCommand,string.format("setblock %d %d %d air replace",x,y,z))
                return
            end
        end
    end

    -- ② 正常拦截
    if not edge_guard_enabled() then return end
    local name=d.map[rid]
    if type(name)~="string" or name=="" then return end
    if not edge_is_border(x,z) then return end
    edge_clear(x,y,z,name)
end

-- 自动校准驱动：每 0.7 秒在机器人脚下放一个容器，抓 UpdateBlock 得到运行时ID
EDGE_CALIB_INTERVAL = 0.7
function edge_calib_tick()
    local d=edge_guard_db()
    local c=d.calib or {}
    if c.done==true then return end
    local idx=tonumber(c.index) or 0
    if idx>=#EDGE_CONTAINER_LIST then
        c.done=true; c.pending=""; d.calib=c; edge_guard_save(d)
        log_event("EDGE_GUARD","calibration finished, mapped="..tostring(edge_map_count()))
        return
    end
    if type(c.pending)=="string" and c.pending~="" then
        local age=util.timestamp()-(tonumber(c.at) or 0)
        if age<=3 then return end
        c.retry=(tonumber(c.retry) or 0)+1
        if c.retry>2 then
            c.index=idx+1; c.retry=0; c.pending=""; d.calib=c; edge_guard_save(d)
            return
        end
        c.at=util.timestamp(); d.calib=c; edge_guard_save(d)
        pcall(game.sendCommand,"setblock ~ ~-4 ~ "..EDGE_CONTAINER_LIST[idx+1])
        return
    end
    local name=EDGE_CONTAINER_LIST[idx+1]
    c.pending=name; c.at=util.timestamp(); c.retry=0
    d.calib=c; edge_guard_save(d)
    pcall(game.sendCommand,"setblock ~ ~-4 ~ "..name)
end

-- ════════════════════════════════════════════════════════════
--   禁言（管理员 / AI 通用）
--   时长支持：秒 / 分钟 / 小时 / 天 / 永久；0 表示立即解除；-1 表示永久。
--   机制：给玩家加 tag=禁言，并把到期时间写入 chat_rate.json 的 mutes，
--        由 tick_chat_mute 到期自动移除 tag。
-- ════════════════════════════════════════════════════════════
function parse_mute_seconds(text)
    text=trim(text or "")
    if text=="" then return nil end
    if text=="永久" or text=="无限" or text=="永久禁言" or text=="inf" then return -1 end
    local patterns={
        {"(%d+)%s*天",86400},{"(%d+)%s*日",86400},
        {"(%d+)%s*小时",3600},{"(%d+)%s*时",3600},
        {"(%d+)%s*分钟",60},{"(%d+)%s*分",60},
        {"(%d+)%s*秒",1},{"(%d+)%s*[Ss]",1},
        {"(%d+)%s*[Mm]",60},{"(%d+)%s*[Hh]",3600},{"(%d+)%s*[Dd]",86400},
    }
    for _,p in ipairs(patterns) do
        local n=text:match(p[1])
        if n then local v=tonumber(n); if v and v>=0 then return v*p[2] end end
    end
    local bare=tonumber(text)
    if bare and bare>=0 then return bare end
    return nil
end

function mute_human(seconds)
    seconds=tonumber(seconds) or 0
    if seconds<0 then return "永久" end
    if seconds<60 then return tostring(math.floor(seconds)).."秒" end
    if seconds<3600 then return tostring(math.floor(seconds/60)).."分钟" end
    if seconds<86400 then return tostring(math.floor(seconds/3600)).."小时" end
    return tostring(math.floor(seconds/86400)).."天"
end

-- target 可以是「玩家名」，duration 为 nil 时从 target 里解析「玩家名 时长」。
function ai_mute_player(target, duration, by)
    target=trim(target or ""); duration=trim(duration or "")
    if duration=="" then
        local nm,dur=target:match("^(.+)%s+([^%s]+)$")
        if nm then target=trim(nm); duration=trim(dur) end
    end
    if target=="" then return "禁言失败：缺少玩家名。" end
    local secs=parse_mute_seconds(duration)
    if not secs then return "禁言失败：时长无法识别（可用：30秒 / 10分钟 / 2小时 / 3天 / 永久）。" end
    local d=chat_rate_db()
    local safe=string.gsub(target,'"','\\"')
    if secs==0 then
        d.mutes[target]=nil
        chat_rate_save(d)
        pcall(game.sendCommand,'tag "'..safe..'" remove 禁言')
        return "✓ 已解除 "..target.." 的禁言。"
    end
    d.mutes[target]=(secs<0) and -1 or (util.timestamp()+secs)
    chat_rate_save(d)
    pcall(game.sendCommand,'tag "'..safe..'" add 禁言')
    send(target,"§c你已被禁言："..mute_human(secs))
    log_event("MUTE", tostring(by or "?").." -> "..target.." "..mute_human(secs))
    return "✓ 已禁言 "..target.."，时长："..mute_human(secs)
end
