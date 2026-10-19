-- AutoParryGS rc1：大剑自动放刀（抵消上捞斩）· 第 1 轮标定版
--
-- 做什么：按住抵消蓄力 (2,21)/(2,22) 时读怪物发给主角的攻击预告；「打我的」DANGER 条目里，
--   最小剩余帧 Q* 落进 [L_min, L] 就在帧开头请求 (2,23) 上捞斩。伤害、火花、顿帧、弹开全部来自
--   游戏原生的刀与攻击碰撞；本脚本唯一有副作用的游戏调用是 changeActionRequest。
--   v1.3 实测：放了 5 次，5 次都是第一次请求就被接受、下一帧进入 (2,23)，其中 1 次从 (2,22)
--   发起（会话记录 14:57:01.594），所以 (2,21)/(2,22) 都生效。
--
-- 依据：docs/autoparry/PLAN.md（DECISION RULE·A、参数表、probe_spec P19/P20）；
--   接口约定：docs/autoparry/CONTRACT.md 第 1~3 节（两者冲突时以 CONTRACT 为准）。
--
-- 为什么这样定规则（附出处）：
--   1. 逐条 DANGER 条目取最小剩余帧（V0），不只看 closest：一招有多个检测体时，closest 和时间最早
--      的那条对不上（PLAN「估计量」）。「closest 取错段导致早到」没被证实，所以不宣称 V0 能修复早到；
--      逐条读取出错时才退回 closest（src=FB 并计数），FB 计数为 0 时终版删掉兜底。
--   2. L_min=18：v1.3 两次成功都在剩 19~19.5 帧时放刀，这是有证据的最低值；再低的话放出去只会先挨打
--      再丢蓄力（不放则由蓄力霸体硬吃、蓄力保留），也顺带排除 remain≤0。
--      长窗口否决：吐息、冲撞这类判定窗口很长的攻击，接触时刻由几何决定，从 HitStart 推不出来；
--      (2,23) 空放后会一直停到玩家有输入（复核样本 f4469→f4794 约 3.4~3.8 s），尾段没有霸体。
--      所以长窗口 DANGER 在 1.5 s 内到来或正在进行时整帧不放刀（PLAN 参数表 W_long / H_veto）。
--   3. 不做 v1.3 的墙钟「粘住」外推：唯一能核对的样本 (0,72) 早到 0.13~0.20 s，偏差来自实时读数本身，
--      没有一次成功是靠外推触发的；外推还会把降级（可能正说明这招不会打中）变成一次放刀（PLAN DROPPED）。
--   另：消息里的 TargetCharacter 恒为接收者（≥36 条全是「打我」），这里仍按地址核对一遍。
--
-- 第 1 轮专用（v1.5 终版删掉）：L 在 {20,24,28,32,36} 轮换；机关扫描测试模式（默认关）。
-- 记录：日志 "[AutoParryGS] KIND k=v ..."，同样的记录写进 reframework/data/AutoParryGS_<会话>_<序号>.json，
--   日志被覆盖后仍能区分自动放刀和手动放刀。字段顺序见 CONTRACT 3.4 节。

local TAG = "[AutoParryGS]"
local VERSION = "1.5-rc1"
local CONFIG_PATH = "AutoParryGS.json"
local DATA_PREFIX = "AutoParryGS"

-- ---------- 常量（PLAN 参数表；第 1 轮之后按 C3~C5 重定） ----------
-- 剩余帧单位是 1/60 s，HitStart/EndRemainFrame 是 System.Single（常带小数），格式化一律 %.Nf。
local LEAD_MIN = 18                 -- L_min（依据见头注释 2）
local LONG_WINDOW = 60              -- W_long：he-hs 超过 1.0 s 的条目不触发，只参与否决（安全阀）
local VETO_HORIZON = 90             -- H_veto：放刀后约 1.5 s 内角色都在 (2,23) 或抵消成功序列里
local CREDIT = 1.3                  -- 放刀后多久内进入 (2,25..27) 算接住：W1 可能到 0.84~0.9 s，怪物端 DelayFrame ≤0.167 s
local TRACK_MAX = 32                -- 最多跟踪 32 条预告，满了丢最旧的
local TRACK_STALE = 8.0             -- 距最后一条消息 8 s 释放：覆盖实测最长预告 402 帧（约 6.7 s）
local PAST_HE, PAST_AGE = -30, 1.0  -- 全部条目 he < -30 且距消息 ≥1 s：这一招早就打完了
local ROTATION = { 20, 24, 28, 32, 36 }
local LEAD_LO, LEAD_HI = 20, 45

local WEAPON_GREAT_SWORD = 0
local LAYER_BASE = 0
local CAT_ATTACK = 2                -- 大剑攻击动作分类
local IDX_SLASH = 23                -- cParrySlash
local PARRY_CHARGE = { [21] = true, [22] = true }        -- cIdleToParryCharge / cParryCharge
local PARRY_HIT = { [25] = true, [26] = true, [27] = true }  -- cParrySlashHitS/M/L：游戏自己切过去的，按动作统计最可靠

local STAT_INTERVAL = 60.0
local JSON_INTERVAL = 60.0          -- 只在空闲帧写、两次间隔 ≥60 s：测量途中写文件会卡帧、弄脏时序
local JSON_SEQ_MAX = 300
local REC_MAX = 5000                -- 内存缓冲上限（rc 的记录都是低频的，正常到不了）
local STOP_FRAMES = 30              -- 帧逻辑连续 30 帧出错 → 自停
local RED_WINDOW, RED_COUNT = 10.0, 3
local ERR_LOG_MAX, ERR_LOG_GAP = 20, 1.0
local ERR_JSON_MAX = 500            -- ERR 记录无条件进 JSON（上限 500）；日志只写前 20 条、排队按 1 行/秒补写
-- 取主角 / 动作 ID 抛错的容忍期（不是返回 nil，是 call 本身抛错，例如切场景时对象正在销毁）：
-- 1.5 s 内按「这一帧不存在」处理（不求值、不放刀、不动 streak），超过才算帧逻辑出错。
-- 否则一次 0.1 s 的瞬时异常就会在 3 帧内标红、HUD 永久提示停下，这一轮作废（审查实验 x_transient_throw）。
-- 间隔不到 0.5 s 的零星失败算同一段，隔帧失败这类间歇故障照样会在 1.5 s 后升级成错误。
local READ_FAIL_TOL, READ_FAIL_GAP = 1.5, 0.5

-- 机关扫描（PLAN 参数表「机关扫描」、probe_spec P20）；X 用 0.01 s 为单位的整数，避免浮点比较
local SCAN_COARSE = { 24, 28, 32, 36, 40, 50, 60, 70, 80, 90, 100 }
local SCAN_X_LO, SCAN_X_HI, SCAN_STEP = 24, 100, 2
local SCAN_SIDE_MAX = 6             -- 每条边界最多 6 个细化点
local SCAN_TRIES = 3                -- 每个 X 最多尝试 3 次
local SCAN_TARGET = 24              -- 有效样本满 24 个完成
local SCAN_CAP = 36                 -- 最多放 36 刀
local SCAN_MAX_TIME = 600.0         -- 最长 10 分钟
local SCAN_LEARN = 2                -- 前 2 个有效周期只学 D_c、不放刀
local SCAN_DC0 = 1.13               -- D_c 初值：cSmallAttack 首帧 → 接触约 1.12~1.15 s（实测）
local SCAN_DELTA0 = 0.012           -- δ 初值：请求 → (2,23) 真正开始
local SCAN_RETRY = 0.05             -- 到点后 0.05 s 内每帧重试
local SCAN_NO_CONTACT = 1.6         -- t0 之后 1.6 s 内没有接触 → 作废
local HITCH_DT = 0.035              -- 一帧超过 35 ms 算卡顿，样本作废
local EM_CYCLE_OK = { cSmallAttack = true, cToSmallAttack = true }   -- 接触前机关只允许这两个动作
-- 认机关时核对完整类名前缀：MCP 核实只有训练机关 Em0165_00 有 cSmallAttack（日志实见
-- app.Em0165_00Action.cSmallAttack）。不核对的话，扫描开着时第一只打到主角的真怪也会被当成机关
local DUMMY_CLASS_PREFIX = "app.Em0165_00Action."

-- HUD：draw.text 的颜色是 ImU32，低字节是 R（REF 源码 api::draw::text 直接传给 AddText）
local HUD_X, HUD_Y = 24, 96
local COLOR_WHITE, COLOR_RED, COLOR_YELLOW, COLOR_SHADOW = 0xFFFFFFFF, 0xFF3030FF, 0xFF30E0FF, 0xC0000000
-- imgui 窗口兜底：NoTitleBar | NoResize | NoScrollbar | NoCollapse | AlwaysAutoResize | NoFocusOnAppearing
local HUD_WINDOW_FLAGS = 1 + 2 + 8 + 32 + 64 + 4096

