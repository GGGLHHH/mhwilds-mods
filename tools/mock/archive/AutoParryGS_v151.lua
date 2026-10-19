-- AutoParryGS v1.5.1：大剑自动放刀（抵消上捞斩）· 发布版
--
-- 原理：按住抵消蓄力 (2,21)/(2,22) 时读怪物发给主角的攻击预告 cMsgEmAttackAreaResult，「打我的」DANGER 条目里最早
--   一段的剩余帧 Q* 落进 [L_min, L] 就在帧开头请求 (2,23) 上捞斩。抵消要刀和攻击实际碰撞才成立，伤害、火花、顿帧、
--   弹开全部来自游戏原生的碰撞（docs/NOTES.md「抵消上捞斩」）。唯一有副作用的游戏调用是
--   changeActionRequest(LAYER 0, (2,23), false)：不写游戏字段，不伪造、不重放受击。
-- 规则（docs/autoparry/PLAN.md「DECISION RULE·A」；v1.5 = rc 1.5-rc1 做减法、规则不变，docs/autoparry/V15.md；
--   v1.5.1 = V15.md 第 9 节：默认提前量改回 30、加抓取否决）：
--   前提：开关开、大剑、基础层在 (2,21)/(2,22)。只认 TargetCharacter 是主角的结果，逐条看 DANGER 条目（多段攻击时
--   closest 和最早的一段对不上，所以取最小 hs）。否决：有 he−hs > W_long 的长窗口条目且 hs ≤ H_veto、he ≥ 0 就整帧
--   不放（吐息、冲撞的接触时刻由几何决定、推不出来；放刀后约 1.5 s 内吃到长攻击就是没有霸体的受击）；抓取条目
--   （DamageType ∈ CATCH/CATCH_ZAKO/CATCH_SLINGER）同一口径否决 —— 抓取抵消不了：第 2 轮 em27 的抓取刀碰到了也不触发
--   抵消，吃了 259 伤害（V15 第 9 节，实测）。那次 (2,23) 的 SUPER_ARMOR 一直开着也被抓了（探针 ARM/CT 实测），所以
--   不放刀也不保证不被抓；否决的作用只是不把人锁进 (2,23)、不白放一刀（未验证）。
--   候选：hs ≥ L_min、0 ≤ he−hs ≤ W_long、不是弹体、不是咆哮/风压/震动/抓取、发送者不是联机副本；Q* = 最小 hs ≤ L 就请求。
--   连续成立的帧合并成一次放刀（streak），不设超时（Q 单调递减，离开区间自然停）；不做墙钟外推。
-- 参数（第 1 轮标定 tools/out/round1_report.md，结论在 docs/NOTES.md）：首个接触早于 0.328 s 接不住、0.331~≥0.944 s
--   全接住（机关扫描 24 样本，真怪 26/26 一致）；请求到动作开始 δ≈0；残差 r 中位数 0.008 s、IQR 0.08 s。
--   L 默认 30（滑块 22~45）：C3 满覆盖平台 26~33 的中点（PLAN 预注册的取法）。v1.5 取下沿 26 是为了少一些「上捞斩
--   约 0.32 s 先砍中怪物、把攻击打断」（第 1 轮 8 次空放里 6 次是这样），但压缩了早侧余量：第 2 轮新怪 em27 同一招 (0,82)
--   两次比预告早到约 0.12 s，L=26 时接触落在 W0 之前（放早），L=30 时约 0.38 s、在窗口内（V15 第 9 节）。
--   L_min 22：C4 ⌈60·(W0+0.02+δ−Q25(r))⌉，W0=0.328、Q25(r)=−0.018。W_long 60：C5 he−hs∈(30,60] 组接住 10/10。
--   第 1 轮有接触的放刀接住 25/26、空放 8/34、mod 开销中位数占帧时间 1.6%；closest 兜底 0 次（已删）。
-- 联机未测：发送者怪物 _Context:get_IsMaster() 第 1 轮单人 100% 可读（恒为 true）；为 false（怪物是副本，预告要等
--   网络包、速度被同步调整）的怪只参与否决、不放刀，读不到按主机处理（fail-open）。
-- 记录：日志 "[AutoParryGS] KIND k=v ..." + reframework/data/AutoParryGS_<会话>_<序号>.json（docs/autoparry/CONTRACT.md
--   2、3.4 节；v1.5 删 SCAN、加 CFG，差异见 V15.md 4.1 节；v1.5.1 的 VETO 追加 why），第 2 轮验收的离线分析靠它们。

local TAG, VERSION = "[AutoParryGS]", "1.5.1"
local CONFIG_PATH, DATA_PREFIX = "AutoParryGS.json", "AutoParryGS"

-- ---------- 常量（依据见头注释）。剩余帧单位 1/60 s、是 System.Single，格式化一律 %.Nf ----------
local LEAD_DEFAULT, LEAD_LO, LEAD_HI = 30, 22, 45   -- L 默认值与滑块范围（比 L_min 小就永远不会触发）
local CFG_VER = 2                   -- 配置格式版本：v1.5.1 起存配置都写上；读到的配置没有它 = rc 或 v1.5 写的（见 load_config）
local LEAD_MIN, LONG_WINDOW, VETO_HORIZON = 22, 60, 90   -- L_min；W_long（1.0 s，只参与否决）；H_veto（1.5 s）
local CREDIT = 1.3                  -- 放刀后 1.3 s 内进 (2,25..27) 算接住（窗口终点 ≥0.944 s，怪物端顿帧 ≤0.167 s）
local TRACK_MAX, TRACK_STALE = 32, 8.0   -- 最多跟踪 32 条；距最后一条消息 8 s 释放（实测最长预告 402 帧，约 6.7 s）
local PAST_HE, PAST_AGE = -30, 1.0  -- 全部条目 he < -30 且距消息 ≥1 s：这一招早就打完了
local WEAPON_GREAT_SWORD, LAYER_BASE, CAT_ATTACK, IDX_SLASH = 0, 0, 2, 23   -- (2,23) = cParrySlash
local PARRY_CHARGE = { [21] = true, [22] = true }           -- 从 (2,22) 放刀也实测被接受过
local PARRY_HIT = { [25] = true, [26] = true, [27] = true }  -- cParrySlashHitS/M/L：游戏自己切过去的，按动作统计最可靠
local STAT_INTERVAL, JSON_INTERVAL = 60.0, 60.0   -- JSON 只在空闲帧写、两次间隔 ≥60 s：写文件会卡帧
local JSON_SEQ_MAX, REC_MAX, STOP_FRAMES = 300, 5000, 30   -- 文件数上限；内存缓冲上限；帧逻辑连续出错多少帧自停
local RED_WINDOW, RED_COUNT, ERR_LOG_MAX, ERR_LOG_GAP, ERR_JSON_MAX = 10.0, 3, 20, 1.0, 500
-- 读主角/动作 ID 的调用抛错（切场景时对象正在销毁）：1.5 s 内按「这一帧不存在」处理，否则一次 0.1 s 的瞬时异常
-- 3 帧内就会标红；间隔不到 0.5 s 的零星失败算同一段，间歇故障照样会在 1.5 s 后升级成错误
local READ_FAIL_TOL, READ_FAIL_GAP = 1.5, 0.5
local COLOR_RED, COLOR_GRAY = 0xFF4040FF, 0xFFA0A0A0   -- imgui 颜色是 ABGR

