-- AutoParryCalib（APCal）：大剑自动放刀第 1 轮标定 —— 测量探针
--
-- 【只记录，不修改游戏】
--   只读游戏数据，只写日志（[APCal] 开头）和 reframework/data/APCal_<会话>_<序号>.json。
--   不调用任何有副作用的游戏方法：不请求动作、不写字段、不伪造或重放命中。
--   放刀和机关扫描都在 AutoParryGS.lua（rc）里；两个脚本互相看不见，离线按 os.clock() 的 t 对齐。
--
-- 依据：docs/autoparry/PLAN.md 的 PROBE SPEC P01~P18、P21、P22；接口约定 docs/autoparry/CONTRACT.md
--   （两者冲突以 CONTRACT 为准）。记录种类和字段顺序见 CONTRACT 4.2。
--
-- 和 CONTRACT 4.2 表格的差异（离线按 key=value 解析，多出来的键可以忽略）：
--   · JSON 里 CT 的「本帧第几次」k 改名 kn（JSON 的 k 已经是记录种类；和 tools/apcal_analyze.py 的
--     FIELD_RENAME 一致）；日志行里仍写 k=。
--   · 表格字段之后追加了几项（PLAN 要求记录、但 4.2 表里没列）：
--       MSG  snd   发送者 GameObject 名（PLAN P04：get_SendGameObject 是否怪物本体待核实）；
--            snd_em 发送者身上 EnemyCharacter 的地址（P23「攻击者相同」的首选键，和 CT 的 atk_em 直接比）
--       PERF hook_ms_ps（钩子体每秒耗时）、actfail（读主角抛错、容忍期内跳过的帧）、red_state（是否已红）
--       TYP  why   add / type / jump / del        SER  fb=1：逐条读取失败，退回 closest
--       ENT  ap    AttackParam 地址（离线对 EMPARRY 的 ap，PLAN 离线 5）；obb 中心/半长
--       CT   em    攻击者 em<EmID>#<SystemIndex>（和 MSG/EP 的 em 对齐，P23 匹配用）；chara
--       DMG  em        POSE em        EMINFO comp（get_MotionSpeed_* 各分量，PLAN P13）
--       PT   t_end、end（leave/timeout/lost/stop/reset）、swing（空挥样本）、gdeg（PT 首帧的 _GuardDegree，
--            PLAN 安全-1：确认 v1.4.1 在抵消动作里不改防御角度）
--       EP   end（结束原因：fin / he / stale，或被下一回合切开的 keep / msg / jump / reuse，
--            或 evict / lost / stop / reset / error）、hold（对象在 holder 列表里出现的比例，P16）、
--            pts（回合内开始的 PT 编号）、snd / snd_em（同 MSG）。reason（表内字段）= new / keep / msg / jump / reuse
--       HDR  det   mcEnemyAttackAreaDetector 的 PLAYER_RADIUS,PLAYER_HEIGHT,DETECT_DISTANCE_SQ（P01）
--       HITCH/GAP gdt（via.Application.get_DeltaTime，P02 可选）
--       PERF logdrop、buf、files
--   · 另有两种表里没有的记录：STOP / RESUME（t why），标出「停止记录」的区间，离线可以忽略。
--   · RED（t mod why）：进入红状态时写一行（CONTRACT 2.1；离线只把它算关键错误）。
--   · POSE when=FIRE：PT 首帧对每只有未结束 DANGER 回合的怪各写一条（带 em），不再只写一条。
--   · JSON 文件头多一个 why（idle / valve / hard / button / stop / reset）：离线据此判断这一轮有没有正常收尾。
--   · 上捞斩砍中怪物（EMHIT）后这只怪再盯 1.5 s 动作写 EMSTATE：被打断的那一招常在同一帧结束，回合关了也要记受击动作。
--   · EP 的 rate_med/min/max 单位是「帧/秒」（−Δhs/Δt，名义值 60）。
--   · 动作统一写成 (c,i)，和 rc 的 FIRE 一致。
--   · 探针看不到 rc 的请求：EMINFO/POSE 的 when=FIRE 指「PT 首帧」（比 rc 请求晚 1 帧）。
--   · PT 不判断起因（auto/scan/manual）：离线按 t 和 rc 的 FIRE/FIRE_END/SCAN 关联（PLAN P08）。
--   · 日志预算平均 ≤5 行/秒（PLAN「性能与日志预算」）：普通记录走令牌桶（2.5 行/秒，容量 30，从空开始），
--     超出时只进 JSON，PERF 报 logdrop；SIG 只在桶里还剩一半以上时写日志；
--     总是写日志：HDR/SELFTEST/ERR/PERF/PROG/PT/GAP、有条目的 EP、进出 (2,21)~(2,29) 的 ACT、
--     每帧每个攻击者每种分类的第一个 CT（JSON 丢了时离线靠这些兜底）；SER/ANIM/HOLD 只进 JSON。
--   · JSON 里值为 nil 的字段：字符串、地址写 "-"；数值不写这个键（REF 的 json 写不出 null）。
--     ERR：JSON 立刻记；日志只写前 20 条，排队按 1 行/秒写出（加载自检可能同一时刻报好几个模块）。
--   · PT 的 hit_t、t_obs、t_start、t_end 都是 os.clock() 绝对时刻；hold = t_start − 进入抵消蓄力的时刻。
--   · PROG 的 phase：A1 空挥（<3 次）/ A2（空挥已满、还没见过 DANGER，即机关段）/ B（见过第一个 DANGER 之后）。
--     空挥样本 = 没有敌方接触、没有砍中、没有抵消事件、(2,23) 停 ≥3 s、已知怪物都在 10 m 外。
--   · HUD 在屏幕左上角 (12, 12)，一行；rc 的 HUD 要避开这一行。
--   · 文件末尾 return 了几个纯计算函数（回合切分、在线粗分类、θ 等）给 mock 测；REF 忽略这个返回值。
--
-- 模块与级别（CONTRACT 2.1、4.1）：
--   核心 HDR CLOCK MSG SERIES ACT PT CT DMG PH(含 PS) EMHIT EP JSON MENU FMT
--     10 s 内出错 ≥3 次 → 红，HUD 显示「停下发日志」；加载自检缺核心项也直接标红。
--   可选（第一次出错就停用该模块、标黄，测量继续）：
--     ENT ITEM NULL AP OBB CHARA LV SND PMSG EMPARRY EMID EMSTATE TGT SPD MASTER FIND ATK SIG CONT ANIM
--     HOLD POSE SHELL CTPOS PHDELAY GDT HDRX HUD HUDWIN
--   CONTRACT 1.2 里「TDB 有、Lua 没用过」的接口都放在可选模块里，读不到写 -。
--
-- 跨帧持有与 REF 的引用记账（1.1 起；docs/NOTES.md「跨帧持有与 REF 的引用记账」，REF 源码 Sdk.cpp 核对过）：
--   · 对象交给 Lua 时 REF 自动 add_ref 一份、按地址全状态（所有 autorun 脚本共用一个 Lua 状态）只记一份；脚本自己
--     add_ref() 在这一份已经在时是空操作；release() 扣的就是这共用的一份；userdata 被回收时 REF 还会自动 release 一次。
--   · 所以和放刀模块同时持有同一个预告结果时，谁先手动 release 谁就扣掉了唯一的游戏侧引用，另一个脚本手里的就成了
--     悬空指针（2c 实测：本探针 1.0.1 关闭回合 release 之后 15 ms，放刀模块帧逻辑报 caught (...) exception）。
--   · 改法：跨帧持有的对象（预告结果 S.trk[*].obj、findEnemy 不可用时退路缓存的怪物 S.ems[*].ref）只 add_ref、
--     不手动 release；丢弃时只删 Lua 引用，让 userdata 回收时 REF 自动 release。add_ref 保留：对局部对象（游戏引用数
--     ≤ 0、REF 推入时没加引用）它才真正加一份，防万一。全文件不再有任何 release 调用。
--   · 部署约束：B 阶段 v1.6 必须和本版（≥ 1.1）一起跑；v1.5.1 开着开关时和本版同跑，同样会重现 2c 的悬空指针
--     （docs/autoparry/V16.md 第 5.4 节）。记录格式不变，分析脚本照旧解析。
--
-- 实测依据（只列和本探针取舍有关的）：
--   · 消息里的 AttackAreaResult 被怪物复用，跨帧持有要 add_ref（v1.3、AGWarn 实测长时间稳定）。
--   · onParryHitPreProcess 每秒 6~18 万次，钩它会掉到约 22 fps —— 本探针不钩它。
--   · HitStartRemainFrame / HitEndRemainFrame 返回 System.Single，几乎总带小数：
--     一律 %.Nf 格式化（旧探针 AutoParryPredictProbe 第 119 行用 %d 抛错，已作废）。
--   · 抵消成功的同一帧可以同时有身体 ATTACK_GET 接触（日志 16:12:47.045）：CT 每次都记，结局离线互斥分类。

local TAG = "[APCal] "
local VERSION = "apcal-1.1"     -- 1.0.1：activateAttack 频率守卫只数激活调用（见 K.ATK_LIMIT）；
                                -- 1.1：引用记账只 add_ref、不手动 release（见头注释「跨帧持有与 REF 的引用记账」；
                                -- 版本号按 V16 第 5.3 节，离线分析 1.4 对 v1.6 的 session 要求探针 ≥ apcal-1.1）

-- ========================================================================
-- 常量
-- ========================================================================
local K = {
    HITCH_DT = 0.035,       -- 卡顿阈值（PLAN P02；rc 扫描作废规则也按 0.035 判断）
    GAP_DT = 0.1,
    PERF_PERIOD = 5.0,
    PROG_PERIOD = 30.0,
    FPS_BASE_WIN = 10.0,    -- 加载后前 10 s 的 fps 中位数作基线
    FPS_DROP = 0.10,        -- 之后下降超过 10% 在 HUD 提示
    TRACK_MAX = 32,         -- 跟踪上限，满了丢最旧的（PLAN 参数表「预告跟踪与释放」）
    TRACK_STALE = 8.0,      -- 距最后一条消息 8 s 释放（覆盖实测最长 402 帧≈6.7 s 的预告）
    RELEASE_HE = -30,       -- 全部条目 he < -30 ……
    RELEASE_MSG = 1.0,      -- …… 且距最后一条消息 ≥1 s 才释放
    DENSE_HS = 90,          -- 本结果最小 hs ≤90 时每帧存一格 SER，否则每 4 帧（P05）
    SPARSE_EVERY = 4,
    TYP_JUMP = 2,           -- hs 比上一格回跳 >2 帧写 TYP
    EPOCH_JUMP = 10,        -- hs 回跳 >10 帧开新回合（P18）
    RATE_WIN = 0.1,         -- 倒数速率统计窗口 ≥0.1 s
    ENT_MAX = 16,           -- 每个回合最多写 16 行 ENT（防止条目对象被重建时刷屏）
    TYP_MAX = 40,           -- 每个回合 TYP 最多 40 行进日志，之后只进 JSON
    PT_MAX = 4.0,           -- PT 汇总最长 4 s（收尾挨打统计到离开 (2,23)，最长 4 s）
    CREDIT = 1.3,           -- 结局判定常数（PLAN 参数表）
    SWING_MIN = 3.0,        -- 空挥：(2,23) 停 ≥3 s（不撞上会停到玩家有输入为止，复核约 3.4~3.8 s）
    SWING_DIST = 10.0,
    W0_HUD = 0.33,          -- 只给 HUD 在线粗分类用；正式窗口离线按 C1 求
    W1_HUD = 0.80,
    ARM_AFTER = 1.5,        -- 霸体：抵消动作族期间及离开后 1.5 s（P07）
    SIG_AFTER = 0.5,        -- 窗口信号：抵消动作族期间及离开后 0.5 s（P15）
    RECENT_KEEP = 1.5,      -- 钩子事件保留多久，PT 开始时补收「动作刚切换那一帧」的事件
    HOLD_EVERY = 5,         -- holder 每 5 帧读一次（P16）
    -- activateAttack 的「激活」调用（第 1 个参数为 true）连续 3 个统计周期 >3000 次/秒 → 钩子第一行直接 return。
    -- 1.0.1 起只数激活调用：关闭判定的调用每个碰撞体每帧都有，第一行判一位就返回、几乎没有开销，
    -- 以前连它一起数，小怪多的场景（2b、2c，em39/em40）打 10~20 分钟就触发守卫，之后整段没有 ATK 记录
    ATK_LIMIT = 3000,
    ATK_PERIODS = 3,
    JSON_IDLE = 60.0,       -- 空闲帧写 JSON，两次间隔 ≥60 s（P21）
    JSON_SEQ_MAX = 300,
    JSON_VALVE = 60000,     -- 安全阀：缓冲超过这么多条时不等空闲帧，但仍要求没有 PT、不在 (2,23)~(2,29)、
                            -- 没有未结束回合（可以在蓄力中写）：几 MB 的 JSON 可能卡 0.1~0.3 s，不能压在判定时机上
    JSON_HARD = 150000,     -- 硬上限：到这里才无条件写（内存仍只有几十 MB）
    JSON_VALVE_RETRY = 10.0,
    BACKOFF_FRAMES = 30,    -- 核心模块连续 30 帧每帧出错 → 暂停该模块 1 s（红照旧）：这版 REF 每截住一次访问冲突
    BACKOFF_PAUSE = 1.0,    -- 要往日志写 60 多行寄存器转储（日志 16:09:37.903），每帧都撞会刷屏卡帧
    ACT_FAIL_TOL = 1.5,     -- 取主角/动作 ID 抛错的容忍期：1.5 s 内这一帧沿用上一帧的状态，超过才算 ACT 核心错误
    ACT_FAIL_GAP = 0.5,     -- 间隔不到 0.5 s 的零星失败算同一段（隔帧失败的间歇故障照样会升级）
    EM_WATCH = 1.5,         -- 上捞斩砍中怪物后，这只怪再盯 1.5 s 动作（被打断那一招的回合常在同一帧就结束）
    FPS_GAP_RESET = 1.0,    -- 一帧超过 1 s（读盘、切场景）后 fps 基线重新取
    AUTO_STOP = 5400,       -- 加载 90 分钟后自停记录（P22）
    ERR_LOG_MAX = 20,       -- 前 20 条错误写日志，限频 1 行/秒（CONTRACT 2.1）
    ERR_JSON_MAX = 500,
    RED_N = 3,              -- 核心模块 10 s 内出错 ≥3 次 → 红
    RED_WIN = 10.0,
    LOG_RATE = 2.5,         -- 日志令牌桶：普通记录平均 ≤2.5 行/秒，加上总写的 PT/EP/抵消族 ACT/首个 CT 等，合计 ≤5 行/秒
    LOG_BURST = 30,         -- 桶容量；加载时桶是空的（开头的突发不计入平均预算）
    EM_CACHE_AGE = 30.0,    -- EnemyCharacter 地址 → em 编号缓存的有效期（地址可能被新对象复用）
    EM_REF_STALE = 60.0,    -- 退路缓存的怪物对象多久没再见到就丢掉（只删 Lua 引用）
    B_PT = 45, B_CONTACT = 20, B_DANGER = 60, SWINGS = 3,
    HUD_X = 12, HUD_Y = 12,
}

local CHARGE = { [21] = true, [22] = true }     -- (2,21) cIdleToParryCharge / (2,22) cParryCharge
local SLASH = { [23] = true, [24] = true }      -- (2,23) cParrySlash / (2,24) 前进版
local HITACT = { [25] = true, [26] = true, [27] = true }   -- cParrySlashHitS/M/L

-- ========================================================================
-- 状态
-- ========================================================================
local S = {
    session = os.time(),
    t_load = os.clock(),
    now = os.clock(),
    f = 0, t_prev = nil, dt = 0,
    rec = true, rec_t0 = os.clock(), auto_stopped = false,
    -- 错误
    red = false, n_red = 0, n_yellow = 0, err_logged = 0, err_log_t = -100, err_json = 0, err_list = {},
    err_queue = {},
    in_err = false, st1 = nil, st1_core_fail = false, st2 = nil,
    -- 日志预算（令牌桶从空开始）
    bucket = 0, log_drop = 0,
    -- JSON
    jbuf = {}, seq = 0, last_write_t = os.clock(), files = 0, last_file = "-", valve_t = -100, seq_full = false,
    -- 主角：只缓存地址和数值，不跨帧持有对象；S.hunter 只在本帧回调里有效
    hc = {}, cur = { ok = false }, hunter = nil,
    -- 预告跟踪
    trk = {}, n_trk = 0, ep_id = 0,
    ems = {},               -- [SystemIndex] = { key, ref（findEnemy 不可用时的退路，add_ref、不 release）, t_ref, act_addr, act }
    em_by_addr = {},        -- EnemyCharacter 地址 → { key, idx, t }
    atk_cache = {}, atk_cache_t = 0,
    -- 放刀尝试
    pt = nil, pt_id = 0, recent = {}, charge_t0 = nil, charge_lv = nil,
    -- 进度
    phase_b = false, b_t0 = nil, swings = 0, scan_pt = 0, b_pt = 0, b_contact = 0, b_danger = 0,
    last_class = nil, prog_sig = nil, prog_t = -100,
    -- 每帧
    ct_k = 0, ct_first = {}, ct_logged = {}, snap_f = -1, fam_until = -100, sig_until = -100,
    arm = nil, sig_prev = nil, hold_sig = nil, hold_present = nil,
    -- 性能（hook_ms：钩子体累计耗时，PERF 换算成每秒毫秒数）
    perf = { t0 = os.clock(), frames = 0, maxdt = 0, lua_sum = 0, lua_n = 0, lua_max = 0, hook_ms = 0, actfail = 0 },
    -- fps 基线（只给 HUD 提示用）：每次换场景（主角对象变化、一帧超过 1 s）后重新取前 10 s 的中位数，
    -- 训练场和野外的 fps 本来就差一倍（AutoGuardGS PERF 实测 147~163 / 约 80），不能跨场景比
    fpsb = { t0 = os.clock(), sec_t = os.clock(), n = 0, samples = {}, base = nil, done = false },
    actfail = { t0 = nil, t_last = nil },
    snd_cache = {},         -- 发送者 GameObject 地址 → EnemyCharacter 地址（"-" = 不是怪），30 s 清一次
    fps_warn = nil, perf_text = "统计中", atk_hi = 0, atk_guard = false,
    atk_act = 0,            -- 本统计周期内 activateAttack 激活调用次数（频率守卫只看它；HN.atk 仍是原始调用次数）
    hud_mode = 1,
}

