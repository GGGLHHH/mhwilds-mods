-- AutoGuardGS v1.5：大剑自动防御 + 自动放刀（实验）
--
-- 一个文件两部分，共用一个菜单、一个配置文件 reframework/data/AutoGuardGS.json、一个帧回调。两部分的内部实现各自放在
-- do 块里（§5、§6），只把帧回调、Reset、菜单要用的几个函数露到外面：互相看不见对方的状态，也避开 Lua 一个函数最多 200 个
-- 局部变量的限制。文档：游戏内部结构和实测结论 docs/NOTES.md；放刀规则 docs/autoparry/V16.md（规则版本 1.6，本版一处没改）；
-- 两个脚本怎么合并、怎么验收 docs/autoparry/MERGE.md。
--
-- ===== 自动防御（原 AutoGuardGS v1.4.2，逻辑不变；每一条都在探针里验证过）=====
-- 被怪物打中、伤害结算之前（HunterCharacter.evHit_DamagePreProcess），打开角色状态标志里的防御标志：TECHNICAL_GUARD →
--   精确防御，GUARD → 普通防御。方向、体力、削伤、防御反应全部由游戏按自己的规则处理；结算完（evHit_Damage 之后）关掉。
--   为什么不预判举剑：同一时刻「会打中」和「打不中」的判定框距离曲线一模一样（实测），误触发无法消除；
--   受击时判定只在真的打中时才触发，对任何怪、任何招式都通用。
-- 能不能举剑：已拔刀 + 问游戏行为表能否到达防御动作 + 动作属性黑名单（翻滚、倒地等）。霸体中不防御，交给霸体硬吃。
-- 自动肩撞：蓄力中挨打（蓄力霸体照常硬吃），下一帧起向动作控制器请求切成肩撞，游戏原生出肩撞，之后能接下一级蓄力。
--   经验（实测）：「改状态」可以在受击结算中途做；「改动作」必须在帧开头请求，不能中途硬切。
-- 防御角度：Wp00ActionParam 的 _GuardDegree / _AimGuardDegree（全角，70 = 正前方左右各 35 度），所有大剑共用（包括 NPC
--   支援猎人），所以只在主玩家这一下的结算期间临时改写，结算完立刻还原；抵消动作族 (2,21)~(2,29) 里不改写。
--   还原有三处兜底：结算后、每帧开头、Reset。
-- 【测试】无限蓄力：7 种蓄力参数的 _OverheatTime 改成极大值（同样所有大剑共用）；关开关、换武器、主角消失、Reset 都还原。
-- 【测试】锁血：游戏扣血分两步，受击时 cHunterHealth.requestDamage 登记、之后 update 里结算。锁血时对主玩家在登记这一步
--   跳过原函数，另外每帧把血补满兜底（覆盖不走 requestDamage 的扣血）。被打的反应动作照常。
--
-- ===== 自动放刀（原 AutoParryGS v1.6，放刀规则一处没改，有逐刀等价测试为证）=====
-- 按住抵消蓄力 (2,21)/(2,22) 时读怪物发给主角的攻击预告 cMsgEmAttackAreaResult，「打我的」DANGER 条目里最早一段的
--   真实剩余帧 Q 落进 [L_min, L] 就在帧开头请求 (2,23) 上捞斩；抵消、伤害、弹开全部来自刀和攻击的原生碰撞。
-- 时机 E5c（V16 第 2 节；机制 SPEED 第 1~2 节，实测）：hs 的初值是怪物 1 倍速下的名义帧、在接收端按真实时间每秒减 60，
--   怪物却按 CoreState 倍速推进，C > 1 时攻击早到约 A·(1−1/C)/60 s。
--     m = max(1, C)（疲劳 C < 1 按 1）；X += Δhs·(m_上帧 − 1)（用条目 hs 自己的递减当时钟：卡顿时游戏把扣减钳在约 0.133 s，
--     墙钟会漂）；Q = (hs − (X − X0_e)) / m，X0_e = 条目首见时的 X。
--   C 从登记后第一个帧回调起每帧读、不在钩子里读（CoreState 恰在发消息那一帧按招切换，钩子里读到的是上一招的值）；
--   首帧读不到的结果永不放刀、照样参与否决，中途读不到沿用上一帧的 m；不回退到原始 hs（会放早）。
-- 候选：L_min ≤ Q ≤ L、0 ≤ he−hs ≤ 60、不是联机副本、通过「该接」过滤，取 Q 最小的；连续成立的帧合并成一次放刀，不设超时。
-- 「该接」（V16 第 3 节，游戏自己的抵消判定 G1，没有按怪、按招的表）：不是弹体；_IsParryBreak 为假（被弹开 4/4 是 pb=1，
--   实测）；GuardType 是 NORMAL / ALL_RANGE；不是咆哮、风压、震动、抓取。读不准就不放（放错比不放糟：pb=1 上放刀被弹开加
--   挨打，抓取上放刀被抓 259 伤害，实测）。
-- 否决（按原始 hs）：视野（hs ≤ 90、he ≥ 0）里有长窗口、抓取或 SKILL_GUARD 家族的攻击就整帧不放；否决侧读不到类型按不是抓取。
-- 提前量 L 默认 28（Q 单位，滑块 23~45），L_min 22。抵消窗口（实测）：首个接触 < 0.328 s 接不住、0.331~≥0.944 s 全接住。
-- 结局（只用于菜单统计和调试日志）：放刀后 1.3 s 内进 (2,26)/(2,27) 记接住；进 (2,25) 记被弹开（会随即挨打，实测）。
-- 引用记账（NOTES「跨帧持有与 REF 的引用记账」）：REF 按地址给整个 Lua 状态记一份游戏侧引用、所有脚本共用，谁先手动扣，
--   同时持有的另一个脚本就拿着悬空指针（实测）。所以登记时只 add_ref、丢弃时只删 Lua 引用，等 userdata 回收时 REF 自动扣；
--   本文件不调任何手动扣引用的接口。
-- 唯一有副作用的游戏调用是 changeActionRequest(0, (2,23), false)；只钩 receiveGameMessage 一个函数。
-- 联机没测过：发送者怪物 _Context:get_IsMaster() 为 false（副本）的只参与否决、不放刀，读不到按主机处理。
--
-- 调试日志（菜单「调试日志」，默认关，两部分共用）：防御写 [AutoGuardGS] 调试行和每 5 秒一行 PERF；放刀每次写两行
--   [AutoParryGS] FIRE（放刀）、RES（结局），本次加载第一行之前补一行 HDR。放刀出错的 ERR / RED 不看开关总写。
--   标签沿用 [AutoParryGS]，意思是「放刀记录」：tools/apcal_analyze.py 和旧日志都按它找。

-- ---------- §1 常量、状态、小工具 ----------

local TAG, REC_TAG = "[AutoGuardGS] ", "[AutoParryGS]"
local VERSION = "v1.5"
-- 放刀规则的版本，写进 HDR 的 ver：规则（何时放、放不放）变了才改，只改代码结构或日志格式不改。
-- 不能写成 1.5：分析脚本会把它当成旧的 AutoParryGS v1.5（L = 26、hs 口径）去判
local PARRY_RULE = "1.6"
local HOST = "AutoGuardGS-" .. VERSION    -- HDR 的 host：标明放刀记录是合并版写的
local CONFIG_PATH = "AutoGuardGS.json"
local LEGACY_PARRY_CONFIG = "AutoParryGS.json"   -- 旧的独立放刀脚本的配置：首次加载迁移一次（§3），只读不写

local WEAPON_GREAT_SWORD, LAYER_BASE = 0, 0
local REQ_SIG = "changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)"
local ANGLE_MIN, ANGLE_MAX = 30.0, 360.0
local GUARD_WARN_MAX = 20           -- 防御的警告每类每次加载最多写这么多行（出错时不至于每帧刷一行）
-- 放刀里配置、HDR、错误分级也要用的常量（其余在 §6）。剩余帧单位 1/60 s、是 System.Single，格式化一律 %.Nf
local LEAD_DEFAULT, LEAD_LO, LEAD_HI = 28, 23, 45   -- L（Q 单位）默认值与滑块范围（下限 23：[L_min, L] 至少 1 帧宽）
local LEGACY_CFG_VER = 3            -- 旧 AutoParryGS.json 的 cfg_ver ≥ 3 时 parry_lead 才是 Q 单位（V16 2.7）
local LEAD_MIN, LONG_WINDOW, VETO_HORIZON = 22, 60, 90   -- L_min（Q 单位）；W_long、H_veto（原始帧，只参与否决）
local C_LO, C_HI = 0.5, 2.0         -- CoreState 合法范围：只剔除坏值（NaN、0、乱码）
local CREDIT = 1.3                  -- 放刀后 1.3 s 内进 (2,25..27) 才算结局（刀攻击判定顿帧时最晚约 1.22 s 关，G1 实测）
local RED_WINDOW, RED_COUNT, ERR_LOG_MAX = 10.0, 3, 20   -- 核心模块 10 s 内出错 3 次标红；ERR 每次加载最多写 20 行
local COLOR_RED, COLOR_GRAY = 0xFF4040FF, 0xFFA0A0A0   -- imgui 颜色是 ABGR

-- 配置（§3 读写）。前 8 个键和 v1.4.2 相同；auto_parry / parry_lead 是 v1.5 新加的，默认值同 AutoParryGS v1.6
local config = {
    enabled = true,             -- 自动防御（含自动肩撞）
    guard_type = 1,             -- 1 = 精确防御，2 = 普通防御
    guard_angle = nil,          -- nil = 用游戏原值
    respect_armor = true,       -- 身上有霸体时不触发（保护真蓄力斩等霸体攻击）
    auto_tackle = true,         -- 蓄力中挨打后自动肩撞
    infinite_charge = false,    -- 测试用：无限蓄力（蓄满后不会过热自动放出）
    lock_health = false,        -- 测试用：锁血（主玩家不掉血、不会倒下）
    debug_log = false,          -- 调试日志，两部分共用
    auto_parry = true,          -- 自动放刀
    parry_lead = LEAD_DEFAULT,  -- 提前量 L（真实剩余帧）
}

