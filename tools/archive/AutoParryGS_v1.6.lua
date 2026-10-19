-- AutoParryGS v1.6：大剑自动放刀（抵消上捞斩）
--
-- 原理：按住抵消蓄力 (2,21)/(2,22) 时读怪物发给主角的攻击预告 cMsgEmAttackAreaResult，「打我的」DANGER 条目里最早一段的
--   真实剩余帧 Q 落进 [L_min, L] 就在帧开头请求 (2,23) 上捞斩；抵消、伤害、弹开全部来自刀和攻击的原生碰撞（NOTES「抵消上
--   捞斩」）。唯一有副作用的游戏调用是 changeActionRequest(LAYER 0, (2,23), false)。规格 docs/autoparry/V16.md，没提到的同 V15.md。
-- 时机 E5c（V16 第 2 节；机制 docs/autoparry/SPEED.md 第 1~2 节，4 只怪实测一致）：hs 的初值是怪物 1 倍速下的名义帧、在接收端
--   按真实时间每秒减 60，怪物却按 CoreState 倍速推进，C > 1 时攻击早到约 A·(1−1/C)/60 s（2c 的 em27 有接触 6 刀放早 5）。
--     m = max(1, C)（疲劳 C < 1 按 1，方向远离放早）；X += Δhs·(m_上帧 − 1)（用条目 hs 自己的递减当时钟：卡顿时游戏把扣减钳在
--     约 0.133 s，墙钟会漂）；Q = (hs − (X − X0_e)) / m，X0_e = 条目首见时的 X（C 不变时 Q = hs − A·(1 − 1/m)，即 E1）。
--   C 从登记后第一个帧回调起每帧读、不在钩子里读（CoreState 恰在发消息那一帧按招切换，离线验证的 C 全是下一帧采的）；
--   不用 calcMotionSpeedTotal（含已算进名义帧的招式因子）。读不到：首帧读不到的结果永不放刀、照样参与否决，中途读不到沿用上一
--   帧的 m，连续 5 个新结果首帧读不到报黄；不回退到原始 hs（E0@30 现有数据放早约 26%）。
-- 规则：前提 开关开、大剑、在 (2,21)/(2,22)。否决按原始 hs（同 v1.5.1）：视野（hs ≤ H_veto、he ≥ 0）内有长窗口、抓取或
--   SKILL_GUARD 家族（v1.6 新认，why=sg）就整帧不放。候选按 Q：L_min ≤ Q ≤ L、0 ≤ he−hs ≤ W_long、不是联机副本、通过「该接」
--   过滤，取 Q 最小的（不再要求 hs ≤ 90）；连续成立的帧合并成一次放刀，不设超时。
-- 「该接」（V16 第 3 节，游戏自己的抵消判定 G1，没有按怪、按招的表）：不是弹体；_IsParryBreak 为假（RECOIL 4/4 是 pb=1、WAIT
--   53/53 是 pb=0，实测）；GuardType ∈ {NORMAL, ALL_RANGE}（SKILL_GUARD 只出现在抓取上；UNABLE_GUARD 只在 GESTURE 上、从没测过
--   能不能抵消；新值按不该接）；不是咆哮/风压/震动/抓取。候选侧读不准就不放（放错比不放糟：pb=1 上放刀被弹加挨打，抓取上放刀
--   被抓 259 伤害，实测）；否决侧读不到仍按不是抓取（整帧否决会连带压掉别的可接攻击，是另一个变量）。
-- 参数：L 默认 28（Q 单位，用户定；E1@28 接触层回放窗口内 88/90、放早 0/90，样本内），滑块 23~45；L_min 22；W_long 60、
--   H_veto 90（原始帧）；C 合法范围 [0.5, 2.0] 只剔除坏值。抵消窗口：首个接触 < 0.328 s 接不住、0.331~≥0.944 s 全接住（第 1 轮）。
-- 结局：CREDIT 内进 (2,26)/(2,27) 记接住；进 (2,25) cParrySlashHitS 记 RECOIL（被弹并随即挨打，G1 实测），不算接住。
-- 引用记账（V16 第 5 节、NOTES「跨帧持有与 REF 的引用记账」）：REF 按地址给整个 Lua 状态记一份游戏侧引用、所有脚本共用，谁先
--   手动扣，同时持有的另一个脚本就拿着悬空指针（2c 实测：探针扣掉后 15 ms 本模块 caught (...) exception）。所以登记时只 add_ref、
--   丢弃时只删 Lua 引用，等 userdata 回收时 REF 自动扣，本文件不调任何手动扣引用的接口；B 阶段须和 APCal ≥ 1.1 一起跑（V16 5.4）。
-- 联机未测：发送者怪物 _Context:get_IsMaster() 为 false（副本）的只参与否决、不放刀，读不到按主机处理（fail-open）。
-- 记录：日志 "[AutoParryGS] KIND k=v ..." + reframework/data/AutoParryGS_<会话>_<序号>.json（V16 第 6 节：旧字段不动，新字段
--   追加在后；新增 UVIEW、SKIP）。

local TAG, VERSION = "[AutoParryGS]", "1.6"
local CONFIG_PATH, DATA_PREFIX = "AutoParryGS.json", "AutoParryGS"