-- 各钩子调用次数（PERF 用 —— 钩子分发开销用 os.clock 量不出来，只能看次数和 fps）
local HN = { msg = 0, ct = 0, shell = 0, dmg = 0, ph = 0, ps = 0, emhit = 0, emparry = 0, atk = 0 }
local HN_ORDER = { "msg", "ct", "shell", "dmg", "ph", "ps", "emhit", "emparry", "atk" }

-- activateAttack 自停开关：钩子第一行就判断它（频率守卫、模块停用、停止记录时为 true）
local atk_off = false

-- 模块表
local MODS = {}
local CORE_MODS = { "HDR", "CLOCK", "MSG", "SERIES", "ACT", "PT", "CT", "DMG", "PH", "EMHIT", "EP", "JSON",
    "MENU", "FMT" }
local OPT_MODS = { "HDRX", "ENT", "ITEM", "NULL", "AP", "OBB", "CHARA", "LV", "SND", "PMSG", "EMPARRY", "EMID",
    "EMSTATE", "TGT", "SPD", "MASTER", "FIND", "ATK", "SIG", "CONT", "ANIM", "HOLD", "POSE", "SHELL", "CTPOS",
    "PHDELAY", "GDT", "HUD", "HUDWIN" }
for _, n in ipairs(CORE_MODS) do MODS[n] = { core = true, on = true, n = 0, errs = {} } end
for _, n in ipairs(OPT_MODS) do MODS[n] = { core = false, on = true, n = 0, errs = {} } end

-- ========================================================================
-- 格式化、记录、错误
-- ========================================================================
local FFMT = { t4 = "%.4f", f1 = "%.1f", f2 = "%.2f", f3 = "%.3f", f4 = "%.4f" }
local M_FORCE, M_JSON = 1, 2
-- 总是写日志的种类（低频、离线必须）；只进 JSON 的种类（高频连续量）；
-- 低优先级种类（SIG 翻转可能很密）只在令牌桶还剩一半以上时写日志，把预算留给 MSG/CT/EP 这些
local LOG_FORCE = { HDR = true, SELFTEST = true, ERR = true, PERF = true, PROG = true, PT = true, GAP = true }
local JSON_ONLY = { SER = true, ANIM = true, HOLD = true }
local LOG_LOW = { SIG = true }

local report_error   -- 前置声明：safe_fmt 失败时要计错误