-- 菜单统计，「清零统计」一次清两部分。放刀：fires 每次放刀 +1，其余四个按结局各计一次（fires 减去它们 = 还在等结局的那一刀）
local stats = { guarded = 0, skipped_armor = 0, skipped_state = 0, already_guarding = 0, tackled = 0, damage_blocked = 0,
    fires = 0, catch26 = 0, catch27 = 0, recoils = 0, nocatch = 0 }

local note_error    -- 前向声明（§2）：safe_fmt 失败也要计错误
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
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
local function hex(v) return math.tointeger(v) and safe_fmt("%X", math.tointeger(v)) or nil end

local function debug(text)
    if config.debug_log then log.info(TAG .. text) end
end

-- 防御部分出错：写一行警告（每类每次加载最多 GUARD_WARN_MAX 行），不进放刀的红黄计数（两部分互不牵连）
local warn_n = {}
local function guard_warn(kind, err)
    local n = (warn_n[kind] or 0) + 1
    warn_n[kind] = n
    if n <= GUARD_WARN_MAX then log.warn(TAG .. kind .. " err: " .. tostring(err)) end
end

-- 性能计数（诊断卡顿用）：一直计数（开销很小），只在打开调试日志时每 5 秒写一行 PERF、在菜单里显示。
-- frame = 整个帧回调（两部分）；dmg_pre / dmg = 受击钩子；msg = 放刀的消息钩子。
-- os.clock 在 Windows 上精度约 1 毫秒，单次耗时很小时只看调用次数更可靠。
local PROF_INTERVAL, PROF_KEYS = 5.0, { "frame", "dmg_pre", "dmg", "msg" }
local prof = { frame = { n = 0, t = 0 }, dmg_pre = { n = 0, t = 0 }, dmg = { n = 0, t = 0 }, msg = { n = 0, t = 0 } }
local prof_last, prof_text = os.clock(), ""

local function timed(name, fn)
    return function(...)
        local t0 = os.clock()
        local r = fn(...)
        local p = prof[name]
        p.n = p.n + 1
        p.t = p.t + (os.clock() - t0)
        return r
    end
end

local function prof_report()
    local now = os.clock()
    local dt = now - prof_last
    if dt < PROF_INTERVAL then return end
    local parts = {}
    for _, k in ipairs(PROF_KEYS) do
        local p = prof[k]
        table.insert(parts, string.format("%s %.0f/s %.1fms/s", k, p.n / dt, p.t * 1000 / dt))
        p.n, p.t = 0, 0
    end
    prof_text = table.concat(parts, " | ")
    debug("PERF " .. prof_text)
    prof_last = now
end