-- ---------- 常量（依据见头注释）。剩余帧单位 1/60 s、是 System.Single，格式化一律 %.Nf ----------
local LEAD_DEFAULT, LEAD_LO, LEAD_HI = 28, 23, 45   -- L（Q 单位）默认值与滑块范围（下限 23：[L_min, L] 至少 1 帧宽）
local CFG_VER = 3                   -- 配置格式版本：v1.6 起滑块是「真实剩余帧」，读到 cfg_ver 不是 ≥3 的配置一律迁成 28
local LEAD_MIN, LONG_WINDOW, VETO_HORIZON = 22, 60, 90   -- L_min（Q 单位）；W_long、H_veto（原始帧，只参与否决）
local C_LO, C_HI = 0.5, 2.0         -- CoreState 合法范围：只剔除坏值（NaN、0、乱码）
local SPEED_FAIL_STREAK = 5         -- 连续这么多个新结果首帧读不到 C 就报黄
local CLOCK_DMAX = 30               -- 时钟条目一对读数之间 hs 递减的上限：30 + 60 × 两次读数隔开的秒数（单帧 dt 钳在 0.133 s）
local CREDIT = 1.3                  -- 放刀后 1.3 s 内进 (2,25..27) 才算结局（刀攻击判定顿帧时最晚约 1.22 s 关，G1 实测）
local TRACK_MAX, TRACK_STALE = 32, 8.0   -- 最多跟踪 32 条；距最后一条消息 8 s 丢弃（实测最长预告 402 帧，约 6.7 s）
local PAST_HE, PAST_AGE = -30, 1.0  -- 全部条目 he < -30 且距消息 ≥1 s：这一招早就打完了
local WEAPON_GREAT_SWORD, LAYER_BASE, CAT_ATTACK, IDX_SLASH, IDX_SLASH_FWD = 0, 0, 2, 23, 24   -- (2,23) cParrySlash
local PARRY_CHARGE = { [21] = true, [22] = true }           -- 从 (2,22) 放刀也实测被接受过
local PARRY_OUT = { [25] = "RECOIL", [26] = "CATCH26", [27] = "CATCH27" }   -- 游戏自己切的结局动作（G1：(2,25) 是被弹）
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
-- readerr = 逐条读取出过错的结果数；v1.6 新增的含义见 V16 6.3（ferr 只给菜单用：过滤字段读取出过错的条目数）
local stats = { fires = 0, catches = 0, vetoes = 0, failopen = 0, errors = 0, err_red = 0, err_yellow = 0,
    readfail = 0, replica = 0, readerr = 0, recoils = 0, speedfail = 0, speedhold = 0, clockskip = 0, vetoq = 0,
    fclosed = 0, excl = 0, uview = 0, sidmis = 0, ferr = 0 }
local err_state = { red = false, stopped = false, yellow = 0, logged = 0, last_log = -100.0, times = {}, recent = {},
    queue = {}, json_n = 0, final = false }
local mod_off = {}          -- 报过黄的可选模块（items/speed/filter/filter_enum 例外：报黄但不停用读取，见 draw_status）
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
local function hex(v) return math.tointeger(v) and safe_fmt("%X", math.tointeger(v)) or nil end
local FLOAT_FMT = { i = "%.1f", f1 = "%.1f", f2 = "%.2f", f3 = "%.3f", f4 = "%.4f" }   -- i 字段遇到非整数按 %.1f
-- 返回（日志文本，JSON 值）：布尔写 1/0；地址写成十六进制串（JSON 里 64 位整数不可靠）；nil/NaN/inf → "-"、JSON 省略
local function fmt_value(v, ft)
    if ft == "b" and v ~= nil then v = (v == true or (type(v) == "number" and v ~= 0)) and 1 or 0 end
    if ft == "h" then v = hex(v) end
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