-- 所有格式化都走这里：Lua 5.4 里 %d 遇到带小数的数会抛错，失败时输出 FMT_ERR 并计错误（CONTRACT 1）
local function safe_fmt(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    if ok then return s end
    if report_error then report_error("FMT", "format " .. tostring(fmt) .. ": " .. tostring(s)) end
    return "FMT_ERR_" .. tostring(fmt)
end

-- 日志值里不能有空格；非 ASCII 字节换成 ?（游戏字符串截断后可能是坏 UTF-8，JSON 会写不进去）
local function clean(v)
    local s = tostring(v)
    s = s:gsub("%s", "_")
    s = s:gsub("[\128-\255]", "?")
    return s
end

-- 一个字段的日志文本和 JSON 值。kd：s 字符串 / b 布尔 1/0 / i 整数 / x 地址十六进制 / t4 f1~f4 浮点
-- nil：日志写 -；JSON 里字符串和地址字段也写 "-"（REF 的 json 写不出 null，键干脆缺失又容易让离线读错），
-- 数值字段不写这个键（离线按 null 处理）
local function fmt_value(v, kd)
    if v == nil then
        if kd == "s" or kd == "x" then return "-", "-" end
        return "-", nil
    end
    local tv = type(v)
    if kd == "b" then
        local b = (v == true) or (tv == "number" and v ~= 0)
        return b and "1" or "0", b and 1 or 0
    end
    if kd == "s" or tv ~= "number" then
        local s = clean(v)
        return s, s
    end
    if v ~= v or v == math.huge or v == -math.huge then return "-", nil end   -- NaN / inf → null
    if kd == "x" then
        local iv = math.tointeger(v)
        if not iv then return "-", nil end
        local s = safe_fmt("%X", iv)
        return s, s
    end
    if kd == "i" then
        local iv = math.tointeger(v) or math.tointeger(math.floor(v + 0.5))
        if not iv then
            local s = safe_fmt("%.0f", v)
            return s, tonumber(s)
        end
        return safe_fmt("%d", iv), iv
    end
    local s = safe_fmt(FFMT[kd] or "%.4f", v)
    return s, tonumber(s)
end

-- 公共记录机制（CONTRACT 2）：emit(种类, 事件时刻, 名, 值, 格式, 名, 值, 格式, ...)
-- 日志：[APCal] KIND k1=v1 k2=v2 ...；JSON：{ k = KIND, t = ..., 字段... }（nil / NaN 的字段不写 = null）
local function emit_core(kind, t, mode, ...)
    local a = table.pack(...)
    local do_log
    if mode == M_JSON or JSON_ONLY[kind] then
        do_log = false
    elseif mode == M_FORCE or LOG_FORCE[kind] then
        do_log = true
    elseif S.bucket >= (LOG_LOW[kind] and K.LOG_BURST / 2 or 1) then
        S.bucket = S.bucket - 1
        do_log = true
    else
        S.log_drop = S.log_drop + 1
        do_log = false
    end
    local parts = do_log and { TAG, kind } or nil
    local rec = { k = kind }
    for i = 1, a.n, 3 do
        local name = a[i]
        local s, jv = fmt_value(a[i + 1], a[i + 2])
        if parts then parts[#parts + 1] = " " .. name .. "=" .. s end
        if jv ~= nil then
            if name == "k" then name = "kn" end
            rec[name] = jv
        end
    end
    if rec.t == nil then rec.t = tonumber(safe_fmt("%.4f", t or os.clock())) end
    if parts then log.info(table.concat(parts)) end
    local buf = S.jbuf
    buf[#buf + 1] = rec
end

local function emit(kind, t, ...)
    return emit_core(kind, t, nil, ...)
end

-- 排队的 ERR 日志行：每秒最多写 1 行（CONTRACT 2.1 限频）
local function err_flush(now)
    if #S.err_queue > 0 and now - S.err_log_t >= 1.0 then
        log.info(table.remove(S.err_queue, 1))
        S.err_logged = S.err_logged + 1
        S.err_log_t = now
    end
end

-- 进入「红」状态时写一行 RED（只写一次，总写日志）。离线只把 RED 算「关键错误」（C9(d)、C10），
-- 和 HUD 标红、用户按协议停下的口径一致；零星的核心模块错误（没到红）单列报告
local function set_red(modname, why)
    if S.red then return end
    S.red = true
    local now = os.clock()
    emit_core("RED", now, M_FORCE, "t", now, "t4", "mod", modname, "s", "why", why, "s")
end

-- 核心模块是否在退避暂停中（连续 30 帧出错后停 1 s；红照旧）
local function paused(m)
    return m.pause_until ~= nil and S.now < m.pause_until
end

-- 错误分级（CONTRACT 2.1）：核心 10 s 内 ≥3 次 → 红；可选第一次出错 → 停用该模块、标黄
report_error = function(modname, err)
    if S.in_err then return end
    S.in_err = true
    local m = MODS[modname] or MODS.HDR
    local now = os.clock()
    local msg = clean(err):sub(1, 180)
    m.n = m.n + 1
    local level
    if m.core then
        level = "red"
        S.n_red = S.n_red + 1
        local keep = {}
        for _, t in ipairs(m.errs) do
            if now - t <= K.RED_WIN then keep[#keep + 1] = t end
        end
        keep[#keep + 1] = now
        m.errs = keep
        if #keep >= K.RED_N then set_red(modname, "3in10s") end
        -- 退避：同一模块连续 BACKOFF_FRAMES 帧都出错 → 暂停 1 s（每帧照调会每帧撞同一个异常）
        if m.err_f ~= S.f then
            m.err_run = (m.err_f == S.f - 1) and ((m.err_run or 0) + 1) or 1
            m.err_f = S.f
            if m.err_run >= K.BACKOFF_FRAMES then
                m.pause_until = now + K.BACKOFF_PAUSE
                m.err_run = 0
                m.n_pause = (m.n_pause or 0) + 1
            end
        end
    else
        level = "yellow"
        if m.on then S.n_yellow = S.n_yellow + 1 end
        m.on = false
        if modname == "ATK" then atk_off = true end
    end
    table.insert(S.err_list, 1, safe_fmt("%.1f %s %s %s", now - S.t_load, modname, level, msg))
    if #S.err_list > 12 then table.remove(S.err_list) end
    -- JSON 立刻记（上限 500 条）；日志只写前 20 条，排队按 1 行/秒写出（加载自检可能同时报好几个模块）
    if S.err_json < K.ERR_JSON_MAX then
        S.err_json = S.err_json + 1
        emit_core("ERR", now, M_JSON, "mod", modname, "s", "level", level, "s", "msg", msg, "s")
    end
    if S.err_logged + #S.err_queue < K.ERR_LOG_MAX then
        S.err_queue[#S.err_queue + 1] = TAG .. "ERR mod=" .. modname .. " level=" .. level .. " msg=" .. msg
    end
    S.in_err = false
    err_flush(now)
end

-- 每个模块独立 pcall，出错按模块分级
local function run(modname, fn, ...)
    local m = MODS[modname]
    if not m.on or paused(m) then return false end
    local ok, err = pcall(fn, ...)
    if not ok then report_error(modname, err) end
    return ok
end

-- 可选读取：返回读到的值（最多 4 个）；出错时停用该模块并返回 nil
local function opt(modname, fn, ...)
    if not MODS[modname].on then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
    report_error(modname, a)
    return nil
end

-- ========================================================================
-- 纯计算（不碰 sdk，mock 里可以直接测；文件末尾 return 出去）
-- ========================================================================
local function median(list)
    local n = #list
    if n == 0 then return nil end
    local tmp = {}
    for i = 1, n do tmp[i] = list[i] end
    table.sort(tmp)
    if n % 2 == 1 then return tmp[(n + 1) // 2] end
    return (tmp[n // 2] + tmp[n // 2 + 1]) / 2
end

local function min_max(list)
    local mn, mx = nil, nil
    for _, v in ipairs(list) do
        if mn == nil or v < mn then mn = v end
        if mx == nil or v > mx then mx = v end
    end
    return mn, mx
end

-- 回合切分（P18）。回合 =（结果对象, epoch）。返回开新回合的原因，nil = 不开新回合。
--   first      对象刚登记（第一条消息）
--   open       当前有没有打开的回合；ep_keep / ep_minhs 是它的 KeepActionID 和最小 hs
--   new_msg    上一帧以来同一对象又收到消息；max_jump 本帧各条目 hs 的最大回跳量；active 有条目 he ≥ -30
local function epoch_split(first, open, ep_keep, ep_minhs, keep, new_msg, max_jump, active)
    if first then return "new" end
    if not open then
        if new_msg then return "msg" end
        if active then return "reuse" end   -- 回合已结束、没有新消息，但条目又活了：对象被复用
        return nil
    end
    if keep ~= ep_keep then return "keep" end                                  -- KeepActionID 变了
    if new_msg and ep_minhs ~= nil and ep_minhs <= 0 then return "msg" end     -- 新消息且本回合 hs 已 ≤0
    if max_jump > K.EPOCH_JUMP then return "jump" end                          -- hs 回跳 >10 帧
    return nil
end

-- 回合结束（P18）：IsAttackFinished / 全部条目 he < -30 / 距最后一条消息超过 8 s
local function epoch_end(fin, n_ent, all_below, since_msg)
    if fin then return "fin" end
    if n_ent > 0 and all_below then return "he" end
    if since_msg > K.TRACK_STALE then return "stale" end
    return nil
end

-- 在线结局粗分类（只给 HUD；正式分类离线按 DECISION RULE B 节做，时刻按 t_req）。
-- 这里没有 t_req，用 t_start 代替；W0/W1 用粗值。p = { t_start, catch_t, recoil, contacts = {{t=}...},
-- ph_n, late_body }
local function classify_pt(p, w0, w1, credit)
    if p.catch_t and p.catch_t - p.t_start <= credit then return "CATCH" end
    if p.recoil then return "RECOIL" end
    local c_first = nil
    for _, c in ipairs(p.contacts or {}) do
        local rel = c.t - p.t_start
        if c_first == nil or rel < c_first then c_first = rel end
    end
    if c_first and c_first < w0 then return "FAIL_EARLY" end
    if (c_first and c_first > w1) or p.late_body then return "FAIL_LATE" end
    if c_first or (p.ph_n or 0) > 0 then return "FAIL_OTHER" end
    return "WHIFF"
end

-- 水平来向角 θ（度）和距离（P17）：f = 主角 AxisZ 水平分量，v = 怪物 − 主角
-- θ = atan(f.x·v.z − f.z·v.x, f.x·v.x + f.z·v.z)；正负号离线用接触点角度分布核实
local function calc_theta(fx, fz, vx, vz)
    local cross = fx * vz - fz * vx
    local dot = fx * vx + fz * vz
    return math.deg(math.atan(cross, dot)), math.sqrt(vx * vx + vz * vz)
end

-- 配置表转成紧凑 JSON 字符串（HDR 用；不依赖 json.dump_string）
local function mini_json(v, depth)
    depth = depth or 0
    local tv = type(v)
    if tv == "nil" then return "null" end
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if math.type(v) == "integer" then return tostring(v) end
        return safe_fmt("%.4g", v)
    end
    if tv == "string" then return '"' .. clean(v):gsub('[%c"\\]', "_") .. '"' end
    if tv ~= "table" or depth > 4 then return '"?"' end
    local n = #v
    local is_arr = n > 0
    for k in pairs(v) do
        if math.type(k) ~= "integer" then is_arr = false break end
    end
    local parts = {}
    if is_arr then
        for i = 1, n do parts[i] = mini_json(v[i], depth + 1) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = { k = k, s = tostring(k) } end
    table.sort(keys, function(x, y) return x.s < y.s end)
    for i, e in ipairs(keys) do
        parts[i] = '"' .. clean(e.s) .. '":' .. mini_json(v[e.k], depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- ========================================================================
-- 枚举（遍历静态字段，AGPCall 实测写法）
-- ========================================================================
local E = {}
local ENUM_TYPES = {
    RT = "app.AttackAreaResult.RESULT_TYPE",
    PS = "app.HunterDef.PARRY_STATE",
    LAYER = "app.CollisionFilter.LAYER",
    HR = "app.Hit.RESULT",
    TAK = "app.TARGET_ACCESS_KEY.CATEGORY",
    DT = "app.HitDef.DAMAGE_TYPE",
    SF = "app.HunterDef.STATUS_FLAG",
    GT = "app.Hit.GUARD_TYPE",
    NP = "app.PlayerDef.NETWORK_POSITION",
    TO = "app.cEmModuleTarget.TARGET_ORDER",
    CF = "app.HunterDef.CONTINUE_FLAG",
    GR = "app.HunterDef.GUARD_REACTION",
    CL = "app.Wp00Def.CHARGE_LEVEL",
}

local function enum_load(key, type_name)
    local names, values = {}, {}
    local td = sdk.find_type_definition(type_name)
    if td then
        for _, fld in ipairs(td:get_fields()) do
            if fld:is_static() then
                local ok, v = pcall(fld.get_data, fld, nil)
                if ok and type(v) == "number" then
                    local nm = fld:get_name()
                    names[v] = nm
                    values[nm] = v
                end
            end
        end
    end
    E[key] = { n = names, v = values, ok = td ~= nil }
end

for key, tn in pairs(ENUM_TYPES) do
    local ok = pcall(enum_load, key, tn)
    if not ok then E[key] = { n = {}, v = {}, ok = false } end   -- 缺失由加载自检统一报告
end

local function ename(key, v)
    if v == nil then return nil end
    local e = E[key]
    local nm = e and e.n[v]
    if nm then return nm end
    return tostring(math.tointeger(v) or v)
end

local function ev(key, name)
    local e = E[key]
    return e and e.v[name]
end

-- 常用枚举值
local V = {
    RT_DANGER = ev("RT", "DANGER"),
    LAYER_GET = ev("LAYER", "ATTACK_GET"),
    LAYER_PARRY_GET = ev("LAYER", "ATTACK_PARRY_GET"),
    SF_SA = ev("SF", "SUPER_ARMOR"),
    SF_HA = ev("SF", "HYPER_ARMOR"),
    SF_ND = ev("SF", "NO_DAMAGE"),
    TO_FIRST = ev("TO", "FIRST") or 0,
    CF_PARRY_IMMDIATE = ev("CF", "PARRY_IMMDIATE"),
    CF_PARRY_COMBO = ev("CF", "PARRY_COMBO"),
    CF_WP_COLLISION = ev("CF", "WP_ATTACK_COLLISION_ON"),
}

-- ========================================================================
-- 通用读取
-- ========================================================================
local T_ENEMY, T_MOTION = nil, nil
pcall(function() T_ENEMY = sdk.typeof("app.EnemyCharacter") end)
pcall(function() T_MOTION = sdk.typeof("via.motion.Motion") end)

local function get_hunter()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    return p and p:call("get_Character")
end

local function act_str(c, i)
    if c == nil or i == nil then return nil end
    return safe_fmt("(%d,%d)", math.tointeger(c) or -1, math.tointeger(i) or -1)
end

local function short_name(full)
    if not full then return nil end
    return (full:gsub("^app%.", ""))
end

local function go_name(go)
    return go and go:call("get_Name") or nil
end

-- 攻击者 GameObject → EnemyCharacter（不是怪物返回 nil）
local function go_enemy(go)
    if not go or not T_ENEMY then return nil end
    return go:call("getComponent(System.Type)", T_ENEMY)
end

local function em_key(emid, idx)
    return "em" .. tostring(math.tointeger(emid) or emid or "?") .. "#" .. tostring(math.tointeger(idx) or idx or "?")
end

-- EnemyCharacter → "em<EmID>#<SystemIndex>", SystemIndex（_Context._Em 路径 AGPCall 实测；
-- get_SystemIndex 本次 MCP 核实存在、Lua 待核实，所以放在可选模块 EMID 里）
local function enemy_id_raw(enemy)
    local holder = enemy:get_field("_Context")
    local em = holder and holder:get_field("_Em")
    if not em then return nil, nil end
    local emid = em:call("get_EmID")
    local idx = em:call("get_SystemIndex")
    return em_key(emid, idx), idx
end

local function enemy_key(enemy)
    if not enemy then return nil, nil end
    local addr = enemy:get_address()
    local c = S.em_by_addr[addr]
    if c and S.now - c.t < K.EM_CACHE_AGE then return c.key, c.idx end
    local key, idx = opt("EMID", enemy_id_raw, enemy)
    if key then S.em_by_addr[addr] = { key = key, idx = idx, t = S.now } end
    return key, idx
end

-- 当前动作的 raw 计时：_RawTotalElapsedSecond 是真字段（偏移 0x50，MCP 实读）；读不到退回 getter
local function read_raw(act)
    local raw = act:get_field("_RawTotalElapsedSecond")
    if raw == nil then raw = act:call("get_RawTotalElapsedSecond") end
    return raw
end

local function v3_str(v)
    if not v then return "?" end
    return safe_fmt("%.2f,%.2f,%.2f", v.x, v.y, v.z)
end

-- Nullable 读取（ShellIndex / RequestSetID）：返回 数值字符串 / "none"（无值）/ nil（读不到）
-- 返回形态在 Lua 里没用过：可能是带 _HasValue/_Value 的值类型，也可能被自动拆箱成数字，两种都接
local function nullable_str(obj, getter, backing)
    local nv = obj:call(getter)
    if nv == nil and backing then nv = obj:get_field(backing) end
    if nv == nil then return nil end
    local tv = type(nv)
    if tv == "number" then return tostring(math.tointeger(nv) or nv) end
    if tv == "boolean" or tv == "string" then return nil end
    local has = nv:get_field("_HasValue")
    if not has then return "none" end
    local v = nv:get_field("_Value")
    if v == nil then return "none" end
    return tostring(math.tointeger(v) or v)
end

-- OBB 中心和半长（值类型方法调用待核实；get_Extent 读不到时退回 extent 字段）
local function obb_str(d)
    local obb = d:call("get_Obb")
    if obb == nil then return nil end
    local pos = obb:call("get_Position")
    local ext = obb:call("get_Extent")
    if ext == nil then ext = obb:get_field("extent") end
    if pos == nil and ext == nil then return nil end
    return v3_str(pos) .. "/" .. v3_str(ext)
end

-- ========================================================================
-- 怪物：取对象、目标、速度、主从、位置（P13、P17）
-- ========================================================================
-- 当帧取怪物：优先 EnemyManager.findEnemy_SystemIndex（不跨帧持有）；不可用时退回缓存（add_ref 过的）
local function find_enemy(idx)
    local mgr = sdk.get_managed_singleton("app.EnemyManager")
    local info = mgr and mgr:call("findEnemy_SystemIndex(System.Int32)", idx)
    if not info then return nil, nil end
    return info:call("get_Character"), info
end

local function em_enemy(idx)
    if idx == nil then return nil, nil end
    if MODS.FIND.on then
        local enemy, info = opt("FIND", find_enemy, idx)
        if enemy then return enemy, info end
    end
    local e = S.ems[idx]
    return e and e.ref or nil, nil
end

-- findEnemy 不可用时，从攻击者 / 发送者记住怪物对象：跨帧持有只 add_ref、不手动 release；换对象时只丢掉旧的 Lua 引用
-- （1.1，见头注释「跨帧持有与 REF 的引用记账」：手动 release 会扣掉放刀模块也在用的那一份共享引用）
local function em_remember(idx, key, enemy)
    if idx == nil or not enemy or MODS.FIND.on then return end
    local e = S.ems[idx]
    if not e then
        e = { key = key }
        S.ems[idx] = e
    end
    e.t_seen = S.now
    if e.ref and e.ref:get_address() == enemy:get_address() then
        e.t_ref = S.now
        return
    end
    enemy:add_ref()
    e.ref, e.t_ref, e.key = enemy, S.now, key or e.key
end

-- 丢掉退路缓存的全部怪物对象：只删 Lua 引用，userdata 回收时 REF 自动 release
local function em_release_all()
    for _, e in pairs(S.ems) do e.ref = nil end
    S.ems = {}
    S.em_by_addr = {}
end

local function target_str(enemy)
    local holder = enemy:get_field("_Context")
    local em = holder and holder:get_field("_Em")
    local tm = em and em:get_field("Target")
    if not tm then return nil end
    local key = tm:call("getTarget(System.Boolean, app.cEmModuleTarget.TARGET_ORDER)", false, V.TO_FIRST)
    if not key then return nil end
    return (ename("TAK", key:get_field("Category")) or "?") .. "/" .. tostring(key:get_field("UniqueIndex"))
end

local SPEED_PARTS = { "get_MotionSpeed_Action", "get_MotionSpeed_Random", "get_MotionSpeed_CoreState",
    "get_MotionSpeed_ScaleAdjusted", "get_MotionSpeed_Replica", "get_MotionSpeed_WaitPacket" }

local function speed_of(enemy)
    local spt = enemy:call("calcMotionSpeedTotal(System.Boolean)", true)
    local spf = enemy:call("calcMotionSpeedTotal(System.Boolean)", false)
    local go = enemy:call("get_GameObject")
    local ts = go and go:call("get_TimeScale")
    local parts = {}
    for i, m in ipairs(SPEED_PARTS) do
        local v = enemy:call(m)
        parts[i] = type(v) == "number" and safe_fmt("%.3f", v) or "?"
    end
    return spt, spf, ts, table.concat(parts, "/")
end

local function master_of(enemy)
    local holder = enemy:get_field("_Context")
    return holder and holder:call("get_IsMaster")
end

local function delay_of(go)
    local enemy = go_enemy(go)
    local holder = enemy and enemy:get_field("_Context")
    local em = holder and holder:get_field("_Em")
    local hit = em and em:get_field("Hit")
    local dp = hit and hit:get_field("DelayParryInfo")
    return dp and dp:get_field("DelayFrame")
end

local function transform_pos(obj)
    local go = obj:call("get_GameObject")
    local tr = go and go:call("get_Transform")
    return tr and tr:call("get_Position")
end

-- 怪物根位置：有 cEnemyManageInfo 用 get_Pos，否则读 Transform
local function em_pos(enemy, info)
    if info then
        local p = opt("FIND", info.call, info, "get_Pos")
        if p then return p end
    end
    if not enemy then return nil end
    return opt("POSE", transform_pos, enemy)
end

-- EMINFO：目标键、速度、主从、位置（when = DANGER / FIRE / CT）
local function eminfo(now, when, enemy, key, info)
    if not enemy then return end
    local tgt, spt, spf, ts, comp, master = nil, nil, nil, nil, nil, nil
    if MODS.TGT.on then tgt = opt("TGT", target_str, enemy) end
    if MODS.SPD.on then spt, spf, ts, comp = opt("SPD", speed_of, enemy) end
    if MODS.MASTER.on then master = opt("MASTER", master_of, enemy) end
    local p = em_pos(enemy, info)
    emit("EMINFO", now, "t", now, "t4", "em", key, "s", "when", when, "s", "tgt", tgt, "s", "speed_t", spt, "f3",
        "speed_f", spf, "f3", "ts", ts, "f3", "master", master, "b", "x", p and p.x, "f2", "y", p and p.y, "f2",
        "z", p and p.z, "f2", "comp", comp, "s")
end

-- POSE：主角位置和朝向、怪物根位置、水平来向角和距离；返回距离（空挥判定用）
local function pose_emit(now, when, hunter, enemy, info, key)
    if not hunter then return nil end
    local go = hunter:call("get_GameObject")
    local tr = go and go:call("get_Transform")
    local p = tr and tr:call("get_Position")
    local ax = tr and tr:call("get_AxisZ")
    local ep = enemy and em_pos(enemy, info) or nil
    local theta, dist = nil, nil
    if p and ax and ep then theta, dist = calc_theta(ax.x, ax.z, ep.x - p.x, ep.z - p.z) end
    emit("POSE", now, "t", now, "t4", "when", when, "s", "px", p and p.x, "f2", "pz", p and p.z, "f2",
        "fx", ax and ax.x, "f3", "fz", ax and ax.z, "f3", "ex", ep and ep.x, "f2", "ez", ep and ep.z, "f2",
        "theta", theta, "f1", "dist", dist, "f2", "em", key, "s")
    return dist
end

-- ========================================================================
-- 预告跟踪、条目时间序列、回合（P04、P05、P06、P18）
-- ========================================================================
-- 丢掉一个预告结果：只删 Lua 引用（1.1 起不手动 release，见头注释「跨帧持有与 REF 的引用记账」）
local function trk_release(tr)
    tr.obj = nil
    if S.trk[tr.addr] then
        S.trk[tr.addr] = nil
        S.n_trk = S.n_trk - 1
    end
end

local function ep_open(tr, now, reason)
    S.ep_id = S.ep_id + 1
    tr.epoch = tr.epoch + 1
    tr.ep = {
        id = S.ep_id, epoch = tr.epoch, reason = reason, keep = tr.keep, t0 = now, n_msg = 0,
        first_type = nil, first_hs = nil, types = {}, last_rt = nil, rates = {}, stall = 0, maxdt = 0,
        charge_all = true, atk_on = not atk_off, minhs = nil, danger = false, pts = {}, hold_n = 0, hold_hit = 0,
        n_ent = 0, n_typ = 0,
    }
    -- 结果对象和条目对象都会被怪物复用：新回合里的条目一律当作「第一次出现」，重新写 TYP add 和 ENT
    tr.ents = {}
    tr.ent_logged = 0
end

local function ep_close_body(tr, now, why)
    local ep = tr.ep
    tr.ep = nil
    if not ep then return end
    local med = median(ep.rates)
    local mn, mx = min_max(ep.rates)
    local pts = {}
    for i, id in ipairs(ep.pts) do pts[i] = tostring(id) end
    local hold = ep.hold_n > 0 and ep.hold_hit / ep.hold_n or nil
    -- 一个条目都没见过的回合（SAFE、空预告，比如训练机关）只进 JSON，省日志；有条目的回合总是写日志
    -- （每次出招一行，量小，是日志兜底时离线归属接触的依据）
    local mode = M_FORCE
    if ep.n_ent == 0 then mode = M_JSON end
    emit_core("EP", now, mode, "id", ep.id, "i", "obj", tr.addr, "x", "epoch", ep.epoch, "i", "em", tr.em, "s",
        "keep", ep.keep, "s", "reason", ep.reason, "s", "n_msg", ep.n_msg, "i", "first_type", ep.first_type, "s",
        "first_hs", ep.first_hs, "f2", "types", #ep.types > 0 and table.concat(ep.types, ">") or nil, "s",
        "rate_med", med, "f1", "rate_min", mn, "f1", "rate_max", mx, "f1", "stall", ep.stall, "i",
        "maxdt", ep.maxdt, "f4", "charge_all", ep.charge_all, "b", "atk_on", ep.atk_on, "b",
        "t0", ep.t0, "t4", "t1", now, "t4", "end", why, "s", "hold", hold, "f2",
        "pts", #pts > 0 and table.concat(pts, ",") or nil, "s", "snd", tr.snd, "s", "snd_em", tr.snd_em, "x")
end

local function ep_close(tr, now, why)
    if tr.ep then run("EP", ep_close_body, tr, now, why) end
    tr.ep = nil
end

local function trk_drop(tr, now, why)
    ep_close(tr, now, why)
    trk_release(tr)
end

local function release_all_tracks(now, why)
    for _, tr in pairs(S.trk) do
        ep_close(tr, now, why)
        tr.obj = nil        -- 只删 Lua 引用，不手动 release
    end
    S.trk = {}
    S.n_trk = 0
end

-- 新的打我的结果登记（消息钩子里调用）：add_ref 后登记（对已推入的对象是空操作，局部对象才真正加一份；丢弃时只删
-- Lua 引用，不 release），满 32 条丢 t_msg 最旧的（最久没收到消息的那条；
-- CONTRACT 3.3，和 rc 同一口径 —— 两边淘汰对象不同会让持有集合不一致，离线影子回放和 rc 对不上）。
-- snd / snd_em：发送者 GameObject 名和它的 EnemyCharacter 地址（SND 模块），P23「攻击者相同」的首选键
local function track_msg(r, addr, key, idx, keep, now, snd, snd_em)
    local tr = S.trk[addr]
    if tr then
        tr.msg_pending = tr.msg_pending + 1
        tr.t_msg = now
        tr.n_msg = tr.n_msg + 1
        tr.em, tr.idx = key, idx
        if snd then tr.snd = snd end
        if snd_em then tr.snd_em = snd_em end
        return false
    end
    if S.n_trk >= K.TRACK_MAX then
        local oldest = nil
        for _, o in pairs(S.trk) do
            if not oldest or o.t_msg < oldest.t_msg then oldest = o end
        end
        if oldest then trk_drop(oldest, now, "evict") end
    end
    r:add_ref()
    tr = {
        obj = r, addr = addr, em = key, idx = idx, keep = keep, t_first = now, t_msg = now, n_msg = 1,
        msg_pending = 1, first = true, ents = {}, epoch = 0, div = 0, ent_logged = 0, ep = nil, busy = false,
        min_hs = nil, snd = snd, snd_em = snd_em,
    }
    S.trk[addr] = tr
    S.n_trk = S.n_trk + 1
    return true
end

local function read_entry(d, i)
    local addr = d:get_address()
    return { d = d, addr = addr, idx = i, ty = d:call("get_ResultType"), hs = d:call("get_HitStartRemainFrame"),
        he = d:call("get_HitEndRemainFrame") }
end

-- 逐条读取（List.get_Count / get_Item 在 TDB 里有、Lua 待核实）。
-- 读不到（get_Count 不是整数、get_Item 返回 nil）一律当出错：REF 调用泛型实例方法失败时可能返回 nil 而不抛错，
-- 以前静默当成「没有条目」，整段 SER/首次 DANGER/自检2/B 段都不会触发、也不标黄（审查实验 fb_fallback 改 nil）。
-- 和 rc 的 read_items 一致：出错由 read_entries 报 ITEM（黄）并退回 closest
local function list_entries(r, out)
    local list = r:call("get_DetectedDataList")
    if not list then return end
    local n = math.tointeger(list:call("get_Count"))
    if not n then error("get_Count is not an integer") end
    for i = 0, n - 1 do
        local d = list:call("get_Item", i)
        if not d then error("get_Item(" .. tostring(i) .. ") returned nil") end
        out[#out + 1] = read_entry(d, i)
    end
end

-- 第一次出错就停用 ITEM（黄），之后只读 closest（v1.3 实测可用），返回 条目表, 是否退回 closest
local function read_entries(r)
    if MODS.ITEM.on then
        local out = {}
        local ok, err = pcall(list_entries, r, out)
        if ok then return out, false end
        report_error("ITEM", err)
    end
    local d = r:call("getClosestDetectedData")
    if d then return { read_entry(d, -1) }, true end
    return {}, true
end

local function list_count(r)
    local list = r:call("get_DetectedDataList")
    if not list then return nil end
    local n = math.tointeger(list:call("get_Count"))
    if not n then error("get_Count is not an integer") end
    return n
end

-- ENT：条目第一次出现时读一次静态属性（P06；全部是 TDB 有、Lua 没用过的接口，可选）
local function ap_read(ap)
    local ud = ap:get_field("_UserData")
    return {
        guard = ename("GT", ap:get_field("_GuardType")),
        dmgtype = ename("DT", ap:get_field("_DamageType")),
        dmglv = ap:get_field("_DamageLevel"),
        filter = ap:get_field("_AttackFilterType"),
        vguard = ap:get_field("_VersusGuardPower"),
        pbreak = ap:get_field("_IsParryBreak"),
        pfix = ap:get_field("_IsParryFix"),
        pstock = ap:get_field("_IsParryStockOnly"),
        tgbreak = ap:get_field("_IsTechGuardBreak"),
        block = ap:get_field("_IsBlockEnable"),
        name = ud and ud:call("get_Name") or nil,
        addr = ap:get_address(),
    }
end

local function ent_emit(tr, e, closest_addr, now)
    local d = e.d
    local shell, reqset, a, obb = nil, nil, nil, nil
    if MODS.NULL.on then
        shell = opt("NULL", nullable_str, d, "get_ShellIndex", "<ShellIndex>k__BackingField")
        reqset = opt("NULL", nullable_str, d, "get_RequestSetID", "<RequestSetID>k__BackingField")
    end
    if MODS.AP.on then
        local ap = opt("AP", d.call, d, "get_AttackParam")
        if ap then a = opt("AP", ap_read, ap) end
    end
    a = a or {}
    if MODS.OBB.on then obb = opt("OBB", obb_str, d) end
    emit("ENT", now, "obj", tr.addr, "x", "ent", e.addr, "x", "idx", e.idx, "i",
        "closest", closest_addr ~= nil and e.addr == closest_addr, "b", "shell", shell, "s", "reqset", reqset, "s",
        "guard", a.guard, "s", "dmgtype", a.dmgtype, "s", "dmglv", a.dmglv, "i", "filter", a.filter, "i",
        "vguard", a.vguard, "f2", "pbreak", a.pbreak, "b", "pfix", a.pfix, "b", "pstock", a.pstock, "b",
        "tgbreak", a.tgbreak, "b", "block", a.block, "b", "name", a.name, "s", "ap", a.addr, "x", "obb", obb, "s")
end

-- 首次 DANGER 实物自检（P06）：对活对象逐项试读，结果以「自检2 x/y」显示在 HUD
local function selftest2(tr, e, now)
    local d = e.d
    local r = tr.obj
    local enemy = em_enemy(tr.idx)
    local okn, total, failed = 0, 0, {}
    local core_fail = false
    local function chk(name, modname, fn)
        total = total + 1
        local ok, res = pcall(fn)
        if ok and res then
            okn = okn + 1
            return
        end
        failed[#failed + 1] = name
        local why = ok and "no value" or tostring(res)
        if modname == "SERIES" then core_fail = true end
        if modname and MODS[modname].on then report_error(modname, "selftest2 " .. name .. ": " .. why) end
    end
    chk("item", "ITEM", function()
        local list = r:call("get_DetectedDataList")
        return list and list:call("get_Item", 0) ~= nil
    end)
    chk("entry", "SERIES", function()
        return type(d:call("get_HitStartRemainFrame")) == "number" and type(d:call("get_HitEndRemainFrame")) == "number"
    end)
    chk("shell", "NULL", function() return nullable_str(d, "get_ShellIndex", "<ShellIndex>k__BackingField") ~= nil end)
    chk("reqset", "NULL", function()
        return nullable_str(d, "get_RequestSetID", "<RequestSetID>k__BackingField") ~= nil
    end)
    chk("ap", "AP", function()
        local ap = d:call("get_AttackParam")
        return ap ~= nil and type(ap:get_field("_DamageType")) == "number"
    end)
    chk("obb", "OBB", function() return obb_str(d) ~= nil end)
    chk("find", "FIND", function() return find_enemy(tr.idx) ~= nil end)
    -- 没取到怪物时下面三项只记失败、不停用模块（不是接口本身的问题）
    chk("tgt", enemy and "TGT" or nil, function() return enemy ~= nil and target_str(enemy) ~= nil end)
    chk("master", enemy and "MASTER" or nil, function() return enemy ~= nil and type(master_of(enemy)) == "boolean" end)
    chk("speed", enemy and "SPD" or nil, function()
        return enemy ~= nil and type(enemy:call("calcMotionSpeedTotal(System.Boolean)", true)) == "number"
    end)
    -- 一致性（只记录）：消息里的 EmSystemIndex 找到的怪物，EmID 是否和消息一致
    chk("sysidx", nil, function()
        if not enemy then return false end
        local key = enemy_id_raw(enemy)
        return key == tr.em
    end)
    S.st2 = { ok = okn, total = total, failed = failed, core_fail = core_fail }
    emit("SELFTEST", now, "stage", 2, "i", "ok", okn, "i", "total", total, "i",
        "failed", #failed > 0 and table.concat(failed, ",") or nil, "s")
    -- 条目剩余帧读不出数字：核心测量做不了，HUD 标红（协议：自检2 红就停下），记一行 RED
    if core_fail then set_red("SERIES", "selftest2") end
end

-- 一个结果对象的每帧处理：条目序列、TYP/SER/ENT、回合切分与统计、释放
local function trk_tick(tr, now)
    local r = tr.obj
    local fin = r:call("get_IsAttackFinished")
    local rt = r:call("get_ResultType")
    local kid = r:call("get_KeepActionID")
    local keep = kid and act_str(kid:get_field("_Category"), kid:get_field("_Index")) or nil
    tr.keep = keep
    local new_msg = tr.msg_pending
    tr.msg_pending = 0

    local ents, fb = {}, false
    if not fin then ents, fb = read_entries(r) end

    -- 回跳量、最小 hs、是否还有活条目
    local max_jump, min_hs, min_e, active, all_below = 0, nil, nil, false, #ents > 0
    for _, e in ipairs(ents) do
        local p = tr.ents[e.addr]
        if p and p.hs and e.hs then
            local j = e.hs - p.hs
            if j > max_jump then max_jump = j end
        end
        if e.hs and (min_hs == nil or e.hs < min_hs) then min_hs, min_e = e.hs, e end
        if e.he and e.he >= K.RELEASE_HE then
            active = true
            all_below = false
        elseif e.he == nil then
            all_below = false
        end
    end
    tr.min_hs = min_hs

    -- 回合切分
    local reason = epoch_split(tr.first, tr.ep ~= nil, tr.ep and tr.ep.keep, tr.ep and tr.ep.minhs, keep,
        new_msg > 0, max_jump, active)
    tr.first = false
    if reason then
        if tr.ep then ep_close(tr, now, reason) end
        ep_open(tr, now, reason)
    end
    local ep = tr.ep
    if ep then
        ep.n_msg = ep.n_msg + new_msg
        if S.dt > ep.maxdt then ep.maxdt = S.dt end
        if not S.cur.charge then ep.charge_all = false end
        if atk_off then ep.atk_on = false end
        local rts = ename("RT", rt)
        if rts and rts ~= ep.last_rt then
            ep.last_rt = rts
            if #ep.types < 16 then ep.types[#ep.types + 1] = rts:sub(1, 1) end
        end
        if min_e and ep.first_type == nil then
            ep.first_type = ename("RT", min_e.ty)
            ep.first_hs = min_e.hs
        end
        if min_hs and (ep.minhs == nil or min_hs < ep.minhs) then ep.minhs = min_hs end
    end

    -- 条目：TYP（类型变化、hs 回跳 >2 帧、条目增减）+ SER（采样密度规则）+ ENT（第一次出现）
    local dense = min_hs ~= nil and min_hs <= K.DENSE_HS
    tr.div = (tr.div + 1) % K.SPARSE_EVERY
    local sample_all = dense or tr.div == 0 or S.snap_f == S.f
    local charge = S.cur.charge == true
    local now_set = {}
    local closest_addr = nil
    local danger_e = nil
    for _, e in ipairs(ents) do
        now_set[e.addr] = true
        local p = tr.ents[e.addr]
        local why = nil
        if not p then
            why = "add"
            p = {}
            tr.ents[e.addr] = p
            if MODS.ENT.on and tr.ent_logged < K.ENT_MAX then
                tr.ent_logged = tr.ent_logged + 1
                if closest_addr == nil then
                    local cd = r:call("getClosestDetectedData")
                    closest_addr = cd and cd:get_address() or false
                end
                run("ENT", ent_emit, tr, e, closest_addr or nil, now)
            end
        elseif p.ty ~= e.ty then
            why = "type"
        elseif p.hs and e.hs and e.hs - p.hs > K.TYP_JUMP then
            why = "jump"
        end
        local tys = ename("RT", e.ty)
        if why then
            local mode = nil
            if ep then
                ep.n_typ = ep.n_typ + 1
                if ep.n_typ > K.TYP_MAX then mode = M_JSON end
            end
            emit_core("TYP", now, mode, "t", now, "t4", "f", S.f, "i", "obj", tr.addr, "x", "ent", e.addr, "x",
                "type", tys, "s", "hs", e.hs, "f2", "he", e.he, "f2", "why", why, "s")
        end
        if why or sample_all then
            emit("SER", now, "t", now, "t4", "f", S.f, "i", "obj", tr.addr, "x", "ent", e.addr, "x", "type", tys, "s",
                "hs", e.hs, "f2", "he", e.he, "f2", "charge", charge, "b", "fb", fb and 1 or nil, "i")
        end
        -- 回合统计：倒数速率（−Δhs/Δt，窗口 ≥0.1 s）、停滞帧
        if ep then
            ep.n_ent = ep.n_ent + 1
            if e.hs and e.hs > 0 then
                if p.hs and why ~= "jump" and e.hs >= p.hs and S.dt > 0 then ep.stall = ep.stall + 1 end
                if p.anchor_t == nil or why == "jump" or why == "add" then
                    p.anchor_t, p.anchor_hs = now, e.hs
                elseif now - p.anchor_t >= K.RATE_WIN then
                    ep.rates[#ep.rates + 1] = -(e.hs - p.anchor_hs) / (now - p.anchor_t)
                    p.anchor_t, p.anchor_hs = now, e.hs
                end
            end
            if V.RT_DANGER ~= nil and e.ty == V.RT_DANGER and not ep.danger and not danger_e then danger_e = e end
        end
        p.ty, p.hs, p.he = e.ty, e.hs, e.he
    end
    for a, p in pairs(tr.ents) do
        if not now_set[a] then
            tr.ents[a] = nil
            local mode = nil
            if ep then
                ep.n_typ = ep.n_typ + 1
                if ep.n_typ > K.TYP_MAX then mode = M_JSON end
            end
            emit_core("TYP", now, mode, "t", now, "t4", "f", S.f, "i", "obj", tr.addr, "x", "ent", a, "x",
                "type", "GONE", "s", "hs", p.hs, "f2", "he", p.he, "f2", "why", "del", "s")
        end
    end

    -- 本回合第一次 DANGER：进入 B 段、DANGER 回合计数、EMINFO、首次实物自检
    if ep and not ep.danger and (danger_e or (V.RT_DANGER ~= nil and rt == V.RT_DANGER and min_e)) then
        ep.danger = true
        if not S.phase_b then
            S.phase_b = true
            S.b_t0 = now
        end
        S.b_danger = S.b_danger + 1
        if MODS.EMSTATE.on then
            local enemy, info = em_enemy(tr.idx)
            if enemy then run("EMSTATE", eminfo, now, "DANGER", enemy, tr.em, info) end
        end
        if not S.st2 then run("HDR", selftest2, tr, danger_e or min_e, now) end
    end
    tr.busy = ep ~= nil and active

    -- 回合结束与释放（P04 释放条件，P18 结束条件）
    local since = now - tr.t_msg
    local why_end = epoch_end(fin, #ents, all_below, since)
    if why_end == "fin" or why_end == "stale" then
        trk_drop(tr, now, why_end)
        return
    end
    if why_end == "he" then
        ep_close(tr, now, "he")
        if since >= K.RELEASE_MSG then trk_release(tr) end
    end
end

local function track_tick(now)
    for _, tr in pairs(S.trk) do
        if tr.obj then
            local ok, err = pcall(trk_tick, tr, now)
            if not ok then
                report_error("SERIES", err)
                trk_drop(tr, now, "error")   -- 坏对象直接放掉，避免每帧重复出错
            end
        end
    end
end

-- ========================================================================
-- 放刀尝试 PT（P08）
-- ========================================================================
local function pt_absorb(pt, ev)
    local k = ev.k
    if k == "CT" then
        pt.contacts[#pt.contacts + 1] = { t = ev.t, cls = ev.cls }
        if ev.cls == "BLADE" then
            pt.n_blade = pt.n_blade + 1
        elseif ev.cls == "BODY" then
            pt.n_body = pt.n_body + 1
            -- (2,23) 里身体被打且确认没有 SUPER_ARMOR（读不到霸体标志时不算）
            if ev.in_slash and ev.sa == false then pt.late_body = true end
        end
    elseif k == "PH" then
        pt.ph_n = pt.ph_n + 1
        pt.ph = pt.ph or ev.state
    elseif k == "PS" then
        pt.ps = pt.ps or ev.state
        if ev.state == "RECOIL" then pt.recoil = true end
    elseif k == "PMSG" then
        if ev.state == "RECOIL" then pt.recoil = true end
    elseif k == "EMHIT" then
        pt.emhit = pt.emhit + 1
    elseif k == "DMG" then
        pt.dmg = pt.dmg + (ev.total or 0)
    end
end

-- 钩子事件：先进最近事件表（PT 开始时补收「动作刚切换那一帧」的事件），PT 进行中直接汇总
local function note_event(ev)
    local r = S.recent
    r[#r + 1] = ev
    if S.pt then pt_absorb(S.pt, ev) end
end

local function eminfo_fire(now)
    local seen = {}
    for _, tr in pairs(S.trk) do
        if tr.ep and tr.idx ~= nil and not seen[tr.idx] then
            seen[tr.idx] = true
            local enemy, info = em_enemy(tr.idx)
            if enemy then eminfo(now, "FIRE", enemy, tr.em, info) end
        end
    end
end

-- FIRE 时刻（PT 首帧）的 POSE：每只有未结束 DANGER 回合的怪各写一条（和 eminfo_fire 一样按怪去重），
-- 返回最近的距离（空挥判定用）。以前只写一条、取所有跟踪结果里 min_hs 最小的那只：已经打完的长窗口条目
-- （hs 远小于 0）或 CAUTION 条目也会入选，离线 g2/g4 就会拿另一只怪的角度和距离去评估闸门（审查 long_veto 实测）
local function pose_fire(now)
    local seen, near, any = {}, nil, false
    for _, tr in pairs(S.trk) do
        if tr.ep and tr.ep.danger and tr.idx ~= nil and not seen[tr.idx] then
            seen[tr.idx] = true
            any = true
            local enemy, info = em_enemy(tr.idx)
            local d = pose_emit(now, "FIRE", S.hunter, enemy, info, tr.em)
            if d and (near == nil or d < near) then near = d end
        end
    end
    if not any then return pose_emit(now, "FIRE", S.hunter, nil, nil, nil) end
    return near
end

-- 当前防御角度（PLAN 安全-1：HDR 和 PT 都记 _GuardDegree，确认 v1.4.1 在抵消动作里没改它）
local function guard_degree()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local cat = pm and pm:call("get_Catalog")
    local prm = cat and cat:call("getWeaponActionParam(app.WeaponDef.TYPE)", 0)
    return prm and prm:get_field("_GuardDegree") or nil
end

local function pt_open(now)
    local cur = S.cur
    S.pt_id = S.pt_id + 1
    local raw0 = cur.raw
    local t_start = raw0 and (now - raw0) or now    -- t_start = (2,23) 首帧读到的时刻 − 当时的 raw（PLAN C）
    local hold = nil
    if cur.prev_c == 2 and CHARGE[cur.prev_i] and S.charge_t0 then hold = t_start - S.charge_t0 end
    local pt = {
        id = S.pt_id, t_obs = now, raw0 = raw0, t_start = t_start, from = cur.prev_s, hold = hold, lv = S.charge_lv,
        contacts = {}, n_blade = 0, n_body = 0, ph_n = 0, ph = nil, ps = nil, emhit = 0, dmg = 0,
        catch_t = nil, catch_idx = nil, recoil = false, late_body = false, slash_until = now, near = nil,
        gdeg = nil,
    }
    if MODS.HDRX.on then pt.gdeg = opt("HDRX", guard_degree) end
    for _, e in ipairs(S.recent) do
        if e.t >= t_start - 0.005 then pt_absorb(pt, e) end
    end
    S.pt = pt
    S.snap_f = S.f     -- 本帧给所有跟踪中的条目强制存一格 SER（PT 开头的条目快照）
    for _, tr in pairs(S.trk) do
        if tr.ep then
            local p = tr.ep.pts
            p[#p + 1] = pt.id
        end
    end
    if MODS.EMSTATE.on then run("EMSTATE", eminfo_fire, now) end
    if MODS.POSE.on then pt.near = opt("POSE", pose_fire, now) end
end

local function pt_close(now, why)
    local pt = S.pt
    S.pt = nil
    if not pt then return end
    local cls = classify_pt(pt, K.W0_HUD, K.W1_HUD, K.CREDIT)
    local n_contact = #pt.contacts
    -- 空挥样本：没有敌人接触 / 砍中 / 抵消事件，(2,23) 停了 ≥3 s，已知怪物都在 10 m 外
    local swing = n_contact == 0 and pt.emhit == 0 and pt.ph_n == 0
        and (pt.slash_until - pt.t_obs) >= K.SWING_MIN and (pt.near == nil or pt.near >= K.SWING_DIST)
    emit("PT", now, "id", pt.id, "i", "t_obs", pt.t_obs, "t4", "raw0", pt.raw0, "f4", "t_start", pt.t_start, "t4",
        "from", pt.from, "s", "hold", pt.hold, "f3", "lv", pt.lv, "s", "contacts_blade", pt.n_blade, "i",
        "contacts_body", pt.n_body, "i", "ph", pt.ph, "s", "ps", pt.ps, "s", "hit_t", pt.catch_t, "t4",
        "hit_idx", pt.catch_idx, "i", "recoil", pt.recoil, "b", "emhit", pt.emhit, "i", "dmg", pt.dmg, "f1",
        "online_class", cls, "s", "t_end", now, "t4", "end", why, "s", "swing", swing, "b", "gdeg", pt.gdeg, "f1")
    S.last_class = cls
    if S.phase_b then
        S.b_pt = S.b_pt + 1
        if n_contact > 0 then S.b_contact = S.b_contact + 1 end
    elseif swing then
        S.swings = S.swings + 1
    else
        S.scan_pt = S.scan_pt + 1
    end
end

local function pt_tick(now)
    local cur = S.cur
    if not cur.ok then
        if S.pt then pt_close(now, "lost") end
        return
    end
    if cur.changed then
        -- 每次从非上捞斩动作进入 (2,23)/(2,24) 都是一次新的放刀尝试（后续动作里再出刀也单独算）
        local prev_slash = cur.prev_c == 2 and SLASH[cur.prev_i] == true
        if cur.slash and not prev_slash then
            if S.pt then pt_close(now, "leave") end
            pt_open(now)
        elseif S.pt then
            if cur.c == 2 and HITACT[cur.i] and not S.pt.catch_t then
                S.pt.catch_t, S.pt.catch_idx = now, cur.i
            end
            -- RECOIL：进入类名以 Recoil 结尾的动作（DECISION RULE B 节「类名以 cRecoil 结尾」，这里放宽到 Recoil）
            if cur.name and cur.name:find("Recoil$") then S.pt.recoil = true end
            if not cur.ptfam then pt_close(now, "leave") end
        end
    end
    local pt = S.pt
    if pt then
        if cur.slash then pt.slash_until = now end
        if now - pt.t_obs >= K.PT_MAX then pt_close(now, "timeout") end
    end
end

-- ========================================================================
-- 主角动作、计时、霸体 ACT/ARM（P07）
-- ========================================================================
local function arm_tick(now, hunter)
    local st = hunter:call("get_HunterStatus")
    local flags = st and st:get_field("_HunterStatusFlag")
    if not flags then return end
    local sa = flags:call("check(System.UInt32)", V.SF_SA) == true
    local ha = flags:call("check(System.UInt32)", V.SF_HA) == true
    local nd = flags:call("check(System.UInt32)", V.SF_ND) == true
    local sig = (sa and 4 or 0) + (ha and 2 or 0) + (nd and 1 or 0)
    if sig ~= S.arm then
        S.arm = sig
        emit("ARM", now, "t", now, "t4", "f", S.f, "i", "act", S.cur.act_s, "s", "sa", sa, "b", "ha", ha, "b",
            "nd", nd, "b", "raw", S.cur.raw, "f4")
    end
end

local function on_hunter_lost(now, why)
    if S.pt then pt_close(now, why) end
    release_all_tracks(now, why)
    em_release_all()
    S.atk_cache = {}
    S.hc = {}
    S.cur = { ok = false }
    S.arm, S.sig_prev = nil, nil
    S.charge_t0, S.charge_lv = nil, nil
end

-- 换场景（主角对象变了、一帧超过 1 s）后 fps 基线重新取（只影响 HUD 的「帧率降 x%」提示）
local function fps_base_reset(now)
    S.fpsb = { t0 = now, sec_t = now, n = 0, samples = {}, base = nil, done = false }
    S.fps_warn = nil
end

-- 取主角 → GameObject / WeaponHandling / 武器种类 → 动作控制器 → 动作 ID。返回 nil = 本帧没有主角。
-- 这一段抛错（不是返回 nil）时整段按瞬时异常处理，见 act_tick
local function read_hunter_core()
    local hunter = get_hunter()
    if not hunter then return nil end
    local ctrl = hunter:call("get_BaseActionController")
    local id = ctrl and ctrl:call("get_CurrentActionID")
    local c, i = nil, nil
    if id then c, i = id:get_field("_Category"), id:get_field("_Index") end
    return { hunter = hunter, addr = hunter:get_address(), go = hunter:call("get_GameObject"),
        wh = hunter:call("get_WeaponHandling"), gs = hunter:call("get_WeaponType") == 0, ctrl = ctrl, c = c, i = i }
end

-- 读主角抛错：容忍期内返回 false（这一帧沿用上一帧的状态），持续超过 1.5 s 返回 true（算 ACT 核心错误）。
-- 一次 0.1 s 的瞬时异常（切场景时对象正在销毁）以前会在 3 帧内标红、HUD 永久提示停下，这一轮作废
-- （审查实验 x_transient_throw）。容忍期内跳过的帧数进 PERF 的 actfail
local function act_read_failed(now)
    local F = S.actfail
    if not F.t0 or now - F.t_last > K.ACT_FAIL_GAP then F.t0 = now end
    F.t_last = now
    S.perf.actfail = S.perf.actfail + 1
    return now - F.t0 >= K.ACT_FAIL_TOL
end

local function act_tick(now)
    local cur = S.cur
    cur.changed = false
    local ok_read, h = pcall(read_hunter_core)
    if not ok_read then
        if act_read_failed(now) then error(h, 0) end
        return      -- 容忍期内：这一帧沿用上一帧的动作状态；S.hunter 为 nil，依赖主角对象的可选模块本帧跳过
    end
    local F = S.actfail
    if F.t0 and now - F.t_last > K.ACT_FAIL_GAP then F.t0 = nil end
    if not h then
        if S.hc.addr then on_hunter_lost(now, "lost") end
        S.cur.ok = false
        return
    end
    local hunter, addr = h.hunter, h.addr
    if S.hc.addr ~= addr then
        if S.hc.addr then
            on_hunter_lost(now, "lost")
            fps_base_reset(now)
        end
        S.hc = { addr = addr }
        cur = S.cur
        cur.changed = false
    end
    S.hunter = hunter
    S.hc.go_addr = h.go and h.go:get_address() or nil
    local wh = h.wh
    S.hc.wh_addr = wh and wh:get_address() or nil
    local gs = h.gs
    local ctrl = h.ctrl
    if h.c == nil or h.i == nil then
        cur.ok = false
        return
    end
    local c, i = h.c, h.i
    local act = ctrl:call("get_CurrentAction")
    local raw = act and read_raw(act) or nil
    local chara = nil
    if act and MODS.CHARA.on then chara = opt("CHARA", act.call, act, "get_CharaElapsedSecond") end
    -- 动作变化：ID 变了，或同一动作重新进入（raw 明显变小）
    local changed = c ~= cur.c or i ~= cur.i
    if not changed and raw and cur.raw and raw < cur.raw - 0.02 then changed = true end
    if changed then
        local name = act and short_name(act:get_type_definition():get_full_name()) or nil
        local to_s = act_str(c, i)
        if gs then
            -- 进出抵消动作族 (2,21)~(2,29) 的 ACT 总是写日志（t_start、接住档位都靠它），其余走令牌桶
            local fam_edge = (c == 2 and i >= 21 and i <= 29) or (cur.c == 2 and cur.i and cur.i >= 21 and cur.i <= 29)
            emit_core("ACT", now, fam_edge and M_FORCE or nil, "t", now, "t4", "f", S.f, "i", "from", cur.act_s, "s",
                "to", to_s, "s", "from_name", cur.name, "s", "to_name", name, "s", "raw_prev", cur.raw, "f4",
                "raw_new", raw, "f4", "chara_new", chara, "f4")
        end
        local was_charge = cur.c == 2 and CHARGE[cur.i] == true
        cur.prev_c, cur.prev_i, cur.prev_s = cur.c, cur.i, cur.act_s
        cur.c, cur.i, cur.act_s, cur.name = c, i, to_s, name
        cur.t_enter = now
        cur.changed = true
        if c == 2 and CHARGE[i] and not was_charge then
            S.charge_t0, S.charge_lv = now, nil      -- 抵消蓄力开始（算按住时长）
        end
    end
    cur.raw, cur.chara = raw, chara
    cur.ok, cur.gs = true, gs
    cur.charge = gs and c == 2 and CHARGE[i] == true
    cur.slash = gs and c == 2 and SLASH[i] == true
    cur.fam = gs and c == 2 and i >= 21 and i <= 29
    cur.ptfam = gs and c == 2 and i >= 23 and i <= 29
    if cur.fam then
        S.fam_until = now + K.ARM_AFTER
        S.sig_until = now + K.SIG_AFTER
    end
    if cur.charge and wh and MODS.LV.on then
        local lv = opt("LV", wh.get_field, wh, "_ChargeLevel")
        if lv ~= nil then S.charge_lv = ename("CL", lv) end
    end
    if gs and (cur.fam or now <= S.fam_until) then
        arm_tick(now, hunter)
    else
        S.arm = nil
    end
end

-- ========================================================================
-- 怪物动作 EMSTATE（P13）：对有未结束回合的怪物、以及刚被上捞斩砍中的怪物（盯 1.5 s），每帧读一次动作类名
-- ========================================================================
local function em_read_action(idx, key, now)
    local enemy = em_enemy(idx)
    if not enemy then return end
    local act = enemy:call("getCurrentAction()")
    local aaddr = act and act:get_address() or nil
    local e = S.ems[idx]
    if not e then
        e = { key = key }
        S.ems[idx] = e
    end
    if aaddr ~= e.act_addr then
        e.act_addr = aaddr
        local name = act and short_name(act:get_type_definition():get_full_name()) or nil
        if name ~= e.act then
            e.act = name
            emit("EMSTATE", now, "t", now, "t4", "em", key or e.key, "s", "act", name, "s")
        end
    end
end

local function em_tick(now)
    local seen = {}
    for _, tr in pairs(S.trk) do
        local idx = tr.idx
        if tr.ep and idx ~= nil and not seen[idx] then
            seen[idx] = true
            em_read_action(idx, tr.em, now)
        end
    end
    -- 上捞斩先砍中把怪打断时，这一招的结果常在同一帧就结束（回合关闭、跟踪释放），上面的循环就不再读这只怪，
    -- 受击动作记不下来，离线的 INTERRUPTED 永远判不出（审查：mock whiff 真值 interrupted，报告「被打断 0」）
    for idx, e in pairs(S.ems) do
        if not seen[idx] and e.watch_until and now <= e.watch_until then
            seen[idx] = true
            em_read_action(idx, e.key, now)
        end
    end
    -- 退路缓存里太久没见到的怪物对象丢掉（只删 Lua 引用）；10 s 没有未结束回合的怪物，连动作记录一起清掉
    -- （SystemIndex 会被之后刷新的怪物复用）
    for idx, e in pairs(S.ems) do
        if seen[idx] then e.t_seen = now end
        if e.ref and now - (e.t_ref or 0) > K.EM_REF_STALE then e.ref = nil end
        if not e.ref and now - (e.t_seen or now) > 10.0 then S.ems[idx] = nil end
    end
end

-- EMHIT 之后盯这只怪的动作（em_tick 里读）；findEnemy 不可用时顺便记住怪物对象（em_remember 内部判断）
local function em_watch(enemy, now)
    local key, idx = enemy_key(enemy)
    if idx == nil then return end
    em_remember(idx, key, enemy)
    local e = S.ems[idx]
    if not e then
        e = { key = key }
        S.ems[idx] = e
    end
    e.key = key or e.key
    e.watch_until = now + K.EM_WATCH
    e.t_seen = now
end

-- ========================================================================
-- 窗口候选信号 SIG 与动画时钟 ANIM（P15）
-- ========================================================================
local SEQ_FIELDS = { "_ParryImmdiate", "_ActionFlag1", "_ActionFlag2", "_ActionFlag3", "_WpUniqueFlag1",
    "_SuperArmor", "_HyperArmor", "_NoHit" }
local SIG_NAMES = { "_ParryImmdiate", "_ActionFlag1", "_ActionFlag2", "_ActionFlag3", "_WpUniqueFlag1",
    "_SuperArmor", "_HyperArmor", "_NoHit", "wp._IsAttackColliderOn", "CF.PARRY_IMMDIATE", "CF.PARRY_COMBO",
    "CF.WP_ATTACK_COLLISION_ON" }

local function sig_seq(hunter, vals)
    local sup = hunter:get_field("_HunterMotionSupporter")
    local seq = sup and sup:get_field("_BaseBasicMotionSeq")
    if seq then
        for _, fname in ipairs(SEQ_FIELDS) do
            local v = seq:get_field(fname)
            if v ~= nil then vals[fname] = v == true end
        end
    end
    local wp = hunter:call("get_Weapon")
    local on = wp and wp:get_field("_IsAttackColliderOn")
    if on ~= nil then vals["wp._IsAttackColliderOn"] = on == true end
end

local function sig_cont(hunter, vals)
    local list = { { "CF.PARRY_IMMDIATE", V.CF_PARRY_IMMDIATE }, { "CF.PARRY_COMBO", V.CF_PARRY_COMBO },
        { "CF.WP_ATTACK_COLLISION_ON", V.CF_WP_COLLISION } }
    for _, it in ipairs(list) do
        if it[2] ~= nil then
            vals[it[1]] = hunter:call("checkHunterContinueFlag(app.HunterDef.CONTINUE_FLAG)", it[2]) == true
        end
    end
end

-- 动画层：PLAN P15 的取法 GameObject → getComponent(via.motion.Motion) → getLayer(0)
local function anim_read(hunter)
    local go = hunter:call("get_GameObject")
    local mot = go and T_MOTION and go:call("getComponent(System.Type)", T_MOTION)
    local layer = mot and mot:call("getLayer(System.UInt32)", 0)
    if not layer then return nil, nil, nil end
    return layer:call("get_Frame"), layer:call("get_Speed"), layer:call("get_MotionID")
end

local function sig_tick(now)
    local cur = S.cur
    if not (cur.ok and cur.gs and (cur.fam or now <= S.sig_until)) or not S.hunter then
        S.sig_prev = nil
        return
    end
    local hunter = S.hunter
    local vals = {}
    if MODS.SIG.on then opt("SIG", sig_seq, hunter, vals) end
    if MODS.CONT.on then opt("CONT", sig_cont, hunter, vals) end
    local frame, speed, motion = nil, nil, nil
    if MODS.ANIM.on then frame, speed, motion = opt("ANIM", anim_read, hunter) end
    emit("ANIM", now, "t", now, "t4", "raw", cur.raw, "f4", "frame", frame, "f2", "speed", speed, "f3",
        "motion", motion, "i")
    -- 窗口刚开始时只记为 1 的信号（其余默认 0），之后有变化才记
    local prev = S.sig_prev
    for _, name in ipairs(SIG_NAMES) do
        local v = vals[name]
        if v ~= nil then
            local pv = prev and prev[name]
            if (pv == nil and v) or (pv ~= nil and pv ~= v) then
                emit("SIG", now, "t", now, "t4", "name", name, "s", "val", v, "b", "raw", cur.raw, "f4",
                    "chara", cur.chara, "f4", "frame", frame, "f2")
            end
        end
    end
    S.sig_prev = vals
end

-- ========================================================================
-- 预告持有者对照 HOLD（P16）：每 5 帧读 holder 列表，变化才进 JSON
-- ========================================================================
local function hold_tick(now)
    local hunter = S.hunter
    if not hunter then return end
    local holder = hunter:call("get_AttackAreaResult")
    local list = holder and holder:get_field("_AttackAreaResultList")
    local n = list and list:call("get_Count") or 0
    local present, addrs = {}, {}
    for i = 0, math.min(n, K.TRACK_MAX) - 1 do
        local it = list:call("get_Item", i)
        if it then
            local a = it:get_address()
            present[a] = true
            addrs[#addrs + 1] = safe_fmt("%X", math.tointeger(a) or 0)
        end
    end
    local sig = table.concat(addrs, ",")
    if sig ~= S.hold_sig then
        S.hold_sig = sig
        emit("HOLD", now, "t", now, "t4", "n", n, "i", "addrs", sig ~= "" and sig or nil, "s")
    end
    for _, tr in pairs(S.trk) do
        local ep = tr.ep
        if ep then
            ep.hold_n = ep.hold_n + 1
            if present[tr.addr] then ep.hold_hit = ep.hold_hit + 1 end
        end
    end
end

-- ========================================================================
-- 钩子
-- ========================================================================
-- 预告消息（P04）+ cMsgParrySuccess（PMSG）
local function pmsg_body(msg)
    local now = os.clock()
    local st = ename("PS", msg:call("get_State"))
    emit("PMSG", now, "t", now, "t4", "state", st, "s")
    note_event({ k = "PMSG", t = now, state = st })
end

-- 发送者 GameObject 名和它身上 EnemyCharacter 的地址。PLAN P23 的「攻击者相同」首选「发送者或攻击者的
-- EnemyCharacter 地址」：发送者若就是怪物本体（P04 待核实），这个地址就等于 CT 的 atk_em，离线可直接比对，
-- 不用依赖两边的 SystemIndex 是不是同一套编号。按 GameObject 地址缓存（每秒几十条消息），30 s 清一次
local function sender_info(msg)
    local go = msg:call("get_SendGameObject")
    if not go then return nil, nil end
    local ga = go:get_address()
    local c = S.snd_cache[ga]
    if c == nil then
        local enemy = go_enemy(go)
        c = { name = go_name(go), em = enemy and enemy:get_address() or false }
        S.snd_cache[ga] = c
    end
    return c.name, c.em or nil
end

-- findEnemy 不可用时的退路：发送者 GameObject 上的 EnemyCharacter（是否怪物本体待核实）
local function remember_sender(msg, idx, key)
    local enemy = go_enemy(msg:call("get_SendGameObject"))
    if enemy then em_remember(idx, key, enemy) end
end

local function msg_body(args)
    local msg = sdk.to_managed_object(args[3])
    if not msg then return end
    local tname = msg:get_type_definition():get_full_name()
    if tname == "app.game_message.cMsgParrySuccess" then
        if MODS.PMSG.on then run("PMSG", pmsg_body, msg) end
        return
    end
    if tname ~= "app.game_message.cMsgEmAttackAreaResult" then return end
    local r = msg:call("get_AttackAreaResult")
    if not r then return end
    -- 收到就立刻读（对象被怪物复用，PLAN P04）
    local now = os.clock()
    local addr = r:get_address()
    local tgt = r:call("get_TargetCharacter")
    local my_addr = S.hc.addr
    if my_addr == nil then      -- 刚恢复记录、帧回调还没跑过：当场取一次主角地址
        local h = get_hunter()
        my_addr = h and h:get_address() or nil
    end
    local tme = tgt ~= nil and my_addr ~= nil and tgt:get_address() == my_addr
    local idx = r:call("get_EmSystemIndex")
    local key = em_key(r:call("get_EmID"), idx)
    local kid = r:call("get_KeepActionID")
    local keep = kid and act_str(kid:get_field("_Category"), kid:get_field("_Index")) or nil
    local rt = r:call("get_ResultType")
    local n = nil
    if MODS.ITEM.on then n = opt("ITEM", list_count, r) end
    local area = r:call("get_MergedAreaData")
    local ms = area and area:get_field("AttackStartFrame") or nil
    local me = area and area:get_field("AttackEndFrame") or nil
    local cd = r:call("getClosestDetectedData")
    local fin = r:call("get_IsAttackFinished")
    local snd, snd_em = nil, nil
    if MODS.SND.on then snd, snd_em = opt("SND", sender_info, msg) end
    local isnew = nil
    if tme and S.rec then isnew = track_msg(r, addr, key, idx, keep, now, snd, snd_em) end
    emit("MSG", now, "t", now, "t4", "f", S.f, "i", "obj", addr, "x", "new", isnew, "b", "tme", tme, "b",
        "em", key, "s", "keep", keep, "s", "rt", ename("RT", rt), "s", "n", n, "i", "mstart", ms, "f1",
        "mend", me, "f1", "closest", cd and cd:get_address() or nil, "x", "fin", fin, "b", "snd", snd, "s",
        "snd_em", snd_em, "x")
    if tme and not MODS.FIND.on and MODS.SND.on and idx ~= nil then opt("SND", remember_sender, msg, idx, key) end
end

-- 钩子体耗时累计（PERF 的 hook_ms_ps，C9(d) 的开销占比用）。REF 的钩子分发开销本身 os.clock 量不到
local function hook_time(t0)
    local P = S.perf
    P.hook_ms = P.hook_ms + (os.clock() - t0) * 1000.0
end

local function msg_pre(args)
    HN.msg = HN.msg + 1
    if not S.rec or paused(MODS.MSG) then return end
    local t0 = os.clock()
    local ok, err = pcall(msg_body, args)
    if not ok then report_error("MSG", err) end
    hook_time(t0)
end

-- 主角被敌方打中 CT（P09）：pre 读 HitInfo，post 读 RESULT 后写一行
local function ct_pre_body(args, shell)
    local hunter = sdk.to_managed_object(args[2])
    if not hunter or not hunter:call("get_IsMaster") then return false end
    local info = sdk.to_managed_object(args[3])
    if not info then return false end
    local owner = nil
    if shell then owner = info:call("getActualAttackOwner") end
    if not owner then owner = info:call("get_AttackOwner") end
    local enemy = go_enemy(owner)
    if not enemy then return false end
    local now = os.clock()
    local dmgobj = info:call("get_DamageObj")
    local layer = info:call("get_CollisionLayer")
    -- BLADE：刀上的抵消碰撞（被打中的是武器、层 ATTACK_PARRY_GET）；BODY：层 ATTACK_GET
    local cls = "OTHER"
    if layer ~= nil and layer == V.LAYER_PARRY_GET and (dmgobj == nil or dmgobj:get_address() ~= S.hc.go_addr) then
        cls = "BLADE"
    elseif layer ~= nil and layer == V.LAYER_GET then
        cls = "BODY"
    end
    local wh = hunter:call("get_WeaponHandling")
    local ps = wh and wh:call("get_ParryState") or nil
    local st = hunter:call("get_HunterStatus")
    local flags = st and st:get_field("_HunterStatusFlag")
    local sa = nil
    if flags and V.SF_SA ~= nil then sa = flags:call("check(System.UInt32)", V.SF_SA) == true end
    local pos = nil
    if MODS.CTPOS.on then pos = opt("CTPOS", info.call, info, "get_Position") end
    local key, idx = enemy_key(enemy)
    S.ct_k = S.ct_k + 1
    return {
        t = now, f = S.f, k = S.ct_k, atk = go_name(owner), atk_em = enemy:get_address(), em = key, idx = idx,
        dmgobj = go_name(dmgobj), layer = ename("LAYER", layer), cls = cls, ps = ename("PS", ps),
        act = S.cur.act_s, raw = S.cur.raw, chara = S.cur.chara, sa = sa, shell = shell, pos = pos,
        in_slash = S.cur.slash == true, enemy = enemy, hunter = hunter,
    }
end

local function ct_post_body(rec, retval)
    local res = ename("HR", sdk.to_int64(retval) & 0xFFFFFFFF)
    local p = rec.pos
    -- 每帧、每个攻击者、每种分类（BLADE/BODY/OTHER）的第一次接触总是写日志（c_first 和「接住那一帧同时
    -- 有身体接触」都靠它）；同帧多个碰撞体的其余接触走令牌桶
    local lkey = tostring(rec.atk_em) .. rec.cls
    local mode = nil
    if not S.ct_logged[lkey] then
        S.ct_logged[lkey] = true
        mode = M_FORCE
    end
    emit_core("CT", rec.t, mode, "t", rec.t, "t4", "f", rec.f, "i", "k", rec.k, "i", "atk", rec.atk, "s",
        "atk_em", rec.atk_em, "x", "dmgobj", rec.dmgobj, "s", "layer", rec.layer, "s", "cls", rec.cls, "s",
        "ps", rec.ps, "s", "res", res, "s", "act", rec.act, "s", "raw", rec.raw, "f4", "sa", rec.sa, "b",
        "shell", rec.shell, "b", "px", p and p.x, "f2", "py", p and p.y, "f2", "pz", p and p.z, "f2",
        "em", rec.em, "s", "chara", rec.chara, "f4")
    note_event({ k = "CT", t = rec.t, cls = rec.cls, sa = rec.sa, in_slash = rec.in_slash })
    -- 每帧每个攻击者的第一次接触：EMINFO + POSE（PLAN P13/P17「每次接触时」，多碰撞体同帧只记一次）
    if not S.ct_first[rec.atk_em] then
        S.ct_first[rec.atk_em] = true
        if MODS.EMSTATE.on then run("EMSTATE", eminfo, rec.t, "CT", rec.enemy, rec.em, nil) end
        if MODS.POSE.on then opt("POSE", pose_emit, rec.t, "CT", rec.hunter, rec.enemy, nil, rec.em) end
    end
    em_remember(rec.idx, rec.em, rec.enemy)
end

local function make_ct_hooks(shell)
    local stack, stackf = {}, {}
    local modname = shell and "SHELL" or "CT"
    local counter = shell and "shell" or "ct"
    local function pre(args)
        HN[counter] = HN[counter] + 1
        local rec = false
        if S.rec and MODS[modname].on and not paused(MODS[modname]) then
            local t0 = os.clock()
            local ok, res = pcall(ct_pre_body, args, shell)
            if ok then rec = res or false else report_error(modname, res) end
            hook_time(t0)
        end
        stack[#stack + 1] = rec
        stackf[#stackf + 1] = S.f
    end
    local function post(retval)
        local n = #stack
        local rec = stack[n]
        stack[n], stackf[n] = nil, nil
        if rec then
            local t0 = os.clock()
            local ok, err = pcall(ct_post_body, rec, retval)
            if not ok then report_error(modname, err) end
            hook_time(t0)
        end
        return retval
    end
    return pre, post, stack, stackf
end

local ct_pre, ct_post, CT_STACK, CT_STACKF = make_ct_hooks(false)
local sh_pre, sh_post, SH_STACK, SH_STACKF = make_ct_hooks(true)

-- HP 损失 DMG（P10）：pre 记下主角，post 读 DamageInfo（AGParry 实测）
local DMG_STACK, DMG_STACKF = {}, {}

local function dmg_pre_body(args)
    local hunter = sdk.to_managed_object(args[2])
    if not hunter or not hunter:call("get_IsMaster") then return false end
    local info = sdk.to_managed_object(args[3])
    local enemy = info and go_enemy(info:call("get_AttackOwner")) or nil
    return { hunter = hunter, em = enemy and (enemy_key(enemy)) or nil }
end

local function dmg_post_body(rec)
    local di = rec.hunter:call("get_DamageInfo")
    if not di then return end
    local now = os.clock()
    local total = di:get_field("_TotalDamage")
    emit("DMG", now, "t", now, "t4", "total", total, "f1", "react", ename("GR", di:get_field("_GuardReaction")), "s",
        "em", rec.em, "s")
    note_event({ k = "DMG", t = now, total = type(total) == "number" and total or 0 })
end

local function dmg_pre(args)
    HN.dmg = HN.dmg + 1
    local rec = false
    if S.rec and not paused(MODS.DMG) then
        local t0 = os.clock()
        local ok, res = pcall(dmg_pre_body, args)
        if ok then rec = res or false else report_error("DMG", res) end
        hook_time(t0)
    end
    DMG_STACK[#DMG_STACK + 1] = rec
    DMG_STACKF[#DMG_STACKF + 1] = S.f
end

local function dmg_post(retval)
    local n = #DMG_STACK
    local rec = DMG_STACK[n]
    DMG_STACK[n], DMG_STACKF[n] = nil, nil
    if rec then
        local t0 = os.clock()
        local ok, err = pcall(dmg_post_body, rec)
        if not ok then report_error("DMG", err) end
        hook_time(t0)
    end
    return retval
end

-- 抵消事件 PH/PS（P11）：用主角 WeaponHandling 地址过滤（AGPState 实测）
local function ph_body(args)
    local h = sdk.to_managed_object(args[2])
    if not h or S.hc.wh_addr == nil or h:get_address() ~= S.hc.wh_addr then return end
    local now = os.clock()
    local st = ename("PS", sdk.to_int64(args[3]) & 0xFFFFFFFF)
    local tgo = sdk.to_managed_object(args[4])
    local delay = nil
    if MODS.PHDELAY.on then delay = opt("PHDELAY", delay_of, tgo) end
    emit("PH", now, "t", now, "t4", "state", st, "s", "target", go_name(tgo), "s", "raw", S.cur.raw, "f4",
        "chara", S.cur.chara, "f4", "delay", delay, "f1")
    note_event({ k = "PH", t = now, state = st })
end

local function ps_body(args)
    local h = sdk.to_managed_object(args[2])
    if not h or S.hc.wh_addr == nil or h:get_address() ~= S.hc.wh_addr then return end
    local now = os.clock()
    local st = ename("PS", sdk.to_int64(args[3]) & 0xFFFFFFFF)
    emit("PS", now, "t", now, "t4", "state", st, "s")
    note_event({ k = "PS", t = now, state = st })
end

local function ph_pre(args)
    HN.ph = HN.ph + 1
    if not S.rec or paused(MODS.PH) then return end
    local t0 = os.clock()
    local ok, err = pcall(ph_body, args)
    if not ok then report_error("PH", err) end
    hook_time(t0)
end

local function ps_pre(args)
    HN.ps = HN.ps + 1
    if not S.rec or paused(MODS.PH) then return end
    local t0 = os.clock()
    local ok, err = pcall(ps_body, args)
    if not ok then report_error("PH", err) end
    hook_time(t0)
end

-- 上捞斩砍中怪物 EMHIT（P12）：只在 (2,23)~(2,29) 期间、攻击者是主角时记
local function emhit_body(args)
    local info = sdk.to_managed_object(args[3])
    local atk = info and info:call("get_AttackOwner")
    if not atk or S.hc.go_addr == nil or atk:get_address() ~= S.hc.go_addr then return end
    local now = os.clock()
    local enemy = sdk.to_managed_object(args[2])
    local key = enemy and (enemy_key(enemy)) or nil
    emit("EMHIT", now, "t", now, "t4", "raw", S.cur.raw, "f4", "chara", S.cur.chara, "f4",
        "dmgobj", go_name(info:call("get_DamageObj")), "s", "layer", ename("LAYER", info:call("get_CollisionLayer")), "s",
        "em", key, "s")
    note_event({ k = "EMHIT", t = now })
    if enemy and MODS.EMSTATE.on then opt("EMSTATE", em_watch, enemy, now) end
end

local function emhit_pre(args)
    HN.emhit = HN.emhit + 1
    if not S.rec or not S.cur.ptfam or paused(MODS.EMHIT) then return end
    local t0 = os.clock()
    local ok, err = pcall(emhit_body, args)
    if not ok then report_error("EMHIT", err) end
    hook_time(t0)
end

-- 怪物的攻击被抵消 EMPARRY（P11，可选）：参数对象地址，离线和条目的 AttackParam 地址比对
local function emparry_body(args)
    local now = os.clock()
    local enemy = sdk.to_managed_object(args[2])
    local ap = sdk.to_managed_object(args[4])
    emit("EMPARRY", now, "t", now, "t4", "em", enemy and (enemy_key(enemy)) or nil, "s",
        "ap", ap and ap:get_address() or nil, "x")
end

local function emparry_pre(args)
    HN.emparry = HN.emparry + 1
    if not S.rec or not MODS.EMPARRY.on then return end
    local t0 = os.clock()
    local ok, err = pcall(emparry_body, args)
    if not ok then report_error("EMPARRY", err) end
    hook_time(t0)
end

-- 攻击判定激活 ATK（P14，可选）：调用频率未知（HitboxViewer 也钩它），带自停守卫
local function atk_body(args)
    local sw = sdk.to_managed_object(args[2])
    local hc = sw and sw:get_field("_HitController")
    local owner = hc and hc:call("get_Owner")
    if not owner then return end
    local oaddr = owner:get_address()
    local key = S.atk_cache[oaddr]
    if key == nil then
        local enemy = go_enemy(owner)
        if enemy then
            -- 读不到 em 编号（EMID 停用）时退回 EnemyCharacter 地址，至少能和 CT 的 atk_em 对上
            key = enemy_key(enemy) or ("@" .. safe_fmt("%X", math.tointeger(enemy:get_address()) or 0))
        else
            key = false
        end
        S.atk_cache[oaddr] = key
    end
    if not key then return end
    local now = os.clock()
    emit("ATK", now, "t", now, "t4", "em", key, "s", "a4", sdk.to_int64(args[4]) & 0xFFFFFFFF, "i",
        "a5", sdk.to_int64(args[5]) & 0xFFFFFFFF, "i")
end

local function atk_pre(args)
    if atk_off then return end      -- 第一行：自停 / 停用 / 停止记录时立即返回
    HN.atk = HN.atk + 1
    if (sdk.to_int64(args[3]) & 1) == 0 then return end   -- 关闭判定的调用（每帧都有）直接返回
    S.atk_act = S.atk_act + 1
    local t0 = os.clock()
    local ok, err = pcall(atk_body, args)
    if not ok then report_error("ATK", err) end
    hook_time(t0)
end

-- ========================================================================
-- 帧时钟、PERF、进度、JSON（P02、P21、P22）
-- ========================================================================
local APP_PTR, APP_TD = nil, nil

local function read_gdt()
    if APP_PTR == nil then
        APP_PTR = sdk.get_native_singleton("via.Application")
        APP_TD = sdk.find_type_definition("via.Application")
    end
    if not APP_PTR or not APP_TD then return nil end
    return sdk.call_native_func(APP_PTR, APP_TD, "get_DeltaTime")
end

local function hooks_str(period)
    local parts = {}
    for i, k in ipairs(HN_ORDER) do
        parts[i] = k .. ":" .. safe_fmt("%.1f", HN[k] / period)
    end
    return table.concat(parts, ",")
end

local function perf_emit(now)
    local P = S.perf
    local period = now - P.t0
    if period < K.PERF_PERIOD then return end
    local fps = P.frames / period
    local atk_rate = HN.atk / period
    local lua_avg = P.lua_n > 0 and P.lua_sum / P.lua_n or nil
    local hooks = hooks_str(period)
    local gdt = nil
    if MODS.GDT.on then gdt = opt("GDT", read_gdt) end
    -- hook_ms_ps：钩子体每秒耗时（ms/s）；actfail：容忍期内跳过的读主角失败帧（瞬时异常）
    emit("PERF", now, "t", now, "t4", "fps", fps, "f1", "maxdt", P.maxdt, "f4", "hooks", hooks, "s",
        "lua_ms_avg", lua_avg, "f3", "lua_ms_max", P.lua_max, "f3", "tracked", S.n_trk, "i", "red", S.n_red, "i",
        "yellow", S.n_yellow, "i", "logdrop", S.log_drop, "i", "buf", #S.jbuf, "i", "files", S.files, "i",
        "gdt", gdt, "f4", "hook_ms_ps", P.hook_ms / period, "f3", "actfail", P.actfail, "i",
        "red_state", S.red, "b")
    S.perf_text = safe_fmt("fps %.1f maxdt %.3f lua %.3f/%.3f ms | %s", fps, P.maxdt, lua_avg or 0, P.lua_max, hooks)
    -- fps 基线之后下降超过 10% → HUD 提示
    local base = S.fpsb.base
    if base and base > 0 and fps < base * (1 - K.FPS_DROP) then
        S.fps_warn = (1 - fps / base) * 100
    else
        S.fps_warn = nil
    end
    -- activateAttack 频率守卫：激活调用连续 3 个周期 >3000 次/秒 → 钩子第一行直接 return（只数激活，见 K.ATK_LIMIT）
    local act_rate = S.atk_act / period
    if not atk_off then
        if act_rate > K.ATK_LIMIT then S.atk_hi = S.atk_hi + 1 else S.atk_hi = 0 end
        if S.atk_hi >= K.ATK_PERIODS then
            S.atk_guard = true
            report_error("ATK", safe_fmt("rate guard: activateAttack(true) %.0f calls/s (all %.0f) for %d periods",
                act_rate, atk_rate, S.atk_hi))
            atk_off = true
        end
    end
    S.atk_act = 0
    for _, k in ipairs(HN_ORDER) do HN[k] = 0 end
    P.t0, P.frames, P.maxdt, P.lua_sum, P.lua_n, P.lua_max = now, 0, 0, 0, 0, 0
    P.hook_ms, P.actfail = 0, 0
end

local function clock_tick(now)
    local dt = S.t_prev and (now - S.t_prev) or nil
    S.t_prev = now
    S.dt = dt or 0
    if not dt then return end
    S.bucket = math.min(K.LOG_BURST, S.bucket + dt * K.LOG_RATE)
    local P = S.perf
    P.frames = P.frames + 1
    if dt > P.maxdt then P.maxdt = dt end
    -- fps 基线（只给 HUD 提示）：这一场景开始后（加载、主角对象变化、一帧超过 1 s 之后）前 10 s，
    -- 每秒一个样本，取中位数
    if dt > K.FPS_GAP_RESET then fps_base_reset(now) end
    local B = S.fpsb
    if not B.done then
        B.n = B.n + 1
        if now - B.sec_t >= 1.0 then
            B.samples[#B.samples + 1] = B.n / (now - B.sec_t)
            B.n, B.sec_t = 0, now
        end
        if now - B.t0 >= K.FPS_BASE_WIN then
            B.done = true
            B.base = median(B.samples)
        end
    end
    if not S.rec then return end
    if dt > K.HITCH_DT then
        local gdt = nil
        if MODS.GDT.on then gdt = opt("GDT", read_gdt) end
        emit("HITCH", now, "t", now, "t4", "f", S.f, "i", "dt", dt, "f4", "gdt", gdt, "f4")
        if dt > K.GAP_DT then emit("GAP", now, "t", now, "t4", "f", S.f, "i", "dt", dt, "f4", "gdt", gdt, "f4") end
    end
    perf_emit(now)
end

local function phase_name()
    if S.phase_b then return "B" end
    if S.swings >= K.SWINGS then return "A2" end
    return "A1"
end

local function prog_tick(now)
    local ph = phase_name()
    local sig = table.concat({ ph, S.swings, S.scan_pt, S.b_pt, S.b_contact, S.b_danger }, ",")
    if sig ~= S.prog_sig or now - S.prog_t >= K.PROG_PERIOD then
        if sig ~= S.prog_sig and now - S.prog_t < 1.0 then return end   -- 变化太密时最多 1 行/秒
        S.prog_sig, S.prog_t = sig, now
        emit("PROG", now, "t", now, "t4", "phase", ph, "s", "swings", S.swings, "i", "scan_pt", S.scan_pt, "i",
            "b_pt", S.b_pt, "i", "b_contact", S.b_contact, "i", "b_danger", S.b_danger, "i")
    end
end

-- 写 JSON（P21）：只写上次写出之后新增的记录；返回值为假计一次核心错误
local function json_flush(why)
    if #S.jbuf == 0 then return true end
    if S.seq >= K.JSON_SEQ_MAX then
        if not S.seq_full then
            S.seq_full = true
            report_error("JSON", "seq limit reached (" .. tostring(K.JSON_SEQ_MAX) .. "), " .. tostring(why))
        end
        return false
    end
    S.seq = S.seq + 1
    local name = safe_fmt("APCal_%d_%d.json", S.session, S.seq)
    -- why = idle / valve / hard / button / stop / reset：离线据最后一份的 why 判断这一轮有没有正常收尾
    local data = { kind = "APCal", ver = VERSION, session = S.session, seq = S.seq, why = tostring(why),
        records = S.jbuf }
    local ok, res = pcall(json.dump_file, name, data, -1)
    S.last_write_t = os.clock()
    if ok and res then
        S.files = S.files + 1
        S.last_file = name
        S.jbuf = {}
        return true
    end
    report_error("JSON", "dump_file " .. name .. " failed (" .. tostring(why) .. "): " .. tostring(res))
    return false
end

local function any_busy()
    for _, tr in pairs(S.trk) do
        if tr.busy then return true end
    end
    return false
end

local function json_tick(now)
    -- 空闲帧：没有未结束的回合、不在 (2,21)~(2,29)、距上次写出 ≥60 s（写盘会卡帧，不能在测量途中写）
    if now - S.last_write_t >= K.JSON_IDLE and not S.pt and not S.cur.fam and not any_busy() then
        json_flush("idle")
    elseif #S.jbuf >= K.JSON_VALVE and now - S.valve_t >= K.JSON_VALVE_RETRY then
        -- 安全阀：缓冲太大（B 段一直按住蓄力，空闲帧可能很少）时不等空闲帧，但仍不压在判定时机上：
        -- 没有 PT、不在 (2,23)~(2,29)、没有未结束回合才写（蓄力中可以写）；到硬上限才无条件写
        local calm = not S.pt and not S.cur.ptfam and not any_busy()
        if calm or #S.jbuf >= K.JSON_HARD then
            S.valve_t = now
            json_flush(calm and "valve" or "hard")
        end
    end
end

local function prune_recent(now)
    local r = S.recent
    if #r == 0 then return end
    local keep = {}
    for _, e in ipairs(r) do
        if now - e.t <= K.RECENT_KEEP then keep[#keep + 1] = e end
    end
    S.recent = keep
end

-- 钩子 pre/post 配对的兜底：两帧前还没等到 post 的记录直接丢掉
local function clear_stale_stacks()
    local f = S.f
    for _, pair in ipairs({ { CT_STACK, CT_STACKF }, { SH_STACK, SH_STACKF }, { DMG_STACK, DMG_STACKF } }) do
        local st, sf = pair[1], pair[2]
        if #st > 0 and sf[1] and sf[1] < f - 1 then
            for i = #st, 1, -1 do st[i], sf[i] = nil, nil end
        end
    end
end

-- 停止 / 恢复记录（菜单开关、90 分钟自停）
local function set_rec(on, why)
    local now = os.clock()
    if on == S.rec then return end
    if not on then
        if S.pt then pt_close(now, "stop") end
        release_all_tracks(now, "stop")
        em_release_all()
        -- STOP / RESUME 不在 CONTRACT 4.2 表里：只是标出记录中断的区间，离线可忽略
        emit_core("STOP", now, M_FORCE, "t", now, "t4", "why", why, "s")
        json_flush("stop")
        S.rec = false
        atk_off = true
    else
        S.rec = true
        S.rec_t0 = now
        S.auto_stopped = false
        atk_off = (not MODS.ATK.on) or S.atk_guard
        S.hc, S.cur = {}, { ok = false }
        S.t_prev = nil
        local P = S.perf
        P.t0, P.frames, P.maxdt, P.lua_sum, P.lua_n, P.lua_max = now, 0, 0, 0, 0, 0
        P.hook_ms, P.actfail = 0, 0
        for _, k in ipairs(HN_ORDER) do HN[k] = 0 end
        emit_core("RESUME", now, M_FORCE, "t", now, "t4", "why", why, "s")
    end
end

-- 每帧（帧开头，PLAN 求值时机同 rc）
local function frame_body(now)
    if now - S.rec_t0 >= K.AUTO_STOP then
        S.auto_stopped = true
        set_rec(false, "auto90")
        return
    end
    S.ct_k = 0
    if next(S.ct_first) then S.ct_first = {} end
    if next(S.ct_logged) then S.ct_logged = {} end
    clear_stale_stacks()
    prune_recent(now)
    if S.now - S.atk_cache_t > K.EM_CACHE_AGE then
        S.atk_cache, S.atk_cache_t = {}, S.now
        S.snd_cache = {}
    end
    run("ACT", act_tick, now)
    run("PT", pt_tick, now)
    run("SERIES", track_tick, now)
    if MODS.EMSTATE.on then run("EMSTATE", em_tick, now) end
    -- SIG/CONT/ANIM 各自用 opt 分别停用；外层的拼装出错算在 ANIM 头上（不连带停掉 SIG/CONT）
    if MODS.SIG.on or MODS.CONT.on or MODS.ANIM.on then
        local ok, err = pcall(sig_tick, now)
        if not ok then report_error("ANIM", err) end
    end
    if MODS.HOLD.on and S.f % K.HOLD_EVERY == 0 and S.cur.ok then run("HOLD", hold_tick, now) end
    run("MENU", prog_tick, now)
    run("JSON", json_tick, now)
end

local function on_pre_update()
    local t0 = os.clock()
    S.f = S.f + 1
    S.now = t0
    run("CLOCK", clock_tick, t0)
    if S.rec then
        local ok, err = pcall(frame_body, t0)
        if not ok then report_error("ACT", err) end
    end
    S.hunter = nil      -- 主角对象不跨帧持有
    err_flush(t0)
    local ms = (os.clock() - t0) * 1000
    local P = S.perf
    P.lua_sum = P.lua_sum + ms
    P.lua_n = P.lua_n + 1
    if ms > P.lua_max then P.lua_max = ms end
end

-- ========================================================================
-- 加载自检与表头（P01）
-- ========================================================================
local ATK_SIG = "activateAttack(System.Boolean, System.UInt32, System.UInt32, System.Nullable`1<System.Boolean>, "
    .. "app.Hit.HIT_ID_GROUP, System.Nullable`1<System.Single>, System.Nullable`1<System.Single>)"
local LIST_DD = "System.Collections.Generic.List`1<app.AttackAreaResult.DetectedData>"

-- { 模块, 类型, 方法签名, 字段名 }（用声明它的类型核对；2026-10-10 MCP 只读 get_type 全部核对过）
local MANIFEST = {
    { "ACT", "app.PlayerManager", "getMasterPlayer()" },
    { "ACT", "app.cPlayerManageInfo", "get_Character()" },
    { "ACT", "app.CharacterBase", "get_BaseActionController()" },
    { "ACT", "app.HunterCharacter", "get_WeaponType()" },
    { "ACT", "app.HunterCharacter", "get_HunterStatus()" },
    { "ACT", "ace.cActionController", "get_CurrentActionID()" },
    { "ACT", "ace.cActionController", "get_CurrentAction()" },
    { "ACT", "ace.ACTION_ID", nil, "_Category" },
    { "ACT", "ace.ACTION_ID", nil, "_Index" },
    { "ACT", "app.cCharacterActionBase", nil, "_RawTotalElapsedSecond" },
    { "ACT", "app.cHunterStatus", nil, "_HunterStatusFlag" },
    { "ACT", "ace.cSafeContinueFlagGroup", "check(System.UInt32)" },
    { "ACT", "#enum", "SF", "SUPER_ARMOR" },
    { "ACT", "#enum", "SF", "HYPER_ARMOR" },
    { "ACT", "#enum", "SF", "NO_DAMAGE" },
    { "CHARA", "app.cCharacterActionBase", "get_CharaElapsedSecond()" },
    { "LV", "app.cHunterWp00Handling", nil, "_ChargeLevel" },
    { "MSG", "app.cMasterPlayerControllerEntity", "receiveGameMessage(ace.cGameMessage)" },
    { "MSG", "app.game_message.cMsgEmAttackAreaResult", "get_AttackAreaResult()" },
    { "MSG", "app.AttackAreaResult", "get_TargetCharacter()" },
    { "MSG", "app.AttackAreaResult", "get_ResultType()" },
    { "MSG", "app.AttackAreaResult", "get_IsAttackFinished()" },
    { "MSG", "app.AttackAreaResult", "get_KeepActionID()" },
    { "MSG", "app.AttackAreaResult", "get_EmID()" },
    { "MSG", "app.AttackAreaResult", "get_EmSystemIndex()" },
    { "MSG", "app.AttackAreaResult", "getClosestDetectedData()" },
    { "MSG", "app.AttackAreaResult", "get_DetectedDataList()" },
    { "MSG", "app.AttackAreaResult", "get_MergedAreaData()" },
    { "MSG", "app.AttackAreaData", nil, "AttackStartFrame" },
    { "MSG", "app.AttackAreaData", nil, "AttackEndFrame" },
    { "MSG", "#enum", "RT", "DANGER" },
    { "SND", "app.game_message.cMsgEmAttackAreaResult", "get_SendGameObject()" },
    { "PMSG", "app.game_message.cMsgParrySuccess", "get_State()" },
    { "SERIES", "app.AttackAreaResult.DetectedData", "get_ResultType()" },
    { "SERIES", "app.AttackAreaResult.DetectedData", "get_HitStartRemainFrame()" },
    { "SERIES", "app.AttackAreaResult.DetectedData", "get_HitEndRemainFrame()" },
    { "ITEM", LIST_DD, "get_Count()", nil, "List<DetectedData>.get_Count" },
    { "ITEM", LIST_DD, "get_Item(System.Int32)", nil, "List<DetectedData>.get_Item" },
    { "NULL", "app.AttackAreaResult.DetectedData", "get_ShellIndex()" },
    { "NULL", "app.AttackAreaResult.DetectedData", "get_RequestSetID()" },
    { "NULL", "System.Nullable`1<System.Int32>", nil, "_HasValue", "Nullable<Int32>._HasValue" },
    { "NULL", "System.Nullable`1<System.Int32>", nil, "_Value", "Nullable<Int32>._Value" },
    { "AP", "app.AttackAreaResult.DetectedData", "get_AttackParam()" },
    { "AP", "app.cAttackParamBase", nil, "_GuardType" },
    { "AP", "app.cAttackParamBase", nil, "_DamageType" },
    { "AP", "app.cAttackParamBase", nil, "_VersusGuardPower" },
    { "AP", "app.cAttackParamBase", nil, "_UserData" },
    { "AP", "app.cAttackParamEm", nil, "_DamageLevel" },
    { "AP", "app.cAttackParamEm", nil, "_AttackFilterType" },
    { "AP", "app.cAttackParamEm", nil, "_IsParryBreak" },
    { "AP", "app.cAttackParamEm", nil, "_IsParryFix" },
    { "AP", "app.cAttackParamEm", nil, "_IsParryStockOnly" },
    { "AP", "app.cAttackParamEm", nil, "_IsTechGuardBreak" },
    { "AP", "app.cAttackParamEm", nil, "_IsBlockEnable" },
    { "AP", "via.physics.RequestSetColliderUserData", "get_Name()" },
    { "OBB", "app.AttackAreaResult.DetectedData", "get_Obb()" },
    { "OBB", "via.OBB", "get_Position()" },
    { "OBB", "via.OBB", "get_Extent()" },
    { "CT", "app.HunterCharacter", "evHit_DamagePreProcess(app.HitInfo)" },
    { "CT", "app.HunterCharacter", "get_IsMaster()" },
    { "CT", "app.HunterCharacter", "get_WeaponHandling()" },
    { "CT", "app.HitInfo", "get_AttackOwner()" },
    { "CT", "app.HitInfo", "get_DamageObj()" },
    { "CT", "app.HitInfo", "get_CollisionLayer()" },
    { "CT", "via.GameObject", "getComponent(System.Type)" },
    { "CT", "via.GameObject", "get_Name()" },
    { "CT", "via.Component", "get_GameObject()" },
    { "CT", "app.cHunterWeaponHandlingBase", "get_ParryState()" },
    { "CT", "#enum", "LAYER", "ATTACK_GET" },
    { "CT", "#enum", "LAYER", "ATTACK_PARRY_GET" },
    { "CT", "#enum", "HR", "SUCCESS" },
    { "CT", "#type", "app.EnemyCharacter" },
    { "CTPOS", "app.HitInfo", "get_Position()" },
    { "SHELL", "app.HunterCharacter", "evHit_ShellDamagePreProcess(app.HitInfo)" },
    { "SHELL", "app.HitInfo", "getActualAttackOwner()" },
    { "DMG", "app.HunterCharacter", "evHit_Damage(app.HitInfo)" },
    { "DMG", "app.HunterCharacter", "get_DamageInfo()" },
    { "DMG", "app.cHunterDamageInfo", nil, "_TotalDamage" },
    { "DMG", "app.cHunterDamageInfo", nil, "_GuardReaction" },
    { "PH", "app.cHunterWeaponHandlingBase", "onParryHit(app.HunterDef.PARRY_STATE, via.GameObject, via.vec3)" },
    { "PH", "app.cHunterWeaponHandlingBase", "onParrySuccess(app.HunterDef.PARRY_STATE)" },
    { "PH", "#enum", "PS", "WAIT" },
    { "PHDELAY", "app.cEmModuleHit", nil, "DelayParryInfo" },
    { "PHDELAY", "app.cEmModuleHit.cParryInfo", nil, "DelayFrame" },
    { "EMHIT", "app.EnemyCharacter", "evHit_DamagePreProcess(app.HitInfo)" },
    { "EMID", "app.EnemyCharacter", nil, "_Context" },
    { "EMID", "app.cEnemyContextHolder", nil, "_Em" },
    { "EMID", "app.cEnemyContext", "get_EmID()" },
    { "EMID", "app.cEnemyContext", "get_SystemIndex()" },
    { "EMPARRY", "app.EnemyCharacter", "evHit_AttackParry(app.HitInfo, app.cAttackParamEm)" },
    { "EMSTATE", "app.EnemyCharacter", "getCurrentAction()" },
    { "SPD", "app.EnemyCharacter", "calcMotionSpeedTotal(System.Boolean)" },
    { "SPD", "app.EnemyCharacter", "get_MotionSpeed_Action()" },
    { "SPD", "via.GameObject", "get_TimeScale()" },
    { "MASTER", "app.cEnemyContextHolder", "get_IsMaster()" },
    { "TGT", "app.cEnemyContext", nil, "Target" },
    { "TGT", "app.cEmModuleTarget", "getTarget(System.Boolean, app.cEmModuleTarget.TARGET_ORDER)" },
    { "TGT", "app.TARGET_ACCESS_KEY", nil, "Category" },
    { "TGT", "app.TARGET_ACCESS_KEY", nil, "UniqueIndex" },
    { "FIND", "app.EnemyManager", "findEnemy_SystemIndex(System.Int32)" },
    { "FIND", "app.cEnemyManageInfo", "get_Character()" },
    { "FIND", "app.cEnemyManageInfo", "get_Pos()" },
    { "ATK", "app.ColliderSwitcher", ATK_SIG, nil, "ColliderSwitcher.activateAttack" },
    { "ATK", "app.ColliderSwitcher", nil, "_HitController" },
    { "ATK", "app.HitController", "get_Owner()" },
    { "SIG", "app.HunterCharacter", nil, "_HunterMotionSupporter" },
    { "SIG", "app.HunterCharacter.cMotionSupporter", nil, "_BaseBasicMotionSeq" },
    { "SIG", "app.motion_track.HunterBasic", nil, "_ParryImmdiate" },
    { "SIG", "app.motion_track.HunterBasic", nil, "_ActionFlag1" },
    { "SIG", "app.motion_track.HunterBasic", nil, "_WpUniqueFlag1" },
    { "SIG", "app.motion_track.HunterBasic", nil, "_SuperArmor" },
    { "SIG", "app.motion_track.HunterBasic", nil, "_NoHit" },
    { "SIG", "app.HunterCharacter", "get_Weapon()" },
    { "SIG", "app.Weapon", nil, "_IsAttackColliderOn" },
    { "CONT", "app.HunterCharacter", "checkHunterContinueFlag(app.HunterDef.CONTINUE_FLAG)" },
    { "CONT", "#enum", "CF", "PARRY_IMMDIATE" },
    { "ANIM", "via.motion.Motion", "getLayer(System.UInt32)" },
    { "ANIM", "via.motion.TreeLayer", "get_Frame()" },
    { "ANIM", "via.motion.TreeLayer", "get_Speed()" },
    { "ANIM", "via.motion.TreeLayer", "get_MotionID()" },
    { "HOLD", "app.HunterCharacter", "get_AttackAreaResult()" },
    { "HOLD", "app.mcHunterAttackAreaResultHolder", nil, "_AttackAreaResultList" },
    { "POSE", "via.GameObject", "get_Transform()" },
    { "POSE", "via.Transform", "get_Position()" },
    { "POSE", "via.Transform", "get_AxisZ()" },
    { "GDT", "via.Application", "get_DeltaTime()" },
    { "HDRX", "app.PlayerManager", nil, "_CurrentNetworkPosition" },
    { "HDRX", "app.PlayerManager", "get_Catalog()" },
    { "HDRX", "app.cPlayerCatalogHolder", "getWeaponActionParam(app.WeaponDef.TYPE)" },
    { "HDRX", "app.user_data.WpActionParamBase", nil, "_GuardDegree" },
    { "HDRX", "app.user_data.WpActionParamBase", nil, "_AimGuardDegree" },
    { "HDRX", "app.user_data.Wp00ActionParam", nil, "_ChargeParam_Parry" },
    { "HDRX", "app.user_data.Wp00ActionParam.cCharge", nil, "_OverheatTime" },
}

local function manifest_label(it)
    if it[5] then return it[5] end
    if it[2] == "#enum" then return it[3] .. "." .. it[4] end
    if it[2] == "#type" then return it[3] end
    local tn = it[2]:gsub("^app%.", "")
    local member = it[3] and it[3]:gsub("%(.*%)$", "") or it[4]
    return tn .. "." .. tostring(member)
end

local function manifest_check(it)
    if it[2] == "#enum" then return ev(it[3], it[4]) ~= nil end
    if it[2] == "#type" then return sdk.find_type_definition(it[3]) ~= nil and T_ENEMY ~= nil end
    local td = sdk.find_type_definition(it[2])
    if not td then return false end
    if it[3] then return td:get_method(it[3]) ~= nil end
    if it[4] then return td:get_field(it[4]) ~= nil end
    return true
end

local function selftest1()
    local now = os.clock()
    local okn, failed, by_mod, order = 0, {}, {}, {}
    for _, it in ipairs(MANIFEST) do
        local ok, good = pcall(manifest_check, it)
        if ok and good then
            okn = okn + 1
        else
            local label = manifest_label(it)
            failed[#failed + 1] = label
            if not by_mod[it[1]] then
                by_mod[it[1]] = {}
                order[#order + 1] = it[1]
            end
            local l = by_mod[it[1]]
            l[#l + 1] = label
        end
    end
    -- draw.text 是 REF 自带 API，但本项目没用过：没有就直接走 imgui 窗口
    if type(draw) ~= "table" or type(draw.text) ~= "function" then S.hud_mode = 2 end
    -- 缺核心项 → 标红；缺可选项 → 停用该模块、标黄（每个模块报一次）
    for _, modname in ipairs(order) do
        local m = MODS[modname]
        if m.core then
            S.st1_core_fail = true
            set_red(modname, "selftest1")
        end
        report_error(modname, "selftest1 missing: " .. table.concat(by_mod[modname], ","))
    end
    S.st1 = { ok = okn, total = #MANIFEST, failed = failed }
    local fl = table.concat(failed, ",")
    if #fl > 600 then fl = fl:sub(1, 600) .. "..." end
    emit("SELFTEST", now, "stage", 1, "i", "ok", okn, "i", "total", #MANIFEST, "i", "failed", fl ~= "" and fl or nil, "s")
end

local ENUM_SHOW = {
    { "RT", { "SAFE", "CAUTION", "DANGER" } },
    { "PS", { "NONE", "WAIT", "HIT", "SUCCESS", "RECOIL" } },
    { "LAYER", { "ATTACK_GET", "ATTACK_PARRY_GET", "ATTACK_PUT", "ATTACK_PARRY_PUT" } },
    { "HR", { "FAILURE", "PASS", "SUCCESS" } },
    { "TAK", { "INVALID", "PLAYER", "OTOMO", "PORTER", "NPC", "ENEMY", "GIMMICK" } },
    { "DT", { "NONE", "NORMAL", "EAR", "WIND", "QUAKE" } },
    { "SF", { "SUPER_ARMOR", "HYPER_ARMOR", "NO_DAMAGE" } },
    { "GT", { "NORMAL", "ALL_RANGE", "UNABLE_GUARD", "SKILL_GUARD", "SKILL_GUARD_ALL_RANGE" } },
    { "NP", { "NONE", "LOBBY", "VISUAL_LOBBY", "QUEST", "LINKED" } },
    { "TO", { "FIRST", "SECOND" } },
}

local function enums_str()
    local groups = {}
    for _, g in ipairs(ENUM_SHOW) do
        local parts = {}
        for _, nm in ipairs(g[2]) do
            local v = ev(g[1], nm)
            parts[#parts + 1] = nm .. ":" .. (v ~= nil and tostring(math.tointeger(v) or v) or "?")
        end
        groups[#groups + 1] = g[1] .. "{" .. table.concat(parts, ",") .. "}"
    end
    return table.concat(groups, ";")
end

local function load_cfg(name)
    local ok, t = pcall(json.load_file, name)
    if ok and type(t) == "table" then return mini_json(t) end
    return nil
end

local function hdr_extra()
    local h = {}
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    if pm then
        h.net = ename("NP", pm:get_field("_CurrentNetworkPosition"))
        local cat = pm:call("get_Catalog")
        local prm = cat and cat:call("getWeaponActionParam(app.WeaponDef.TYPE)", 0)
        if prm then
            h.gd = prm:get_field("_GuardDegree")
            h.ad = prm:get_field("_AimGuardDegree")
            local cp = prm:get_field("_ChargeParam_Parry")
            h.oh = cp and cp:get_field("_OverheatTime") or nil
        end
    end
    -- 预告系统的判定参数（静态字段，读不到写 ?）
    local td = sdk.find_type_definition("app.mcEnemyAttackAreaDetector")
    local function sv(n)
        local ok, v = pcall(function() return td:get_field(n):get_data(nil) end)
        if ok and type(v) == "number" then return safe_fmt("%.3f", v) end
        return "?"
    end
    h.det = td and (sv("PLAYER_RADIUS") .. "," .. sv("PLAYER_HEIGHT") .. "," .. sv("DETECT_DISTANCE_SQ")) or nil
    return h
end

local function hdr_emit()
    local now = os.clock()
    local h = opt("HDRX", hdr_extra) or {}
    emit("HDR", now, "ver", VERSION, "s", "session", S.session, "i", "net", h.net, "s", "guard_deg", h.gd, "f1",
        "aim_deg", h.ad, "f1", "overheat_parry", h.oh, "f1", "cfg_guard", load_cfg("AutoGuardGS.json"), "s",
        "cfg_parry", load_cfg("AutoParryGS.json"), "s", "enums", enums_str(), "s", "det", h.det, "s")
end

-- ========================================================================
-- HUD 与菜单（P22）
-- ========================================================================
local function hud_text()
    if not S.rec then
        if S.auto_stopped then return "APCal 已停止记录（加载满 90 分钟；菜单里可重新开启）" end
        return "APCal 已停止记录"
    end
    if S.red then
        return safe_fmt("APCal 出错，停下发日志  错误 %d/%d", S.n_red, S.n_yellow)
            .. (S.st2 and safe_fmt(" | 自检2 %d/%d", S.st2.ok, S.st2.total) or "")
    end
    local st = S.st1_core_fail and "自检失败" or "自检 OK"
    local s = safe_fmt("APCal %s 错误 %d/%d | ", st, S.n_red, S.n_yellow)
    if S.phase_b then
        if S.b_pt >= K.B_PT and S.b_contact >= K.B_CONTACT then
            s = s .. "B 完成"
        else
            s = s .. safe_fmt("B 段：放刀 %d/%d 接触 %d/%d DANGER %d/%d", S.b_pt, K.B_PT, S.b_contact, K.B_CONTACT,
                S.b_danger, K.B_DANGER)
        end
        local el = math.floor(S.now - (S.b_t0 or S.now))
        s = s .. safe_fmt(" 用时 %d:%02d", el // 60, el % 60)
    else
        s = s .. safe_fmt("空挥 %d/%d", math.min(S.swings, K.SWINGS), K.SWINGS)
        if S.swings >= K.SWINGS then s = s .. safe_fmt(" | 机关段放刀 %d", S.scan_pt) end
    end
    if S.st2 then s = s .. safe_fmt(" | 自检2 %d/%d", S.st2.ok, S.st2.total) end
    if S.fps_warn then s = s .. safe_fmt(" | 帧率降 %.0f%%", S.fps_warn) end
    return s
end

-- draw 的颜色是 ABGR（REF 文档 imgui 页）
local COL_WHITE, COL_YELLOW, COL_RED, COL_GREEN = 0xFFFFFFFF, 0xFF40FFFF, 0xFF4040FF, 0xFF60FF60

local function hud_color()
    if S.red or S.st1_core_fail or (S.st2 and S.st2.core_fail) then return COL_RED end
    if S.n_yellow > 0 or S.n_red > 0 or (S.st2 and #S.st2.failed > 0) then return COL_YELLOW end
    if S.st2 then return COL_GREEN end
    return COL_WHITE
end

local function hud_window(text)
    imgui.begin_window("APCal##APCal_hud", true, 0)
    local ok, err = pcall(imgui.text, text)
    imgui.end_window()
    if not ok then error(err) end
end

local function on_frame()
    if S.hud_mode == 0 then return end
    local ok, text = pcall(hud_text)
    if not ok then text = "APCal HUD 文字出错" end
    if S.hud_mode == 1 then
        local ok2, err = pcall(draw.text, text, K.HUD_X, K.HUD_Y, hud_color())
        if not ok2 then
            report_error("HUD", err)    -- draw.text 不可用：退回 imgui 窗口
            S.hud_mode = 2
        end
        return
    end
    if not MODS.HUDWIN.on then
        S.hud_mode = 0
        return
    end
    local ok3, err3 = pcall(hud_window, text)
    if not ok3 then
        report_error("HUDWIN", err3)    -- 再失败只在菜单里显示
        S.hud_mode = 0
    end
end

local function draw_menu()
    imgui.text(hud_text())
    imgui.text(safe_fmt("版本 %s  会话 %d  帧 %d  跟踪 %d 条  缓冲 %d 条  已写 %d 个文件（最近 %s）", VERSION,
        S.session, S.f, S.n_trk, #S.jbuf, S.files, S.last_file))
    local changed, v = imgui.checkbox("停止记录##APCal_stop", not S.rec)
    if changed then set_rec(not v, "menu") end
    imgui.same_line()
    if imgui.button("写出数据##APCal_flush") then json_flush("button") end
    imgui.separator()
    imgui.text(safe_fmt("进度：阶段 %s  空挥 %d/%d  机关段放刀 %d  B 段放刀 %d/%d  接触 %d/%d  DANGER 回合 %d/%d",
        phase_name(), S.swings, K.SWINGS, S.scan_pt, S.b_pt, K.B_PT, S.b_contact, K.B_CONTACT, S.b_danger, K.B_DANGER))
    imgui.text("上一次放刀（在线粗分类，只供参考，正式分类在离线）：" .. tostring(S.last_class or "-"))
    imgui.separator()
    if S.st1 then
        imgui.text(safe_fmt("加载自检：%d/%d 通过%s", S.st1.ok, S.st1.total, S.st1_core_fail and "（缺核心项）" or ""))
        if #S.st1.failed > 0 then imgui.text("  缺：" .. table.concat(S.st1.failed, ", "):sub(1, 400)) end
    end
    if S.st2 then
        imgui.text(safe_fmt("自检2（首次 DANGER）：%d/%d 通过", S.st2.ok, S.st2.total))
        if #S.st2.failed > 0 then imgui.text("  失败：" .. table.concat(S.st2.failed, ", ")) end
    else
        imgui.text("自检2：等第一次 DANGER 预告")
    end
    imgui.text("性能：" .. tostring(S.perf_text))
    imgui.separator()
    imgui.text(safe_fmt("错误：核心 %d  可选 %d%s", S.n_red, S.n_yellow, S.red and "（红：停下来，把日志发给我）" or ""))
    local off = {}
    for _, n in ipairs(OPT_MODS) do
        if not MODS[n].on then off[#off + 1] = n end
    end
    if #off > 0 then imgui.text("已停用的可选模块：" .. table.concat(off, " ")) end
    for _, line in ipairs(S.err_list) do imgui.text(line) end
end

-- ========================================================================
-- 注册（钩子、回调）与加载
-- ========================================================================
local function hook(modname, type_name, sig, pre, post)
    local ok, err = pcall(function()
        local td = sdk.find_type_definition(type_name)
        local m = td and td:get_method(sig)
        if not m then error("method not found: " .. type_name .. "." .. sig) end
        sdk.hook(m, pre, post)
    end)
    if not ok then
        if MODS[modname].core then set_red(modname, "hook") end
        report_error(modname, err)
    end
    return ok
end

local function load_main()
    hdr_emit()
    selftest1()
    hook("MSG", "app.cMasterPlayerControllerEntity", "receiveGameMessage(ace.cGameMessage)", msg_pre, nil)
    hook("CT", "app.HunterCharacter", "evHit_DamagePreProcess(app.HitInfo)", ct_pre, ct_post)
    if MODS.SHELL.on then
        hook("SHELL", "app.HunterCharacter", "evHit_ShellDamagePreProcess(app.HitInfo)", sh_pre, sh_post)
    end
    hook("DMG", "app.HunterCharacter", "evHit_Damage(app.HitInfo)", dmg_pre, dmg_post)
    hook("PH", "app.cHunterWeaponHandlingBase", "onParryHit(app.HunterDef.PARRY_STATE, via.GameObject, via.vec3)",
        ph_pre, nil)
    hook("PH", "app.cHunterWeaponHandlingBase", "onParrySuccess(app.HunterDef.PARRY_STATE)", ps_pre, nil)
    hook("EMHIT", "app.EnemyCharacter", "evHit_DamagePreProcess(app.HitInfo)", emhit_pre, nil)
    if MODS.EMPARRY.on then
        hook("EMPARRY", "app.EnemyCharacter", "evHit_AttackParry(app.HitInfo, app.cAttackParamEm)", emparry_pre, nil)
    end
    if MODS.ATK.on then
        if not hook("ATK", "app.ColliderSwitcher", ATK_SIG, atk_pre, nil) then atk_off = true end
    else
        atk_off = true
    end
end

local load_ok, load_err = pcall(load_main)
if not load_ok then
    set_red("HDR", "load")
    report_error("HDR", load_err)
end

re.on_pre_application_entry("UpdateBehavior", on_pre_update)

re.on_frame(function()
    local ok, err = pcall(on_frame)
    if not ok then report_error("HUD", err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("APCal 测量探针##APCal") then return end
    local ok, err = pcall(draw_menu)
    if not ok then report_error("MENU", err) end
    imgui.tree_pop()
end)

-- Reset Scripts：结算未完的 PT/回合、丢掉跨帧持有的对象（只删 Lua 引用，Lua 状态关闭时 REF 自动 release）、写出 JSON
re.on_script_reset(function()
    local now = os.clock()
    pcall(function()
        if S.pt then pt_close(now, "reset") end
        release_all_tracks(now, "reset")
        em_release_all()
    end)
    pcall(json_flush, "reset")
end)

-- 纯计算函数给模拟测试用（REF 运行 autorun 脚本时忽略返回值）
return {
    epoch_split = epoch_split,
    epoch_end = epoch_end,
    classify_pt = classify_pt,
    calc_theta = calc_theta,
    median = median,
    mini_json = mini_json,
    fmt_value = fmt_value,
}