-- ---------- 配置 ----------
local DEFAULTS = { auto_parry = true, parry_lead = 28, lead_rotation = true, scan = false, debug_log = true }
local config = {}
for k, v in pairs(DEFAULTS) do config[k] = v end

-- ---------- 运行状态 ----------
local session = os.time()
-- errors = 全部错误；err_red / err_yellow = 核心 / 可选模块错误（STAT 分开报，离线据此核对 ERR 记录有没有丢）；
-- readfail = 取主角/动作 ID 抛错、在容忍期内按「这一帧不存在」跳过的帧数
local stats = { fires = 0, catches = 0, vetoes = 0, fb = 0, failopen = 0, errors = 0, err_red = 0, err_yellow = 0,
    readfail = 0 }
local err_state = { red = false, stopped = false, yellow = 0, logged = 0, last_log = -100.0, times = {}, recent = {},
    queue = {}, json_n = 0 }
local mod_off = {}          -- 已停用的可选模块
local records = {}          -- 待写出的 JSON 记录
local rec_dropped = 0
local json_seq = 0
local json_status = ""
local next_id = 1           -- FIRE 和 SCAN 共用的编号，保证全局唯一

-- 核心模块出错只计数、标红；可选模块第一次出错就停用、标黄（CONTRACT 2.1）
local CORE = { msg = true, frame = true, fire = true, json = true }

-- ---------- 安全格式化与记录 ----------
local note_error   -- 前向声明：safe_fmt 失败也要计错误

local function clean_str(v)
    -- 日志值不能含空白（离线按空格切字段），统一换成 _
    return (tostring(v):gsub("%s", "_"))
end

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
    if type(v) == "number" then return safe_fmt("%.1f", v) end
    return tostring(v)
end

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local FLOAT_FMT = { f1 = "%.1f", f2 = "%.2f", f3 = "%.3f", f4 = "%.4f" }

-- 返回（日志文本，JSON 值）。nil / NaN / inf → 日志 "-"、JSON 省略（等价于 null）
local function fmt_value(v, ft)
    if v == nil then return "-", nil end
    if ft == "s" then
        local s = clean_str(v)
        return s, s
    elseif ft == "b" then
        local b = v == true or (type(v) == "number" and v ~= 0)
        return b and "1" or "0", b and 1 or 0
    elseif ft == "h" then
        -- 地址写成十六进制字符串（JSON 里 64 位整数不可靠）
        local iv = math.tointeger(v)
        if not iv then return "-", nil end
        local s = safe_fmt("%X", iv)
        return s, s
    end
    if type(v) ~= "number" then
        local s = clean_str(v)
        return s, s
    end
    if not finite(v) then return "-", nil end
    if ft == "i" then
        local iv = math.tointeger(v)
        if iv then return tostring(iv), iv end
        local s = safe_fmt("%.1f", v)
        return s, tonumber(s)
    end
    local s = safe_fmt(FLOAT_FMT[ft] or "%.3f", v)
    return s, tonumber(s)
end

-- 记录种类与字段顺序（CONTRACT 3.4）：{字段名, 格式}；格式 i 整数 / fN N 位小数 / s 文本 / b 布尔 1/0 / h 地址
local SPEC = {
    HDR = { { "ver", "s" }, { "session", "i" }, { "auto_parry", "b" }, { "lead", "i" }, { "rotation", "b" },
            { "scan", "b" }, { "L_min", "i" }, { "W_long", "i" }, { "H_veto", "i" }, { "credit", "f1" } },
    FIRE = { { "id", "i" }, { "t", "f4" }, { "L", "i" }, { "R0", "f2" }, { "he0", "f2" }, { "src", "s" },
             { "ent", "h" }, { "res", "h" }, { "em", "s" }, { "keep", "s" }, { "from", "s" } },
    FIRE_END = { { "id", "i" }, { "t", "f4" }, { "R1", "f2" }, { "n", "i" }, { "entered", "b" } },
    VETO = { { "t", "f4" }, { "hs", "f2" }, { "he", "f2" }, { "res", "h" }, { "ent", "h" }, { "em", "s" } },
    RES = { { "id", "i" }, { "t", "f4" }, { "outcome", "s" }, { "dt", "f3" } },
    SCAN = { { "id", "i" }, { "t", "f4" }, { "phase", "s" }, { "X", "f2" }, { "t0", "f4" }, { "Dc", "f3" },
             { "t_req", "f4" }, { "status", "s" }, { "reason", "s" } },
    -- STAT：CONTRACT 3.4 的 6 个字段之后追加 red yellow（核心/可选错误数）、lua_ms_avg / lua_ms_max（本窗口每帧
    -- 帧回调耗时）、hook_ms_ps（钩子体每秒耗时）、readfail（容忍期内跳过的帧）。C9(d) 用前四项估开销占比
    STAT = { { "fires", "i" }, { "catches", "i" }, { "vetoes", "i" }, { "fb", "i" }, { "failopen", "i" }, { "errors", "i" },
             { "red", "i" }, { "yellow", "i" }, { "lua_ms_avg", "f3" }, { "lua_ms_max", "f3" }, { "hook_ms_ps", "f3" },
             { "readfail", "i" } },
    ERR = { { "mod", "s" }, { "level", "s" }, { "msg", "s" } },
    -- RED：进入「红」状态的那一刻写一行（核心模块 10 s 内 ≥3 次 / 帧逻辑连续出错自停 / 加载时核心类型缺失）。
    -- 离线只把 RED 算「关键错误」（C9(d)、C10），和 HUD 标红、用户停下的口径一致；零星的核心错误单列
    RED = { { "t", "f4" }, { "mod", "s" }, { "why", "s" } },
}

local function round4(v) return math.floor(v * 10000 + 0.5) / 10000 end