-- ---------- §2 放刀记录与错误分级 ----------
-- 日志行 "[AutoParryGS] KIND k=v ..."。SPEC：「字段名:格式」，i 整数 / fN N 位小数 / s 文本 / b 布尔（写 1/0）/ h 地址
-- （十六进制）；值为 nil、NaN、无穷时写 -。留下来的字段格式和 v1.6 完全相同，分析脚本照读（MERGE 4.2）
local SPEC = {}
for kind, s in pairs({
    HDR = "ver:s session:i auto_parry:b lead:i L_min:i W_long:i H_veto:i credit:f1 rule:s filter:s c_lo:f2 c_hi:f2 "
        .. "host:s enum_skip:s",
    FIRE = "id:i t:f4 L:i R0:f2 he0:f2 ent:h res:h em:s keep:s from:s C1:f3 Cf:f3 mf:f3 nchg:i dX:f2 A0:f2 Q0:f2",
    RES = "id:i t:f4 outcome:s dt:f3 to:s entered:b",
    ERR = "mod:s level:s msg:s",
    RED = "t:f4 mod:s why:s",
}) do
    SPEC[kind] = {}
    for name, ft in s:gmatch("([%w_]+):(%w+)") do SPEC[kind][#SPEC[kind] + 1] = { name, ft } end
end
local FLOAT_FMT = { i = "%.1f", f1 = "%.1f", f2 = "%.2f", f3 = "%.3f", f4 = "%.4f" }   -- i 字段遇到非整数按 %.1f
local function fmt_value(v, ft)
    if ft == "b" and v ~= nil then v = (v == true or (type(v) == "number" and v ~= 0)) and 1 or 0 end
    if ft == "h" then v = hex(v) end
    if v == nil then return "-" end
    if ft == "s" or type(v) ~= "number" then return clean_str(v) end
    if not finite(v) then return "-" end
    if (ft == "i" or ft == "b") and math.tointeger(v) then return tostring(math.tointeger(v)) end
    return safe_fmt(FLOAT_FMT[ft] or "%.3f", v)
end
local function rec_line(kind, vals)   -- vals 按 SPEC 的字段顺序，可以含 nil
    local spec, parts = SPEC[kind], { REC_TAG, kind }
    for i = 1, #spec do parts[#parts + 1] = spec[i][1] .. "=" .. fmt_value(vals[i], spec[i][2]) end
    return table.concat(parts, " ")
end

-- HDR 懒写：默认不记，调试日志关着、又没出错时一行 [AutoParryGS] 都不写；但本次加载第一次写别的 [AutoParryGS] 行之前必须
-- 先补一行（分析脚本按最近的 HDR 划分 session，不补的话这次的记录会被算进上一次加载）。补写的 auto_parry、lead 是那一刻的值。
-- 加载期间写的行（初始化出错的 ERR / RED）先攒在 rec_pending 里，加载完再写（§10）：HDR 要等配置迁移完、枚举读完才写得准。
local session = os.time()
local enum_skip = nil       -- 加载时没读到的抓取名、黑名单名，逗号分隔（§6 填；都读到时为 nil，写成 -）
local hdr_written, rec_pending = false, {}
local function write_hdr()
    hdr_written = true
    log.info(rec_line("HDR", { PARRY_RULE, session, config.auto_parry, config.parry_lead, LEAD_MIN, LONG_WINDOW,
        VETO_HORIZON, CREDIT, "E5c", "g1", C_LO, C_HI, HOST, enum_skip }))
end
local function rec(kind, vals)
    local line = rec_line(kind, vals)
    if rec_pending then
        rec_pending[#rec_pending + 1] = line
        return
    end
    if not hdr_written then write_hdr() end
    log.info(line)
end

-- 错误分级（CONTRACT 2.1），不许静默吞错：核心模块（CORE）10 s 内 3 次标红；可选模块第一次出错就标黄（多数同时停用那项读取，
-- items / speed / filter / filter_enum 例外，见 §6 的 SOFT_MODS）。ERR 每次加载前 20 条立刻写，之后只计不写。
-- 只管放刀和配置读写；防御出错走 guard_warn，不进这里的红黄计数
local CORE = { msg = true, frame = true, fire = true }
local err_state = { red = false, stopped = false, yellow = 0, logged = 0, times = {} }
local mod_off = {}          -- 报过黄的可选模块
local function set_red(now, mod, why)   -- 只在第一次进红状态时写 RED（自停另写一行 why=self_stop）
    if err_state.red and why ~= "self_stop" then return end
    err_state.red = true
    rec("RED", { now, mod, why })
end
note_error = function(mod, err)
    local now, E = os.clock(), err_state
    -- 非 ASCII 换成 ?：错误文本里的路径可能是系统代码页，原样写进日志是乱码
    local msg = clean_str(err):gsub("[\128-\255]", "?"):sub(1, 200)
    local level, red_now = "yellow", false
    if CORE[mod] then
        level = "red"
        local ts = E.times[mod] or {}
        E.times[mod] = ts
        ts[#ts + 1] = now
        while #ts > 0 and now - ts[1] > RED_WINDOW do table.remove(ts, 1) end
        red_now = #ts >= RED_COUNT
    elseif not mod_off[mod] then
        mod_off[mod], E.yellow = true, E.yellow + 1
    end
    if E.logged < ERR_LOG_MAX then
        E.logged = E.logged + 1
        rec("ERR", { mod, level, msg })
    end
    if red_now then set_red(now, mod, "3in10s") end
end

-- ---------- §3 配置 ----------

local function clamp_lead(v) return math.max(LEAD_LO, math.min(LEAD_HI, math.floor(v + 0.5))) end

-- 本次加载读 AutoGuardGS.json 抛错（文件被占用等）：这次加载一律不写配置。内存里是默认值，写了就把多半完好的原文件盖掉；
-- v1.4.2 读配置不包 pcall，抛错时整个脚本加载失败，同样一个字节都不写（审查修订）。读出来不是表（文件不存在、内容坏了，
-- REF 返回 nil）分不清是哪种，照 v1.4.2：存配置时照常写
local cfg_unreadable = false
local function save_config()
    if cfg_unreadable then return end
    local ok, ret = pcall(json.dump_file, CONFIG_PATH, config)
    if not ok or ret == false then note_error("cfg", ok and "config dump_file returned false" or ret) end
end

do
    -- 读 AutoGuardGS.json：只接受认识的键和合法的值（文件被手改坏也不至于出怪事）。前 8 个键的读法和 v1.4.2 一字不差；
    -- 不认识的键（旧版留下的 cfg_ver、lead_rotation、scan 等）忽略。返回读到的表，迁移要看里面有没有放刀的两个键
    local function load_config()
        local ok, loaded = pcall(json.load_file, CONFIG_PATH)
        if not ok then
            cfg_unreadable = true
            note_error("cfg", loaded)
            return nil
        end
        if type(loaded) ~= "table" then return nil end
        for k, v in pairs(loaded) do
            if k == "guard_angle" then
                if type(v) == "number" then config.guard_angle = math.max(ANGLE_MIN, math.min(ANGLE_MAX, v)) end
            elseif k == "guard_type" then
                if v == 1 or v == 2 then config.guard_type = v end
            elseif k == "parry_lead" then
                if finite(v) then config.parry_lead = clamp_lead(v) end
            elseif config[k] ~= nil and type(v) == type(config[k]) then
                config[k] = v
            end
        end
        return loaded
    end

    -- 从旧的 AutoParryGS.json 迁移，只迁一次（MERGE 3.3）：AutoGuardGS.json 里 auto_parry、parry_lead 两个键都没有时才迁。
    -- 取值和 AutoParryGS v1.6 读同一个文件得到的完全相同：auto_parry 是布尔才收；cfg_ver 不是 ≥3 的数（缺失、1、2、
    -- 字符串 "3"）时旧提前量是名义帧口径，一律用 28。debug_log 不迁：调试日志只用本脚本自己的开关。
    -- 迁完立刻写回 AutoGuardGS.json，以后不再读旧文件。旧文件只读，不改不删：回滚到 v1.6 时它还要用。
    -- 旧文件不存在或内容坏了：用默认值、不写回（下次加载再试一次，结果相同）。
    -- 只有 AutoGuardGS.json 读出了表才在加载时写回：文件不存在、读不出来时只在内存里迁，等存配置时再写。否则迁移完以后
    -- 哪次加载读盘偶发失败，就会在加载那一刻拿默认值把用户的防御设置整份盖掉（旧文件永远在，每次都会走到这里；审查修订）
    local function migrate_parry_config(loaded)
        if loaded and (loaded.auto_parry ~= nil or loaded.parry_lead ~= nil) then return end
        local ok, old = pcall(json.load_file, LEGACY_PARRY_CONFIG)
        if not ok then
            note_error("cfg", old)
            return
        end
        if type(old) ~= "table" then return end
        if type(old.auto_parry) == "boolean" then config.auto_parry = old.auto_parry end
        local ver = old.cfg_ver
        if type(ver) == "number" and ver >= LEGACY_CFG_VER and finite(old.parry_lead) then
            config.parry_lead = clamp_lead(old.parry_lead)
        end
        if loaded then save_config() end
    end

    local ok, err = pcall(function() migrate_parry_config(load_config()) end)
    if not ok then note_error("cfg", err) end
end

-- ---------- §4 主角与动作 ----------

local function make_action_id(cat, idx)
    local id = ValueType.new(sdk.find_type_definition("ace.ACTION_ID"))
    id:set_field("_Category", cat)
    id:set_field("_Index", idx)
    return id
end

local function master_player()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    return pm and pm:call("getMasterPlayer")
end

-- 每帧开头读一次主角快照，交给防御和放刀两段共用（两段之间没有游戏更新，读到的值相同）。调用顺序和 AutoParryGS v1.6 的
-- read_hunter 一字不差：主角 → 地址 → 武器 → 动作控制器 → 动作 ID。没有主角返回 nil；动作 ID 读不到时 cat / idx 为 nil
local function read_hunter()
    local p = master_player()
    local hunter = p and p:call("get_Character")
    if not hunter then return nil end
    local addr = hunter:get_address()
    local gs = hunter:call("get_WeaponType") == WEAPON_GREAT_SWORD
    local ctrl = hunter:call("get_BaseActionController")
    local id = ctrl and ctrl:call("get_CurrentActionID")
    if not id then return hunter, addr, gs end
    return hunter, addr, gs, id:get_field("_Category"), id:get_field("_Index")
end

-- ---------- §5 自动防御 ----------
-- 对外：帧回调用 guard_tick、restore_hit_state；Reset 用 restore_hit_state、restore_overheat；菜单用 draw_guard、draw_tests
local guard_ready = false   -- init_guard 成功才为 true；失败时防御整块不工作，放刀照常（MERGE 1.5）
local guard_tick, restore_hit_state, restore_overheat, draw_guard, draw_tests
do
    local GUARD_TYPES = { "精确防御", "普通防御" }
    local GUARD_FLAG_NAMES = { "TECHNICAL_GUARD", "GUARD" }
    local ANGLE_FIELDS = { "_GuardDegree", "_AimGuardDegree" }
    local guard_init_err = nil
    local HunterCharacter, HunterHealth, T_CharacterBase = nil, nil, nil
    local GUARD_FLAGS, EXISTING_GUARD_FLAGS, ARMOR_FLAGS = nil, nil, nil
    local CANCEL_INDEX_INVALID, GUARD_ACTION_ID = nil, nil

    local forced = nil          -- { flags = 标志组, list = 我们打开的标志 }
    local angle_defaults = nil  -- 游戏原值 { _GuardDegree = 70, _AimGuardDegree = 70 }
    local angle_restore = nil   -- 结算期间要还原的 { param = ..., values = {...} }
    local tackle = nil          -- 进行中的肩撞请求 { id, deadline, tries }
    local master_health_addr = nil   -- 锁血：主玩家 cHunterHealth 的地址，每帧开头更新；钩子里拿 this 的地址和它比，只拦主玩家

    -- 钩子里照旧现读动作：受击结算在帧中途，动作可能已经和帧开头的快照不同
    local function current_action(hunter)
        local id = hunter:call("get_BaseActionController"):call("get_CurrentActionID")
        return id:get_field("_Category"), id:get_field("_Index")
    end

    -- 调试用：当前动作的简短名字，例如 "(1,14) cIdle"
    local function action_text(hunter)
        local ctrl = hunter:call("get_BaseActionController")
        local id = ctrl:call("get_CurrentActionID")
        local act = ctrl:call("get_CurrentAction")
        local name = act and act:get_type_definition():get_full_name() or "?"
        name = name:gsub("app%.Wp%d%dAction%.", ""):gsub("app%.PlayerCommonAction%.", "")
        return string.format("(%d,%d) %s", id:get_field("_Category"), id:get_field("_Index"), name)
    end

    local function is_enemy(game_object)
        if not game_object then return false end
        local chara = game_object:call("getComponent(System.Type)", T_CharacterBase)
        return chara ~= nil and chara:get_type_definition():is_a("app.EnemyCharacter")
    end

    local function any_flag(flags, list)
        for _, f in ipairs(list) do
            if flags:call("check(System.UInt32)", f) then return true end
        end
        return false
    end

    -- 能不能举剑。第一层问游戏：checkContainsActionInCurrentBTable 回答「当前行为表里有没有通往防御动作 (1,141) 的路」。
    --   实测：收刀、受击硬直、蓄力中都是 false，判断准确；但它不看时机（翻滚后半段能取消成防御，所以整个翻滚都返回 true）。
    -- 第二层：动作属性黑名单，补上不看时机漏掉的情况（翻滚、倒地起身等）。
    --   用属性而不是动作名：属性是游戏给动作打的标签，所有武器、所有同类动作通用。
    local BLOCKED_ATTR_NAMES = {
        -- 翻滚
        "DODGE", "DODGE_BACK", "DODGE_LEFT", "DODGE_RIGHT",
        -- 受击、倒地、起身
        "DAMAGE", "DAMAGE_DOWN", "DAMAGE_SLIP", "SMASH_DAMAGE", "SMASH_DAMAGE_LAND", "PRONE", "SUPINE",
        -- 异常状态
        "STUN", "SLEEP", "PARALYZE", "FROZEN", "STICKY", "QUAKE",
        -- 用道具（喝药、磨刀）、收刀
        "ITEM_USE", "WP_OFF",
        -- 骑乘、移动手段、非战斗动作
        "BATTLE_RIDING", "PORTER", "TARZAN_ATTACH", "USE_ROPE", "HAGITORI", "FACILITY", "COMMUNICATION", "PETTING", "DIE",
    }
    local BLOCKED_ATTRS = {}

    -- 返回 nil 表示可以举剑，否则返回不能举剑的原因
    local function why_cannot_guard(hunter, player)
        if not hunter:call("get_IsWeaponOn") then return "weapon off" end
        local entity = player:call("get_Controller"):call("get_ControllerEntity")
        local can = entity:call("checkContainsActionInCurrentBTable(ace.ACTION_ID, app.AppActionDef.LAYER, app.ACTION_CANCEL_INDEX)",
            GUARD_ACTION_ID, LAYER_BASE, CANCEL_INDEX_INVALID)
        if not can then return "btable" end
        for _, a in ipairs(BLOCKED_ATTRS) do
            if hunter:call("isActionAttrCurrentAction(app.HunterDef.ACTION_ATTR)", a.value) then return "attr " .. a.name end
        end
        return nil
    end

    -- 防御角度。Catalog 暂时为 nil 时按「参数还读不到」处理（菜单显示「等待读取角色数据」），不抛错：v1.4.2 在这里直接
    -- 索引 nil，菜单那几帧抛错、imgui 栈不平衡（推测：标题画面、读盘时 PlayerManager 已在而 Catalog 未建，没直接测到）
    local function gs_action_param()
        local pm = sdk.get_managed_singleton("app.PlayerManager")
        local cat = pm and pm:call("get_Catalog")
        return cat and cat:call("getWeaponActionParam(app.WeaponDef.TYPE)", WEAPON_GREAT_SWORD)
    end

    local function ensure_angle_defaults()
        if angle_defaults then return true end
        local param = gs_action_param()
        if not param then return false end
        angle_defaults = {}
        for _, f in ipairs(ANGLE_FIELDS) do angle_defaults[f] = param:get_field(f) end
        log.info(string.format("%sgame guard angle: %.1f (aim %.1f)", TAG, angle_defaults._GuardDegree, angle_defaults._AimGuardDegree))
        return true
    end

    local function current_angle()
        return config.guard_angle or (angle_defaults and angle_defaults._GuardDegree)
    end

    local function apply_angle()
        -- 已经改过还没还原（同一帧连续挨打）：别再保存一次，否则会把改过的值当成原值
        if angle_restore or not ensure_angle_defaults() then return end
        local angle = current_angle()
        local param = gs_action_param()
        if not angle or not param then return end
        local saved = {}
        for _, f in ipairs(ANGLE_FIELDS) do
            saved[f] = param:get_field(f)
            param:set_field(f, angle)
        end
        angle_restore = { param = param, values = saved }
    end

    -- 【测试】无限蓄力。每种蓄力参数（Wp00ActionParam.cCharge）里有 _OverheatTime：蓄满后再按住这么久就「过热」自动放出
    -- （实测原值：普通 / 强 / 真蓄力 3 秒，抵消蓄力 2.5 秒）。生效条件：开关打开且主玩家拿着大剑，否则还原。
    -- 不只在「蓄力动作中」才改：游戏可能在进入蓄力时就读走这个值，等进了蓄力再改会晚一帧。
    -- 代价：这份参数所有大剑共用，生效期间 NPC 支援猎人的大剑也会无限蓄力（测试开关，可接受）。
    local CHARGE_PARAM_FIELDS = { "_ChargeParam", "_ChargeParam_Strong", "_ChargeParam_Spirit", "_ChargeParam_Parry",
                                  "_ChargeParam_Fly", "_ChargeParam_Sliding", "_ChargeParam_BattleRide" }
    local INFINITE_OVERHEAT = 99999.0
    local overheat_restore = nil   -- { { obj = cCharge, value = 原值 }, ... }；nil = 没改

    local function apply_infinite_charge()
        if overheat_restore then return end
        local param = gs_action_param()
        if not param then return end
        local saved = {}
        for _, name in ipairs(CHARGE_PARAM_FIELDS) do
            local c = param:get_field(name)
            if c then
                table.insert(saved, { obj = c, value = c:get_field("_OverheatTime") })
                c:set_field("_OverheatTime", INFINITE_OVERHEAT)
            end
        end
        overheat_restore = saved
        debug(string.format("infinite charge ON (%d params)", #saved))
    end

    restore_overheat = function()
        if not overheat_restore then return end
        for _, s in ipairs(overheat_restore) do
            pcall(function() s.obj:set_field("_OverheatTime", s.value) end)
        end
        overheat_restore = nil
        debug("infinite charge OFF (restored)")
    end

    -- 自动肩撞。走过的弯路（都实测过）：受击结算中途 changeActionImmediate 切成肩撞，进入流程被跳过，动画和超级霸体都
    --   没跟上；虚拟按住防御键，按了 28 帧游戏都没反应（蓄力中出肩撞不走这个键）。
    -- 现在的做法：每帧开头请求，由动作控制器在当帧按正常流程处理，和游戏自己出招是同一条路。挨打后的顿帧期间请求可能被拒，
    --   所以每帧重试，直到进了肩撞或超时（实测都是第一次就成功）。肩撞 ID 跟蓄力等级走（实测）：开始蓄力 / 一段蓄力 → (2,15)，
    --   强蓄力 / 真蓄力 → (2,17)。和自动放刀互不干扰：肩撞只从 (2,5)/(2,6)/(2,7)/(2,11) 出，放刀只从 (2,21)/(2,22) 出，
    --   两段读的是同一个快照，同一帧最多一个动作请求
    local CHARGE_TO_TACKLE = { [5] = 15, [6] = 15, [7] = 17, [11] = 17 }   -- 分类 2 内：蓄力动作编号 -> 肩撞编号
    local TACKLE_ACTIONS = { [15] = true, [17] = true }
    local TACKLE_TIMEOUT = 0.3

    local function charge_index(hunter)   -- 钩子里用：现读动作
        local cat, idx = current_action(hunter)
        if cat == 2 and CHARGE_TO_TACKLE[idx] then return idx end
        return nil
    end

    local function request_tackle(hunter, charge_idx)
        if tackle then return end
        local idx = CHARGE_TO_TACKLE[charge_idx]
        tackle = { id = make_action_id(2, idx), deadline = os.clock() + TACKLE_TIMEOUT, tries = 0 }
        debug(string.format("tackle requested -> (2,%d) | %s", idx, action_text(hunter)))
    end

    -- 每帧开头推进（用帧开头的动作快照）：直到进了肩撞 / 超时 / 已不在蓄力
    local function update_tackle(hunter, cat, idx)
        if not tackle then return end
        if cat == nil or idx == nil then   -- 动作 ID 读不到：清掉请求（v1.4.2 在这里抛错进 pcall 再清掉，结果一样）
            tackle = nil
            return
        end
        if cat == 2 and TACKLE_ACTIONS[idx] then
            stats.tackled = stats.tackled + 1
            debug(string.format("tackle OK after %d requests | %s", tackle.tries, action_text(hunter)))
            tackle = nil
            return
        end
        if os.clock() > tackle.deadline then
            debug(string.format("tackle TIMEOUT after %d requests | %s", tackle.tries, action_text(hunter)))
            tackle = nil
            return
        end
        -- 已经不在蓄力了（比如被打倒、自己放了斩击）：不再强行肩撞
        if not (cat == 2 and CHARGE_TO_TACKLE[idx]) then
            debug("tackle CANCELLED, no longer charging | " .. action_text(hunter))
            tackle = nil
            return
        end
        local accepted = hunter:call(REQ_SIG, LAYER_BASE, tackle.id, false)
        tackle.tries = tackle.tries + 1
        if tackle.tries == 1 or accepted then
            debug(string.format("tackle request #%d accepted=%s | %s", tackle.tries, tostring(accepted), action_text(hunter)))
        end
    end

    -- 还原受击钩子里改的东西（标志和角度都不许跨帧）。只还原状态，和 REF 的 release（扣引用）无关
    restore_hit_state = function()
        if angle_restore then
            for f, v in pairs(angle_restore.values) do angle_restore.param:set_field(f, v) end
            angle_restore = nil
        end
        if forced then
            for _, f in ipairs(forced.list) do forced.flags:call("off(System.UInt32)", f) end
            forced = nil
        end
    end

    -- 受击：结算前打开防御标志
    local function on_damage_pre(args)
        if not guard_ready then return end
        local ok, err = pcall(function()
            local hunter = sdk.to_managed_object(args[2])
            if not hunter:call("get_IsMaster") then return end
            if hunter:call("get_WeaponType") ~= WEAPON_GREAT_SWORD then return end
            if not is_enemy(sdk.to_managed_object(args[3]):call("get_AttackOwner")) then return end

            -- 角度对手动防御同样生效，所以先于开关判断。例外：抵消动作族 (2,21)~(2,29) 里不改（v1.4.1）。刀上的抵消碰撞
            -- （ATTACK_PARRY_GET）也会走进这个钩子，而且在同一帧的抵消结算之前（日志 16:12:47.045 实测）；这时改写共用的
            -- 防御角度，会混进自动放刀的结果，也可能造成 mod 导致的「全向抵消」假象
            local cat, idx = current_action(hunter)
            if not (cat == 2 and idx >= 21 and idx <= 29) then apply_angle() end

            if not config.enabled then return end

            -- 蓄力中：不防御（蓄力霸体会硬吃），改为挨打后自动肩撞
            local charge_idx = charge_index(hunter)
            if config.auto_tackle and charge_idx then
                request_tackle(hunter, charge_idx)
                return
            end

            local flags = hunter:call("get_HunterStatus"):get_field("_HunterStatusFlag")
            if any_flag(flags, EXISTING_GUARD_FLAGS) then
                stats.already_guarding = stats.already_guarding + 1
                return
            end
            if config.respect_armor and any_flag(flags, ARMOR_FLAGS) then
                stats.skipped_armor = stats.skipped_armor + 1
                debug("skip: armor | " .. action_text(hunter))
                return
            end

            local reason = why_cannot_guard(hunter, master_player())
            if reason then
                stats.skipped_state = stats.skipped_state + 1
                debug("skip: " .. reason .. " | " .. action_text(hunter))
                return
            end

            local f = GUARD_FLAGS[config.guard_type]
            flags:call("on(System.UInt32)", f)
            forced = { flags = flags, list = { f } }
            stats.guarded = stats.guarded + 1
            debug("guard forced: " .. GUARD_FLAG_NAMES[config.guard_type] .. " | " .. action_text(hunter))
        end)
        if not ok then
            guard_warn("pre", err)
            local ok2, err2 = pcall(restore_hit_state)
            if not ok2 then guard_warn("pre", err2) end
        end
    end

    -- 结算完关掉我们打开的标志、还原角度
    local function on_damage_post(retval)
        if guard_ready then
            local ok, err = pcall(restore_hit_state)
            if not ok then guard_warn("post", err) end
        end
        return retval
    end

    -- 【测试】锁血：登记伤害（受击扣血）和红血伤害时，对主玩家跳过原函数
    local function block_master_damage(args)
        if not guard_ready or not config.lock_health or not master_health_addr then return nil end
        local ok, hit = pcall(function() return sdk.to_int64(args[2]) == master_health_addr end)
        if ok and hit then
            stats.damage_blocked = stats.damage_blocked + 1
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        return nil
    end

    -- 每帧兜底：血不满就补满（覆盖不走 requestDamage 的扣血）
    local function update_lock_health(hunter)
        if not config.lock_health then
            master_health_addr = nil
            return
        end
        local health = hunter:call("get_HunterHealth")
        master_health_addr = health and health:get_address() or nil
        local mgr = health and health:call("get_HealthMgr")
        if not mgr then return end
        local hp, max = mgr:call("get_Health"), mgr:call("get_MaxHealth")
        if hp and max and hp < max then mgr:call("set_Health(System.Single)", max) end
    end

    -- 帧开头（快照之后）：锁血兜底、无限蓄力开关、推进自动肩撞。
    -- 快照读到一半抛错（rok 为 false）时照 v1.4.2 自己再读一遍，只读这一帧用得到的、顺序同 v1.4.2：主角；武器只在无限蓄力
    -- 开着时读；动作只在有肩撞请求时读。为什么不直接跳过这一帧：快照比 v1.4.2 多读武器、动作控制器，这几项出错时 v1.4.2
    -- 照常补血、照常还原 _OverheatTime，跳过的话关开关后的还原要拖到故障结束（审查修订；mock 场景 guard_read_fault、
    -- guard_tackle_read_fault）。
    -- 自己读也抛错时由 guard_tick 清掉肩撞请求，同 v1.4.2 的「帧出错」
    local function guard_frame(rok, hunter, gs, cat, idx)
        if not rok then
            local p = master_player()
            hunter = p and p:call("get_Character")
        end
        if not hunter then
            tackle = nil
            master_health_addr = nil
            restore_overheat()
            return
        end
        update_lock_health(hunter)
        if not rok then gs = config.infinite_charge and hunter:call("get_WeaponType") == WEAPON_GREAT_SWORD end
        if config.infinite_charge and gs then apply_infinite_charge() else restore_overheat() end
        if not rok and tackle then cat, idx = current_action(hunter) end
        update_tackle(hunter, cat, idx)
    end

    guard_tick = function(rok, hunter, gs, cat, idx)
        local ok, err = pcall(guard_frame, rok, hunter, gs, cat, idx)
        if not ok then
            guard_warn("frame", err)
            tackle = nil
        end
    end

    local function hook_pre(kind, fn)   -- 前置钩子外层的 pcall：出错写警告，返回 nil（照常调用原函数）
        return function(args)
            local ok, r = pcall(fn, args)
            if ok then return r end
            guard_warn(kind, r)
            return nil
        end
    end

    local function need(v, what)   -- 初始化时类型、方法拿不到：报清楚是哪个（菜单里显示），别让后面的 nil 索引报一句看不懂的错
        if v == nil then error(what .. " not found", 0) end
        return v
    end

    -- 查类型、读枚举、注册 4 个钩子（顺序同 v1.4.2）。整个包在 pcall 里：失败只停防御（guard_ready = false），放刀照常；
    -- 已经注册上的钩子第一句先看 guard_ready
    local function init_guard()
        HunterCharacter = need(sdk.find_type_definition("app.HunterCharacter"), "app.HunterCharacter")
        local STATUS_FLAG = need(sdk.find_type_definition("app.HunterDef.STATUS_FLAG"), "app.HunterDef.STATUS_FLAG")
        local ACTION_ATTR = need(sdk.find_type_definition("app.HunterDef.ACTION_ATTR"), "app.HunterDef.ACTION_ATTR")
        T_CharacterBase = need(sdk.typeof("app.CharacterBase"), "typeof app.CharacterBase")
        local function flag(name) return need(STATUS_FLAG:get_field(name), "STATUS_FLAG." .. name):get_data(nil) end
        GUARD_FLAGS = { flag("TECHNICAL_GUARD"), flag("GUARD") }
        -- 已经在防御（手动防御、肩撞的判定点防御等）就不用我们插手
        EXISTING_GUARD_FLAGS = { flag("GUARD"), flag("TECHNICAL_GUARD"), flag("GUARD_POINT"), flag("POWER_GUARD") }
        ARMOR_FLAGS = { flag("SUPER_ARMOR"), flag("HYPER_ARMOR") }
        local cancel = need(sdk.find_type_definition("app.ACTION_CANCEL_INDEX"), "app.ACTION_CANCEL_INDEX")
        CANCEL_INDEX_INVALID = need(cancel:get_field("Invalid"), "ACTION_CANCEL_INDEX.Invalid"):get_data(nil)
        GUARD_ACTION_ID = make_action_id(1, 141)   -- app.Wp00Action.cGuard
        for _, n in ipairs(BLOCKED_ATTR_NAMES) do
            local f = ACTION_ATTR:get_field(n)
            if f then
                table.insert(BLOCKED_ATTRS, { name = n, value = f:get_data(nil) })
            else
                log.warn(TAG .. "ACTION_ATTR." .. n .. " not found, skipped")
            end
        end
        local function hook(td, sig, pre, post)
            sdk.hook(need(td:get_method(sig), td:get_full_name() .. "." .. sig), pre, post)
        end
        hook(HunterCharacter, "evHit_DamagePreProcess(app.HitInfo)", timed("dmg_pre", on_damage_pre), nil)
        hook(HunterCharacter, "evHit_Damage(app.HitInfo)", nil, timed("dmg", on_damage_post))
        HunterHealth = need(sdk.find_type_definition("app.cHunterHealth"), "app.cHunterHealth")
        hook(HunterHealth, "requestDamage(app.HunterCharacter, System.Single, System.Single, System.Boolean, System.Boolean, "
            .. "System.Boolean, System.Boolean, System.Boolean, System.Boolean)", hook_pre("health", block_master_damage), nil)
        hook(HunterHealth, "requestRedDamage(System.Single)", hook_pre("health", block_master_damage), nil)
    end

    local ok, err = pcall(init_guard)
    guard_ready = ok
    if not ok then
        guard_init_err = tostring(err)
        guard_warn("init", guard_init_err)
    end

    draw_guard = function()
        if not guard_ready then
            imgui.text("自动防御初始化失败：" .. tostring(guard_init_err) .. "；自动放刀不受影响")
            return
        end
        local changed, v
        changed, v = imgui.checkbox("启用自动防御（含自动肩撞）##enabled", config.enabled)
        if changed then config.enabled = v end
        changed, v = imgui.combo("防御类型##guard_type", config.guard_type, GUARD_TYPES)
        if changed then config.guard_type = v end
        changed, v = imgui.checkbox("霸体时不防御（保护真蓄力斩等霸体攻击）##respect_armor", config.respect_armor)
        if changed then config.respect_armor = v end
        changed, v = imgui.checkbox("蓄力中挨打后自动肩撞##auto_tackle", config.auto_tackle)
        if changed then config.auto_tackle = v end
        imgui.separator()
        if ensure_angle_defaults() then
            changed, v = imgui.slider_float("防御角度##guard_angle", current_angle(), ANGLE_MIN, ANGLE_MAX, "%.0f 度")
            if changed then config.guard_angle = v end
            imgui.same_line()
            if imgui.button("恢复默认##angle_default") then config.guard_angle = nil end
            imgui.text(string.format("游戏默认 %.0f 度（正前方左右各 %.0f 度），当前左右各 %.0f 度。手动防御同样生效。",
                angle_defaults._GuardDegree, angle_defaults._GuardDegree / 2, current_angle() / 2))
        else
            imgui.text("防御角度：等待读取角色数据……")
        end
    end

    draw_tests = function()
        if not guard_ready then return end
        local changed, v = imgui.checkbox("【测试】无限蓄力（蓄满后不会自动放出）##infinite_charge", config.infinite_charge)
        if changed then config.infinite_charge = v end
        if config.infinite_charge then
            imgui.text(overheat_restore and "状态：生效中（同场 NPC 支援猎人的大剑也会受影响）" or "状态：等待（拿起大剑后生效）")
        end
        changed, v = imgui.checkbox("【测试】锁血（不掉血、不会倒下，被打的动作照常）##lock_health", config.lock_health)
        if changed then config.lock_health = v end
        if config.lock_health then
            imgui.text(string.format("状态：%s，已拦下扣血 %d 次", master_health_addr and "生效中" or "等待（进入任务后生效）",
                stats.damage_blocked))
        end
    end
end

-- ---------- §6 自动放刀 ----------
-- 对外：帧回调用 parry_tick；Reset 用 parry_reset；菜单用 draw_parry
local parry_tick, parry_reset, draw_parry
do
    local SPEED_FAIL_STREAK = 5         -- 连续这么多个新结果首帧读不到 C 就报黄
    local CLOCK_DMAX = 30               -- 时钟条目一对读数之间 hs 递减的上限：30 + 60 × 两次读数隔开的秒数（单帧 dt 钳在 0.133 s）
    local TRACK_MAX, TRACK_STALE = 32, 8.0   -- 最多跟踪 32 条；距最后一条消息 8 s 丢弃（实测最长预告 402 帧，约 6.7 s）
    local PAST_HE, PAST_AGE = -30, 1.0  -- 全部条目 he < -30 且距消息 ≥1 s：这一招早就打完了
    local CAT_ATTACK, IDX_SLASH, IDX_SLASH_FWD = 2, 23, 24   -- (2,23) cParrySlash 上捞斩；(2,24) 前进版
    local PARRY_CHARGE = { [21] = true, [22] = true }       -- 从 (2,22) 放刀也会被接受（v1.6 试打 7 刀里 3 刀，实测）
    local PARRY_OUT = { [25] = "RECOIL", [26] = "CATCH26", [27] = "CATCH27" }   -- 游戏自己切的结局动作（G1：(2,25) 是被弹）
    local STOP_FRAMES = 30              -- 帧逻辑连续出错这么多帧就自停
    -- 读主角/动作 ID 的调用抛错（切场景时对象正在销毁）：1.5 s 内按「这一帧不存在」处理，否则一次 0.1 s 的瞬时异常
    -- 3 帧内就会标红；间隔不到 0.5 s 的零星失败算同一段，间歇故障照样会在 1.5 s 后升级成错误
    local READ_FAIL_TOL, READ_FAIL_GAP = 1.5, 0.5
    local MSG_TYPE = "app.game_message.cMsgEmAttackAreaResult"

    local RT_DANGER, SLASH_ID = nil, nil   -- app.AttackAreaResult.RESULT_TYPE.DANGER；ace.ACTION_ID (2,23)
    local EFFECT_DAMAGE = {}    -- app.HitDef.DAMAGE_TYPE 的 EAR/WIND/QUAKE：咆哮、风压、震动不是能抵消的打击
    local effect_partial = false   -- 效果攻击有名字没读到：认不出的伤害类型可能就是它（候选侧按读不准处理）
    local GRAB_DAMAGE = {}      -- app.HitDef.DAMAGE_TYPE 的 CATCH/CATCH_ZAKO/CATCH_SLINGER：抓取，刀碰到了也抵消不了（实测）
    -- 攻击的防御类型 app.Hit.GUARD_TYPE（2026-10-11 MCP 核对：NORMAL、ALL_RANGE、UNABLE_GUARD、SKILL_GUARD、
    -- SKILL_GUARD_ALL_RANGE、MAX）：白名单 = 该接；SKILL_GUARD 家族同抓取（否决、不进候选）；UNABLE_GUARD 和其余值不该接
    local HIT_GUARD_WHITE, HIT_GUARD_SG, HIT_GUARD_UG = {}, {}, nil
    local filter_enum_missing = nil   -- 读不到的过滤枚举名（效果名、白名单名），状态行写清缺了哪个
    local T_ENEMY = nil         -- sdk.typeof("app.EnemyCharacter")：联机闸门从发送者身上取怪物

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

    local function self_stop_init(err)     -- 核心类型或钩子拿不到，规则无法运行：直接自停并标红（防御照常）
        note_error("frame", err)
        set_red(os.clock(), "frame", "init")
        err_state.stopped = true
    end

    local function addr_of(obj)
        if not obj then return nil end
        local ok, a = pcall(obj.get_address, obj)
        return ok and a or nil
    end

    -- 唯一有副作用的游戏调用：帧开头请求上捞斩，走动作控制器的正常进入流程（NOTES「改动作」实测）
    local function request_slash(hunter)
        local ok, err = pcall(hunter.call, hunter, REQ_SIG, LAYER_BASE, SLASH_ID, false)
        if not ok then note_error("fire", err) end
    end

    -- 预告跟踪。跨帧只持有结果对象 tr.obj（登记时 add_ref、丢弃时只删 Lua 引用）；条目、怪物、主角对象只在当帧用，
    -- 跨帧只存地址和数值
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
        if old_key then drop_track(old_key) end
    end

    -- 联机闸门：发送者就是怪物本体（第 1 轮 435/435，实测），它的 _Context:get_IsMaster() 为 false = 怪物是副本。
    -- 链上哪一环是 nil 返回 nil（按主机处理）；返回值不是布尔就抛错
    local function read_master(msg)
        local go = msg:call("get_SendGameObject")
        local enemy = go and go:call("getComponent(System.Type)", T_ENEMY)
        local holder = enemy and enemy:get_field("_Context")
        if not holder then return nil end
        local m = holder:call("get_IsMaster")
        if type(m) ~= "boolean" then error("get_IsMaster returned " .. tostring(m)) end
        return m
    end

    -- 钩子里不读速度（见头注释），只存 SystemIndex。每个结果对象只发一条消息（1620/1620，实测）；万一已跟踪的结果又来消息
    -- 只刷新 t_msg：E5c 按条目首见时刻记 X0，不用重置（重置反而会清掉已经累加的 X）
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
        -- get_EmID 必须在登记时读（不能挪到写 FIRE 时）：它抛错会让整条预告不登记，挪走就改了出故障时放不放刀
        local em = "em" .. int_s(r:call("get_EmID")) .. "#" .. int_s(idx)
        -- 是不是主机只在登记时读一次。读不到按主机处理（fail-open，单人时恒为 true）；抛错第一次标黄并停用这项读取
        local master = nil
        if not mod_off.master then
            local ok, m = pcall(read_master, msg)
            if ok then master = m else note_error("master", m) end
        end
        if n_tracks >= TRACK_MAX then drop_oldest() end
        r:add_ref()
        -- E5c：X = 怪物比计时器多走的名义帧；x0 / a0 = 条目首见时的 X、hs；hs_prev / t_prev = 上次读到的 [条目地址] = hs 和
        -- 时刻；c1 / cf = 首帧 / 本帧原始 C，nchg = m 变了几次（这三个和 a0 只给 FIRE 用：诊断放早）
        tracks[key] = { obj = r, t_msg = now, em = em, master = master ~= false, idx = math.tointeger(idx), first = true,
            m = nil, X = 0.0, x0 = {}, a0 = {}, hs_prev = nil, clock = nil, nchg = 0, c1 = nil, cf = nil, nofire = false }
        n_tracks = n_tracks + 1
    end

    -- 速度（E5c，V16 第 2 节）。speed_cache[SystemIndex] = 本帧读到的 { c = C 或 nil }，每帧清空；spd = 首帧连续读不到的
    -- 结果数、≥5 的状态（状态行用）
    local speed_cache = {}
    local spd = { streak = 0, x5 = false, x5_ever = false, err = false }
    -- 读路径照抄 APCal 的 find_enemy（实测）。2026-10-11 MCP get_type 核对：findEnemy_SystemIndex(System.Int32) →
    -- app.cEnemyManageInfo；get_Character() → app.EnemyCharacter；CoreState → System.Single
    local function core_read(idx)
        local mgr = sdk.get_managed_singleton("app.EnemyManager")
        if not mgr then return nil end
        local info = mgr:call("findEnemy_SystemIndex(System.Int32)", idx)
        if not info then return nil end
        local enemy = info:call("get_Character")
        if not enemy then return nil end
        local c = enemy:call("get_MotionSpeed_CoreState")
        if not finite(c) or c < C_LO or c > C_HI then return nil end
        return c
    end
    -- 读 C 抛错不算帧逻辑错误（不进 frame 的红计数、不进 30 帧自停）：第一次报黄 speed，不停用读取
    local function core_of(idx)
        if idx == nil then return nil end
        local s = speed_cache[idx]
        if not s then
            local ok, c = pcall(core_read, idx)
            if not ok and not spd.err then
                spd.err = true
                note_error("speed", c)
            end
            s = { c = ok and c or nil }
            speed_cache[idx] = s
        end
        return s.c
    end
    -- 时钟条目两帧之间 hs 的递减：优先沿用上一帧用过的那条；不在了按条目表顺序找第一条两帧都有的，并改记 tr.clock
    local function clock_delta(tr, list, cur)
        local prev, c = tr.hs_prev, tr.clock
        if c and cur[c] and prev[c] then return prev[c] - cur[c] end
        for _, e in ipairs(list) do
            if prev[e.key] then tr.clock = e.key; return prev[e.key] - e.hs end
        end
    end
    -- 每帧每个结果（不论在不在蓄力，X 要从登记起连续累加）。list 为 nil（读出错）的帧不累加、不记 X0，C 照读。之后那一对
    -- 读数（读主角抛错的容忍期同样）跨好几帧：乘最后的 m（近似），上限按隔开的时间放宽（固定 30 时断档 ≥0.5 s 整段不累加）
    local function speed_step(tr, list, now)
        local C = core_of(tr.idx)
        local cur = list and {} or nil
        for _, e in ipairs(list or {}) do cur[e.key] = e.hs end
        -- (a) 累加：上一帧的 m × 同一条条目两帧之间 hs 的递减（写成「在区间里才累加」，NaN 也不累加）
        if cur and tr.hs_prev and tr.m then
            local d = clock_delta(tr, list, cur)
            if d and d >= 0 and d <= CLOCK_DMAX + 60.0 * (now - tr.t_prev) then tr.X = tr.X + d * (tr.m - 1.0) end
        end
        -- (b) m：登记后第一个帧回调 = 离线验证的采样点
        if tr.first then
            tr.first = false
            if C then
                tr.m, tr.c1 = math.max(1.0, C), C
                spd.streak, spd.x5 = 0, false
            else
                tr.nofire, spd.streak = true, spd.streak + 1
                if spd.streak >= SPEED_FAIL_STREAK and not spd.x5 then   -- 每次进入这个状态报一次黄，不停用读取
                    spd.x5, spd.x5_ever = true, true
                    note_error("speed", "first_frame_fail_x5")
                end
            end
        elseif tr.m and C then   -- 中途读不到：沿用上一帧的 m
            local m = math.max(1.0, C)
            if math.abs(m - tr.m) > 1e-4 then tr.nchg = tr.nchg + 1 end
            tr.m = m
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

    -- 条目读取与「该接」过滤（V16 第 3 节）
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
    -- 过滤字段读取出错（抛错、类型不对、ShellIndex 形态不认识）：第一次报黄 filter，不停用读取（停用就再也放不了刀）
    local function filter_error(err)
        if not mod_off.filter then note_error("filter", err) end
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
    local function shell_of(e)
        if e.s == nil then
            local ok, v = pcall(has_shell, e.d)
            if ok then e.s = v else
                filter_error(v)
                e.s = "?"
            end
        end
        if e.s == "?" then return nil end
        return e.s
    end
    -- 读攻击参数的一个字段（每个字段单独 pcall：_GuardType 读坏了不能连带丢掉只靠 _DamageType 的抓取否决）。
    -- 整数字段返回整数、布尔字段返回布尔；抛错或类型不对报 filter、返回 nil
    local function ap_field(ap, name, want_bool)
        local ok, v = pcall(ap.get_field, ap, name)
        if ok and want_bool and type(v) == "boolean" then return v end
        local iv = ok and not want_bool and math.tointeger(v) or nil
        if iv then return iv end
        filter_error(ok and (name .. "=" .. tostring(v)) or v)
        return nil
    end
    -- 攻击参数 cAttackParamEm（字段 2026-10-11 MCP 核对）→ c：dmg_ok、grab、effect（nil = 效果名缺认不出）、guard_ok、
    -- g（white | ug | sg | unknown）、pb（nil = 读不准）。攻击参数为 nil 是数据情况（em27 个别条目），不报黄。
    -- 本帧缓存在条目上（否决、候选共用）
    local function classify(e)
        if e.c then return e.c end
        local c = { dmg_ok = false, guard_ok = false }
        e.c = c
        local ok, ap = pcall(e.d.call, e.d, "get_AttackParam")
        if not ok then filter_error(ap) end
        if not ok or ap == nil then return c end
        local t = ap_field(ap, "_DamageType")
        if t then
            c.dmg_ok, c.grab = true, GRAB_DAMAGE[t] ~= nil
            if EFFECT_DAMAGE[t] then c.effect = true elseif not effect_partial then c.effect = false end
        end
        local g = ap_field(ap, "_GuardType")
        if g then
            c.guard_ok = true
            c.g = HIT_GUARD_WHITE[g] and "white" or (g == HIT_GUARD_UG and "ug") or (HIT_GUARD_SG[g] and "sg") or "unknown"
        end
        c.pb = ap_field(ap, "_IsParryBreak", true)
        return c
    end
    -- 该接 = 下面几条同时成立，哪一条读不准都按不该接（fail-closed）。和 v1.6 的 filter_reason(...) == nil 逐项等价（MERGE 2.7）。
    -- 弹体放在最后读：只对前面全部通过的条目读 ShellIndex，和 v1.6 对该接条目的读取顺序相同
    local function catchable(e)
        local c = classify(e)
        if not (c.dmg_ok and c.guard_ok) then return false end      -- 伤害类型或防御类型读不准
        if c.grab or c.effect ~= false then return false end        -- 抓取；效果攻击（true）；效果名缺、认不出（nil）
        if c.g ~= "white" then return false end                     -- SKILL_GUARD 家族、UNABLE_GUARD、未知值
        if c.pb ~= false then return false end                      -- _IsParryBreak 为真，或读不准
        return shell_of(e) == false                                 -- 是弹体，或读不准
    end

    -- 规则（V16 2.4）。每条 DANGER 条目：否决按原始 hs（读不到类型 → 不否决）；候选按 Q。否决只记有没有：放不放只看这一帧
    -- 有没有否决。否决侧对视野内每条 DANGER 条目都读 classify，见到一个否决也不提前停：读取的顺序和次数要和 v1.6 一样
    -- （否则出故障时报黄的时刻会变）
    local function consider(tr, list, ev)
        local L = ev.L
        for _, e in ipairs(list) do
            if e.rt == RT_DANGER then
                local hs, he = e.hs, e.he
                local w = he - hs
                local x0 = tr.x0[e.key]
                local Q = (tr.m and not tr.nofire and x0) and (hs - (tr.X - x0)) / tr.m or nil
                if hs <= VETO_HORIZON and he >= 0 then
                    local c = classify(e)
                    -- SKILL_GUARD 家族同抓取；两者都永远不进候选
                    if w > LONG_WINDOW or (c.dmg_ok and c.grab) or (c.guard_ok and c.g == "sg") then ev.veto = true end
                end
                -- catchable 在区间条件之后、比较 Q 之前：条目一落进窗口就做过滤读取（同 v1.6）
                if Q and tr.master and w >= 0 and w <= LONG_WINDOW and Q >= LEAD_MIN and Q <= L and catchable(e) then
                    if not ev.best or Q < ev.best.Q then ev.best = { tr = tr, e = e, Q = Q } end
                end
            end
        end
    end

    -- 每帧每条预告（V16 2.3 的顺序）：清理 → 读条目（每帧都读，不论在不在蓄力）→ 速度 → 打完了 → ev 非 nil 时参与规则求值
    local function process_track(tr, now, ev)
        local age, r = now - tr.t_msg, tr.obj
        if age >= TRACK_STALE then return "stale" end
        if r:call("get_IsAttackFinished") then return "finished" end
        local ok, list = pcall(read_items, r)
        if not ok then
            -- 逐条读取出错：本帧不放刀、不否决、不按 he 丢弃，速度照读；第一次标黄但不停用（停用就再也放不了刀）
            if not mod_off.items then note_error("items", list) end
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

    -- 清理全部跟踪；L 非 nil 时同时求值，返回 ev = { L, veto, best }。单条预告读坏了就丢掉它、计一次帧逻辑错误
    local function evaluate(now, L)
        local ev = L and { L = L } or nil
        for key, tr in pairs(tracks) do
            local ok, why = pcall(process_track, tr, now, ev)
            if not ok then note_error("frame", why) end
            if not ok or why then drop_track(key) end
        end
        return ev
    end

    -- 放刀 streak 与结局。写 FIRE / RES 的代码只读状态、不写状态：next_id、计数、res_wait 的记账都不看调试日志开没开，
    -- 调试日志开着和关着放刀完全一样（MERGE 2.7 B 类）
    local streak = nil          -- { id, t }：条件连续成立的帧合并为一次放刀
    local res_wait = nil        -- { id, t, to, entered }：等 CREDIT 秒内进 (2,25..27)
    local next_id = 1           -- 每次放刀都递增，FIRE 和 RES 靠它对上
    local function keep_text(r)
        local k = r:call("get_KeepActionID")
        return k and ("(" .. int_s(k:get_field("_Category")) .. "," .. int_s(k:get_field("_Index")) .. ")") or nil
    end
    local function keep_or_nil(r)   -- keep 只是 FIRE 的诊断字段：读不到写 -，不算错误
        local ok, k = pcall(keep_text, r)
        return ok and k or nil
    end
    local function finish_res(now, outcome)
        local w = res_wait
        res_wait = nil
        if outcome == "CATCH26" then stats.catch26 = stats.catch26 + 1
        elseif outcome == "CATCH27" then stats.catch27 = stats.catch27 + 1
        elseif outcome == "RECOIL" then stats.recoils = stats.recoils + 1
        else stats.nocatch = stats.nocatch + 1 end
        if config.debug_log then rec("RES", { w.id, now, outcome, now - w.t, w.to, w.entered }) end
    end
    local function start_streak(now, ev, idx)
        if res_wait then finish_res(now, "NOCATCH") end   -- 又回到蓄力了，上一刀不可能再接住
        streak = { id = next_id, t = now }
        next_id, stats.fires = next_id + 1, stats.fires + 1
        if config.debug_log then
            local b = ev.best
            local tr, e = b.tr, b.e
            rec("FIRE", { streak.id, now, ev.L, e.hs, e.he, e.key, addr_of(tr.obj), tr.em, keep_or_nil(tr.obj),
                "(" .. int_s(CAT_ATTACK) .. "," .. int_s(idx) .. ")", tr.c1, tr.cf, tr.m, tr.nchg, tr.X - tr.x0[e.key],
                tr.a0[e.key], b.Q })
        end
    end
    -- 每次放刀都有一行 RES（离线一一对应）：没放出去（entered = false）当场结算成 NOCATCH；放出去了等结局
    local function end_streak(now, entered)
        local s = streak
        streak = nil
        if res_wait then finish_res(now, "NOCATCH") end
        res_wait = { id = s.id, t = s.t, to = nil, entered = entered }
        if not entered then finish_res(now, "NOCATCH") end
    end

    local function update_fire(hunter, now, cat, idx)
        -- 请求被接受，下一帧就在 (2,23) 里了（实测都是下一帧）
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
        -- 前提：开关、大剑、基础层在 (2,21)/(2,22)；任一不满足就结束 streak（清理和速度照常做）
        local active = config.auto_parry and not err_state.stopped and me_gs
            and cat == CAT_ATTACK and PARRY_CHARGE[idx] == true
        local ev = evaluate(now, active and config.parry_lead or nil)
        if not active then
            if streak then end_streak(now, false) end
            return
        end
        if ev.best and not ev.veto then
            -- Q ≤ L 已在 consider 里保证；不设超时：Q 单调递减（m 变化那一帧跳一下），离开 [L_min, L] 自然停
            if not streak then start_streak(now, ev, idx) end
            request_slash(hunter)
        elseif streak then
            end_streak(now, false)
        end
    end

    local consec_err = 0
    local read_fail = { t0 = nil, t_last = nil }
    local function lose_hunter(now)    -- 主角为 nil 或换了（换场景等）：全部丢弃
        release_all_tracks()
        if streak then end_streak(now, false) end
        if res_wait then finish_res(now, "NOCATCH") end
        me_addr = nil
    end
    -- 读主角抛错时：容忍期内返回 false（这一帧跳过），超过容忍期返回 true（按帧逻辑出错处理）
    local function read_failed(now)
        local F = read_fail
        if not F.t0 or now - F.t_last > READ_FAIL_GAP then F.t0 = now end
        F.t_last = now
        return now - F.t0 >= READ_FAIL_TOL
    end

    -- 帧开头（快照之后、防御段之后）。rok = 读主角没抛错；rok 为 false 时 hunter 是错误信息
    local function parry_frame(now, rok, hunter, addr, gs, cat, idx)
        if not rok then
            if read_failed(now) then error(hunter, 0) end
            return      -- 容忍期内：这一帧不存在（不求值、不放刀，streak、跟踪和 E5c 的状态都保持原样）
        end
        if read_fail.t0 and now - read_fail.t_last > READ_FAIL_GAP then read_fail.t0 = nil end
        if not hunter then
            if me_addr or n_tracks > 0 then lose_hunter(now) end
            me_gs = false
            return
        end
        if me_addr and addr ~= me_addr then lose_hunter(now) end
        me_addr, me_gs = addr, gs
        if not config.auto_parry and n_tracks > 0 then release_all_tracks() end   -- 关开关时全部丢弃（菜单里只改配置）
        if next(speed_cache) ~= nil then speed_cache = {} end
        -- 主角在、动作 ID 暂时读不到（cat / idx 为 nil：切场景、加载的头几帧）：update_fire 里按「不在蓄力」处理，
        -- 不算帧逻辑出错（否则满 30 帧就自停）
        update_fire(hunter, now, cat, idx)
    end

    local function self_stop(now)
        err_state.stopped = true
        set_red(now, "frame", "self_stop")
        local ok, err = pcall(function()
            release_all_tracks()
            if streak then end_streak(now, false) end
            if res_wait then finish_res(now, "NOCATCH") end   -- 自停后帧逻辑不再跑、没人结算：每次放刀都要有结局
        end)
        if not ok then note_error("frame", err) end
    end

    parry_tick = function(now, rok, hunter, addr, gs, cat, idx)
        local ok, err = pcall(parry_frame, now, rok, hunter, addr, gs, cat, idx)
        consec_err = ok and 0 or consec_err + 1
        if not ok then note_error("frame", err) end
        if consec_err >= STOP_FRAMES then self_stop(now) end
    end

    -- Reset：丢弃预告跟踪（只删 Lua 引用，REF 回收 userdata 时自动扣引用，这里不手动扣），结算没结束的放刀和结局
    parry_reset = function(now)
        local ok, err = pcall(release_all_tracks)
        if not ok then note_error("frame", err) end
        ok, err = pcall(function()
            if streak then end_streak(now, false) end
            if res_wait then finish_res(now, "NOCATCH") end
        end)
        if not ok then note_error("frame", err) end
    end

    -- 类型、枚举、消息钩子。读的顺序同 v1.6；出错照 v1.6 分级（核心的拿不到就自停，防御照常）
    local function init_parry()
        local ok, err = pcall(function()
            RT_DANGER = enum_value("app.AttackAreaResult.RESULT_TYPE", "DANGER")
            SLASH_ID = make_action_id(CAT_ATTACK, IDX_SLASH)
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
        -- 效果名或白名单名缺任何一个：报黄 filter_enum，读不准的条目一律不放（缺效果名 = 不放刀了；缺 NORMAL = NORMAL 全不放）
        local missing = {}
        local e1 = names("app.HitDef.DAMAGE_TYPE", { "EAR", "WIND", "QUAKE" }, EFFECT_DAMAGE, missing)
        effect_partial = #missing > 0
        local e2 = names("app.Hit.GUARD_TYPE", { "NORMAL", "ALL_RANGE" }, HIT_GUARD_WHITE, missing)
        if #missing > 0 then
            filter_enum_missing = table.concat(missing, ",")
            note_error("filter_enum", filter_enum_missing .. " " .. tostring(e1 or e2))
        end
        -- 抓取名、黑名单名缺：只是少认一种抓取 / SG 否决（候选侧白名单已经排除），不报黄，记进 HDR 的 enum_skip
        local skipped, ug = {}, {}
        names("app.HitDef.DAMAGE_TYPE", { "CATCH", "CATCH_ZAKO", "CATCH_SLINGER" }, GRAB_DAMAGE, skipped)
        names("app.Hit.GUARD_TYPE", { "UNABLE_GUARD" }, ug, skipped)
        HIT_GUARD_UG = next(ug)
        names("app.Hit.GUARD_TYPE", { "SKILL_GUARD", "SKILL_GUARD_ALL_RANGE" }, HIT_GUARD_SG, skipped)
        if #skipped > 0 then enum_skip = table.concat(skipped, ",") end
        ok, err = pcall(function() T_ENEMY = sdk.typeof("app.EnemyCharacter") end)
        if not ok or not T_ENEMY then note_error("master", ok and "typeof app.EnemyCharacter = nil" or err) end
        ok, err = pcall(function()
            local td = sdk.find_type_definition("app.cMasterPlayerControllerEntity")
            sdk.hook(td:get_method("receiveGameMessage(ace.cGameMessage)"), timed("msg", function(args)
                local ok2, err2 = pcall(on_message, args)
                if not ok2 then note_error("msg", err2) end
            end), nil)
        end)
        if not ok then self_stop_init(err) end
    end

    local ok, err = pcall(init_parry)
    if not ok then self_stop_init(err) end

    -- 状态行。报黄但不停用读取的模块各有自己的措辞，不算「有可选模块停用，自动放刀照常」（那句只给 master、cfg、ui 等）
    local SOFT_MODS = { "items", "speed", "filter", "filter_enum" }
    local function draw_status()
        local E, p = err_state, {}
        local n_off = E.yellow
        for _, m in ipairs(SOFT_MODS) do if mod_off[m] then n_off = n_off - 1 end end
        p[#p + 1] = E.stopped and "已自停（帧逻辑连续出错）" or E.red and "核心模块出错"
            or n_off > 0 and ("有可选模块停用（黄 " .. int_s(n_off) .. "），自动放刀照常") or nil
        if mod_off.items then p[#p + 1] = "条目读取出过错：读不出条目的预告不放刀" end
        p[#p + 1] = spd.x5 and "速度读不到，已停止自动放刀" or spd.x5_ever and "速度曾读不到，已恢复" or nil
        if mod_off.filter then p[#p + 1] = "过滤字段读取出过错：读不准的条目不放刀" end
        if mod_off.filter_enum then
            p[#p + 1] = "过滤用的枚举读不到（缺 " .. tostring(filter_enum_missing) .. "）：这些攻击一律不放刀"
        end
        imgui.text("状态：" .. (#p > 0 and table.concat(p, "；") or "正常"))
        if E.red then imgui.text_colored("出错了：请把 re2_framework_log.txt 发给开发者，然后 Reset Scripts", COLOR_RED) end
    end

    local function draw_full()
        local changed, v = imgui.checkbox("自动放刀（实验）##ap_enabled", config.auto_parry)
        if changed then config.auto_parry = v == true end   -- 预告的丢弃、streak 的结束都在下一帧的帧逻辑里做
        imgui.text_colored("按住抵消蓄力时，危险攻击快到就自动放出抵消上捞斩；伤害、火花、弹开都是游戏原生的", COLOR_GRAY)
        draw_status()
        changed, v = imgui.slider_int("提前量（真实剩余帧，1/60 秒）##ap_lead", config.parry_lead, LEAD_LO, LEAD_HI)
        if changed and finite(v) then config.parry_lead = clamp_lead(v) end
        imgui.text_colored("已按怪物速度修正。越小越常出抵消动作；太小会被先打到。默认 " .. int_s(LEAD_DEFAULT), COLOR_GRAY)
    end

    draw_parry = function()   -- 出过错（ERR mod=ui）之后只画状态行和红字，同 v1.6 的简化菜单
        local ok2, err2 = pcall(mod_off.ui and draw_status or draw_full)
        if not ok2 then note_error("ui", err2) end
    end
end

-- ---------- §7 帧回调 ----------
-- 只有一个，顺序固定：PERF → 防御状态还原兜底 → 读主角快照 → 防御 → 放刀。每段各自 pcall，一段出错不影响另一段。
-- 先防御后放刀，和原来两个脚本时一样（REF 按文件名字母序加载，AutoGuardGS 的帧回调先跑，日志时间戳实测）
re.on_pre_application_entry("UpdateBehavior", timed("frame", function()
    local now = os.clock()
    local ok, err = pcall(prof_report)
    if not ok then guard_warn("perf", err) end
    -- 受击钩子打开的标志、改写的角度不许跨帧（结算后的还原万一没跑到，这里兜底）
    ok, err = pcall(restore_hit_state)
    if not ok then guard_warn("restore", err) end
    if not guard_ready and err_state.stopped then return end   -- 两部分都不工作了：不读主角
    local rok, hunter, addr, gs, cat, idx = pcall(read_hunter)
    if guard_ready then guard_tick(rok, hunter, gs, cat, idx) end
    if not err_state.stopped then parry_tick(now, rok, hunter, addr, gs, cat, idx) end
end))

-- ---------- §8 Reset 与存配置 ----------
-- Reset 依次做三件事，各自 pcall（一件出错不耽误后面的）：还原受击状态 → 还原无限蓄力 → 丢弃预告跟踪、结算放刀
re.on_script_reset(function()
    local ok, err = pcall(restore_hit_state)
    if not ok then guard_warn("reset", err) end
    ok, err = pcall(restore_overheat)
    if not ok then guard_warn("reset", err) end
    ok, err = pcall(parry_reset, os.clock())
    if not ok then note_error("frame", err) end
end)

-- 菜单改动立刻写进内存里的配置，什么时候落盘由 REF 触发
re.on_config_save(function()
    local ok, err = pcall(save_config)
    if not ok then note_error("cfg", err) end
end)

-- ---------- §9 菜单 ----------
-- "##" 后面是 imgui 的内部 ID，不显示；保证中文标签改了也不会和别的控件撞 ID（沿用两个旧脚本的 ID）。
-- 分块各自 pcall：防御的一块出错只把这一块换成一行提示，不连累别的块；放刀一节自己处理出错（§6 draw_parry）
local function draw_stats()
    imgui.text(string.format("自动防御：%d 次   自动肩撞：%d 次   本来就在防御：%d 次",
        stats.guarded, stats.tackled, stats.already_guarding))
    imgui.text(string.format("跳过：霸体 %d 次   不能举剑（翻滚、收刀、硬直等）%d 次", stats.skipped_armor, stats.skipped_state))
    imgui.text("自动放刀：放了 " .. int_s(stats.fires) .. " 刀   接住 " .. int_s(stats.catch26 + stats.catch27)
        .. " 刀（26：" .. int_s(stats.catch26) .. "，27：" .. int_s(stats.catch27) .. "）   被弹开 "
        .. int_s(stats.recoils) .. " 次   没接住 " .. int_s(stats.nocatch) .. " 次")
    if imgui.button("清零统计##reset_stats") then
        for k in pairs(stats) do stats[k] = 0 end
    end
    imgui.same_line()
    local changed, v = imgui.checkbox("调试日志##debug_log", config.debug_log)
    if changed then config.debug_log = v == true end
    if config.debug_log then
        imgui.text("性能（每秒）：" .. (prof_text ~= "" and prof_text or "统计中……"))
        imgui.text_colored("放刀记录写在 re2_framework_log.txt：[AutoParryGS] FIRE（放刀）、RES（结局）", COLOR_GRAY)
    end
end

-- 一块画出错后，UI_RETRY 秒内只画一行提示，之后再试：出错多半是瞬时的（切场景、读盘），永久降级就要 Reset 才能再看到
-- 防御的控件；隔几秒再试，一直出错也不至于每帧画一遍出错的代码、刷满警告（警告本来每类最多 20 行；审查修订）
local UI_RETRY = 2.0
local ui_bad = {}   -- [块名] = 出错的时刻
local function ui_part(name, fn)
    local t = ui_bad[name]
    if t and os.clock() - t < UI_RETRY then
        imgui.text("（菜单出错，见日志 re2_framework_log.txt）")
        return
    end
    ui_bad[name] = nil
    local ok, err = pcall(fn)
    if not ok then
        ui_bad[name] = os.clock()
        guard_warn("ui", err)
    end
end

local function draw_menu()
    if cfg_unreadable then
        imgui.text_colored("读不出配置文件 AutoGuardGS.json：这次用默认设置，改动也不保存（免得盖掉原文件）。Reset Scripts 重读",
            COLOR_RED)
    end
    ui_part("guard", draw_guard)
    imgui.separator()
    draw_parry()
    imgui.separator()
    ui_part("tests", draw_tests)
    imgui.separator()
    ui_part("stats", draw_stats)
end

re.on_draw_ui(function()
    local ok, opened = pcall(imgui.tree_node, "大剑自动防御 " .. VERSION .. "##AutoGuardGS")
    if not ok then
        guard_warn("ui", opened)
        return
    end
    if not opened then return end
    local ok2, err = pcall(draw_menu)
    if not ok2 then guard_warn("ui", err) end
    imgui.tree_pop()        -- 出错也要配对 tree_pop
end)

-- ---------- §10 加载完成 ----------
log.info(TAG .. VERSION .. " loaded")
-- 加载期间攒下的 [AutoParryGS] 行（初始化出错的 ERR / RED）现在写；调试日志开着、或者有攒下的行时先写 HDR
do
    local pending = rec_pending
    rec_pending = nil
    if config.debug_log or #pending > 0 then write_hdr() end
    for _, line in ipairs(pending) do log.info(line) end
end