-- 记录种类与字段顺序（CONTRACT 3.4 + V15 4.1 + V16 6.1）：「字段名:格式」，i 整数 / fN N 位小数 / s 文本 / b 布尔 / h 地址。
-- 旧字段一个都不动、新字段只追加在后面（旧解析代码照读）；HDR 的 rotation/scan、STAT 的 fb 恒为 0，FIRE 的 src 恒为 V0
local SPEC = {}
for kind, s in pairs({
    HDR = "ver:s session:i auto_parry:b lead:i rotation:b scan:b L_min:i W_long:i H_veto:i credit:f1 "
        .. "rule:s filter:s cfg_ver:i c_lo:f2 c_hi:f2",
    FIRE = "id:i t:f4 L:i R0:f2 he0:f2 src:s ent:h res:h em:s keep:s from:s "
        .. "C1:f3 Cf:f3 mf:f3 nchg:i dX:f2 A0:f2 Q0:f2 Qp:f2 Qe1:f2 mode:s vq:b",
    FIRE_END = "id:i t:f4 R1:f2 n:i entered:b",
    VETO = "t:f4 hs:f2 he:f2 res:h ent:h em:s why:s",
    RES = "id:i t:f4 outcome:s dt:f3 to:s",
    STAT = "fires:i catches:i vetoes:i fb:i failopen:i errors:i red:i yellow:i lua_ms_avg:f3 lua_ms_max:f3 hook_ms_ps:f3 "
        .. "readfail:i replica:i readerr:i recoils:i speedfail:i speedhold:i clockskip:i vetoq:i fclosed:i excl:i uview:i sidmis:i",
    CFG = "t:f4 auto_parry:b lead:i",
    UVIEW = "id:i t:f4 hs:f2 he:f2 why:s em:s keep:s same:b res:h ent:h",
    SKIP = "t:f4 why:s hs:f2 he:f2 Q:f2 em:s keep:s res:h ent:h",
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
-- 错误分级（CONTRACT 2.1），不许静默吞错：核心模块 10 s 内 3 次标红；可选模块第一次出错就标黄（多数同时停用那项读取，
-- items/speed/filter/filter_enum 例外）。每条错误立刻进 JSON（上限 500）；日志只写前 20 条、排队按 1 行/秒补写
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
-- 只接受认识的键和类型正确的值；rc 留下的 lead_rotation、scan 直接忽略。迁移（V16 2.7）：滑块含义变成「真实剩余帧」，旧值
-- 含义都变了，所以读到了配置文件、cfg_ver 却不是 ≥3 的数（缺失、1、2、字符串 "3"）时一律换成 28；没有配置文件不算迁移
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
    local ver = loaded.cfg_ver
    if not (type(ver) == "number" and ver >= CFG_VER) then
        config.parry_lead = LEAD_DEFAULT
        dbg("cfg_upgrade", "from", loaded.parry_lead, "to", LEAD_DEFAULT)
    end
end
load_config()
emit("HDR", { VERSION, session, config.auto_parry, config.parry_lead, false, false, LEAD_MIN, LONG_WINDOW,
    VETO_HORIZON, CREDIT, "E5c", "g1", CFG_VER, C_LO, C_HI })

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
local effect_partial = false   -- 效果攻击有名字没读到：认不出的伤害类型可能就是它（候选侧读不准 → fc）
local GRAB_DAMAGE = {}      -- app.HitDef.DAMAGE_TYPE 的 CATCH/CATCH_ZAKO/CATCH_SLINGER：抓取，刀碰到了也抵消不了
-- app.Hit.GUARD_TYPE（2026-10-11 MCP 核对：NORMAL、ALL_RANGE、UNABLE_GUARD、SKILL_GUARD、SKILL_GUARD_ALL_RANGE、MAX）：白名单 =
-- 该接；UNABLE_GUARD → SKIP ug；SKILL_GUARD 家族同抓取（否决 why=sg、不进候选）；其余值（含 MAX）未知 → fc
local GUARD_WHITE, GUARD_SG, GUARD_UG = {}, {}, nil
local filter_enum_missing = nil   -- 读不到的过滤枚举名（效果名、白名单名），菜单状态行写清缺了哪个
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
    -- 过滤用的名字逐个读、各组互不连累（V16 3.2）：读到的进 into，读不到的名字进 miss，返回第一个错误
    local function names(type_name, list, into, miss)
        local first = nil
        for _, n in ipairs(list) do
            local ok2, v = pcall(enum_value, type_name, n)
            if ok2 then into[v] = n else miss[#miss + 1], first = n, first or v end
        end
        return first
    end
    -- 效果名或白名单名缺任何一个：报黄 filter_enum，读不准的条目一律 fc（缺效果名 = 这个模块不放刀；缺 NORMAL = NORMAL 全 fc）
    local missing = {}
    local e1 = names("app.HitDef.DAMAGE_TYPE", { "EAR", "WIND", "QUAKE" }, EFFECT_DAMAGE, missing)
    effect_partial = #missing > 0
    local e2 = names("app.Hit.GUARD_TYPE", { "NORMAL", "ALL_RANGE" }, GUARD_WHITE, missing)
    if #missing > 0 then
        filter_enum_missing = table.concat(missing, ",")
        note_error("filter_enum", filter_enum_missing .. " " .. tostring(e1 or e2))
    end
    -- 抓取名、黑名单名缺：只是少认一种抓取 / SG 否决（候选侧白名单已排除），不报黄；跳过了哪些总写一行 DBG（不看调试开关）
    local skipped, gskipped, ug = {}, {}, {}
    names("app.HitDef.DAMAGE_TYPE", { "CATCH", "CATCH_ZAKO", "CATCH_SLINGER" }, GRAB_DAMAGE, skipped)
    if #skipped > 0 then log.info(dbg_line("grab_enum", "skipped", table.concat(skipped, ","))) end
    names("app.Hit.GUARD_TYPE", { "UNABLE_GUARD" }, ug, gskipped)
    GUARD_UG = next(ug)
    names("app.Hit.GUARD_TYPE", { "SKILL_GUARD", "SKILL_GUARD_ALL_RANGE" }, GUARD_SG, gskipped)
    if #gskipped > 0 then log.info(dbg_line("guard_enum", "skipped", table.concat(gskipped, ","))) end
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
-- 唯一有副作用的游戏调用：帧开头请求上捞斩，走动作控制器的正常进入流程（NOTES「改动作」实测）
local function request_slash(hunter)
    local ok, err = pcall(hunter.call, hunter, SLASH_SIG, LAYER_BASE, SLASH_ID, false)
    if not ok then note_error("fire", err) end
end

-- ---------- 预告跟踪（PLAN 参数表「预告跟踪与释放」、CONTRACT 3.3，丢弃条件不变） ----------
-- 跨帧只持有结果对象 tr.obj（登记时 add_ref、丢弃时只删 Lua 引用）；条目、怪物、主角对象只在当帧用，跨帧只存地址和数值
local tracks, n_tracks = {}, 0      -- [结果地址] = 跟踪记录（字段见 on_message）
local me_addr, me_gs = nil, false   -- 主角 HunterCharacter 地址、是不是大剑（每帧更新）
local function drop_track(key) if tracks[key] then tracks[key], n_tracks = nil, n_tracks - 1 end end
local function release_all_tracks() tracks, n_tracks = {}, 0 end
-- 满了丢 t_msg 最旧的（最久没收到消息的），不按登记先后
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

-- 联机闸门：发送者就是怪物本体（第 1 轮 435/435），它的 _Context:get_IsMaster() 为 false = 怪物是副本。链上哪一环是 nil
-- 返回 nil（按主机处理）；返回值不是布尔就抛错。第二个返回值是链上的怪物地址（只存数，sidmis 诊断用，V16 2.5）
local function read_master(msg)
    local go = msg:call("get_SendGameObject")
    local enemy = go and go:call("getComponent(System.Type)", T_ENEMY)
    local snd = enemy and enemy:get_address() or nil
    local holder = enemy and enemy:get_field("_Context")
    if not holder then return nil, snd end
    local m = holder:call("get_IsMaster")
    if type(m) ~= "boolean" then error("get_IsMaster returned " .. tostring(m)) end
    return m, snd
end

-- 钩子里不读速度（见头注释），只存 SystemIndex 和发送者地址。每个结果对象只发一条消息（1620/1620，实测）；万一已跟踪的
-- 结果又来消息只刷新 t_msg：E5c 按条目首见时刻记 X0，不用重置（重置反而会清掉已经累加的 X）
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
    local idx = r:call("get_EmSystemIndex")
    local em = "em" .. int_s(r:call("get_EmID")) .. "#" .. int_s(idx)
    -- 是不是主机只在登记时读一次。读不到按主机处理（fail-open，单人时恒为 true）；抛错第一次标黄并停用这项读取
    local master, snd = nil, nil
    if not mod_off.master then
        local ok, m, a = pcall(read_master, msg)
        if ok then master, snd = m, a else note_error("master", m) end
    end
    if n_tracks >= TRACK_MAX then drop_oldest() end
    r:add_ref()
    -- fo/sk/fe：已计 fail-open / 已写 SKIP / 已计过滤读取错误的条目（每个结果的每条条目一次）。E5c：X = 怪物比计时器多走的名义帧；
    -- x0/a0 = 条目首见时的 X、hs；hs_prev/t_prev = 上次读到的 [条目地址]=hs 和时刻；c1/cf = 首帧/本帧原始 C；ql/qf = 上次的 Q、帧号
    tracks[key] = { obj = r, t_msg = now, em = em, master = master ~= false, fo = {}, sk = {}, fe = {},
        idx = math.tointeger(idx), snd = snd, first = true, m = nil, X = 0.0, x0 = {}, a0 = {}, hs_prev = nil,
        clock = nil, nchg = 0, c1 = nil, cf = nil, nofire = false, ql = {}, qf = {} }
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

-- ---------- 速度（E5c，V16 第 2 节） ----------
-- frame_no = 实际运行求值的帧回调序号（读主角抛错、容忍期内跳过的帧不算）；speed_cache[SystemIndex] = 本帧读到的
-- { c = C 或 nil, addr = 怪物地址, why = 读不到的原因 }，只存数值，每帧清空；spd = 首帧连续读不到的结果数、≥5 状态
local frame_no, speed_cache = 0, {}
local spd = { streak = 0, x5 = false, x5_ever = false, err = false }
-- 读路径照抄 APCal 的 find_enemy（加载自检 2 的 find、sysidx 4 段都通过，实测）。2026-10-11 MCP get_type 核对：
-- findEnemy_SystemIndex(System.Int32) → app.cEnemyManageInfo；get_Character() → app.EnemyCharacter；CoreState → System.Single
local function core_read(idx)
    local mgr = sdk.get_managed_singleton("app.EnemyManager")
    if not mgr then return nil, nil, "no_manager" end
    local info = mgr:call("findEnemy_SystemIndex(System.Int32)", idx)
    if not info then return nil, nil, "not_found" end
    local enemy = info:call("get_Character")
    if not enemy then return nil, nil, "no_character" end
    local addr = enemy:get_address()
    local c = enemy:call("get_MotionSpeed_CoreState")
    if not finite(c) then return nil, addr, type(c) == "number" and "not_finite" or "not_number" end
    if c < C_LO or c > C_HI then return nil, addr, "out_of_range" end
    return c, addr, nil
end
-- 读 C 抛错不算帧逻辑错误（不进 frame 的红计数、不进 30 帧自停）：第一次报黄 speed（带错误文本），不停用读取
local function core_of(idx)
    if idx == nil then return nil, nil, "no_idx" end
    local s = speed_cache[idx]
    if not s then
        local ok, c, addr, why = pcall(core_read, idx)
        if not ok and not spd.err then
            spd.err = true
            note_error("speed", c)
        end
        s = ok and { c = c, addr = addr, why = why } or { why = "error" }
        speed_cache[idx] = s
    end
    return s.c, s.addr, s.why
end
-- 时钟条目两帧之间 hs 的递减：优先沿用上一帧用过的那条；不在了按条目表顺序找第一条两帧都有的，并改记 tr.clock
local function clock_delta(tr, list, cur)
    local prev, c = tr.hs_prev, tr.clock
    if c and cur[c] and prev[c] then return prev[c] - cur[c] end
    for _, e in ipairs(list) do
        if prev[e.key] then tr.clock = e.key; return prev[e.key] - e.hs end
    end
end
-- 每帧每个结果（不论在不在蓄力，X 要从登记起连续累加）。list 为 nil（读出错）的帧不累加、不记 X0，C 照读。之后那一对读数（读主角
-- 抛错的容忍期同样）跨好几帧：乘最后的 m（近似），上限按隔开的时间放宽（固定 30 时断档 ≥0.5 s 整段不累加，Q 偏大、放刀偏晚）
local function speed_step(tr, list, now)
    local C, found, why = core_of(tr.idx)
    local cur = list and {} or nil
    for _, e in ipairs(list or {}) do cur[e.key] = e.hs end
    -- (a) 累加：上一帧的 m × 同一条条目两帧之间 hs 的递减（写成「在区间里才累加」，NaN 也落到 clockskip）
    if cur and tr.hs_prev and tr.m then
        local d = clock_delta(tr, list, cur)
        if d and d >= 0 and d <= CLOCK_DMAX + 60.0 * (now - tr.t_prev) then tr.X = tr.X + d * (tr.m - 1.0)
        else stats.clockskip = stats.clockskip + 1 end
    end
    -- (b) m：登记后第一个帧回调 = 离线验证的采样点
    if tr.first then
        tr.first = false
        if C then
            tr.m, tr.c1 = math.max(1.0, C), C
            spd.streak, spd.x5 = 0, false
        else
            tr.nofire, stats.speedfail, spd.streak = true, stats.speedfail + 1, spd.streak + 1
            dbg("speed_fail", "idx", tr.idx, "why", why)
            if spd.streak >= SPEED_FAIL_STREAK and not spd.x5 then   -- 每次进入这个状态报一次黄，不停用读取
                spd.x5, spd.x5_ever = true, true
                note_error("speed", "first_frame_fail_x5")
            end
        end
        -- sidmis：首帧找到的怪物 ≠ 钩子里的发送者（两边都有值才比）。只计数不拦：这个等式没直接核对过（V16 2.5）
        if found and tr.snd and found ~= tr.snd then
            stats.sidmis = stats.sidmis + 1
            dbg("sidmis", "idx", tr.idx, "snd", hex(tr.snd), "found", hex(found))
        end
    elseif tr.m then
        if C then
            local m = math.max(1.0, C)
            if math.abs(m - tr.m) > 1e-4 then tr.nchg = tr.nchg + 1 end
            tr.m = m
        else
            stats.speedhold = stats.speedhold + 1   -- 中途读不到：沿用上一帧的 m，按帧计
        end
    end
    tr.cf = C
    -- (c) 首次读到的条目记 X0、A0（之后不重置，即使中途消失再出现）
    if cur then
        for _, e in ipairs(list) do
            if tr.x0[e.key] == nil then tr.x0[e.key], tr.a0[e.key] = tr.X, e.hs end
        end
        tr.hs_prev, tr.t_prev = cur, now
    end
end

-- ---------- 条目读取与「该接」过滤（V16 第 3 节） ----------
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
        out[#out + 1] = { d = d, key = d:get_address(), rt = d:call("get_ResultType"), hs = hs, he = he }
    end
    return out
end
-- 过滤字段读取出错（抛错、类型不对、ShellIndex 形态不认识）：第一次报黄 filter，不停用读取（停用就再也放不了刀）；按条目计数
local function filter_error(tr, e, err)
    if not mod_off.filter then note_error("filter", err) end
    if not tr.fe[e.key] then tr.fe[e.key], stats.ferr = true, stats.ferr + 1 end
end
-- 弹体：ShellIndex 是 Nullable<Int32>，有值就是弹体。REF 的返回形态三种都认：nil、拆箱成数字、带 _HasValue 的值类型
local function has_shell(d)
    local v = d:call("get_ShellIndex")
    if v == nil then return false end
    if type(v) == "number" then return true end
    if type(v) ~= "userdata" then error("ShellIndex returned " .. type(v)) end
    local hv = v:get_field("_HasValue")
    if type(hv) ~= "boolean" then error("ShellIndex._HasValue=" .. tostring(hv)) end
    return hv
end
-- 返回 true / false / nil（读不准）；本帧结果缓存在条目表上
local function shell_of(tr, e)
    if e.s == nil then
        local ok, v = pcall(has_shell, e.d)
        if ok then e.s = v else
            filter_error(tr, e, v)
            e.s = "?"
        end
    end
    if e.s == "?" then return nil end
    return e.s
end
-- 读攻击参数的一个字段（每个字段单独 pcall：_GuardType 读坏了不能连带丢掉只靠 _DamageType 的抓取否决）。
-- 整数字段返回整数、布尔字段返回布尔；抛错或类型不对报 filter、返回 nil
local function ap_field(tr, e, ap, name, want_bool)
    local ok, v = pcall(ap.get_field, ap, name)
    if ok and want_bool and type(v) == "boolean" then return v end
    local iv = ok and not want_bool and math.tointeger(v) or nil
    if iv then return iv end
    filter_error(tr, e, ok and (name .. "=" .. tostring(v)) or v)
    return nil
end
-- 攻击参数 cAttackParamEm（字段 2026-10-11 MCP 核对）→ c：dmg_ok、grab、effect（nil = 效果名缺认不出）、guard_ok、g（white|ug|
-- sg|unknown）、pb（nil = 读不准）。攻击参数为 nil 是数据情况（em27 个别条目），不报黄。本帧缓存在条目上（否决、候选共用）
local function classify(tr, e)
    if e.c then return e.c end
    local c = { dmg_ok = false, guard_ok = false }
    e.c = c
    local ok, ap = pcall(e.d.call, e.d, "get_AttackParam")
    if not ok then filter_error(tr, e, ap) end
    if not ok or ap == nil then return c end
    local t = ap_field(tr, e, ap, "_DamageType")
    if t then
        c.dmg_ok, c.grab = true, GRAB_DAMAGE[t] ~= nil
        if EFFECT_DAMAGE[t] then c.effect = true elseif not effect_partial then c.effect = false end
    end
    local g = ap_field(tr, e, ap, "_GuardType")
    if g then
        c.guard_ok = true
        c.g = GUARD_WHITE[g] and "white" or (g == GUARD_UG and "ug") or (GUARD_SG[g] and "sg") or "unknown"
    end
    c.pb = ap_field(tr, e, ap, "_IsParryBreak", true)
    return c
end
-- 窗口内条目的结论：nil = 该接；"old" = 旧排除（弹体、效果、抓取、SG 家族，不写 SKIP）；"pb"/"ug"/"fc" = 新过滤挡掉（写 SKIP，
-- 确定的原因优先）。弹体每个窗口内条目都读（SKIP 与遍历顺序无关），已写过 SKIP 的不再读
local function filter_reason(tr, e)
    local c = classify(tr, e)
    if c.dmg_ok and (c.grab or c.effect == true) then return "old" end
    if c.guard_ok and c.g == "sg" then return "old" end
    local why = c.pb == true and "pb" or (c.guard_ok and c.g == "ug") and "ug"
        or (not c.dmg_ok or c.effect == nil or not c.guard_ok or c.g == "unknown" or c.pb == nil) and "fc" or nil
    if why and tr.sk[e.key] then return why end
    local s = shell_of(tr, e)
    if s == true then return "old" end
    if s == nil and why == nil then why = "fc" end
    return why
end

-- ---------- 规则：否决、候选、只记录的量（V16 2.4） ----------
local function keep_text(r)
    local k = r:call("get_KeepActionID")
    return k and ("(" .. int_s(k:get_field("_Category")) .. "," .. int_s(k:get_field("_Index")) .. ")") or nil
end
-- SKIP / UVIEW 的 keep 只是诊断字段：读不到写 -，不算错误（FIRE 的 keep 读错仍按帧逻辑出错，口径同 v1.5.1）
local function keep_or_nil(r)
    local ok, k = pcall(keep_text, r)
    return ok and k or nil
end
-- 在窗口里、被该接过滤挡掉的条目：每个结果的每条条目写一行 SKIP，计 excl（pb/ug）或 fclosed（fc）
local function skip_entry(tr, e, why, Q, now)
    if tr.sk[e.key] then return end
    tr.sk[e.key] = true
    if why == "fc" then stats.fclosed = stats.fclosed + 1 else stats.excl = stats.excl + 1 end
    emit("SKIP", { now, why, e.hs, e.he, Q, tr.em, keep_or_nil(tr.obj), addr_of(tr.obj), e.key })
end
-- 否决 V 取触发条目里 hs 最小的；同 hs 时 long > grab > sg（v1.5 就有的规则优先）
local WHY_RANK = { long = 1, grab = 2, sg = 3 }
local function set_veto(ev, tr, e, why)
    local v = ev.veto
    if not v or e.hs < v.e.hs or (e.hs == v.e.hs and WHY_RANK[why] < WHY_RANK[v.why]) then
        ev.veto = { tr = tr, e = e, why = why }
    end
end
-- 每条 DANGER 条目：Q 和上一个求值帧的 Q（Qp）；否决按原始 hs（读不到类型 → 不否决、failopen 每条一次）；候选按 Q；只记录 vq
-- （长窗口条目按 Q 已在 1.5 s 内、按原始 hs 还不在视野里）和视野内 pb=1 / UNABLE_GUARD 的条目（U，放刀时才读弹体、写 UVIEW）
local function consider(tr, list, ev)
    local L = ev.L
    for _, e in ipairs(list) do
        if e.rt == RT_DANGER then
            local hs, he = e.hs, e.he
            local w = he - hs
            local Q, Qp = nil, nil
            local x0 = tr.x0[e.key]
            if tr.m and not tr.nofire and x0 then
                Q = (hs - (tr.X - x0)) / tr.m
                if tr.qf[e.key] == frame_no - 1 then Qp = tr.ql[e.key] end
                tr.ql[e.key], tr.qf[e.key] = Q, frame_no
            end
            if hs <= VETO_HORIZON and he >= 0 then
                if w > LONG_WINDOW then set_veto(ev, tr, e, "long") end
                local c = classify(tr, e)
                local why = (c.dmg_ok and c.grab) and "grab" or (c.guard_ok and c.g == "sg") and "sg" or nil
                if why then set_veto(ev, tr, e, why) end   -- sg 只在伤害类型不是抓取时记；两者都永远不进候选
                if not (c.dmg_ok and c.guard_ok) and not tr.fo[e.key] then
                    tr.fo[e.key], stats.failopen = true, stats.failopen + 1
                end
                if c.pb == true or (c.guard_ok and c.g == "ug") then
                    ev.ucands = ev.ucands or {}
                    ev.ucands[#ev.ucands + 1] = { tr = tr, e = e, why = c.pb == true and "pb" or "ug" }
                end
            elseif Q and w > LONG_WINDOW and he >= 0 and Q <= VETO_HORIZON then
                ev.vq = true                          -- 这里 hs > H_veto：改成按 Q 否决就会挡掉这一帧
            end
            if Q and tr.master and w >= 0 and w <= LONG_WINDOW and Q >= LEAD_MIN and Q <= L then
                local why = filter_reason(tr, e)
                if why == nil then
                    if not ev.best or Q < ev.best.Q then ev.best = { tr = tr, e = e, Q = Q, Qp = Qp } end
                elseif why ~= "old" then
                    skip_entry(tr, e, why, Q, ev.now)
                end
            end
        end
    end
end
-- 放刀那一帧视野内的 U：非弹体（读不到也算）里 hs 最小的一条；只在 hs 更小时才读弹体，结果与遍历顺序无关
local function pick_u(ev)
    local best = nil
    for _, u in ipairs(ev.ucands or {}) do
        if (not best or u.e.hs < best.e.hs) and shell_of(u.tr, u.e) ~= true then best = u end
    end
    return best
end

-- 每帧每条预告（V16 2.3 的顺序）：清理 → 读条目（每帧都读，不论在不在蓄力）→ 速度 → 打完了 → ev 非 nil 时参与规则求值
local function process_track(tr, now, ev)
    local age, r = now - tr.t_msg, tr.obj
    if age >= TRACK_STALE then return "stale" end
    if r:call("get_IsAttackFinished") then return "finished" end
    local ok, list = pcall(read_items, r)
    if not ok then
        -- 逐条读取出错：本帧不放刀、不否决、不按 he 丢弃，速度照读；第一次标黄但不停用（停用就再也放不了刀），readerr 按结果计
        if not mod_off.items then note_error("items", list) end
        if not tr.re then tr.re, stats.readerr = true, stats.readerr + 1 end
        list = nil
    end
    speed_step(tr, list, now)
    if not list then return nil end
    -- 「全部条目 he < -30」只对非空列表成立：未结束、暂时没有条目的结果要继续持有到 8 s
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

-- 清理全部跟踪；L 非 nil 时同时求值，返回 ev = { L, now, veto, best, vq, ucands }。单条预告读坏了就丢掉它、计一次帧逻辑错误
local function evaluate(now, L)
    local ev = L and { L = L, now = now } or nil
    for key, tr in pairs(tracks) do
        local ok, why = pcall(process_track, tr, now, ev)
        if not ok then note_error("frame", why) end
        if not ok or why then drop_track(key) end
    end
    return ev
end

-- ---------- 放刀 streak、否决、结局 ----------
local streak, veto_on = nil, false  -- streak = { id, t, n, r1 }：条件连续成立的帧合并为一次放刀
local res_wait = nil                -- { id, t, to }：已进入 (2,23)，等 CREDIT 秒内进 (2,25..27)
local act_cat, act_idx = nil, nil   -- 本帧主角动作（空闲判断用，不在 UI 线程里调游戏方法）
local function finish_res(now, outcome)
    local w = res_wait
    res_wait = nil
    if outcome == "CATCH26" or outcome == "CATCH27" then stats.catches = stats.catches + 1
    elseif outcome == "RECOIL" then stats.recoils = stats.recoils + 1 end
    emit("RES", { w.id, now, outcome, now - w.t, w.to })
end
local function start_streak(now, ev, idx)
    if res_wait then finish_res(now, "NOCATCH") end   -- 又回到蓄力了，上一刀不可能再接住
    local b = ev.best
    local tr, e = b.tr, b.e
    local ok, keep = pcall(keep_text, tr.obj)
    if not ok then note_error("frame", keep) end
    streak = { id = next_id, t = now, n = 0, r1 = e.hs }
    next_id, stats.fires = next_id + 1, stats.fires + 1
    if ev.vq then stats.vetoq = stats.vetoq + 1 end
    local c1, a0 = tr.c1, tr.a0[e.key]
    local qe1 = (c1 and a0) and (e.hs - a0 * (1.0 - 1.0 / math.max(1.0, c1))) or nil   -- 影子 E1（只读首帧 C 的规则）
    emit("FIRE", { streak.id, now, ev.L, e.hs, e.he, "V0", e.key, addr_of(tr.obj), tr.em, ok and keep or nil,
        "(" .. int_s(CAT_ATTACK) .. "," .. int_s(idx) .. ")",
        c1, tr.cf, tr.m, tr.nchg, tr.X - tr.x0[e.key], a0, b.Q, b.Qp, qe1, "E5c", ev.vq == true })
    -- 视野里同时有 pb=1 / UNABLE_GUARD 的攻击：只记录不否决（现有数据 0 次共现，整帧否决的收益和代价都估不出来，V16 3.3）
    local u = pick_u(ev)
    if u then
        stats.uview = stats.uview + 1
        emit("UVIEW", { streak.id, now, u.e.hs, u.e.he, u.why, u.tr.em, keep_or_nil(u.tr.obj), u.tr == tr,
            addr_of(u.tr.obj), u.e.key })
    end
end
-- R1 记最后一个请求帧的原始 hs：那一帧的请求被接受，下一帧就在 (2,23) 里了（实测都是下一帧）
local function end_streak(now, entered)
    local s = streak
    streak = nil
    emit("FIRE_END", { s.id, now, s.r1, s.n, entered })
    if res_wait then finish_res(now, "NOCATCH") end
    res_wait = { id = s.id, t = s.t, to = nil }
    if not entered then finish_res(now, "NOCATCH") end   -- 没放出去：每个 FIRE 都有一行 RES，离线一一对应
end

local function update_fire(hunter, now, cat, idx)
    if streak and cat == CAT_ATTACK and idx == IDX_SLASH then end_streak(now, true) end
    if res_wait and not streak then
        -- RES 的 to：进 (2,23) 后第一次看到的、不是 (2,23)/(2,24) 的动作（粗分「停在 (2,23)」和「被打出去」，V16 第 4 节）
        if not res_wait.to and cat ~= nil and idx ~= nil
            and not (cat == CAT_ATTACK and (idx == IDX_SLASH or idx == IDX_SLASH_FWD)) then
            res_wait.to = "(" .. int_s(cat) .. "," .. int_s(idx) .. ")"
        end
        if cat == CAT_ATTACK and PARRY_OUT[idx] then finish_res(now, PARRY_OUT[idx])
        elseif now - res_wait.t >= CREDIT then finish_res(now, "NOCATCH") end
    end
    -- 前提 P1~P3：开关、大剑、基础层在 (2,21)/(2,22)；任一不满足就结束 streak（清理和速度照常做）
    local active = config.auto_parry and not err_state.stopped and me_gs
        and cat == CAT_ATTACK and PARRY_CHARGE[idx] == true
    local ev = evaluate(now, active and config.parry_lead or nil)
    if not active then
        if streak then end_streak(now, false) end
        veto_on = false
        return
    end
    if ev.veto and not veto_on then   -- 每个否决 streak 记一行（长窗口、抓取、sg 同一个 streak），记这一帧 hs 最小的那条
        stats.vetoes = stats.vetoes + 1
        local v = ev.veto
        emit("VETO", { now, v.e.hs, v.e.he, addr_of(v.tr.obj), v.e.key, v.tr.em, v.why })
    end
    veto_on = ev.veto ~= nil
    if ev.best and not ev.veto then
        -- Q ≤ L 已在 consider 里保证；不设超时：Q 单调递减（m 变化那一帧跳一下），离开 [L_min, L] 自然停
        if not streak then start_streak(now, ev, idx) end
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
local function lose_hunter(now)    -- 主角为 nil 或换了（换场景等）：全部丢弃
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
        return      -- 容忍期内：这一帧不存在（不求值、不放刀，streak、跟踪和 E5c 的帧计数都保持原样）
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
    if not config.auto_parry and n_tracks > 0 then release_all_tracks() end   -- 关开关时全部丢弃（菜单里只改配置）
    frame_no = frame_no + 1           -- E5c 的 k：这一帧实际运行求值
    if next(speed_cache) ~= nil then speed_cache = {} end
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

-- STAT：每 60 s 一行；「写出数据」和 Reset 时先补写一行。fb 恒为 0。lua_win = 到下一行 STAT 为止的帧回调耗时
local lua_win = { sum = 0.0, n = 0, max = 0.0, t0 = os.clock() }
local function stat_emit(now)
    local W, S = lua_win, stats
    local span = now - W.t0
    last_stat_t = now
    emit("STAT", { S.fires, S.catches, S.vetoes, 0, S.failopen, S.errors, S.err_red, S.err_yellow,
        W.n > 0 and W.sum / W.n or nil, W.n > 0 and W.max or nil, span > 0 and hook_ms / span or nil,
        S.readfail, S.replica, S.readerr, S.recoils, S.speedfail, S.speedhold, S.clockskip, S.vetoq, S.fclosed,
        S.excl, S.uview, S.sidmis })
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
-- 启用开关、提前量滑块每次改动写一行 CFG（总写，不受 debug_log 控制）：验收只用第一次改动之前的数据（PLAN D）
local function set_cfg(k, v)
    if config[k] == v then return end
    config[k] = v          -- 预告的丢弃、streak 的结束都在下一帧的帧逻辑里做
    emit("CFG", { os.clock(), config.auto_parry, config.parry_lead })
end
-- 报黄但不停用读取的模块各有自己的状态措辞，不算「有可选模块停用，自动放刀照常」（那句只给 master、cfg、ui 等）
local SOFT_MODS = { "items", "speed", "filter", "filter_enum" }
local function draw_status()
    local E, S, p = err_state, stats, {}
    local n_off = E.yellow
    for _, m in ipairs(SOFT_MODS) do if mod_off[m] then n_off = n_off - 1 end end
    p[#p + 1] = E.stopped and "已自停（帧逻辑连续出错）" or E.red and "核心模块出错"
        or n_off > 0 and ("有可选模块停用（黄 " .. int_s(n_off) .. "），自动放刀照常") or nil
    if mod_off.items then p[#p + 1] = "条目读取出过错（读取错误 " .. int_s(S.readerr) .. "）：读不出条目的预告不放刀" end
    p[#p + 1] = spd.x5 and "速度读不到，已停止自动放刀"
        or spd.x5_ever and ("速度曾读不到（" .. int_s(S.speedfail) .. " 个预告没放刀），已恢复") or nil
    if mod_off.filter then p[#p + 1] = "过滤字段读取出过错（" .. int_s(S.ferr) .. " 条）：读不准的条目不放刀" end
    if mod_off.filter_enum then
        p[#p + 1] = "过滤用的枚举读不到（缺 " .. tostring(filter_enum_missing) .. "）：这些攻击一律不放刀"
    end
    imgui.text("版本 " .. VERSION .. "  状态：" .. (#p > 0 and table.concat(p, "；") or "正常"))
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
    changed, v = imgui.slider_int("提前量（真实剩余帧，1/60 秒）##ap_lead", config.parry_lead, LEAD_LO, LEAD_HI)
    if changed and finite(v) then set_cfg("parry_lead", clamp_lead(v)) end
    imgui.text_colored("已按怪物速度修正。越小越常出抵消动作；太小会被先打到。默认 " .. int_s(LEAD_DEFAULT), COLOR_GRAY)
    imgui.separator()
    local S = stats
    imgui.text("放刀 " .. int_s(S.fires) .. "  接住 " .. int_s(S.catches) .. "  被弹 " .. int_s(S.recoils) .. "  否决 "
        .. int_s(S.vetoes) .. "  该接过滤跳过 " .. int_s(S.excl) .. "  读不准不放 " .. int_s(S.fclosed) .. "  速度读不到 "
        .. int_s(S.speedfail) .. "  联机副本跳过 " .. int_s(S.replica) .. "  fail-open " .. int_s(S.failopen)
        .. "  读取错误 " .. int_s(S.readerr))
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
-- 顺序：先丢弃跟踪（只删 Lua 引用，REF 回收 userdata 时自动扣引用，这里不手动扣）→ 结算 streak 和 RES → STAT →
-- 最后一份 JSON → 最后才把排队的 ERR 一次写完（写 JSON 失败的那条错误也要进日志：这一刻以后再也写不出 JSON）
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