-- 按 SPEC 拼一行日志文本和一条 JSON 记录
local function build(kind, vals)
    local spec = SPEC[kind]
    local parts = { TAG, kind }
    local rec = { k = kind }
    for i = 1, #spec do
        local name = spec[i][1]
        local s, jv = fmt_value(vals[i], spec[i][2])
        parts[#parts + 1] = name .. "=" .. s
        rec[name] = jv
    end
    -- 没有 t 字段的种类（HDR/STAT/ERR）在 JSON 里补上发生时刻，离线按 t 和探针关联
    if rec.t == nil then rec.t = round4(os.clock()) end
    return table.concat(parts, " "), rec
end

-- emit(kind, 值数组（按 SPEC 顺序，可含 nil）, opts)：opts.log / opts.json 默认都写
local function emit(kind, vals, opts)
    local line, rec = build(kind, vals)
    if not (opts and opts.log == false) then log.info(line) end
    if not (opts and opts.json == false) then
        if #records < REC_MAX then records[#records + 1] = rec else rec_dropped = rec_dropped + 1 end
    end
    return line
end

-- 调试行 DBG（配置 debug_log，CONTRACT 3.1）：不在 CONTRACT 3.4 的记录表里、离线不解析、不进 JSON，只给人看。
-- 格式仍守 CONTRACT 2「[TAG] KIND k1=v1 ...」：ev=事件名、t=os.clock()，其余按「键, 值」成对传；
-- 值里的空白换成 _，布尔写 1/0（以前写成自由文本，日志里出现不是 k=v 的片段，按空格切字段会切坏）
local function dbg_line(ev, ...)
    local parts = { TAG, "DBG", "ev=" .. clean_str(ev), "t=" .. safe_fmt("%.4f", os.clock()) }
    for i = 1, select("#", ...), 2 do
        local k, v = select(i, ...)
        if type(v) == "boolean" then
            v = v and "1" or "0"
        elseif type(v) == "number" then
            v = int_s(v)
        end
        parts[#parts + 1] = tostring(k) .. "=" .. (v == nil and "-" or clean_str(v))
    end
    return table.concat(parts, " ")
end

local function dbg(ev, ...)
    if config.debug_log then log.info(dbg_line(ev, ...)) end
end

local function new_id()
    local id = next_id
    next_id = next_id + 1
    return id
end

-- 进入「红」状态：只在第一次写 RED（自停另写一行，why=self_stop）。RED 不受 ERR 的限频和条数上限影响
local function set_red(now, mod, why)
    if err_state.red and why ~= "self_stop" then return end
    err_state.red = true
    emit("RED", { now, mod, why })
end

-- 排队的 ERR 日志行：每秒最多补写 1 行（CONTRACT 2.1 限频）。每帧和每次出错时各调一次
local function err_flush(now)
    if #err_state.queue > 0 and now - err_state.last_log >= ERR_LOG_GAP then
        log.info(table.remove(err_state.queue, 1))
        err_state.logged = err_state.logged + 1
        err_state.last_log = now
    end
end

-- 错误分级（CONTRACT 2.1）：不许静默吞错。
-- 每条错误立刻进 JSON（上限 500）；日志只写前 20 条，排队按 1 行/秒补写 —— 以前同一秒内的第二条错误既不写日志
-- 也不进 JSON（例如 items 读坏退回 closest、同一帧 closest 也读坏记 frame 红，后一条红错误整条丢失，审查 x_err_burst）
note_error = function(mod, err)
    local now = os.clock()
    -- 非 ASCII 字节换成 ?（和探针一致）：错误文本里的脚本路径可能是系统代码页而不是 UTF-8，
    -- JSON 序列化遇到非法 UTF-8 会整份写失败，而失败的记录留在缓冲里，之后每次写出都会再失败；
    -- 本脚本自己抛的错误都是英文，换掉不丢信息。全是单字节后，按字节截断也不会切坏字符
    local msg = clean_str(err):gsub("[\128-\255]", "?")
    if #msg > 200 then msg = msg:sub(1, 200) end
    stats.errors = stats.errors + 1
    local level
    local red_now = false
    if CORE[mod] then
        level = "red"
        stats.err_red = stats.err_red + 1
        local ts = err_state.times[mod]
        if not ts then
            ts = {}
            err_state.times[mod] = ts
        end
        ts[#ts + 1] = now
        while #ts > 0 and now - ts[1] > RED_WINDOW do table.remove(ts, 1) end
        red_now = #ts >= RED_COUNT
    else
        level = "yellow"
        stats.err_yellow = stats.err_yellow + 1
        if not mod_off[mod] then
            mod_off[mod] = true
            err_state.yellow = err_state.yellow + 1
        end
    end
    table.insert(err_state.recent, 1, mod .. " " .. level .. ": " .. msg)
    if #err_state.recent > 6 then table.remove(err_state.recent) end
    local line = nil
    if err_state.json_n < ERR_JSON_MAX then
        err_state.json_n = err_state.json_n + 1
        line = emit("ERR", { mod, level, msg }, { log = false })
    end
    if err_state.logged + #err_state.queue < ERR_LOG_MAX then
        err_state.queue[#err_state.queue + 1] = line or build("ERR", { mod, level, msg })
    end
    err_flush(now)
    if red_now then set_red(now, mod, "3in10s") end
end

-- ---------- JSON 持久化（CONTRACT 2；P21 同规则） ----------
local last_json_t = os.clock()
local want_dump = false

local function write_json(reason)
    if #records == 0 then
        json_status = "没有新记录"
        return
    end
    if json_seq >= JSON_SEQ_MAX then
        json_status = "文件数已达上限 " .. int_s(JSON_SEQ_MAX) .. "，不再写出"
        return
    end
    json_seq = json_seq + 1      -- 失败也占一个序号：避免覆盖可能写了一半的文件
    last_json_t = os.clock()
    local n = #records
    local path = DATA_PREFIX .. "_" .. int_s(session) .. "_" .. int_s(json_seq) .. ".json"
    -- why = idle / button / reset：离线据「最后一份是不是按钮或重置写出的」判断这一轮有没有正常收尾
    local doc = { kind = DATA_PREFIX, ver = VERSION, session = session, seq = json_seq, why = tostring(reason),
        records = records }
    -- indent=-1：不缩进不换行，文件小、写得快
    local ok, ret = pcall(json.dump_file, path, doc, -1)
    if ok and ret ~= false then
        records = {}
        json_status = "已写出 " .. int_s(n) .. " 条：" .. path .. "（" .. tostring(reason) .. "）"
    else
        -- 记录留在缓冲里，下次再试
        note_error("json", ok and ("dump_file returned false: " .. path) or ret)
        json_status = "写出失败，见错误详情"
    end
end

-- ---------- 配置读写 ----------
local function clamp_lead(v)
    local iv = math.floor(v + 0.5)
    if iv < LEAD_LO then return LEAD_LO end
    if iv > LEAD_HI then return LEAD_HI end
    return iv
end

-- 只接受认识的键和类型正确的值（文件被手改坏也不至于出怪事）；parry_lead 夹到 20~45
local function load_config()
    local ok, loaded = pcall(json.load_file, CONFIG_PATH)
    if not ok then
        note_error("cfg", loaded)
        return
    end
    if type(loaded) ~= "table" then return end
    for k, v in pairs(loaded) do
        if k == "parry_lead" then
            if finite(v) then config.parry_lead = clamp_lead(v) end
        elseif DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then
            config[k] = v
        end
    end
end
load_config()

emit("HDR", { VERSION, session, config.auto_parry, config.parry_lead, config.lead_rotation, config.scan,
              LEAD_MIN, LONG_WINDOW, VETO_HORIZON, CREDIT })

-- ---------- L 轮换（PARAMETERS parry_lead） ----------
-- 每 5 次一组、组内乱序：避免与怪物连招节奏同相；20 是唯一有 2/2 实测成功的档，留作对照。
-- 只有真的进入 (2,23) 才前进一档：没放出去的那次不算这一档的样本。
math.randomseed(session)
local function new_rotation_group()
    local g = {}
    for i, v in ipairs(ROTATION) do g[i] = v end
    for i = #g, 2, -1 do
        local j = math.random(i)
        g[i], g[j] = g[j], g[i]
    end
    return g
end
local rot = { group = new_rotation_group(), pos = 1 }

local function current_lead()
    if config.lead_rotation then return rot.group[rot.pos] end
    return config.parry_lead
end

local function advance_rotation()
    if not config.lead_rotation then return end
    rot.pos = rot.pos + 1
    if rot.pos > #rot.group then
        rot.group = new_rotation_group()
        rot.pos = 1
    end
end

-- ---------- 游戏类型与枚举 ----------
-- 枚举表写法沿用 AGPCall（实测）：遍历静态字段取 get_data(nil)；表里没有再按名字直接取
local function enum_value(type_name, name)
    local td = sdk.find_type_definition(type_name)
    if not td then error("type not found: " .. type_name) end
    for _, f in ipairs(td:get_fields()) do
        if f:is_static() and f:get_name() == name then
            local v = f:get_data(nil)
            if type(v) == "number" then return v end
        end
    end
    local f = td:get_field(name)
    local v = f and f:get_data(nil)
    if type(v) ~= "number" then error("enum value not found: " .. type_name .. "." .. name) end
    return v
end

local RT_DANGER = nil        -- app.AttackAreaResult.RESULT_TYPE.DANGER
local SLASH_ID = nil         -- ace.ACTION_ID (2,23)
local EFFECT_DAMAGE = nil    -- app.HitDef.DAMAGE_TYPE 的 EAR/WIND/QUAKE（咆哮、风压、震动不是能抵消的打击）
local T_ENEMY = nil          -- sdk.typeof("app.EnemyCharacter")
local MSG_TYPE = "app.game_message.cMsgEmAttackAreaResult"
local SLASH_SIG = "changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)"

local function self_stop_init(err)
    -- 核心类型都拿不到，规则无法运行：直接自停并标红
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

    ok, err = pcall(function()
        local t = {}
        for _, n in ipairs({ "EAR", "WIND", "QUAKE" }) do t[enum_value("app.HitDef.DAMAGE_TYPE", n)] = n end
        EFFECT_DAMAGE = t
    end)
    if not ok then note_error("dmgtype", err) end

    ok, err = pcall(function() T_ENEMY = sdk.typeof("app.EnemyCharacter") end)
    if not ok or not T_ENEMY then note_error("scan", ok and "typeof app.EnemyCharacter = nil" or err) end
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

local function release_obj(obj)
    if obj then pcall(obj.release, obj) end
end

-- 唯一有副作用的游戏调用：帧开头请求上捞斩，走动作控制器的正常进入流程（NOTES「改动作」实测）
local function request_slash(hunter)
    local ok, res = pcall(hunter.call, hunter, SLASH_SIG, LAYER_BASE, SLASH_ID, false)
    if not ok then
        note_error("fire", res)
        return false
    end
    return res
end

-- ---------- 预告跟踪（PLAN 参数表「预告跟踪与释放」） ----------
-- 预告对象是怪物那边的、会被复用，跨帧持有要 add_ref，丢弃时 release，必须成对。
-- 修掉 v1.3 的两个隐患：只认第一条消息（同一对象重发时刷新 t_msg）、5 s 后一律丢弃（改 8 s）。
local tracks = {}           -- [结果地址] = { obj, t_msg, n_msg, em, fb, fo }
local n_tracks = 0
local me_addr = nil         -- 主角 HunterCharacter 地址（每帧更新）
local me_gs = false

local function drop_track(key)
    local tr = tracks[key]
    if not tr then return end
    tracks[key] = nil
    n_tracks = n_tracks - 1
    release_obj(tr.obj)
end

local function release_all_tracks()
    for key in pairs(tracks) do drop_track(key) end
end

-- 满了丢 t_msg 最旧的（最久没收到消息的那条；CONTRACT 3.3，探针同一口径），不按登记先后：
-- 一直在重发的预告是活的，不该因为登记得早被挤掉
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

local function on_message(args)
    if not config.auto_parry or err_state.stopped or not me_addr or not me_gs then return end
    local msg = sdk.to_managed_object(args[3])
    if not msg or msg:get_type_definition():get_full_name() ~= MSG_TYPE then return end
    local r = msg:call("get_AttackAreaResult")
    if not r then return end
    local key = r:get_address()
    local now = os.clock()
    local tr = tracks[key]
    if tr then
        tr.t_msg = now
        tr.n_msg = tr.n_msg + 1
        return
    end
    local target = r:call("get_TargetCharacter")
    if not target or target:get_address() ~= me_addr then return end
    -- 到达时就已结束的不跟踪（训练机关每个周期都发 fin=true 的空预告）
    if r:call("get_IsAttackFinished") then return end
    local em = "em" .. int_s(r:call("get_EmID")) .. "#" .. int_s(r:call("get_EmSystemIndex"))
    if n_tracks >= TRACK_MAX then drop_oldest() end
    r:add_ref()
    tracks[key] = { obj = r, t_msg = now, n_msg = 1, em = em, fb = false, fo = {} }
    n_tracks = n_tracks + 1
end

-- 钩子体耗时（ms，累计到下一行 STAT）：C9(d) 用它和帧回调耗时估 mod 开销占帧时间的比例。
-- REF 的钩子分发开销本身 os.clock 量不到（PLAN「性能与日志预算」），报告里注明
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
local function entry_of(d)
    local hs = d:call("get_HitStartRemainFrame")
    local he = d:call("get_HitEndRemainFrame")
    if type(hs) ~= "number" or type(he) ~= "number" then error("remain frame is not a number") end
    return { d = d, rt = d:call("get_ResultType"), hs = hs, he = he }
end

-- 逐条读（get_Count/get_Item 只在 TDB 核实过，Lua 运行时第一次用 → 出错由调用方退回 closest）
local function read_items(r)
    local list = r:call("get_DetectedDataList")
    if not list then return {} end
    local n = math.tointeger(list:call("get_Count"))
    if not n then error("get_Count is not an integer") end
    local out = {}
    for i = 0, n - 1 do
        local d = list:call("get_Item", i)
        if not d then error("get_Item returned nil") end
        out[#out + 1] = entry_of(d)
    end
    return out
end

local function closest_entries(r)
    local d = r:call("getClosestDetectedData")
    if not d then return {} end
    return { entry_of(d) }
end

-- 弹体：ShellIndex 是 Nullable<Int32>（MCP 核实字段 _HasValue/_Value），有值就是弹体。
-- REF 对 Nullable 的返回形态没在 Lua 里核实过（CONTRACT 1.2）：可能是带 _HasValue 的值类型，也可能
-- 无值时直接给 nil、有值时直接拆箱成数字。三种都认（和探针 nullable_str 一致）；
-- 以前数字形态会在 v:get_field 抛错 → shell 停用 → 之后所有弹体条目都按 fail-open 放刀，正是 PLAN 要排除的情形
local function has_shell(d)
    local v = d:call("get_ShellIndex")
    if v == nil then return false end
    local tv = type(v)
    if tv == "number" then return true end
    if tv ~= "userdata" then error("ShellIndex returned " .. tv) end
    local hv = v:get_field("_HasValue")
    if type(hv) ~= "boolean" then error("ShellIndex._HasValue=" .. tostring(hv)) end
    return hv
end

-- 咆哮、风压、震动：cAttackParamEm._DamageType（app.HitDef.DAMAGE_TYPE，MCP 核实）
-- 返回 true/false；读不到攻击参数返回 nil（按通过处理，计 fail-open）
local function effect_damage(d)
    local ap = d:call("get_AttackParam")
    if ap == nil then return nil end
    local t = ap:get_field("_DamageType")
    if type(t) ~= "number" then error("_DamageType=" .. tostring(t)) end
    return EFFECT_DAMAGE[t] ~= nil
end

-- fail-open：这些读取第一次在真怪上运行时可能出错，不能因此一刀都不放、整轮拿不到数据（PLAN 参数表）
local function fail_open(tr, d)
    local key = addr_of(d) or tostring(d)
    if not tr.fo[key] then
        tr.fo[key] = true
        stats.failopen = stats.failopen + 1
    end
end

local function pass_filters(tr, d)
    if mod_off.shell then
        fail_open(tr, d)
    else
        local ok, res = pcall(has_shell, d)
        if not ok then
            note_error("shell", res)
            fail_open(tr, d)
        elseif res then
            return false
        end
    end
    if mod_off.dmgtype or not EFFECT_DAMAGE then
        fail_open(tr, d)
    else
        local ok, res = pcall(effect_damage, d)
        if not ok then
            note_error("dmgtype", res)
            fail_open(tr, d)
        elseif res == nil then
            fail_open(tr, d)
        elseif res then
            return false
        end
    end
    return true
end

-- 否决 V 与候选 C：ev.veto = hs 最小的长窗口 DANGER；ev.best = C 里 hs 最小的（只看 hs ≤ L 的，
-- 因为只有 Q* ≤ L 才放刀；过滤器只对可能成为新最小值的条目读，省调用）
local function consider(tr, list, src, ev)
    for i = 1, #list do
        local e = list[i]
        if e.rt == RT_DANGER then
            local hs, he = e.hs, e.he
            local w = he - hs
            if w > LONG_WINDOW and hs <= VETO_HORIZON and he >= 0 then
                if not ev.veto or hs < ev.veto.e.hs then ev.veto = { tr = tr, e = e } end
            end
            if hs >= LEAD_MIN and hs <= ev.L and w >= 0 and w <= LONG_WINDOW
                and (not ev.best or hs < ev.best.e.hs) and pass_filters(tr, e.d) then
                ev.best = { tr = tr, e = e, src = src }   -- Q(d) = hs + α·(he-hs)，α=0
            end
        end
    end
end

-- 每帧每条预告：先按释放条件清理；ev 非 nil 时（在蓄力中且开关开着）再参与规则求值
local function process_track(tr, now, ev)
    local age = now - tr.t_msg
    if age >= TRACK_STALE then return "stale" end
    local r = tr.obj
    if r:call("get_IsAttackFinished") then return "finished" end
    if not ev and age < PAST_AGE then return nil end

    local list, src = nil, "V0"
    if not mod_off.items then
        local ok, res = pcall(read_items, r)
        if ok then list = res else note_error("items", res) end
    end
    if not list then
        src = "FB"
        list = closest_entries(r)
    end

    -- 「全部条目 he < -30」只对非空列表成立：未结束、暂时没有条目的结果要继续持有到 8 s。
    -- 否则之后不重发消息就冒出来的 DANGER 条目 rc 看不到，而探针（n_ent>0 才算）和离线影子回放照样看得到
    if age >= PAST_AGE and #list > 0 then
        local past = true
        for i = 1, #list do
            if not (list[i].he < PAST_HE) then
                past = false
                break
            end
        end
        if past then return "past" end
    end

    if ev then
        local target = r:call("get_TargetCharacter")
        if target and target:get_address() == me_addr then
            if src == "V0" then
                consider(tr, list, src, ev)
            elseif #list > 0 and r:call("get_ResultType") == RT_DANGER then
                -- 兜底（PLAN rc 专有）：整体是 DANGER 就用 closest 那一条代替
                if not tr.fb then
                    tr.fb = true
                    stats.fb = stats.fb + 1
                end
                list[1].rt = RT_DANGER
                consider(tr, list, src, ev)
            end
        end
    end
    return nil
end

-- 清理全部跟踪；L 非 nil 时同时求值，返回 ev = { L, veto, best }
local function evaluate(now, L)
    local ev = L and { L = L } or nil
    for key, tr in pairs(tracks) do
        local ok, why = pcall(process_track, tr, now, ev)
        if not ok then
            -- 单条预告读坏了：丢掉它（释放引用），计一次帧逻辑错误，不连累别的预告
            note_error("frame", why)
            drop_track(key)
        elseif why then
            drop_track(key)
        end
    end
    return ev
end

-- ---------- 放刀 streak、否决、结局（P19） ----------
local streak = nil          -- { id, t, n, r1 }：条件连续成立的帧合并为一次放刀
local veto_on = false
local res_wait = nil        -- { id, t }：已进入 (2,23)，等 CREDIT 秒内进 (2,25..27)
local act_cat, act_idx = nil, nil   -- 本帧主角动作（HUD、空闲判断用，不在 UI 线程里调游戏方法）

local function keep_text(r)
    local k = r:call("get_KeepActionID")
    if not k then return nil end
    return "(" .. int_s(k:get_field("_Category")) .. "," .. int_s(k:get_field("_Index")) .. ")"
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
    local id = new_id()
    streak = { id = id, t = now, n = 0, r1 = e.hs }
    stats.fires = stats.fires + 1
    emit("FIRE", { id, now, L, e.hs, e.he, best.src, addr_of(e.d), addr_of(tr.obj), tr.em, keep,
                   "(" .. int_s(CAT_ATTACK) .. "," .. int_s(idx) .. ")" })
end

-- R1 记的是最后一个请求帧的 Q*：那一帧的请求被接受，下一帧就在 (2,23) 里了（v1.3 实测都是下一帧）
local function end_streak(now, entered)
    local s = streak
    streak = nil
    emit("FIRE_END", { s.id, now, s.r1, s.n, entered })
    if res_wait then finish_res(now, "NOCATCH") end
    res_wait = { id = s.id, t = s.t }
    if entered then
        advance_rotation()
    else
        finish_res(now, "NOCATCH")    -- 没放出去：每个 FIRE 都有一行 RES，离线一一对应
    end
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
    local ev = evaluate(now, active and current_lead() or nil)
    if not active then
        if streak then end_streak(now, false) end
        veto_on = false
        return
    end

    if ev.veto then
        if not veto_on then
            veto_on = true
            stats.vetoes = stats.vetoes + 1
            local v = ev.veto
            emit("VETO", { now, v.e.hs, v.e.he, addr_of(v.tr.obj), addr_of(v.e.d), v.tr.em })
        end
    else
        veto_on = false
    end

    local best = ev.best
    if best and not ev.veto then
        -- Q* ≤ L 已在 consider 里保证；不设超时：Q 单调递减，离开 [L_min, L] 自然停
        if not streak then start_streak(now, ev.L, best, idx) end
        streak.n = streak.n + 1
        streak.r1 = best.e.hs
        request_slash(hunter)
    elseif streak then
        end_streak(now, false)
    end
end

-- ---------- 机关扫描（rc 测试模式，默认关；PLAN 参数表「机关扫描」、P20） ----------
-- 机关是测抵消窗口的仪器：出招时序固定（cSmallAttack 首帧后约 1.13 s 接触），没有预告数据也能按时间放刀。
-- 唯一的变量是 X =「放刀 → 机关接触」：t_req = t0 + D_c − X − δ。
-- 流程：认机关（开扫描后第一次敌方接触的攻击者）→ 前 2 个有效周期只学 D_c → 粗网格乱序各 1 次 →
--   成功/失败交界两侧按 0.02 细化（每条边界最多 6 点）→ 交界两端各重复 1 次 → 有效样本满 24 完成。
-- SCAN 行字段约定（离线按这个读）：
--   phase=learn：Dc = 本周期实测的「接触 − t0」，X/t_req 为 -；status=OK 才计入 D_c（取最近 5 次中位数），
--                VOID 的 reason = em_act / hunter_act / hitch / no_contact / bad_dc。
--   phase=fire ：X = 目标值，Dc = 排期用的 D_c，t_req = 第一次请求的时刻（没放出去为 -）；
--                status=OK 时 reason = 在线结局 CATCH25/26/27 或 NOCATCH（CREDIT 秒内是否进 (2,25..27)），
--                status=VOID 时 reason = 作废原因：em_act / hunter_act / no_contact / hitch / req_fail（放了刀，算一次尝试）、
--                not_charging / contact_before_req（没放刀，不算尝试，X 放回队列）。
--   phase=done ：reason = valid24 / cap36 / timeout / exhausted / off / error / reset /
--                lost（主角对象换了，即切场景：机关不在了，扫描就此结束；只是短暂为 nil 不算）。
-- 正式的窗口估计用探针测到的 c_first（PLAN C1），这里的 X 只是排期目标。
local scan = {}

local function median(t)
    local c = {}
    for i, v in ipairs(t) do c[i] = v end
    table.sort(c)
    local n = #c
    if n == 0 then return nil end
    if n % 2 == 1 then return c[(n + 1) // 2] end
    return (c[n // 2] + c[n // 2 + 1]) / 2
end

local function shuffled(list)
    local g = {}
    for i, v in ipairs(list) do g[i] = v end
    for i = #g, 2, -1 do
        local j = math.random(i)
        g[i], g[j] = g[j], g[i]
    end
    return g
end

local function scan_reset_state()
    scan.active = false
    scan.t_start = nil
    scan.dummy, scan.dummy_key, scan.prev_leaf, scan.cyc = nil, nil, nil, nil
    scan.learned = {}               -- D_c 样本：不放刀的有效周期（接触 − cSmallAttack 首帧）
    scan.dc = SCAN_DC0
    scan.deltas = {}
    scan.delta = SCAN_DELTA0
    scan.queue = shuffled(SCAN_COARSE)
    scan.att = {}                   -- [X] = 放过几刀（含作废）
    scan.res = {}                   -- [X] = { pass, fail }（只算有效样本）
    scan.side_n = { lo = 0, hi = 0 }
    scan.valid = 0
    scan.fired = 0
    scan.rehold = false
    scan.finished = nil
end
scan_reset_state()

local function scan_drop_dummy()
    if scan.dummy then release_obj(scan.dummy) end
    scan.dummy, scan.dummy_key, scan.prev_leaf, scan.cyc = nil, nil, nil, nil
end

local function scan_start(now)
    scan_drop_dummy()
    scan_reset_state()
    scan.active = true
    scan.t_start = now
    dbg("scan_start")
end

local function scan_finish(now, reason)
    if scan.active then emit("SCAN", { new_id(), now, "done", nil, nil, scan.dc, nil, "OK", reason }) end
    scan_drop_dummy()
    scan.active = false
    scan.finished = reason
    config.scan = false      -- 完成后自动关扫描
end

local function n_valid(x)
    local r = scan.res[x]
    return r and (r.pass + r.fail) or 0
end

local function can_try(x) return (scan.att[x] or 0) < SCAN_TRIES end

-- 交界：最小成功点以下最近的失败点（下界），最大成功点以上最近的失败点（上界）。
-- 有重叠时只取最外侧成功点，离线另用 logistic 处理重叠（PLAN C1）。
local function scan_boundaries()
    local xs = {}
    for x, r in pairs(scan.res) do
        if r.pass + r.fail > 0 then xs[#xs + 1] = x end
    end
    table.sort(xs)
    local pmin, pmax = nil, nil
    for _, x in ipairs(xs) do
        local r = scan.res[x]
        if r.pass >= r.fail then
            pmin = pmin or x
            pmax = x
        end
    end
    local out = {}
    if not pmin then return out end
    local lo, hi = nil, nil
    for _, x in ipairs(xs) do
        local r = scan.res[x]
        if r.pass < r.fail then
            if x < pmin then lo = x end
            if x > pmax and not hi then hi = x end
        end
    end
    if lo then out[#out + 1] = { side = "lo", a = lo, b = pmin } end
    if hi then out[#out + 1] = { side = "hi", a = pmax, b = hi } end
    return out
end

local function scan_refine_pick(bd)
    if scan.side_n[bd.side] >= SCAN_SIDE_MAX then return nil end
    local a, b = bd.a, bd.b
    if b - a > SCAN_STEP then
        -- 区间内 0.02 网格上、离中点最近、还没有有效样本的点（二分，最多约 3 次就相邻）
        local mid = (a + b) / 2
        local best, best_d = nil, nil
        for x = a + SCAN_STEP, b - SCAN_STEP, SCAN_STEP do
            if n_valid(x) == 0 and can_try(x) then
                local d = math.abs(x - mid)
                if not best or d < best_d then best, best_d = x, d end
            end
        end
        if best then return best end
    end
    -- 已经相邻：交界两端各重复 1 次
    for _, x in ipairs({ a, b }) do
        if n_valid(x) < 2 and can_try(x) then return x end
    end
    return nil
end

-- 补点（细化预算用完但有效样本还不到 24）：交界 ±0.06 内有效样本少的优先；没有交界就轮流重复粗网格
local function scan_filler(bds)
    local best, best_k = nil, nil
    if #bds > 0 then
        for x = SCAN_X_LO, SCAN_X_HI, SCAN_STEP do
            if can_try(x) then
                local d = math.huge
                for _, bd in ipairs(bds) do d = math.min(d, math.abs(x - (bd.a + bd.b) / 2)) end
                if d <= 6 then
                    local k = n_valid(x) * 1000 + d
                    if not best or k < best_k then best, best_k = x, k end
                end
            end
        end
    end
    if not best then
        for _, x in ipairs(SCAN_COARSE) do
            if can_try(x) then
                local k = n_valid(x) * 1000 + (scan.att[x] or 0)
                if not best or k < best_k then best, best_k = x, k end
            end
        end
    end
    return best
end

-- 返回 X、细化边（lo/hi/nil）、是否来自粗网格队列
local function scan_next_x()
    while #scan.queue > 0 do
        local x = table.remove(scan.queue, 1)
        if can_try(x) then return x, nil, true end
    end
    local bds = scan_boundaries()
    for _, bd in ipairs(bds) do
        local x = scan_refine_pick(bd)
        if x then return x, bd.side, false end
    end
    local x = scan_filler(bds)
    if x then return x, nil, false end
    return nil
end

-- 粗网格的 X 作废或没放出去时放回队列；细化的点不用排队，下次会重新算
local function scan_requeue(c, attempted)
    if not c.from_queue or not can_try(c.X) then return end
    if attempted then
        scan.queue[#scan.queue + 1] = c.X
    else
        table.insert(scan.queue, 1, c.X)
    end
end

local function scan_cycle_begin(now, cat, idx)
    local c = { t0 = now, cat = cat, idx = idx, phase = "learn", dc = scan.dc }
    if #scan.learned >= SCAN_LEARN then
        local x, side, from_queue = scan_next_x()
        if not x then return scan_finish(now, "exhausted") end
        c.phase, c.X, c.side, c.from_queue = "fire", x, side, from_queue
        c.t_plan = now + scan.dc - x / 100 - scan.delta
    end
    scan.cyc = c
end

local function scan_learn_done(c, now, status, reason)
    scan.cyc = nil
    -- 放刀周期改来的学习周期（c.silent）：放刀那一行已经记过，作废就不再另记
    if status ~= "OK" and c.silent then return end
    local D = c.contact and (c.contact - c.t0) or nil
    if status == "OK" then
        scan.learned[#scan.learned + 1] = D
        if #scan.learned > 5 then table.remove(scan.learned, 1) end   -- 取最近 5 次的中位数
        if #scan.learned >= SCAN_LEARN then scan.dc = median(scan.learned) end
    end
    emit("SCAN", { new_id(), now, "learn", nil, c.t0, D, nil, status, reason })
end

-- 不算尝试的作废（到点不在蓄力、计划时刻前就被打到等）：X 放回队列
local function scan_skip(c, now, reason)
    scan_requeue(c, false)
    emit("SCAN", { new_id(), now, "fire", c.X / 100, c.t0, c.dc, nil, "VOID", reason })
end

local function scan_fire_done(c, now, status, reason)
    emit("SCAN", { new_id(), now, "fire", c.X / 100, c.t0, c.dc, c.req_t, status, reason })
    if status == "OK" then
        local r = scan.res[c.X]
        if not r then
            r = { pass = 0, fail = 0 }
            scan.res[c.X] = r
        end
        if reason == "NOCATCH" then r.fail = r.fail + 1 else r.pass = r.pass + 1 end
        scan.valid = scan.valid + 1
        if c.side then scan.side_n[c.side] = scan.side_n[c.side] + 1 end
    else
        scan_requeue(c, true)
    end
    scan.cyc = nil
    scan.rehold = true
    if scan.valid >= SCAN_TARGET then
        scan_finish(now, "valid24")
    elseif scan.fired >= SCAN_CAP then
        scan_finish(now, "cap36")
    end
end

-- δ = t_start − t_req，t_start = (2,23) 首帧时刻 − _RawTotalElapsedSecond（PLAN C 节记号）。
-- _RawTotalElapsedSecond 是真字段（偏移 0x50，MCP 核实），Lua 运行时第一次用：出错只停用这一项、δ 保持初值。
local function scan_measure_delta(c, ctrl, now)
    if mod_off.raw then return end
    local ok, raw = pcall(function()
        local act = ctrl:call("get_CurrentAction")
        return act and act:get_field("_RawTotalElapsedSecond")
    end)
    if not ok then
        note_error("raw", raw)
        return
    end
    if not finite(raw) then return end
    local d = (now - raw) - c.req_t
    if d >= -0.05 and d <= 0.1 then
        scan.deltas[#scan.deltas + 1] = d
        if #scan.deltas > 9 then table.remove(scan.deltas, 1) end
        scan.delta = median(scan.deltas)
    end
end

local frame_dt = 0

local function scan_cycle_step(c, hunter, ctrl, now, cat, idx, charging, leaf)
    local before = c.contact == nil
    -- 作废 1：接触之前机关出了 cSmallAttack/cToSmallAttack 以外的动作（麻痹、受击、转身……）
    if before and not EM_CYCLE_OK[leaf] then c.void = c.void or "em_act" end
    -- 接触之前主角动作和 t0 时不同（学习周期据此作废；放刀周期里我们自己切进 (2,23) 也会置位，不用它）
    if before and (cat ~= c.cat or idx ~= c.idx) then c.moved = true end
    -- 作废 4 的素材：本帧这段时间和 [.., 接触] 有重叠、且 dt > 35 ms。
    -- 分开记两段：学习周期看 [t0, 接触]，放刀周期看 [t_req, 接触]
    if (before or now - frame_dt < c.contact) and frame_dt > HITCH_DT then
        if now > c.t0 then c.hitch_t0 = true end
        if c.req_t and now > c.req_t then c.hitch_req = true end
    end

    if c.phase == "fire" then
        if c.req_t then
            if c.hitch_req then c.void = c.void or "hitch" end
            if not c.entered then
                if cat == CAT_ATTACK and idx == IDX_SLASH then
                    c.entered = true
                    scan_measure_delta(c, ctrl, now)
                elseif charging and now - c.req_t <= SCAN_RETRY then
                    c.tries = c.tries + 1
                    request_slash(hunter)
                else
                    c.void = c.void or "req_fail"
                end
            elseif before and not (cat == CAT_ATTACK and (idx == IDX_SLASH or PARRY_HIT[idx])) then
                -- 作废 2：接触前主角离开了上捞斩
                c.void = c.void or "hunter_act"
            end
            if c.entered and cat == CAT_ATTACK and PARRY_HIT[idx] and not c.hit then c.hit = idx end

            if c.void then return scan_fire_done(c, now, "VOID", c.void) end
            if c.hit then return scan_fire_done(c, now, "OK", "CATCH" .. int_s(c.hit)) end
            if before then
                if now - c.t0 >= SCAN_NO_CONTACT then return scan_fire_done(c, now, "VOID", "no_contact") end
                return
            end
            if now - c.req_t >= CREDIT then return scan_fire_done(c, now, "OK", "NOCATCH") end
            return
        end

        -- 还没放刀
        if c.void then
            scan_skip(c, now, c.void)
            scan.cyc = nil
            return
        end
        if before and now >= c.t_plan and charging then
            c.req_t, c.tries = now, 1
            scan.fired = scan.fired + 1
            scan.att[c.X] = (scan.att[c.X] or 0) + 1
            request_slash(hunter)
            return
        end
        if before and now < c.t_plan then return end
        -- 没放出去：到点主角不在蓄力，或计划时刻之前就被打到（D_c 偏大）。不算尝试，X 放回队列；
        -- 本周期改作学习周期：主角动作从 t0 到接触都没变才算一个 D_c 样本（PLAN「之后取最近 5 次的中位数」）
        scan_skip(c, now, before and "not_charging" or "contact_before_req")
        c.phase, c.silent = "learn", true
    end

    -- 学习周期：接触前主角换过动作就作废（站位可能变了，D_c 不可比）
    if c.moved then c.void = c.void or "hunter_act" end
    if c.hitch_t0 then c.void = c.void or "hitch" end
    if c.void then return scan_learn_done(c, now, "VOID", c.void) end
    if not before then
        local D = c.contact - c.t0
        if D < 0.6 or D > SCAN_NO_CONTACT then return scan_learn_done(c, now, "VOID", "bad_dc") end
        return scan_learn_done(c, now, "OK", nil)
    end
    if now - c.t0 >= SCAN_NO_CONTACT then return scan_learn_done(c, now, "VOID", "no_contact") end
end

local function scan_update(hunter, ctrl, now, cat, idx)
    if not config.scan or mod_off.scan then
        if scan.active then scan_finish(now, mod_off.scan and "error" or "off") end
        config.scan = false
        return
    end
    if not scan.active then scan_start(now) end
    if now - scan.t_start >= SCAN_MAX_TIME then return scan_finish(now, "timeout") end
    local charging = me_gs and cat == CAT_ATTACK and PARRY_CHARGE[idx] == true
    if charging then scan.rehold = false end
    if not scan.dummy then return end
    if not config.auto_parry or err_state.stopped then
        scan.cyc = nil          -- 总开关关了：暂停，不放刀
        return
    end
    local act = scan.dummy:call("getCurrentAction()")
    local name = act and act:get_type_definition():get_full_name() or "-"
    local leaf = name:match("([^%.]+)$") or name
    -- 完整名 app.Em0165_00Action.cSmallAttack（日志实见，MCP 核实只有训练机关有这个类）。
    -- prev_leaf 为 nil 表示刚认出机关、还不知道上一帧的动作：认机关那一下正处在 cSmallAttack 中途，
    -- 首帧已经错过，不能当成新周期的 t0。
    local started = leaf == "cSmallAttack" and scan.prev_leaf ~= nil and scan.prev_leaf ~= "cSmallAttack"
    scan.prev_leaf = leaf
    if scan.cyc then scan_cycle_step(scan.cyc, hunter, ctrl, now, cat, idx, charging, leaf) end
    if started and not scan.cyc and scan.active then scan_cycle_begin(now, cat, idx) end
end

-- 扫描模式下自己钩一次主角受击：认机关、拿接触时刻（刀上的抵消碰撞也会进这个钩子）。
-- 不在扫描模式时第一行就返回。
local function on_hunter_hit(args)
    if not scan.active or mod_off.scan or not me_addr or not config.auto_parry or err_state.stopped then return end
    local hunter = sdk.to_managed_object(args[2])
    if not hunter or hunter:get_address() ~= me_addr then return end
    local info = sdk.to_managed_object(args[3])
    local owner = info and info:call("get_AttackOwner")
    if not owner then return end
    local enemy = owner:call("getComponent(System.Type)", T_ENEMY)
    if not enemy then return end
    if not scan.dummy then
        -- 只认训练机关（完整类名前缀核对，见 DUMMY_CLASS_PREFIX）；别的怪打到主角不当机关
        local act = enemy:call("getCurrentAction()")
        local cls = act and act:get_type_definition():get_full_name() or "-"
        if cls:sub(1, #DUMMY_CLASS_PREFIX) ~= DUMMY_CLASS_PREFIX then
            dbg("scan_not_dummy", "cls", cls)
            return
        end
        enemy:add_ref()
        scan.dummy = enemy
        scan.dummy_key = enemy:get_address()
        scan.prev_leaf = nil
        dbg("scan_dummy", "addr", safe_fmt("%X", math.tointeger(scan.dummy_key) or 0))
        return
    end
    if enemy:get_address() ~= scan.dummy_key then return end
    local c = scan.cyc
    if c and not c.contact then c.contact = os.clock() end
end

do
    local ok, err = pcall(function()
        local td = sdk.find_type_definition("app.HunterCharacter")
        sdk.hook(td:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
            local t0 = os.clock()
            local ok2, err2 = pcall(on_hunter_hit, args)
            if not ok2 then note_error("scan", err2) end
            hook_ms = hook_ms + (os.clock() - t0) * 1000.0
        end, nil)
    end)
    if not ok then note_error("scan", err) end
end

local function scan_hint()
    if scan.active then
        local prog = "扫描 " .. int_s(scan.valid) .. "/" .. int_s(SCAN_TARGET)
        if not config.auto_parry then return prog .. " 暂停（自动放刀已关）" end
        if not scan.dummy then return "等待机关出招" end
        local charging = me_gs and act_cat == CAT_ATTACK and act_idx ~= nil and PARRY_CHARGE[act_idx] == true
        if not charging then return prog .. (scan.rehold and " 重新按住" or " 按住") end
        if #scan.learned < SCAN_LEARN then
            return prog .. " 学习 " .. int_s(#scan.learned) .. "/" .. int_s(SCAN_LEARN)
        end
        return prog
    end
    if scan.finished == "error" then return "扫描出错已停" end
    if scan.finished == "lost" then return "扫描中断（换了场景），回到机关前重新勾选「机关扫描」" end
    if scan.finished and scan.finished ~= "off" then
        return "扫描完成 " .. int_s(scan.valid) .. "/" .. int_s(SCAN_TARGET)
    end
    return nil
end

-- ---------- 每帧 ----------
local last_frame_t = nil
local consec_err = 0
local last_stat_t = os.clock()
local action_gap = false    -- 上一帧是否「主角在、但读不到当前动作」（只用来在进出时各写一行 DBG）

local function lose_hunter(now)
    -- 主角为 nil 或换了（换场景等）：全部释放
    release_all_tracks()
    if streak then end_streak(now, false) end
    veto_on = false
    if res_wait then finish_res(now, "NOCATCH") end
    -- 机关对象一并放掉。扫描还开着时，下一次被打到会重新认机关：认机关核对完整类名（DUMMY_CLASS_PREFIX），
    -- 真怪不会被认成机关。主角对象真的换了（切场景）则在 frame_logic 里结束扫描
    scan_drop_dummy()
    me_addr = nil
end

-- 上一次见到的主角对象地址（主角为 nil 时不清）：重新出现时地址变了 = 换了场景（读盘时通常先 nil 一段再换新对象）
local last_hunter_addr = nil

-- 取主角 → 武器 → 动作控制器 → 动作 ID。返回 nil = 本帧没有主角
local function read_hunter()
    local hunter = master_hunter()
    if not hunter then return nil end
    local addr = hunter:get_address()
    local gs = hunter:call("get_WeaponType") == WEAPON_GREAT_SWORD
    local ctrl = hunter:call("get_BaseActionController")
    local id = ctrl and ctrl:call("get_CurrentActionID")
    local cat, idx = nil, nil
    if id then cat, idx = id:get_field("_Category"), id:get_field("_Index") end
    return { hunter = hunter, addr = addr, gs = gs, ctrl = ctrl, cat = cat, idx = idx }
end

local read_fail = { t0 = nil, t_last = nil, n = 0 }

-- 读主角抛错时：容忍期内返回 false（这一帧跳过），超过容忍期返回 true（按帧逻辑出错处理）
local function read_failed(now, err)
    local F = read_fail
    if not F.t0 or now - F.t_last > READ_FAIL_GAP then
        F.t0, F.n = now, 0
        -- 非 ASCII 换成 ?（错误文本里的路径可能是系统代码页），再截断，免得切坏多字节字符
        dbg("read_fail", "err", (tostring(err):gsub("[\128-\255]", "?")):sub(1, 120))
    end
    F.t_last = now
    F.n = F.n + 1
    stats.readfail = stats.readfail + 1
    return now - F.t0 >= READ_FAIL_TOL
end

local function frame_logic(now)
    local ok_read, H = pcall(read_hunter)
    if not ok_read then
        if read_failed(now, H) then error(H, 0) end
        return      -- 容忍期内：这一帧不存在（不求值、不放刀、streak 和跟踪都保持原样）
    end
    if read_fail.t0 and now - read_fail.t_last > READ_FAIL_GAP then
        dbg("read_back", "frames", read_fail.n, "dur", safe_fmt("%.3f", read_fail.t_last - read_fail.t0))
        read_fail.t0 = nil
    end
    if not H then
        if me_addr or n_tracks > 0 then lose_hunter(now) end
        me_gs, act_cat, act_idx = false, nil, nil
        return
    end
    local hunter, addr, ctrl, cat, idx = H.hunter, H.addr, H.ctrl, H.cat, H.idx
    if me_addr and addr ~= me_addr then lose_hunter(now) end
    -- 扫描中换了场景：机关不在了，扫描就此结束（自动关扫描，SCAN done reason=lost）。以前只放掉机关对象、
    -- scan.active 还是真，之后第一只打到主角的怪会被认成机关，持有并每帧轮询到 10 分钟超时（审查 runtime）
    if scan.active and last_hunter_addr and addr ~= last_hunter_addr then scan_finish(now, "lost") end
    last_hunter_addr = addr
    me_addr = addr
    me_gs = H.gs
    -- 主角对象在、动作控制器或动作 ID 暂时读不到（切场景、加载的头几帧）：这一帧按「不在蓄力」处理
    -- （前提 P3 不成立：结束 streak、不放刀，预告照常按时间释放），不算帧逻辑出错 —— 和探针 ACT 的处理一致。
    -- 否则这几帧会连续报错，满 30 帧 rc 就自停标红，这一轮剩下的时间都放不了刀。进出这种状态各写一行 DBG
    local no_action = cat == nil or idx == nil
    if no_action ~= action_gap then
        action_gap = no_action
        dbg(no_action and "no_action" or "action_back")
    end
    act_cat, act_idx = cat, idx
    -- 关开关时全部释放（菜单回调里只改配置，不碰游戏对象）
    if not config.auto_parry then
        if n_tracks > 0 then release_all_tracks() end
        if scan.dummy then scan_drop_dummy() end
    end

    update_fire(hunter, now, cat, idx)

    if config.scan or scan.active then
        local ok, err = pcall(scan_update, hunter, ctrl, now, cat, idx)
        if not ok then
            note_error("scan", err)
            pcall(scan_finish, now, "error")
            config.scan = false
        end
    end
end

local function self_stop(now)
    err_state.stopped = true
    set_red(now, "frame", "self_stop")
    pcall(function()
        release_all_tracks()
        if streak then end_streak(now, false) end
        if scan.active then scan_finish(now, "error") end
        scan_drop_dummy()
    end)
    log.info(dbg_line("self_stop", "why", "frame_logic_failed", "frames", STOP_FRAMES))   -- 不受 debug_log 开关控制
end

local function is_idle()
    if streak or res_wait or scan.cyc then return false end
    if act_cat == CAT_ATTACK and act_idx and act_idx >= 21 and act_idx <= 29 then return false end
    return true
end

-- 帧回调耗时窗口（到下一行 STAT 为止）：C9(d) 用「两个脚本的 Lua 耗时占帧时间的比例」估 mod 开销
local lua_win = { sum = 0.0, n = 0, max = 0.0, t0 = os.clock() }

-- STAT：每 60 s 一行；点「写出数据」和 Reset 时先补写一行，让最后的计数进 JSON
local function stat_emit(now)
    last_stat_t = now
    local W = lua_win
    local span = now - W.t0
    emit("STAT", { stats.fires, stats.catches, stats.vetoes, stats.fb, stats.failopen, stats.errors,
        stats.err_red, stats.err_yellow, W.n > 0 and W.sum / W.n or nil, W.n > 0 and W.max or nil,
        span > 0 and hook_ms / span or nil, stats.readfail })
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
    frame_dt = last_frame_t and (now - last_frame_t) or 0
    last_frame_t = now
    if not err_state.stopped then
        local ok, err = pcall(frame_logic, now)
        if ok then
            consec_err = 0
        else
            consec_err = consec_err + 1
            note_error("frame", err)
            if consec_err >= STOP_FRAMES then self_stop(now) end
        end
    end
    local ok2, err2 = pcall(periodic, now)
    if not ok2 then note_error("json", err2) end
    err_flush(now)
    local ms = (os.clock() - now) * 1000.0
    local W = lua_win
    W.sum, W.n = W.sum + ms, W.n + 1
    if ms > W.max then W.max = ms end
end)

-- ---------- HUD（re.on_frame + draw.text；失败退回 imgui 窗口，再失败只在菜单里显示） ----------
local hud_mode = "draw"

local function hud_text()
    if err_state.red then return "自动放刀 rc 出错，停下发日志", COLOR_RED end
    local s
    if config.auto_parry then
        s = "自动放刀 rc L=" .. int_s(current_lead()) .. " 放刀 " .. int_s(stats.fires) ..
            " 接住 " .. int_s(stats.catches) .. " 否决 " .. int_s(stats.vetoes)
    else
        s = "自动放刀 rc 已关闭"
    end
    local hint = scan_hint()
    if hint then s = s .. " | " .. hint end
    if err_state.yellow > 0 then return s .. " | 黄 " .. int_s(err_state.yellow), COLOR_YELLOW end
    return s, COLOR_WHITE
end

local function draw_hud(text, color)
    draw.text(text, HUD_X + 1, HUD_Y + 1, COLOR_SHADOW)
    draw.text(text, HUD_X, HUD_Y, color)
end

local function window_hud(text, color)
    -- open 传 nil：没有关闭按钮，begin_window 返回 true 时必须配对 end_window
    if imgui.begin_window("自动放刀 rc##AutoParryGS_HUD", nil, HUD_WINDOW_FLAGS) then
        local ok, err = pcall(imgui.text_colored, text, color)
        imgui.end_window()
        if not ok then error(err) end
    end
end

re.on_frame(function()
    if hud_mode == "off" then return end
    local ok, text, color = pcall(hud_text)
    if not ok then
        note_error("hud", text)
        hud_mode = "off"
        return
    end
    if hud_mode == "draw" then
        local ok2, err2 = pcall(draw_hud, text, color)
        if ok2 then return end
        note_error("hud", err2)
        hud_mode = "window"
    end
    local ok3, err3 = pcall(window_hud, text, color)
    if not ok3 then
        note_error("hudwin", err3)
        hud_mode = "off"
    end
end)

-- ---------- 菜单 ----------
local function status_line()
    if err_state.stopped then return "状态：已自停（帧逻辑连续出错），请停下发日志，然后 Reset Scripts" end
    if err_state.red then return "状态：核心模块出错，请停下发日志" end
    if err_state.yellow > 0 then return "状态：有可选模块停用（黄 " .. int_s(err_state.yellow) .. "），测量继续" end
    return "状态：正常"
end

local function draw_menu()
    local changed, v
    imgui.text("版本 " .. VERSION .. "（第 1 轮标定版）  " .. status_line())
    local hud_ok, hud = pcall(hud_text)
    if hud_ok then imgui.text(hud) end

    changed, v = imgui.checkbox("启用自动放刀##ap_enabled", config.auto_parry)
    if changed then
        config.auto_parry = v      -- 预告的释放在下一帧的帧逻辑里做
        dbg("cfg", "auto_parry", v)
    end

    changed, v = imgui.checkbox("提前量轮换 20/24/28/32/36（第 1 轮标定用）##ap_rotation", config.lead_rotation)
    if changed then
        config.lead_rotation = v
        dbg("cfg", "lead_rotation", v)
    end
    if config.lead_rotation then
        imgui.text("提前量 L=" .. int_s(current_lead()) .. " 帧（轮换中第 " .. int_s(rot.pos) .. "/5 档，滑块不生效；进入上捞斩才换下一档）")
    else
        changed, v = imgui.slider_int("提前量（帧，1/60 秒）##ap_lead", config.parry_lead, LEAD_LO, LEAD_HI)
        if changed then
            config.parry_lead = clamp_lead(v)
            dbg("cfg", "parry_lead", config.parry_lead)
        end
    end

    changed, v = imgui.checkbox("机关扫描（测试模式，站到机关正前方一步按住抵消蓄力；完成后自动关闭）##ap_scan", config.scan)
    if changed and not mod_off.scan then
        config.scan = v            -- 开始和结束在下一帧的帧逻辑里做
        dbg("cfg", "scan", v)
    end
    if mod_off.scan then imgui.text("机关扫描模块出错已停用（见错误详情），Reset Scripts 后才能再开") end
    local hint = scan_hint()
    if hint then imgui.text("扫描：" .. hint .. "  已放 " .. int_s(scan.fired) .. "/" .. int_s(SCAN_CAP)) end

    imgui.separator()
    imgui.text("放刀 " .. int_s(stats.fires) .. "  接住 " .. int_s(stats.catches) .. "  否决 " .. int_s(stats.vetoes) ..
        "  兜底 " .. int_s(stats.fb) .. "  fail-open " .. int_s(stats.failopen) .. "  错误 " .. int_s(stats.errors) ..
        "（核心 " .. int_s(stats.err_red) .. " 可选 " .. int_s(stats.err_yellow) .. "）" ..
        (stats.readfail > 0 and ("  读主角抛错跳过 " .. int_s(stats.readfail) .. " 帧") or ""))
    imgui.text("跟踪中的预告 " .. int_s(n_tracks) .. " 条  待写出记录 " .. int_s(#records) .. " 条" ..
        (rec_dropped > 0 and ("  丢弃 " .. int_s(rec_dropped)) or ""))

    changed, v = imgui.checkbox("调试日志##ap_debug", config.debug_log)
    if changed then config.debug_log = v end
    if imgui.button("清零统计##ap_reset") then
        for k in pairs(stats) do stats[k] = 0 end
    end
    imgui.same_line()
    if imgui.button("写出数据##ap_dump") then
        want_dump = true           -- 下一帧在游戏线程里写
        json_status = "写出中……"
    end
    if json_status ~= "" then imgui.text(json_status) end

    for _, line in ipairs(err_state.recent) do imgui.text("错误 " .. line) end
end

-- 完整菜单出过错（ui 模块停用）后只画这几行：状态、写出数据、错误详情
local function draw_menu_min()
    imgui.text("菜单出错已简化  " .. status_line())
    if imgui.button("写出数据##ap_dump_min") then want_dump = true end
    for _, line in ipairs(err_state.recent) do imgui.text("错误 " .. line) end
end

re.on_draw_ui(function()
    if not imgui.tree_node("自动放刀 rc##AutoParryGS") then return end
    local ok, err = pcall(mod_off.ui and draw_menu_min or draw_menu)
    imgui.tree_pop()                -- 出错也要配对 tree_pop
    if not ok then note_error("ui", err) end
end)

-- ---------- 重置与配置保存 ----------
re.on_script_reset(function()
    local now = os.clock()
    local ok, err = pcall(function()
        if streak then end_streak(now, false) end
        if scan.active then scan_finish(now, "reset") end
        release_all_tracks()
        scan_drop_dummy()
    end)
    if not ok then note_error("frame", err) end
    pcall(stat_emit, now)
    -- 排队还没写进日志的 ERR 行在 reset 时一次写完（JSON 里早就有了）
    while #err_state.queue > 0 do log.info(table.remove(err_state.queue, 1)) end
    pcall(write_json, "reset")
end)

re.on_config_save(function()
    -- 机关扫描是一次性的测试模式（PLAN：默认关、完成后自动关）：「扫描中」不存进配置。
    -- 否则扫描途中退出游戏，下次一加载就又进扫描模式，会把第一只打到主角的真怪当成机关
    local saved = {}
    for k, v in pairs(config) do saved[k] = v end
    saved.scan = false
    local ok, ret = pcall(json.dump_file, CONFIG_PATH, saved)
    if not ok or ret == false then note_error("cfg", ok and "config dump_file returned false" or ret) end
end)

dbg("loaded", "ver", VERSION, "session", session, "L", current_lead())