-- ---------- 配置与运行状态 ----------
local DEFAULTS = { auto_parry = true, parry_lead = LEAD_DEFAULT, debug_log = false }
local config = { auto_parry = DEFAULTS.auto_parry, parry_lead = DEFAULTS.parry_lead, debug_log = DEFAULTS.debug_log }
local session = os.time()
-- err_red/err_yellow = 核心/可选模块错误；readfail = 读主角抛错、容忍期内跳过的帧；replica = 登记时是联机副本的结果数；
-- readerr = 逐条读取出过错的结果数
local stats = { fires = 0, catches = 0, vetoes = 0, failopen = 0, errors = 0, err_red = 0, err_yellow = 0,
    readfail = 0, replica = 0, readerr = 0 }
local err_state = { red = false, stopped = false, yellow = 0, logged = 0, last_log = -100.0, times = {}, recent = {},
    queue = {}, json_n = 0, final = false }
local mod_off = {}          -- 报过黄的可选模块（items 例外：报黄但不停用，见 process_track）
local records, rec_dropped, json_seq, json_status, next_id = {}, 0, 0, "", 1
local CORE = { msg = true, frame = true, fire = true, json = true }   -- 核心模块；其余是可选模块（CONTRACT 2.1）

-- ---------- 安全格式化与记录（CONTRACT 2） ----------
local note_error   -- 前向声明：safe_fmt 失败也要计错误
local function clean_str(v) return (tostring(v):gsub("%s", "_")) end   -- 值不能含空白：离线按空格切字段
local function safe_fmt(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    if ok then return s end
    if note_error then note_error("frame", "FMT_ERR " .. fmt) end
    return "FMT_ERR " .. fmt
end
-- 整数转文本：不用 %d（Lua 5.4 里 %d 遇到带小数的值会抛错），非整数退回 %.1f
local function int_s(v)
    local iv = math.tointeger(v)
    if iv then return tostring(iv) end
    return type(v) == "number" and safe_fmt("%.1f", v) or tostring(v)
end
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local FLOAT_FMT = { i = "%.1f", f1 = "%.1f", f2 = "%.2f", f3 = "%.3f", f4 = "%.4f" }   -- i 字段遇到非整数按 %.1f
-- 返回（日志文本，JSON 值）：布尔写 1/0；地址写成十六进制串（JSON 里 64 位整数不可靠）；nil/NaN/inf → "-"、JSON 省略
local function fmt_value(v, ft)
    if ft == "b" and v ~= nil then v = (v == true or (type(v) == "number" and v ~= 0)) and 1 or 0 end
    if ft == "h" then v = math.tointeger(v) and safe_fmt("%X", math.tointeger(v)) end
    if v == nil then return "-", nil end
    if ft == "s" or type(v) ~= "number" then
        local s = clean_str(v)
        return s, s
    end
    if not finite(v) then return "-", nil end
    if (ft == "i" or ft == "b") and math.tointeger(v) then return tostring(math.tointeger(v)), math.tointeger(v) end
    local s = safe_fmt(FLOAT_FMT[ft] or "%.3f", v)
    return s, tonumber(s)
end

-- 记录种类与字段顺序（CONTRACT 3.4 + V15）：「字段名:格式」，i 整数 / fN N 位小数 / s 文本 / b 布尔 / h 地址。
-- 保持 rc 的字段让分析脚本复用：HDR 的 rotation/scan、STAT 的 fb（兜底已删）恒为 0，FIRE 的 src 恒为 V0；
-- STAT 在 rc 的 12 个字段后追加 replica、readerr；CFG = 启用开关或滑块的每次改动；RED = 进入红状态（关键错误）；
-- VETO 在原字段后追加 why = long（长窗口）/ grab（抓取），多个原因时取触发 hs 最小的那条（V15 第 9 节）
local SPEC = {}
for kind, s in pairs({
    HDR = "ver:s session:i auto_parry:b lead:i rotation:b scan:b L_min:i W_long:i H_veto:i credit:f1",
    FIRE = "id:i t:f4 L:i R0:f2 he0:f2 src:s ent:h res:h em:s keep:s from:s",
    FIRE_END = "id:i t:f4 R1:f2 n:i entered:b",
    VETO = "t:f4 hs:f2 he:f2 res:h ent:h em:s why:s",
    RES = "id:i t:f4 outcome:s dt:f3",
    STAT = "fires:i catches:i vetoes:i fb:i failopen:i errors:i red:i yellow:i lua_ms_avg:f3 lua_ms_max:f3 "
        .. "hook_ms_ps:f3 readfail:i replica:i readerr:i",
    CFG = "t:f4 auto_parry:b lead:i",
    ERR = "mod:s level:s msg:s",
    RED = "t:f4 mod:s why:s",
}) do
    SPEC[kind] = {}
    for name, ft in s:gmatch("([%w_]+):(%w+)") do SPEC[kind][#SPEC[kind] + 1] = { name, ft } end
end

local function round4(v) return math.floor(v * 10000 + 0.5) / 10000 end
-- 按 SPEC 拼一行日志和一条 JSON 记录；没有 t 的种类在 JSON 里补上发生时刻，离线按 t 和探针关联
local function build(kind, vals)
    local spec, parts, rec = SPEC[kind], { TAG, kind }, { k = kind }
    for i = 1, #spec do
        local s, jv = fmt_value(vals[i], spec[i][2])
        parts[#parts + 1] = spec[i][1] .. "=" .. s
        rec[spec[i][1]] = jv
    end
    if rec.t == nil then rec.t = round4(os.clock()) end
    return table.concat(parts, " "), rec
end
-- emit(kind, 值数组（按 SPEC 顺序，可含 nil）, opts)：总进 JSON；opts.log == false 时不写日志
local function emit(kind, vals, opts)
    local line, rec = build(kind, vals)
    if not (opts and opts.log == false) then log.info(line) end
    if #records < REC_MAX then records[#records + 1] = rec else rec_dropped = rec_dropped + 1 end
    return line
end
-- 调试行 DBG（debug_log 打开时写，只写关键事件、不每帧刷；离线不解析、不进 JSON），仍守「[TAG] KIND k=v」
local function dbg_line(ev, ...)
    local parts = { TAG, "DBG", "ev=" .. clean_str(ev), "t=" .. safe_fmt("%.4f", os.clock()) }
    for i = 1, select("#", ...), 2 do
        local k, v = select(i, ...)
        if type(v) == "boolean" then v = v and "1" or "0" elseif type(v) == "number" then v = int_s(v) end
        parts[#parts + 1] = tostring(k) .. "=" .. (v == nil and "-" or clean_str(v))
    end
    return table.concat(parts, " ")
end
local function dbg(ev, ...) if config.debug_log then log.info(dbg_line(ev, ...)) end end

-- 进入「红」状态：只在第一次写 RED（自停另写一行 why=self_stop），不受 ERR 限频影响
local function set_red(now, mod, why)
    if err_state.red and why ~= "self_stop" then return end
    err_state.red = true
    emit("RED", { now, mod, why })
end
local function err_flush(now)   -- 排队的 ERR 日志行每秒最多补写 1 行
    local E = err_state
    if #E.queue > 0 and now - E.last_log >= ERR_LOG_GAP then
        log.info(table.remove(E.queue, 1))
        E.logged, E.last_log = E.logged + 1, now
    end
end
-- 错误分级（CONTRACT 2.1），不许静默吞错：核心模块 10 s 内 3 次标红；可选模块第一次出错就停用、标黄。
-- 每条错误立刻进 JSON（上限 500）；日志只写前 20 条、排队按 1 行/秒补写（限频时直接丢会让同一秒的第二条错误整条丢失）
note_error = function(mod, err)
    local now, E = os.clock(), err_state
    -- 非 ASCII 换成 ?：错误文本里的路径可能是系统代码页，非法 UTF-8 会让整份 JSON 写失败、之后每次都失败
    local msg = clean_str(err):gsub("[\128-\255]", "?"):sub(1, 200)
    stats.errors = stats.errors + 1
    local level, red_now = "yellow", false
    if CORE[mod] then
        level, stats.err_red = "red", stats.err_red + 1
        local ts = E.times[mod] or {}
        E.times[mod] = ts
        ts[#ts + 1] = now
        while #ts > 0 and now - ts[1] > RED_WINDOW do table.remove(ts, 1) end
        red_now = #ts >= RED_COUNT
    else
        stats.err_yellow = stats.err_yellow + 1
        if not mod_off[mod] then mod_off[mod], E.yellow = true, E.yellow + 1 end
    end
    table.insert(E.recent, 1, mod .. " " .. level .. ": " .. msg)
    if #E.recent > 6 then table.remove(E.recent) end
    local line = nil
    if E.json_n < ERR_JSON_MAX then
        E.json_n = E.json_n + 1
        line = emit("ERR", { mod, level, msg }, { log = false })
    end
    -- E.final：Reset 收尾时的错误（最后一份 JSON 写不出去）只剩日志能记，不受 20 行上限限制
    if E.final or E.logged + #E.queue < ERR_LOG_MAX then E.queue[#E.queue + 1] = line or build("ERR", { mod, level, msg }) end
    err_flush(now)
    if red_now then set_red(now, mod, "3in10s") end
end

-- ---------- JSON 持久化（CONTRACT 2） ----------
local last_json_t, want_dump = os.clock(), false
local function write_json(reason)
    if #records == 0 then json_status = "没有新记录" return end
    if json_seq >= JSON_SEQ_MAX then json_status = "文件数已达上限 " .. int_s(JSON_SEQ_MAX) .. "，不再写出" return end
    json_seq, last_json_t = json_seq + 1, os.clock()   -- 失败也占一个序号：避免覆盖可能写了一半的文件
    local n, path = #records, DATA_PREFIX .. "_" .. int_s(session) .. "_" .. int_s(json_seq) .. ".json"
    -- why = idle / button / reset：离线据最后一份是不是按钮或重置写出的，判断这一轮有没有正常收尾
    local doc = { kind = DATA_PREFIX, ver = VERSION, session = session, seq = json_seq, why = tostring(reason),
        records = records }
    local ok, ret = pcall(json.dump_file, path, doc, -1)   -- indent=-1：不缩进，文件小、写得快
    if ok and ret ~= false then
        records = {}
        json_status = "已写出 " .. int_s(n) .. " 条：" .. path .. "（" .. tostring(reason) .. "）"
    else
        note_error("json", ok and ("dump_file returned false: " .. path) or ret)   -- 记录留在缓冲里，下次再试
        json_status = "写出失败，见错误详情"
    end
end

-- ---------- 配置读写 ----------
local function clamp_lead(v) return math.max(LEAD_LO, math.min(LEAD_HI, math.floor(v + 0.5))) end
-- 只接受认识的键和类型正确的值（文件被手改坏也不出怪事）；rc 留下的 lead_rotation、scan 直接忽略。
-- 配置升级（V15 第 9 节）：文件里没有 cfg_ver 键 = rc 或 v1.5 写的，那时的提前量（rc 默认 28 且在轮换、v1.5 默认 26）
-- 都不是用户自己调的，一律换成 30；v1.5.1 存配置时写上 cfg_ver，之后用户自己调的值原样保留
local function load_config()
    local ok, loaded = pcall(json.load_file, CONFIG_PATH)
    if not ok then return note_error("cfg", loaded) end
    if type(loaded) ~= "table" then return end
    for k, v in pairs(loaded) do
        if k == "parry_lead" then
            if finite(v) then config.parry_lead = clamp_lead(v) end
        elseif DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then
            config[k] = v
        end
    end
    if loaded.cfg_ver == nil then
        config.parry_lead = LEAD_DEFAULT
        dbg("cfg_upgrade", "from", loaded.parry_lead, "to", LEAD_DEFAULT)
    end
end
load_config()
emit("HDR", { VERSION, session, config.auto_parry, config.parry_lead, false, false, LEAD_MIN, LONG_WINDOW,
    VETO_HORIZON, CREDIT })

-- ---------- 游戏类型与枚举 ----------
-- 枚举写法沿用 AGPCall（实测）：遍历静态字段取 get_data(nil)，表里没有再按名字直接取
local function enum_value(type_name, name)
    local td = sdk.find_type_definition(type_name)
    if not td then error("type not found: " .. type_name) end
    for _, f in ipairs(td:get_fields()) do
        local v = f:is_static() and f:get_name() == name and f:get_data(nil)
        if type(v) == "number" then return v end
    end
    local f = td:get_field(name)
    local v = f and f:get_data(nil)
    if type(v) ~= "number" then error("enum value not found: " .. type_name .. "." .. name) end
    return v
end
local RT_DANGER, SLASH_ID = nil, nil   -- app.AttackAreaResult.RESULT_TYPE.DANGER；ace.ACTION_ID (2,23)
local EFFECT_DAMAGE = {}    -- app.HitDef.DAMAGE_TYPE 的 EAR/WIND/QUAKE：咆哮、风压、震动不是能抵消的打击
local effect_partial = false   -- 效果攻击有名字没读到：认不出的伤害类型可能就是它（见 damage_kind）
local GRAB_DAMAGE = {}      -- app.HitDef.DAMAGE_TYPE 的 CATCH/CATCH_ZAKO/CATCH_SLINGER：抓取，刀碰到了也抵消不了
local T_ENEMY = nil         -- sdk.typeof("app.EnemyCharacter")：联机闸门从发送者身上取怪物
local MSG_TYPE = "app.game_message.cMsgEmAttackAreaResult"
local SLASH_SIG = "changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)"

local function self_stop_init(err)     -- 核心类型或钩子拿不到，规则无法运行：直接自停并标红
    note_error("frame", err)
    set_red(os.clock(), "frame", "init")
    err_state.stopped = true
end
do
    local ok, err = pcall(function()
        RT_DANGER = enum_value("app.AttackAreaResult.RESULT_TYPE", "DANGER")
        local id = ValueType.new(sdk.find_type_definition("ace.ACTION_ID"))
        id:set_field("_Category", CAT_ATTACK)
        id:set_field("_Index", IDX_SLASH)
        SLASH_ID = id
    end)
    if not ok then self_stop_init(err) end
    -- 伤害类型的名字一个一个读，效果攻击和抓取两组互不连累（V15 第 9 节）。效果攻击读不到的名字标黄一次（effect_enum，
    -- 同 v1.5 枚举读失败时报黄），但不停用伤害类型读取：以前整组读失败会记成 dmgtype 停用读取，抓取否决也跟着没了
    -- （第 1 轮审查）。读到的效果类型照常过滤，认不出的类型按 fail-open（damage_kind）
    local missing, first_err = {}, nil
    for _, n in ipairs({ "EAR", "WIND", "QUAKE" }) do
        local ok2, v = pcall(enum_value, "app.HitDef.DAMAGE_TYPE", n)
        if ok2 then
            EFFECT_DAMAGE[v] = n
        else
            missing[#missing + 1] = n
            first_err = first_err or v
        end
    end
    if #missing > 0 then
        effect_partial = true
        note_error("effect_enum", table.concat(missing, ",") .. " " .. tostring(first_err))
    end
    -- 抓取的三个名字 2026-10-11 用 MCP get_type 核对过都在 app.HitDef.DAMAGE_TYPE 里。按名字逐个读、读不到的跳过
    -- （V15 第 9 节）：游戏更新改了名只是少认一种抓取，不能连带停掉 EAR/WIND/QUAKE 过滤；跳过了哪些总写一行 DBG
    local skipped = {}
    for _, n in ipairs({ "CATCH", "CATCH_ZAKO", "CATCH_SLINGER" }) do
        local ok2, v = pcall(enum_value, "app.HitDef.DAMAGE_TYPE", n)
        if ok2 then GRAB_DAMAGE[v] = n else skipped[#skipped + 1] = n end
    end
    if #skipped > 0 then log.info(dbg_line("grab_enum", "skipped", table.concat(skipped, ","))) end
    ok, err = pcall(function() T_ENEMY = sdk.typeof("app.EnemyCharacter") end)
    if not ok or not T_ENEMY then note_error("master", ok and "typeof app.EnemyCharacter = nil" or err) end
end

local function master_hunter()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    return p and p:call("get_Character")
end
local function addr_of(obj)
    if not obj then return nil end
    local ok, a = pcall(obj.get_address, obj)
    return ok and a or nil
end
local function release_obj(obj) if obj then pcall(obj.release, obj) end end
-- 唯一有副作用的游戏调用：帧开头请求上捞斩，走动作控制器的正常进入流程（NOTES「改动作」实测）
local function request_slash(hunter)
    local ok, err = pcall(hunter.call, hunter, SLASH_SIG, LAYER_BASE, SLASH_ID, false)
    if not ok then note_error("fire", err) end
end

-- ---------- 预告跟踪（PLAN 参数表「预告跟踪与释放」、CONTRACT 3.3） ----------
-- 结果对象是怪物那边的、会被复用：跨帧持有要 add_ref，丢弃时 release，必须成对；同一对象重发时刷新 t_msg
local tracks, n_tracks = {}, 0      -- [结果地址] = { obj, t_msg, em, master, fo = {条目 → 已计 fail-open}, re }
local me_addr, me_gs = nil, false   -- 主角 HunterCharacter 地址、是不是大剑（每帧更新）
local function drop_track(key)
    local tr = tracks[key]
    if not tr then return end
    tracks[key], n_tracks = nil, n_tracks - 1
    release_obj(tr.obj)
end
local function release_all_tracks() for key in pairs(tracks) do drop_track(key) end end
-- 满了丢 t_msg 最旧的（最久没收到消息的），不按登记先后：一直在重发的预告是活的
local function drop_oldest()
    local old_key, old_t = nil, nil
    for key, tr in pairs(tracks) do
        if not old_t or tr.t_msg < old_t then old_key, old_t = key, tr.t_msg end
    end
    if old_key then
        drop_track(old_key)
        dbg("track_full", "dropped", "oldest", "max", TRACK_MAX)
    end
end

-- 联机闸门：发送者就是怪物本体（第 1 轮 435/435），它的 _Context:get_IsMaster() 为 false = 怪物是副本。
-- 链上哪一环是 nil 返回 nil（按主机处理）；返回值不是布尔就抛错（按可选模块出错处理）
local function read_master(msg)
    local go = msg:call("get_SendGameObject")
    local enemy = go and go:call("getComponent(System.Type)", T_ENEMY)
    local holder = enemy and enemy:get_field("_Context")
    if not holder then return nil end
    local m = holder:call("get_IsMaster")
    if type(m) ~= "boolean" then error("get_IsMaster returned " .. tostring(m)) end
    return m
end

local function on_message(args)
    if not config.auto_parry or err_state.stopped or not me_addr or not me_gs then return end
    local msg = sdk.to_managed_object(args[3])
    if not msg or msg:get_type_definition():get_full_name() ~= MSG_TYPE then return end
    local r = msg:call("get_AttackAreaResult")
    if not r then return end
    local key, now = r:get_address(), os.clock()
    if tracks[key] then
        tracks[key].t_msg = now
        return
    end
    local target = r:call("get_TargetCharacter")
    if not target or target:get_address() ~= me_addr then return end
    if r:call("get_IsAttackFinished") then return end   -- 到达时就已结束的不跟踪（训练机关每个周期都发空预告）
    local em = "em" .. int_s(r:call("get_EmID")) .. "#" .. int_s(r:call("get_EmSystemIndex"))
    -- 是不是主机只在登记时读一次。读不到按主机处理（fail-open）：单人时恒为 true，不能因为读取出错就一刀都不放；
    -- 抛错第一次标黄并停用这项读取（之后登记的都按主机、计 fail-open）
    local master = nil
    if not mod_off.master then
        local ok, m = pcall(read_master, msg)
        if ok then master = m else note_error("master", m) end
    end
    if n_tracks >= TRACK_MAX then drop_oldest() end
    r:add_ref()
    tracks[key] = { obj = r, t_msg = now, em = em, master = master ~= false, fo = {} }
    n_tracks = n_tracks + 1
    if master == nil then stats.failopen = stats.failopen + 1 end
    if master == false then stats.replica = stats.replica + 1 end
end

-- 钩子体耗时（ms，累计到下一行 STAT）：离线和帧回调耗时一起估 mod 开销占帧时间（REF 的钩子分发开销量不到）
local hook_ms = 0.0
do
    local ok, err = pcall(function()
        local td = sdk.find_type_definition("app.cMasterPlayerControllerEntity")
        sdk.hook(td:get_method("receiveGameMessage(ace.cGameMessage)"), function(args)
            local t0 = os.clock()
            local ok2, err2 = pcall(on_message, args)
            if not ok2 then note_error("msg", err2) end
            hook_ms = hook_ms + (os.clock() - t0) * 1000.0
        end, nil)
    end)
    if not ok then self_stop_init(err) end
end

-- ---------- 条目读取与规则（DECISION RULE·A） ----------
local function read_items(r)
    local list = r:call("get_DetectedDataList")
    if not list then return {} end
    local n = math.tointeger(list:call("get_Count"))
    if not n then error("get_Count is not an integer") end
    local out = {}
    for i = 0, n - 1 do
        local d = list:call("get_Item", i)
        if not d then error("get_Item returned nil") end
        local hs, he = d:call("get_HitStartRemainFrame"), d:call("get_HitEndRemainFrame")
        if type(hs) ~= "number" or type(he) ~= "number" then error("remain frame is not a number") end
        out[#out + 1] = { d = d, rt = d:call("get_ResultType"), hs = hs, he = he }
    end
    return out
end
-- 弹体：ShellIndex 是 Nullable<Int32>，有值就是弹体。REF 的返回形态三种都认：无值给 nil、有值直接拆箱成数字、
-- 带 _HasValue 的值类型（只认后一种的话，数字形态会抛错 → 停用 → 弹体条目全按 fail-open 放刀）
local function has_shell(d)
    local v = d:call("get_ShellIndex")
    if v == nil then return false end
    if type(v) == "number" then return true end
    if type(v) ~= "userdata" then error("ShellIndex returned " .. type(v)) end
    local hv = v:get_field("_HasValue")
    if type(hv) ~= "boolean" then error("ShellIndex._HasValue=" .. tostring(hv)) end
    return hv
end
-- 伤害类型（cAttackParamEm._DamageType）：grab = 抓取，effect = 咆哮、风压、震动，normal = 其他；读不到攻击参数返回 nil。
-- 效果攻击有名字没读到（effect_partial）时，认不出的类型可能就是那一种：返回 nil 按读不到处理（fail-open、计 failopen，
-- 和 v1.5 枚举读失败时每个条目计一次同一口径）；抓取和读到的效果类型照样认
local function damage_kind(d)
    local ap = d:call("get_AttackParam")
    if ap == nil then return nil end
    local t = ap:get_field("_DamageType")
    if type(t) ~= "number" then error("_DamageType=" .. tostring(t)) end
    if GRAB_DAMAGE[t] then return "grab" end
    if EFFECT_DAMAGE[t] then return "effect" end
    if effect_partial then return nil end
    return "normal"
end
-- 可选读取（弹体、伤害类型）。读不到（模块已停用、出错、返回 nil）返回 nil、按通过处理（fail-open），每个条目只计一次
-- fail-open：不能因为一个可选字段读不到就一刀都不放。伤害类型读不到 = 不是抓取、也不是效果攻击（V15 第 9 节）
local function read_opt(tr, d, mod, fn)
    local ok, res = false, nil
    if not mod_off[mod] then
        ok, res = pcall(fn, d)
        if not ok then note_error(mod, res) end
    end
    if ok and res ~= nil then return res end
    local key = addr_of(d) or tostring(d)
    if not tr.fo[key] then tr.fo[key], stats.failopen = true, stats.failopen + 1 end
    return nil
end

-- 否决 V（why = long 长窗口 / grab 抓取）取触发条目里 hs 最小的；同一个 hs 两种原因都有时记 long（v1.5 就有的规则）
local function set_veto(ev, tr, e, why)
    local v = ev.veto
    if not v or e.hs < v.e.hs or (e.hs == v.e.hs and why == "long" and v.why ~= "long") then
        ev.veto = { tr = tr, e = e, why = why }
    end
end
-- 否决 V 与候选 C：只看 1.5 s 内到来或进行中的 DANGER 条目（hs ≤ H_veto、he ≥ 0；候选的 hs ≤ L ≤ 45、he ≥ hs 都在里面）。
-- 伤害类型对这些条目都要读（抓取要否决）；弹体只对可能成为新最小值的候选读，省调用。ev.best = C 里 hs 最小的（只看
-- hs ≤ L 的，因为只有 Q* ≤ L 才放）。副本的条目照样参与否决（偏保守），只是不进候选
local function consider(tr, list, ev)
    for _, e in ipairs(list) do
        if e.rt == RT_DANGER and e.hs <= VETO_HORIZON and e.he >= 0 then
            local hs, he = e.hs, e.he
            local w = he - hs
            if w > LONG_WINDOW then set_veto(ev, tr, e, "long") end
            local kind = read_opt(tr, e.d, "dmgtype", damage_kind)
            if kind == "grab" then
                set_veto(ev, tr, e, "grab")   -- 抓取永远不进候选
            elseif kind ~= "effect" and tr.master and hs >= LEAD_MIN and hs <= ev.L and w >= 0 and w <= LONG_WINDOW
                and (not ev.best or hs < ev.best.e.hs) and read_opt(tr, e.d, "shell", has_shell) ~= true then
                ev.best = { tr = tr, e = e }   -- Q(d) = hs + α·(he−hs)，α=0
            end
        end
    end
end

-- 每帧每条预告：先按释放条件清理；ev 非 nil 时（在蓄力中且开关开着）再参与规则求值
local function process_track(tr, now, ev)
    local age, r = now - tr.t_msg, tr.obj
    if age >= TRACK_STALE then return "stale" end
    if r:call("get_IsAttackFinished") then return "finished" end
    if not ev and age < PAST_AGE then return nil end
    local ok, list = pcall(read_items, r)
    if not ok then
        -- 逐条读取出错（closest 兜底已删）：这个结果本帧不参与（不放刀、不否决、不按 he 释放，最多持有到 8 s）。
        -- 第一次出错标黄，但不停用逐条读取（停用就再也放不了刀）；readerr 按结果计一次
        if not mod_off.items then note_error("items", list) end
        if not tr.re then tr.re, stats.readerr = true, stats.readerr + 1 end
        return nil
    end
    -- 「全部条目 he < -30」只对非空列表成立：未结束、暂时没有条目的结果要继续持有到 8 s，之后不重发消息就冒出来的
    -- DANGER 条目也要看得到（探针和离线影子回放同一口径）
    if age >= PAST_AGE and #list > 0 then
        local past = true
        for _, e in ipairs(list) do
            if not (e.he < PAST_HE) then past = false break end
        end
        if past then return "past" end
    end
    if ev then
        local target = r:call("get_TargetCharacter")
        if target and target:get_address() == me_addr then consider(tr, list, ev) end
    end
end

-- 清理全部跟踪；L 非 nil 时同时求值，返回 ev = { L, veto, best }。单条预告读坏了就丢掉它（释放引用）、
-- 计一次帧逻辑错误，不连累别的预告
local function evaluate(now, L)
    local ev = L and { L = L } or nil
    for key, tr in pairs(tracks) do
        local ok, why = pcall(process_track, tr, now, ev)
        if not ok then note_error("frame", why) end
        if not ok or why then drop_track(key) end
    end
    return ev
end

-- ---------- 放刀 streak、否决、结局 ----------
local streak, veto_on = nil, false  -- streak = { id, t, n, r1 }：条件连续成立的帧合并为一次放刀
local res_wait = nil                -- { id, t }：已进入 (2,23)，等 CREDIT 秒内进 (2,25..27)
local act_cat, act_idx = nil, nil   -- 本帧主角动作（空闲判断用，不在 UI 线程里调游戏方法）
local function keep_text(r)
    local k = r:call("get_KeepActionID")
    return k and ("(" .. int_s(k:get_field("_Category")) .. "," .. int_s(k:get_field("_Index")) .. ")") or nil
end
local function finish_res(now, outcome)
    local w = res_wait
    res_wait = nil
    if outcome ~= "NOCATCH" then stats.catches = stats.catches + 1 end
    emit("RES", { w.id, now, outcome, now - w.t })
end
local function start_streak(now, L, best, idx)
    if res_wait then finish_res(now, "NOCATCH") end   -- 又回到蓄力了，上一刀不可能再接住
    local tr, e = best.tr, best.e
    local ok, keep = pcall(keep_text, tr.obj)
    if not ok then
        note_error("frame", keep)
        keep = nil
    end
    streak = { id = next_id, t = now, n = 0, r1 = e.hs }
    next_id, stats.fires = next_id + 1, stats.fires + 1
    emit("FIRE", { streak.id, now, L, e.hs, e.he, "V0", addr_of(e.d), addr_of(tr.obj), tr.em, keep,
        "(" .. int_s(CAT_ATTACK) .. "," .. int_s(idx) .. ")" })
end
-- R1 记最后一个请求帧的 Q*：那一帧的请求被接受，下一帧就在 (2,23) 里了（实测都是下一帧）
local function end_streak(now, entered)
    local s = streak
    streak = nil
    emit("FIRE_END", { s.id, now, s.r1, s.n, entered })
    if res_wait then finish_res(now, "NOCATCH") end
    res_wait = { id = s.id, t = s.t }
    if not entered then finish_res(now, "NOCATCH") end   -- 没放出去：每个 FIRE 都有一行 RES，离线一一对应
end

local function update_fire(hunter, now, cat, idx)
    if streak and cat == CAT_ATTACK and idx == IDX_SLASH then end_streak(now, true) end
    if res_wait and not streak then
        if cat == CAT_ATTACK and PARRY_HIT[idx] then
            finish_res(now, "CATCH" .. int_s(idx))
        elseif now - res_wait.t >= CREDIT then
            finish_res(now, "NOCATCH")
        end
    end
    -- 前提 P1~P3：开关、大剑、基础层在 (2,21)/(2,22)；任一不满足就结束 streak（清理照常做）
    local active = config.auto_parry and not err_state.stopped and me_gs
        and cat == CAT_ATTACK and PARRY_CHARGE[idx] == true
    local ev = evaluate(now, active and config.parry_lead or nil)
    if not active then
        if streak then end_streak(now, false) end
        veto_on = false
        return
    end
    if ev.veto and not veto_on then   -- 每个否决 streak 记一行（长窗口、抓取同一个 streak），记这一帧 hs 最小的那条
        stats.vetoes = stats.vetoes + 1
        local v = ev.veto
        emit("VETO", { now, v.e.hs, v.e.he, addr_of(v.tr.obj), addr_of(v.e.d), v.tr.em, v.why })
    end
    veto_on = ev.veto ~= nil
    if ev.best and not ev.veto then
        -- Q* ≤ L 已在 consider 里保证；不设超时：Q 单调递减，离开 [L_min, L] 自然停
        if not streak then start_streak(now, ev.L, ev.best, idx) end
        streak.n, streak.r1 = streak.n + 1, ev.best.e.hs
        request_slash(hunter)
    elseif streak then
        end_streak(now, false)
    end
end

-- ---------- 每帧 ----------
local consec_err, last_stat_t = 0, os.clock()
local action_gap = false    -- 上一帧是否「主角在、但读不到当前动作」（只在进出时各写一行 DBG）
local read_fail = { t0 = nil, t_last = nil, n = 0 }
local function lose_hunter(now)    -- 主角为 nil 或换了（换场景等）：全部释放
    release_all_tracks()
    if streak then end_streak(now, false) end
    veto_on = false
    if res_wait then finish_res(now, "NOCATCH") end
    me_addr = nil
end
-- 取主角 → 武器 → 动作控制器 → 动作 ID；没有主角返回 nil，动作 ID 读不到时 cat/idx 为 nil
local function read_hunter()
    local hunter = master_hunter()
    if not hunter then return nil end
    local addr = hunter:get_address()
    local gs = hunter:call("get_WeaponType") == WEAPON_GREAT_SWORD
    local ctrl = hunter:call("get_BaseActionController")
    local id = ctrl and ctrl:call("get_CurrentActionID")
    if not id then return hunter, addr, gs end
    return hunter, addr, gs, id:get_field("_Category"), id:get_field("_Index")
end
-- 读主角抛错时：容忍期内返回 false（这一帧跳过），超过容忍期返回 true（按帧逻辑出错处理）。进出各写一行 DBG
local function read_failed(now, err)
    local F = read_fail
    if not F.t0 or now - F.t_last > READ_FAIL_GAP then
        F.t0, F.n = now, 0
        dbg("read_fail", "err", (tostring(err):gsub("[\128-\255]", "?")):sub(1, 120))
    end
    F.t_last, F.n = now, F.n + 1
    stats.readfail = stats.readfail + 1
    return now - F.t0 >= READ_FAIL_TOL
end

local function frame_logic(now)
    local ok, hunter, addr, gs, cat, idx = pcall(read_hunter)
    if not ok then
        if read_failed(now, hunter) then error(hunter, 0) end
        return      -- 容忍期内：这一帧不存在（不求值、不放刀、streak 和跟踪都保持原样）
    end
    if read_fail.t0 and now - read_fail.t_last > READ_FAIL_GAP then
        dbg("read_back", "frames", read_fail.n, "dur", safe_fmt("%.3f", read_fail.t_last - read_fail.t0))
        read_fail.t0 = nil
    end
    if not hunter then
        if me_addr or n_tracks > 0 then lose_hunter(now) end
        me_gs, act_cat, act_idx = false, nil, nil
        return
    end
    if me_addr and addr ~= me_addr then lose_hunter(now) end
    me_addr, me_gs = addr, gs
    -- 主角在、动作 ID 暂时读不到（切场景、加载的头几帧）：按「不在蓄力」处理，不算帧逻辑出错（否则满 30 帧就自停）
    local no_action = cat == nil or idx == nil
    if no_action ~= action_gap then
        action_gap = no_action
        dbg(no_action and "no_action" or "action_back")
    end
    act_cat, act_idx = cat, idx
    if not config.auto_parry and n_tracks > 0 then release_all_tracks() end   -- 关开关时全部释放（菜单里只改配置）
    update_fire(hunter, now, cat, idx)
end

local function self_stop(now)
    err_state.stopped = true
    set_red(now, "frame", "self_stop")
    local ok, err = pcall(function()
        release_all_tracks()
        if streak then end_streak(now, false) end
        if res_wait then finish_res(now, "NOCATCH") end   -- 自停后帧逻辑不再跑、没人结算：每个 FIRE 都要有 RES
    end)
    if not ok then note_error("frame", err) end
    act_cat, act_idx = nil, nil   -- 不再读主角：停在最后读到的 (2,21..29) 会让空闲写出永远等不到
    log.info(dbg_line("self_stop", "why", "frame_logic_failed", "frames", STOP_FRAMES))   -- 不受 debug_log 控制
end
local function is_idle()
    if streak or res_wait then return false end
    return not (act_cat == CAT_ATTACK and act_idx and act_idx >= 21 and act_idx <= 29)
end

-- STAT：每 60 s 一行；点「写出数据」和 Reset 时先补写一行，让最后的计数进 JSON。fb 恒为 0。
-- lua_win = 到下一行 STAT 为止的帧回调耗时
local lua_win = { sum = 0.0, n = 0, max = 0.0, t0 = os.clock() }
local function stat_emit(now)
    local W = lua_win
    local span = now - W.t0
    last_stat_t = now
    emit("STAT", { stats.fires, stats.catches, stats.vetoes, 0, stats.failopen, stats.errors, stats.err_red,
        stats.err_yellow, W.n > 0 and W.sum / W.n or nil, W.n > 0 and W.max or nil, span > 0 and hook_ms / span or nil,
        stats.readfail, stats.replica, stats.readerr })
    W.sum, W.n, W.max, W.t0 = 0.0, 0, 0.0, now
    hook_ms = 0.0
end
local function periodic(now)
    if now - last_stat_t >= STAT_INTERVAL then stat_emit(now) end
    if want_dump then
        want_dump = false
        stat_emit(now)
        write_json("button")
    elseif #records > 0 and now - last_json_t >= JSON_INTERVAL and is_idle() then
        write_json("idle")
    end
end

re.on_pre_application_entry("UpdateBehavior", function()
    local now = os.clock()
    if not err_state.stopped then
        local ok, err = pcall(frame_logic, now)
        consec_err = ok and 0 or consec_err + 1
        if not ok then note_error("frame", err) end
        if consec_err >= STOP_FRAMES then self_stop(now) end
    end
    local ok2, err2 = pcall(periodic, now)
    if not ok2 then note_error("json", err2) end
    err_flush(now)
    local W, ms = lua_win, (os.clock() - now) * 1000.0
    W.sum, W.n, W.max = W.sum + ms, W.n + 1, math.max(W.max, ms)
end)

-- ---------- 菜单（发布版没有 HUD，状态只在这里显示） ----------
-- 启用开关、提前量滑块每次改动写一行 CFG（总写，不受 debug_log 控制）：第 2 轮验收只用第一次改动之前的数据（PLAN D）
local function set_cfg(k, v)
    if config[k] == v then return end
    config[k] = v          -- 预告的释放、streak 的结束都在下一帧的帧逻辑里做
    emit("CFG", { os.clock(), config.auto_parry, config.parry_lead })
end
local function draw_status()
    local E = err_state
    -- items 报黄但不停用：读不出条目的那个预告不放刀，不能说「停用、照常放刀」（那是读失败按通过的过滤器和 cfg/ui）
    local n_off = E.yellow - (mod_off.items and 1 or 0)
    local s = E.stopped and "已自停（帧逻辑连续出错）" or E.red and "核心模块出错"
        or n_off > 0 and ("有可选模块停用（黄 " .. int_s(n_off) .. "），自动放刀照常") or nil
    if mod_off.items then
        local t = "条目读取出过错（读取错误 " .. int_s(stats.readerr) .. "）：读不出条目的预告不放刀"
        s = s and (s .. "；" .. t) or t
    end
    imgui.text("版本 " .. VERSION .. "  状态：" .. (s or "正常"))
    if E.red then imgui.text_colored("出错了：请把 re2_framework_log.txt 发给开发者，然后 Reset Scripts", COLOR_RED) end
end
-- 「写出数据」按钮、写出状态、最近的错误：完整菜单和出错后的简化菜单共用（简化了也要能收尾、看到错误文本）
local function draw_dump(id)
    if imgui.button("写出数据##" .. id) then want_dump, json_status = true, "写出中……" end   -- 下一帧在游戏线程里写
    if json_status ~= "" then imgui.text(json_status) end
    for _, line in ipairs(err_state.recent) do imgui.text("错误 " .. line) end
end
local function draw_menu_min() draw_status() draw_dump("ap_dump_min") end
local function draw_menu()
    draw_status()
    local changed, v = imgui.checkbox("启用（实验）##ap_enabled", config.auto_parry)
    if changed then set_cfg("auto_parry", v == true) end
    changed, v = imgui.slider_int("提前量（帧，1/60 秒）##ap_lead", config.parry_lead, LEAD_LO, LEAD_HI)
    if changed and finite(v) then set_cfg("parry_lead", clamp_lead(v)) end
    imgui.text_colored("越小越常出抵消动作；太小会被先打到。默认 " .. int_s(LEAD_DEFAULT), COLOR_GRAY)
    imgui.separator()
    local S = stats
    imgui.text("放刀 " .. int_s(S.fires) .. "  接住 " .. int_s(S.catches) .. "  否决 " .. int_s(S.vetoes) .. "  联机副本跳过 "
        .. int_s(S.replica) .. "  fail-open " .. int_s(S.failopen) .. "  读取错误 " .. int_s(S.readerr))
    imgui.text("错误 " .. int_s(S.errors) .. "（红 " .. int_s(S.err_red) .. " 黄 " .. int_s(S.err_yellow) .. "）  跟踪中的预告 "
        .. int_s(n_tracks) .. " 条  待写出记录 " .. int_s(#records) .. " 条"
        .. (rec_dropped > 0 and ("  丢弃 " .. int_s(rec_dropped)) or "")
        .. (S.readfail > 0 and ("  读主角抛错跳过 " .. int_s(S.readfail) .. " 帧") or ""))
    changed, v = imgui.checkbox("调试日志##ap_debug", config.debug_log)
    if changed then config.debug_log = v == true end
    if imgui.button("清零统计##ap_reset") then for k in pairs(stats) do stats[k] = 0 end end
    imgui.same_line()
    draw_dump("ap_dump")
end
re.on_draw_ui(function()
    if not imgui.tree_node("自动放刀（实验）##AutoParryGS") then return end
    local ok, err = pcall(mod_off.ui and draw_menu_min or draw_menu)   -- 完整菜单出过错后只画简化菜单
    imgui.tree_pop()                -- 出错也要配对 tree_pop
    if not ok then note_error("ui", err) end
end)

-- ---------- 重置与配置保存 ----------
-- 顺序：先放引用（不能因为记录写不出去就漏放）→ 结算 streak 和 RES → STAT → 最后一份 JSON → 最后才把排队的 ERR
-- 一次写完（写 JSON 失败的那条错误也要进日志：这一刻以后再也写不出 JSON）
re.on_script_reset(function()
    local now = os.clock()
    local ok, err = pcall(release_all_tracks)
    if not ok then note_error("frame", err) end
    ok, err = pcall(function()
        if streak then end_streak(now, false) end
        if res_wait then finish_res(now, "NOCATCH") end   -- 每个 FIRE 都有 RES（口径同 lose_hunter）
    end)
    if not ok then note_error("frame", err) end
    err_state.final = true
    ok, err = pcall(stat_emit, now)
    if not ok then note_error("json", err) end
    ok, err = pcall(write_json, "reset")
    if not ok then note_error("json", err) end
    while #err_state.queue > 0 do log.info(table.remove(err_state.queue, 1)) end
end)
re.on_config_save(function()
    local saved = { auto_parry = config.auto_parry, parry_lead = config.parry_lead, debug_log = config.debug_log,
        cfg_ver = CFG_VER }
    local ok, ret = pcall(json.dump_file, CONFIG_PATH, saved)
    if not ok or ret == false then note_error("cfg", ok and "config dump_file returned false" or ret) end
end)

dbg("loaded", "ver", VERSION, "session", session, "L", config.parry_lead)
