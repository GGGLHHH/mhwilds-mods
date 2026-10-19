-- AttackTimingProbe（ATP）：怪物攻击「真正打过来的时刻」—— 精确时刻机制探针
--
-- 【只记录，不修改游戏】
--   只读游戏数据，只写日志（[ATP] 开头，低频）和 reframework/data/ATP_<会话>_<序号>.json。
--   只调用 get_* / calc* / find* 这类读取方法和 get_field，不写字段、不请求动作、不伪造或重放命中。
--   不跨帧持有任何游戏对象：只存地址、编号和数值，每帧用 EnemyManager.findEnemy_SystemIndex 重新取怪物；
--   也不调用 add_ref / release（NOTES「跨帧持有与 REF 的引用记账」：同一地址在整个 Lua 状态里只记一份，
--   两个脚本同时持有时谁先 release 谁就让另一个拿着悬空指针）。initData 前置钩子里拿到的条目对象，
--   只用到同一次调用的后置钩子为止；本探针完全不碰 AttackAreaResult 对象（rc 和 APCal 持有的是它）。
--   不钩高频方法：DetectedData.update（每条条目每帧一次）、onParryHitPreProcess 都不钩。
--
-- 要回答的问题（docs/NOTES.md「怪物攻击」；第 2 轮数据实测）：
--   hs（HitStartRemainFrame，1/60 s）按真实时间扣：Δhs ≈ 60·Δt，和怪物动作速度无关；怪物加速时攻击比倒数早到。
--   实测（tools/out/round2a~2c，新结果第一条 MSG 的 mstart = MergedAreaData.AttackStartFrame，和下一帧条目 hs 对比）：
--   mstart ≈ 下一帧最小 hs + 约 1 帧；同一招（同怪种 + 同 KeepActionID + 同 mstart）在速度跨度 ≥0.15 的 15 组里，
--   下一帧 hs 的跨度中位 0.27 帧、最大 0.52 帧（若按速度换算应差 11~104 帧）—— 初值没有按速度换算。
--   推测：initData 按「名义帧」给初值，之后 update(Single, Capsule) 按真实时间扣，丢了速度。
--   若成立，「名义剩余帧 / 当前速度」或「按每帧速度积分」对所有怪都精确，不用逐只怪调参。
--   本探针只把检验这件事需要的原始量记下来，判定在离线 tools/atp_analyze.py 里做。
--
-- 类型库核对（2026-10-11，re-engine-mcp 只读 get_type，签名逐个对过；加载时 SELFTEST 再对一遍）：
--   app.AttackAreaResult.DetectedData.initData(app.EnemyCharacter, app.AttackAreaData, System.Single, via.Capsule,
--     app.cEnemyStockAttackHit)；字段 HitStartRemainFrame / HitEndRemainFrame（Single）、ResultType、RequestSetID 等
--   app.AttackAreaData：AttackStartFrame / AttackEndFrame（Single）、RequestSetID（Nullable<UInt32>）、
--     ShellIndex（Nullable<Int32>）、CollidableIDList（List<UInt32>）、OffsetLen、Obb
--   app.EnemyCharacter：calcMotionSpeedTotal(Boolean)、get_MotionSpeed_*（12 个分量）、
--     字段 _MotionSpeed（app.EnemyCharacter.cMotionSpeed 值类型：_Base/_Action/_Scale/_MoveAction/_MoveSpeed/_Random/
--     _CoreState/_Replica/_WaitPacketReserved/_WaitPacket/_Sequence/_BlendTree/_TotalMotionSpeedThisFream）
--   app.CharacterBase.get_MotionComponent() → via.motion.Motion.getLayer(UInt32) → via.motion.TreeLayer
--     get_Frame / get_Speed / get_MotionID / get_MotionBankID；via.motion.Animation.get_PlaySpeed()
--   app.CharacterBase.get_BaseActionController() → ace.cActionController.get_CurrentActionID / get_CurrentAction →
--     app.cCharacterActionBase._RawTotalElapsedSecond / get_CharaElapsedSecond()
--   via.Application.get_DeltaTime()（单位是帧，PERF 实测 1.0128）、get_FrameCount()
--
-- 另外钩了 app.mcEnemyAttackAreaDetector.getAttackAreaResult(CharacterBase, ACTION_ID, Nullable<Single>,
--   Nullable<Single>, Nullable<vec3>, Boolean) 和 getCurrentAttackAreaResult(CharacterBase, Nullable<Single>,
--   Nullable<Single>, Nullable<vec3>)（频率和建结果对象一样低）：值类型实参按指针传（同 TARGET_ACCESS_KEY），
--   读之前先过 ptr_ok 的地址检查；post 只用 to_int64 取返回值地址，不建对象、不持有。
--
-- 钩子参数（REF：args[1] 线程上下文，args[2] this，args[3..] 依次是参数）：
--   args[3] EnemyCharacter、args[4] AttackAreaData、args[5] Single、args[6] via.Capsule（值类型按指针传，
--   和 NOTES 里 TARGET_ACCESS_KEY 一样）、args[7] cEnemyStockAttackHit。
--   Single 是第 5 个实参（算上线程上下文），x64 调用约定下走栈，栈槽低 32 位就是单精度位：
--   sbits = to_int64 & 0xFFFFFFFF，sgl 用 string.pack/unpack 解码（不依赖 sdk.to_float 的语义），
--   sdk.to_float 有的话另记 sgl2，离线对照。参数含义未知（推测：动作已过帧数或起始偏移），离线检验。
--
-- 记录（JSON 里每条是 { k = 种类, t = os.clock(), ... }；os.clock 是进程时钟，离线和 [APCal] 直接按 t 对齐）：
--   INIT   每次 initData：t f ctx ent em emaddr sgl sgl2 sbits aad ast aen req shell cids ncid stk cap gar tme aeq
--          hs_pre he_pre hs he rt depth same + 怪物快照（见 snap_into：速度、动作层、动作、TimeScale 等）
--          ent = 条目（DetectedData）地址，和 APCal SER/ENT 的 ent 是同一个东西；hs/he 是 initData 刚返回时的值；
--          gar/tme = 外层 getAttackAreaResult 调用的编号、目标是不是主角（没有外层调用就不写）；
--          aeq = 快照里怪物的当前动作 ID 是否等于外层调用的 ACTION_ID 实参（审查 F3：initData 若发生在动作进入事件里，
--          快照可能还是上一个动作 / 上一个 motion，离线要改用 initData 之后第一条 EMF 当锚点）；
--          ems = em 编号的来源，只在不是当场读到时写（stale = 用这个地址上次读到的编号，none = 读不到、em 写成 @地址）
--   GAR    每次探测器建结果（mcEnemyAttackAreaDetector.getAttackAreaResult / getCurrentAttackAreaResult，可选模块）：
--          t id kind f det tgt tme act flag p1 p1s p2 p2s pos res n_init depth
--          p1/p2 = 两个 Nullable<Single> 实参（p1s/p2s = val / none / bad）；res = 返回的结果对象地址（= APCal MSG/SER 的 obj）
--   EMF    每帧帧开头，对「最近 4 s 内有过 initData，或某条 initData 的 hs 还没倒数完」的怪物各一条：
--          t f em v，v 是「|」分隔的紧凑字符串，字段顺序见 HDR 的 emf_fields；读不到的写 -
--          spt/spf（calcMotionSpeedTotal）只在每次 initData 之后的第一条 EMF 里有（菜单可以改成每帧都调）
--   EMSPD  某只怪 _MotionSpeed 分量（字段顺序见 HDR 的 spd_fields）有变化时一条：t f em comp
--   EMACT  某只怪当前动作对象变化时一条：t f em act name aaddr
--   ORPH   帧开头发现上一帧压栈、没等到 post 的钩子记录（审查 F8）：t kind f ent em id —— f 是那条记录所在的帧，
--          离线把这一帧的 INIT 全部剔除（pre/post 可能配错）
--   GUARD  频率 / 耗时守卫停掉一个模块：t mod why（审查 F7：不再占 PERF 的出错额度）
--   HDR / SELFTEST / PERF / ERR / STOP / RESUME / NOTE
--
-- 帧回调选 re.on_pre_application_entry("UpdateBehavior")（帧开头），不选 re.on_frame：
--   1. 和 [APCal] 的 SER、AutoParryGS 的放刀判断是同一个时刻（都在帧开头），同一帧的 EMF 和 SER 的 t 相同（到 ms），
--      离线按 t 直接对齐；放刀逻辑能用的也正是帧开头读到的量。
--   2. 帧开头时上一帧的动作和速度都已经算完，同一帧里读到的值彼此一致；initData 钩子发生在帧中间，单独记一份快照。
--   3. re.on_frame 挂在画面呈现上，不保证和游戏更新一一对应（帧生成、跳帧时会错开）。
--   实测（round2b/2c 的 APCal SER，7~8 万对相邻帧）：帧开头读到的 DeltaTime 是刚过完那一帧的时长，
--   相邻两帧开头之间 hs 扣掉的正是这个值（和上一帧时长的相关 0.96~0.97，和当前帧时长只有 0.48~0.74）。
--
-- 出错处理（审查 F2：旧版可选模块第一次出错就永久停用，切场景时一次瞬时异常就会让整条数据链断掉）：
--   每次读取都带「对象」（怪物 / 条目地址；全局读取不带），出错只跳过这一次读取，不停整个模块。
--   同一模块 K.ERR_WIN 秒内有 K.ERR_PAUSE_N 帧出错、并且涉及 ≥2 个对象（或是全局读取）→ 暂停 K.PAUSE_S 秒后
--   自动重开；连续 K.PERM_PAUSES 次暂停才永久停用。只坏一只怪不会暂停整个模块：
--   - 监视中的一只怪在某个模块上连续 K.OBJ_SKIP_N 帧出错 → 只有这只怪跳过这个模块 K.OBJ_SKIP_S 秒（限住出错频率，
--     免得 REF 每次截住访问冲突都往日志写一大段），别的怪照常读；
--   - 一只怪连续 K.MON_BAD_DROP 帧都有 ≥2 个读数出错（或找怪本身抛错）→ 不再盯它（多半正在销毁）；
--     只有一个读数出错不算（多半是那个模块的问题），不能因此丢掉这只怪的 EMF。
--   同一帧里一个模块已经在 2 个对象上出错 → 本帧剩下的跳过它（多半是系统性错误）。
--   菜单「重开已停用模块」把永久停用和守卫停掉的模块都重开（加载自检缺项、钩子没装上的除外）；重新开始记录也会重开出错停用的。
--
-- 性能与自停：
--   INIT 钩子：每个统计周期（5 s）算 initData 次数/秒和钩子体耗时 ms/秒；连续 2 个周期超过 K.INIT_LIMIT 或
--     K.HOOK_MS_LIMIT → 钩子第一行直接 return（REF 没有卸钩子），写 GUARD。GAR 钩子同样按调用次数自停；
--     钩子耗时是两组合计，超限时两组一起停。停了以后 REF 的钩子分发本身还在（几微秒一次）；
--     钩子第一行无条件计原始调用次数，PERF 里 init_raw_ps / gar_raw_ps 停用后照样有数（审查 F7），
--     万一它大到影响帧率，把本文件移出 autorun 再 Reset Scripts。
--   EMF 每帧模块：平均耗时连续 2 个周期超过 K.FRAME_MS_LIMIT → 停用该模块，写 GUARD。
--   监视表（审查 F6）：最多 K.MON_MAX 只怪；打主角（tme=1）的 initData 一定拿得到位置，满员时挤掉最久没有 tme=1 的那只，
--     其余的只用空位（PERF 的 mon_full / mon_evict 记次数）。
--   JSON 写盘（审查 F5）：写盘可能卡 0.1~0.3 s，只在没有「打主角或目标未知的预告还在倒数」时写；
--     缓冲到硬上限后最多再等 K.JSON_HARD_WAIT 秒，到绝对上限才无条件写。
--   加载 90 分钟后自停记录（菜单里可以重新打开）。
--
-- 离线：python tools/atp_analyze.py <数据目录>（同一目录或 --apcal-dir 里放同一次游戏的 APCal_*.json）。

local TAG = "[ATP] "
local VERSION = "atp-1.1"

-- ========================================================================
-- 常量
-- ========================================================================
local K = {
    WIN = 4.0,              -- initData 之后至少盯这只怪 4 s
    WIN_PAD = 1.0,          -- …… 或者盯到 hs 倒数完再加 1 s（长预告，实测最长约 402 帧）
    WIN_MAX = 8.0,          -- 单次延长最多 8 s
    MON_MAX = 8,            -- 每帧最多盯 8 只怪
    MISS_DROP = 120,        -- 连续 120 帧取不到怪物 → 不再盯
    PERF_PERIOD = 5.0,
    INIT_LIMIT = 600,       -- initData 次数/秒（实测量级未知；按每次钩子体约 0.1 ms 算，600 次/秒 ≈ 60 ms/s）
    HOOK_MS_LIMIT = 30.0,   -- 钩子体耗时 ms/秒（约占 3% 帧时间）
    FRAME_MS_LIMIT = 1.5,   -- EMF 每帧平均耗时 ms
    GUARD_PERIODS = 2,      -- 连续这么多个周期超限才停
    -- 出错退避（见文件头「出错处理」；仿 APCal 的 BACKOFF / ACT_FAIL_TOL）
    ERR_WIN = 3.0,          -- 统计窗口（秒）
    ERR_PAUSE_N = 3,        -- 窗口内这么多帧出错，且涉及 ≥2 个对象或是全局读取 → 暂停
    OBJ_SKIP_N = 10,        -- 监视中的一只怪在某个模块上连续这么多帧出错 → 只有它跳过这个模块 OBJ_SKIP_S 秒
    OBJ_SKIP_S = 3.0,
    PAUSE_S = 2.0,          -- 暂停这么久后自动重开
    PAUSE_CHAIN = 20.0,     -- 两次暂停相隔 ≤20 s 算「连续」
    PERM_PAUSES = 5,        -- 连续这么多次暂停 → 永久停用（菜单可以重开）
    FRAME_SKIP_OBJS = 2,    -- 同一帧里一个模块已在这么多个不同对象上出错 → 本帧剩下的跳过它
    MON_BAD_DROP = 20,      -- 一只怪连续这么多帧有 ≥2 个读数出错（或找怪抛错）→ 不再盯它
    CIDS_MAX = 16,
    EM_CACHE_AGE = 30.0,    -- EnemyCharacter 地址 → em 编号缓存有效期（地址可能被新对象复用；过期后读不到时仍拿来兜底）
    NAME_CACHE_AGE = 60.0,  -- 动作对象地址 → 类名缓存有效期
    JSON_IDLE = 60.0,       -- 没在盯怪物、也没有预告在倒数时，距上次写出 ≥60 s 就写
    JSON_VALVE = 30000,     -- 缓冲超过这么多条：等没有预告在倒数的空档写（写盘可能卡 0.1~0.3 s）
    JSON_HARD = 90000,      -- 到这里还等不到空档：最多再等 JSON_HARD_WAIT 秒
    JSON_HARD_WAIT = 20.0,
    JSON_ABS = 150000,      -- 绝对上限：无条件写（约 30~40 MB 内存）
    JSON_VALVE_RETRY = 10.0,
    JSON_SEQ_MAX = 300,
    BUSY_SLOW = 1.3,        -- 「预告还在倒数」= initData 后 hs/60 × 1.3 + 0.8 s 以内（速度实测 0.81~1.47，
    BUSY_PAD = 0.8,         --   1.3 倍覆盖最慢的怪；0.8 s 覆盖激活到接触，以及放刀后接触落在窗口里的时间）
    BUSY_MAX = 12.0,        -- 单条最多算 12 s（实测最长预告约 402 帧 = 6.7 s）
    ORPH_MAX = 500,         -- ORPH 记录上限
    AUTO_STOP = 5400,       -- 加载 90 分钟后自停
    ERR_LOG_MAX = 20,
    ERR_JSON_MAX = 300,
}

-- EMF 紧凑字符串的字段顺序（HDR 里写出，离线按它解析）
local EMF_FIELDS = { "tot", "ms", "mf", "mid", "bank", "pls", "ts", "ael", "ace", "act", "gdt", "gfc", "spt", "spf" }
-- _MotionSpeed 值类型的字段（EMSPD、INIT 的 scomp 用这个顺序）
local SPD_FIELDS = { "_Base", "_Action", "_Scale", "_MoveAction", "_MoveSpeed", "_Random", "_CoreState", "_Replica",
    "_WaitPacketReserved", "_WaitPacket", "_Sequence", "_BlendTree" }
-- get_MotionSpeed_* 读取器（INIT 的 gcomp 用这个顺序；和上面的字段不一定一一对应，离线对照）
local SPD_GETTERS = { "Base", "Action", "BlendTree", "CoreState", "MoveAction", "MoveSpeedAdjusted", "Random",
    "Replica", "ScaleAdjusted", "Sequence", "WaitPacket", "WaitPacketReserved" }

local INIT_SIG = "initData(app.EnemyCharacter, app.AttackAreaData, System.Single, via.Capsule, app.cEnemyStockAttackHit)"
-- 怪物的攻击预告探测器（app.mcEnemyAttackAreaDetector）建结果对象的两个入口（类型库核对过）。initData 多半在它们里面被调用：
-- 钩它们能知道每条 initData 属于哪个目标、哪个结果对象（返回值地址 = APCal MSG/SER 的 obj），
-- 以及两个 Nullable<Single> 实参是什么（推测：起始帧偏移 / 速度之类 —— 如果有一个是速度，游戏自己就有按速度算的路径）
local GAR_SIG = "getAttackAreaResult(app.CharacterBase, ace.ACTION_ID, System.Nullable`1<System.Single>, "
    .. "System.Nullable`1<System.Single>, System.Nullable`1<via.vec3>, System.Boolean)"
local GCAR_SIG = "getCurrentAttackAreaResult(app.CharacterBase, System.Nullable`1<System.Single>, "
    .. "System.Nullable`1<System.Single>, System.Nullable`1<via.vec3>)"

-- ========================================================================
-- 状态
-- ========================================================================
local S = {
    session = os.time(),
    t_load = os.clock(),
    now = os.clock(),
    f = 0,
    rec = true, rec_t0 = os.clock(), auto_stopped = false,
    -- JSON
    jbuf = {}, seq = 0, files = 0, last_file = "-", last_write_t = os.clock(), valve_t = -100, seq_full = false,
    -- 错误
    n_err = 0, err_logged = 0, err_json = 0, err_list = {}, in_err = false,
    -- 怪物：只存编号、地址和数值
    -- [SystemIndex] = { key, eaddr, until_t, miss, bad, t_first, last_tme, act_addr, spd_sig, calc_once,
    --                   fail / skip（按模块：连续出错帧数 / 跳到什么时候）, nb（本帧读前的各模块出错数） }
    mon = {}, n_mon = 0,
    em_by_addr = {},                -- EnemyCharacter 地址 → { key, idx, t }
    names = {},                     -- 动作对象地址 → { name, t }
    icache = {}, icache_f = -1,     -- 本帧 initData 用的怪物快照（同一帧同一只怪只读一次）
    last_init_t = -100,
    n_init_total = 0,
    busy_until = -100,              -- 打主角或目标未知的预告「还在倒数」到这个时刻（JSON 写盘要避开，审查 F5）
    hard_t0 = nil,                  -- 缓冲到 JSON_HARD 的时刻
    n_orph = 0,
    -- 统计（init / gar = 实际记录的调用；raw = 钩子被调用的原始次数，停用后照样计，审查 F7）
    perf = { t0 = os.clock(), frames = 0, init = 0, hook_ms = 0, frame_ms = 0, frame_n = 0, frame_max = 0,
        orphan = 0, deep = 0, emf = 0, gar = 0, init_raw = 0, gar_raw = 0, mon_full = 0, mon_evict = 0,
        mon_noidx = 0, mon_bad = 0 },
    raw_init_total = 0, raw_gar_total = 0,
    init_hi = 0, hook_hi = 0, frame_hi = 0, gar_hi = 0, perf_text = "统计中",
    hunter_addr = nil,              -- 主角 HunterCharacter 地址（每帧帧开头重新取，只存数字）
    n_gar_total = 0,
    calc_every_frame = false,       -- 菜单开关：每帧也调用 calcMotionSpeedTotal（默认关，见 read_calc）
    st = nil,                       -- 加载自检结果
}

-- initData 钩子自停开关：钩子第一行就判断（停止记录、模块停用 / 暂停 / 守卫时为 true），由 refresh_flags 维护
local init_off = false
-- getAttackAreaResult 钩子自停开关（同上）
local gar_off = false

-- 模块表。出错不再分核心 / 可选：全部按「暂停 → 自动重开 → 连续多次才永久停用」处理（见文件头「出错处理」）
--   on = false：永久停用（perm = 出错停的，guard = 守卫停的，st_missing = 加载自检缺项，no_hook = 钩子没装上）
--   pause_until：暂停到这个时刻；win：窗口内的 (帧, 对象) 出错记录；f_err / f_objs / f_nobj：本帧涉及的对象
local MODS = {}
local MOD_LIST = {
    "INIT", "EMF", "JSON", "MENU", "PERF", "FMT",
    "AREA", "CIDS", "CAP", "EMID", "FIND", "SPDS", "SPDG", "CALC", "MOT", "ACT", "ACTN", "TS",
    "CLK", "EMST", "F2", "RT", "GAR", "HUNT",
}
for _, name in ipairs(MOD_LIST) do
    MODS[name] = { name = name, on = true, n = 0, n_pause = 0, pause_run = 0, pause_t = nil, pause_until = nil,
        win = {}, f_err = -10, f_objs = {}, f_nobj = 0 }
end

-- ========================================================================
-- 格式化、记录、错误
-- ========================================================================
local report_error   -- 前置声明

-- 所有格式化都走这里：Lua 5.4 里 %d 遇到带小数的数会抛错（旧探针踩过），失败时计一次 FMT 错误
local function safe_fmt(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    if ok then return s end
    if report_error then report_error("FMT", "format " .. tostring(fmt) .. ": " .. tostring(s)) end
    return "FMT_ERR"
end

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- 浮点 → 文本（nil / NaN / inf 写 -）
local function fnum(v, fmt)
    if not finite(v) then return "-" end
    return safe_fmt(fmt or "%.4f", v)
end

-- 整数 → 文本：只对整数子类型用 %d，带小数的退回 %.0f
local function fint(v)
    if not finite(v) then return "-" end
    local iv = math.tointeger(v)
    if iv then return safe_fmt("%d", iv) end
    return safe_fmt("%.0f", v)
end

local function fhex(v)
    local iv = type(v) == "number" and math.tointeger(v) or nil
    if not iv then return "-" end
    return safe_fmt("%X", iv)
end

-- JSON 用的数值：按格式取整后转回数字（避免 19.329999923706055 这种尾巴），读不到返回 nil（键不写）
local function jnum(v, fmt)
    if not finite(v) then return nil end
    return tonumber(safe_fmt(fmt or "%.4f", v))
end

local function jint(v)
    if not finite(v) then return nil end
    return math.tointeger(v) or tonumber(safe_fmt("%.0f", v))
end

local function jbool(v)
    if v == nil then return nil end
    return (v == true or (type(v) == "number" and v ~= 0)) and 1 or 0
end

-- 日志值里不能有空格；非 ASCII 换成 ?（游戏字符串截断后可能是坏 UTF-8，JSON 会写不进去）
local function clean(v)
    local s = tostring(v)
    s = s:gsub("%s", "_")
    s = s:gsub("[\128-\255]", "?")
    return s
end

-- 记一条：rec 的值已经是 JSON 能写的数字 / 字符串（nil 的键不写）
local function emit(kind, t, rec)
    rec.k = kind
    rec.t = jnum(t or os.clock(), "%.4f")
    local buf = S.jbuf
    buf[#buf + 1] = rec
end

-- 低频记录同时写一行日志
local function emit_log(kind, t, rec, order)
    emit(kind, t, rec)
    local parts = { TAG, kind }
    for _, name in ipairs(order) do
        local v = rec[name]
        if v ~= nil then parts[#parts + 1] = " " .. name .. "=" .. clean(v) end
    end
    log.info(table.concat(parts))
end

-- 模块能不能用：没停用、不在暂停中、本帧没有在 ≥2 个对象上出错。暂停到期时在这里自动重开（写一条 NOTE）
local function mod_ok(m)
    if not m.on then return false end
    local pu = m.pause_until
    if pu then
        if S.now < pu then return false end
        m.pause_until = nil
        emit("NOTE", S.now, { what = "mod_resume", mod = m.name })
    end
    if m.f_err == S.f and m.f_nobj >= K.FRAME_SKIP_OBJS then return false end
    return true
end

-- 两个钩子的第一行开关：停止记录、模块停用 / 暂停 / 本帧跳过时为 true（帧开头、出错、守卫、菜单操作后重算）
local function refresh_flags()
    init_off = not (S.rec and mod_ok(MODS.INIT))
    gar_off = not (S.rec and mod_ok(MODS.GAR))
end

-- 出错：只跳过这一次读取；按窗口判断要不要暂停整个模块，连续暂停太多次才永久停用（见文件头「出错处理」）。
-- obj = 出错的对象（怪物 / 条目地址等任意可比较的值），全局读取不给。都写 ERR（JSON 前 300 条，日志前 20 条）
report_error = function(modname, err, obj)
    if S.in_err then return end
    S.in_err = true
    local m = MODS[modname] or MODS.MENU
    local now = os.clock()
    local f = S.f
    local okey = obj
    if okey == nil then okey = "*" end
    local msg = clean(err):sub(1, 200)
    m.n = m.n + 1
    S.n_err = S.n_err + 1
    -- 窗口：K.ERR_WIN 秒内的 (帧, 对象) 出错记录，同一帧同一对象只记一次
    local keep, dup = {}, false
    for _, e in ipairs(m.win) do
        if now - e.t <= K.ERR_WIN then
            keep[#keep + 1] = e
            if e.f == f and e.obj == okey then dup = true end
        end
    end
    if not dup then keep[#keep + 1] = { t = now, f = f, obj = okey } end
    m.win = keep
    -- 本帧涉及的对象数（≥ K.FRAME_SKIP_OBJS → mod_ok 让本帧剩下的读取跳过）
    if m.f_err ~= f then m.f_err, m.f_objs, m.f_nobj = f, {}, 0 end
    if not m.f_objs[okey] then
        m.f_objs[okey] = true
        m.f_nobj = m.f_nobj + 1
    end
    local frames, objs, nf, no, global = {}, {}, 0, 0, false
    for _, e in ipairs(keep) do
        if not frames[e.f] then
            frames[e.f] = true
            nf = nf + 1
        end
        if not objs[e.obj] then
            objs[e.obj] = true
            no = no + 1
        end
        if e.obj == "*" then global = true end
    end
    local action = "err"
    if m.on and nf >= K.ERR_PAUSE_N and (no >= 2 or global) then
        if m.pause_t ~= nil and now - m.pause_t <= K.PAUSE_CHAIN + K.PAUSE_S then
            m.pause_run = m.pause_run + 1
        else
            m.pause_run = 1
        end
        m.pause_t = now
        m.n_pause = m.n_pause + 1
        m.win = {}
        if m.pause_run >= K.PERM_PAUSES then
            m.on = false
            m.perm = true
            m.pause_until = nil
            action = "stop"
        else
            m.pause_until = now + K.PAUSE_S
            action = "pause"
        end
    end
    refresh_flags()
    local word = (action == "stop" and "停用") or (action == "pause" and "暂停") or "出错"
    table.insert(S.err_list, 1, safe_fmt("%.1f %s %s %s", now - S.t_load, modname, word, msg))
    if #S.err_list > 10 then table.remove(S.err_list) end
    if S.err_json < K.ERR_JSON_MAX or action ~= "err" then
        S.err_json = S.err_json + 1
        emit("ERR", now, { mod = modname, act = action, stop = action == "stop" and 1 or 0,
            obj = math.type(okey) == "integer" and fhex(okey) or tostring(okey), msg = msg })
    end
    if S.err_logged < K.ERR_LOG_MAX or action ~= "err" then
        S.err_logged = S.err_logged + 1
        log.info(TAG .. "ERR mod=" .. modname .. " act=" .. action .. " msg=" .. msg)
    end
    S.in_err = false
end

-- 守卫停掉一个模块（频率 / 耗时超限）：写 GUARD，不走 report_error（审查 F7：旧版记成 PERF 出错，3 次就把 PERF 自己停了）
local function guard_stop(modname, why, now)
    local m = MODS[modname]
    if not m.on then return end
    m.on = false
    m.guard = true
    refresh_flags()
    emit_log("GUARD", now, { mod = modname, why = why }, { "mod", "why" })
    table.insert(S.err_list, 1, safe_fmt("%.1f %s 守卫停用 %s", now - S.t_load, modname, why))
    if #S.err_list > 10 then table.remove(S.err_list) end
end

-- 重开模块：all = true 时连守卫停掉的也重开（菜单按钮）；加载自检缺项、钩子没装上的不重开
local function reopen_modules(all, why)
    local names = {}
    for _, name in ipairs(MOD_LIST) do
        local m = MODS[name]
        if not m.st_missing and not m.no_hook and (m.perm or m.pause_until or (all and m.guard)) then
            m.on, m.perm, m.pause_until, m.pause_run, m.pause_t, m.win = true, false, nil, 0, nil, {}
            if all then m.guard = false end
            names[#names + 1] = name
        end
    end
    if all then S.init_hi, S.hook_hi, S.frame_hi, S.gar_hi = 0, 0, 0, 0 end
    refresh_flags()
    if #names > 0 then
        emit_log("NOTE", os.clock(), { what = "reopen", why = why, mods = table.concat(names, ",") },
            { "what", "why", "mods" })
    end
end

-- 读取：返回读到的值（最多 6 个）；模块不能用或出错时返回 nil（出错只跳过这一次，见 report_error）
local function opt(modname, obj, fn, ...)
    local m = MODS[modname]
    if not mod_ok(m) then return nil end
    local ok, a, b, c, d, e, f = pcall(fn, ...)
    if ok then return a, b, c, d, e, f end
    report_error(modname, a, obj)
    return nil
end

-- ========================================================================
-- 枚举（只要 RESULT_TYPE 的名字）
-- ========================================================================
local RT_NAMES = {}
local function enum_load(map, type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then return false end
    for _, fld in ipairs(td:get_fields()) do
        if fld:is_static() then
            local ok, v = pcall(fld.get_data, fld, nil)
            if ok and type(v) == "number" then map[v] = fld:get_name() end
        end
    end
    return true
end
pcall(enum_load, RT_NAMES, "app.AttackAreaResult.RESULT_TYPE")

local function rt_name(v)
    if v == nil then return nil end
    return RT_NAMES[v] or fint(v)
end

-- ========================================================================
-- 小工具：位解码、Nullable、列表
-- ========================================================================
-- 栈槽低 32 位 → 单精度（Lua 5.4 的 string.pack / unpack，不依赖 REF）
local function bits_to_float(bits)
    local iv = math.tointeger(bits)
    if not iv then return nil end
    local ok, v = pcall(string.unpack, "<f", string.pack("<I4", iv & 0xFFFFFFFF))
    if ok then return v end
    return nil
end

-- Nullable 值类型（get_field 拿到的 ValueType）→ "数值" / "none" / nil（读不到）
-- 返回形态在 Lua 里可能是带 _HasValue/_Value 的值类型，也可能被自动拆箱成数字，两种都接（同 APCal）
local function nullable_str(nv)
    if nv == nil then return nil end
    local tv = type(nv)
    if tv == "number" then return fint(nv) end
    if tv == "boolean" or tv == "string" then return nil end
    local has = nv:get_field("_HasValue")
    if not has then return "none" end
    local v = nv:get_field("_Value")
    if v == nil then return "none" end
    return fint(v)
end

-- List<UInt32> → "37,38,47"、个数（最多 K.CIDS_MAX 个）
local function u32_list(list)
    if not list then return nil, nil end
    local n = math.tointeger(list:call("get_Count"))
    if not n then error("CollidableIDList.get_Count is not an integer") end
    local parts = {}
    for i = 0, math.min(n, K.CIDS_MAX) - 1 do
        local v = list:call("get_Item", i)
        parts[#parts + 1] = fint(v)
    end
    return table.concat(parts, ","), n
end

local function act_str(c, i)
    if c == nil or i == nil then return nil end
    return "(" .. fint(c) .. "," .. fint(i) .. ")"
end

local function short_name(full)
    if not full then return nil end
    return (full:gsub("^app%.", ""))
end

-- ========================================================================
-- 怪物：编号、取对象、快照
-- ========================================================================
local function em_key(emid, idx)
    return "em" .. tostring(math.tointeger(emid) or emid or "?") .. "#" .. tostring(math.tointeger(idx) or idx or "?")
end

-- EnemyCharacter → "em<EmID>#<SystemIndex>", SystemIndex（和 APCal 同一条路径、同一种写法）。
-- SystemIndex 是每帧找回这只怪的钥匙，单独读；EmID 读不到时写成 em?#<SystemIndex>，监视照常
local function enemy_id_raw(enemy)
    local holder = enemy:get_field("_Context")
    local em = holder and holder:get_field("_Em")
    if not em then return nil, nil end
    local idx = em:call("get_SystemIndex")
    local okid, emid = pcall(em.call, em, "get_EmID")
    return em_key(okid and emid or nil, idx), math.tointeger(idx)
end

-- 返回 key, SystemIndex, 来源（cache / read / stale / none）。
-- 读不到时（瞬时异常、模块暂停）退回这个地址上次读到的编号（过期也用：同一会话里地址被新怪复用的概率很低，
-- 而且 mon_tick 每帧会核对地址）；再没有就返回 nil，调用方把 em 写成 @地址（同 APCal 的退路）。
-- 没有 SystemIndex 的怪不进监视表：规则是不跨帧持有对象，每帧只能靠 SystemIndex 重新找回它（审查 F2 的
-- 「用地址做监视键」做不到：EnemyManager 只有返回 ReadOnlySpan 的列表，按地址找回 = 持有悬空地址）
local function enemy_key(enemy, now)
    local addr = enemy:get_address()
    local c = S.em_by_addr[addr]
    if c and now - c.t < K.EM_CACHE_AGE then return c.key, c.idx, "cache" end
    local key, idx = opt("EMID", addr, enemy_id_raw, enemy)
    if key then
        S.em_by_addr[addr] = { key = key, idx = idx, t = now }
        return key, idx, "read"
    end
    if c then return c.key, c.idx, "stale" end
    return nil, nil, "none"
end

-- 当帧取怪物（不跨帧持有）：EnemyManager.findEnemy_SystemIndex → cEnemyManageInfo.get_Character
local function find_enemy(idx)
    local mgr = sdk.get_managed_singleton("app.EnemyManager")
    local info = mgr and mgr:call("findEnemy_SystemIndex(System.Int32)", idx)
    return info and info:call("get_Character") or nil
end

-- 引擎时钟：DeltaTime（单位帧）、FrameCount（引擎帧号，查跳帧用）
local APP_PTR, APP_TD = nil, nil
local function read_clock()
    if APP_PTR == nil then
        APP_PTR = sdk.get_native_singleton("via.Application")
        APP_TD = sdk.find_type_definition("via.Application")
    end
    if not APP_PTR or not APP_TD then return nil, nil end
    return sdk.call_native_func(APP_PTR, APP_TD, "get_DeltaTime"), sdk.call_native_func(APP_PTR, APP_TD, "get_FrameCount")
end

-- _MotionSpeed 值类型（字段读取，没有副作用）：分量串、_TotalMotionSpeedThisFream
local function read_spd_struct(enemy)
    local ms = enemy:get_field("_MotionSpeed")
    if ms == nil then return nil, nil end
    local parts = {}
    for i, fname in ipairs(SPD_FIELDS) do parts[i] = fnum(ms:get_field(fname), "%.4f") end
    return table.concat(parts, "/"), ms:get_field("_TotalMotionSpeedThisFream")
end

-- get_MotionSpeed_* 读取器（属性读取，只在 initData 时读一次，和字段对照）
local function read_spd_getters(enemy)
    local parts = {}
    for i, g in ipairs(SPD_GETTERS) do parts[i] = fnum(enemy:call("get_MotionSpeed_" .. g), "%.4f") end
    return table.concat(parts, "/")
end

-- calcMotionSpeedTotal(true/false)：APCal 一直在事件时调用（第 1、2 轮几千次），按名字是纯计算。
-- 没法不反编译就证明它无副作用（万一它顺手写 _TotalMotionSpeedThisFream 缓存），所以不在 initData 钩子
-- （帧中间、游戏正在更新这只怪）里调，改成 initData 之后下一帧帧开头调一次（mon.calc_once）；菜单可以打开每帧调用。
local function read_calc(enemy)
    return enemy:call("calcMotionSpeedTotal(System.Boolean)", true),
        enemy:call("calcMotionSpeedTotal(System.Boolean)", false)
end

-- 动作层 0：Frame / Speed / MotionID / MotionBankID；Motion 组件 PlaySpeed
local function read_motion(enemy)
    local mot = enemy:call("get_MotionComponent")
    if not mot then return nil end
    local layer = mot:call("getLayer(System.UInt32)", 0)
    local pls = mot:call("get_PlaySpeed")
    if not layer then return nil, nil, nil, nil, pls end
    return layer:call("get_Frame"), layer:call("get_Speed"), layer:call("get_MotionID"), layer:call("get_MotionBankID"),
        pls
end

-- 当前动作：ID、对象地址、raw 已过秒数、chara 已过秒数
local function read_action(enemy)
    local ctrl = enemy:call("get_BaseActionController")
    if not ctrl then return nil end
    local id = ctrl:call("get_CurrentActionID")
    local act = ctrl:call("get_CurrentAction")
    local s = id and act_str(id:get_field("_Category"), id:get_field("_Index")) or nil
    if not act then return s, nil, nil, nil end
    local raw = act:get_field("_RawTotalElapsedSecond")
    local chara = act:call("get_CharaElapsedSecond")
    return s, act:get_address(), raw, chara, act
end

local function read_ts(enemy)
    local go = enemy:call("get_GameObject")
    return go and go:call("get_TimeScale") or nil
end

-- 动作类名（按动作对象地址缓存；动作对象是怪物预先建好的，地址稳定）
local function action_name(act, aaddr, now)
    if not act or not aaddr then return nil end
    local c = S.names[aaddr]
    if c and now - c.t < K.NAME_CACHE_AGE then return c.name end
    local name = short_name(act:get_type_definition():get_full_name())
    S.names[aaddr] = { name = name, t = now }
    return name
end

-- 怒 / 疲劳、当前动作的覆盖速度率（只在 initData 时读）
local function read_emst(enemy)
    local holder = enemy:get_field("_Context")
    local em = holder and holder:get_field("_Em")
    -- 不能写成 em and em:call(...) or nil：返回 false（不怒）时会变成 nil，记成「读不到」
    local angry, tired = nil, nil
    if em then
        angry = em:call("get_IsAngry")
        tired = em:call("get_IsTired")
    end
    return angry, tired, enemy:call("getOverrideMotionRateAngryCurrentAction"),
        enemy:call("getOverrideMotionRateTiredCurrentAction")
end

-- 每帧读数涉及的模块（mon_tick 按怪统计它们连续出错的帧数，见 K.OBJ_SKIP_N）
local SNAP_MODS = { "SPDS", "CALC", "MOT", "ACT", "TS", "ACTN" }

-- 这只怪现在要不要跳过这个模块（skip = 监视表里这只怪的 { 模块 = 跳到什么时候 }）
local function skipped(skip, name, now)
    local u = skip and skip[name]
    return u ~= nil and now < u
end

-- 一只怪一帧的读数。full = initData 时的完整快照（多读读取器分量、怒疲劳、动作名）；calc = 这次调
-- calcMotionSpeedTotal（只在帧开头）。ekey = 这只怪的地址（出错时按对象计，见 report_error）；skip 见上
local function read_snap(enemy, now, full, calc, ekey, skip)
    local s = {}
    if not skipped(skip, "SPDS", now) then s.scomp, s.tot = opt("SPDS", ekey, read_spd_struct, enemy) end
    if full then s.gcomp = opt("SPDG", ekey, read_spd_getters, enemy) end
    if calc and not skipped(skip, "CALC", now) then s.spt, s.spf = opt("CALC", ekey, read_calc, enemy) end
    if not skipped(skip, "MOT", now) then
        s.mf, s.ms, s.mid, s.bank, s.pls = opt("MOT", ekey, read_motion, enemy)
    end
    local act = nil
    if not skipped(skip, "ACT", now) then
        s.act, s.aaddr, s.ael, s.ace, act = opt("ACT", ekey, read_action, enemy)
    end
    if not skipped(skip, "TS", now) then s.ts = opt("TS", ekey, read_ts, enemy) end
    if act and (full or s.aaddr) and not skipped(skip, "ACTN", now) then
        s.actn = opt("ACTN", ekey, action_name, act, s.aaddr, now)
    end
    if full then s.angry, s.tired, s.ovra, s.ovrt = opt("EMST", ekey, read_emst, enemy) end
    return s
end

-- ========================================================================
-- 监视表：initData 之后盯怪物 K.WIN 秒（或 hs 倒数完 + K.WIN_PAD 秒，最多 K.WIN_MAX）
-- ========================================================================
-- 满员时（审查 F6）：打主角（tme=1）的 initData 挤掉最久没有 tme=1 的那只（从来没有过的最先，同样的挤最早开始盯的），
-- 别的（打随从 / NPC，或者没有外层建结果调用、不知道目标）只用空位。一群打随从的小怪不会把打主角的那只挤掉
local function mon_evict_for(key, now)
    local vi, vm, va = nil, nil, nil
    for i2, m2 in pairs(S.mon) do
        local a = m2.last_tme or -1e18
        if vm == nil or a < va or (a == va and m2.t_first < vm.t_first) then vi, vm, va = i2, m2, a end
    end
    if vi == nil then return false end
    emit("NOTE", now, { what = "evict", em = vm.key, idx = vi, by = key })
    S.mon[vi] = nil
    S.n_mon = S.n_mon - 1
    S.perf.mon_evict = S.perf.mon_evict + 1
    return true
end

local function mon_touch(idx, key, eaddr, now, extra, tme)
    if idx == nil then
        S.perf.mon_noidx = S.perf.mon_noidx + 1
        return nil
    end
    local m = S.mon[idx]
    if not m then
        if S.n_mon >= K.MON_MAX then
            if tme ~= 1 or not mon_evict_for(key, now) then
                S.perf.mon_full = S.perf.mon_full + 1
                return nil
            end
        end
        m = { key = key, eaddr = eaddr, until_t = now, miss = 0, bad = 0, t_first = now, fail = {}, skip = {}, nb = {} }
        S.mon[idx] = m
        S.n_mon = S.n_mon + 1
    end
    if eaddr and m.eaddr ~= eaddr then
        -- SystemIndex 被另一只怪复用：从头开始（动作、分量的「上一次」、出错计数都清掉）
        m.key, m.eaddr, m.act_addr, m.spd_sig, m.miss, m.bad, m.t_first = key, eaddr, nil, nil, 0, 0, now
        m.last_tme, m.fail, m.skip = nil, {}, {}
    end
    m.key = key or m.key
    if tme == 1 then m.last_tme = now end
    local untl = now + math.max(K.WIN, math.min(K.WIN_MAX, extra or 0))
    if untl > m.until_t then m.until_t = untl end
    return m
end

-- ========================================================================
-- initData 钩子：pre 读参数和调用前的条目，post 读初始化后的 hs/he
-- ========================================================================
-- pre/post 配对栈（initData 不会递归；若在别的线程并发调用，post 可能拿到别人的记录 → 记 depth，离线可剔除）
local ISTACK, ISTACKF = {}, {}
-- getAttackAreaResult / getCurrentAttackAreaResult 的调用上下文栈（栈顶 = 正在建的结果，期间的 initData 都归它）
local GSTACK, GSTACKF = {}, {}

-- 值类型实参（按指针传）读之前先看地址像不像指针：≥ 4 GB、≤ 用户态上限、4 字节对齐。
-- 万一某个值类型其实是按值传的，栈槽里是它的头 8 个字节：带浮点的结构（vec3、Nullable<Single>）高 32 位是浮点位，
-- 远超用户态上限；浮点为 0 时整个数 < 4 GB —— 都过不了检查，不会被当成指针去读。
-- 真指针（堆、线程栈）在这台机器上都在 4 GB 以上（实测地址形如 0x13C6200000）。
local function ptr_ok(arg)
    local iv = math.tointeger(sdk.to_int64(arg))
    return iv ~= nil and iv >= 0x100000000 and iv <= 0x7FFFFFFFFFFF and iv % 4 == 0
end

-- 目标胶囊（值类型按指针传）：原始参数直接交给 sdk.to_valuetype（NOTES 里 TARGET_ACCESS_KEY 验证过的用法）
local function cap_str(arg)
    if not ptr_ok(arg) then return nil end
    local cap = sdk.to_valuetype(arg, "via.Capsule")
    if not cap then return nil end
    local p0, p1, r = cap:get_field("p0"), cap:get_field("p1"), cap:get_field("r")
    if not p0 or not p1 then return nil end
    return safe_fmt("%.2f,%.2f,%.2f,%.2f,%.3f", p0.x, p0.y, p0.z, p1.y, r or -1)
end

local function area_read(area, rec, okey)
    rec.req = nullable_str(area:get_field("RequestSetID"))
    rec.shell = nullable_str(area:get_field("ShellIndex"))
    rec.cids, rec.ncid = opt("CIDS", okey, u32_list, area:get_field("CollidableIDList"))
end

local function init_pre_body(args)
    local now = os.clock()
    local this = sdk.to_managed_object(args[2])
    if not this then return false end
    local enemy = sdk.to_managed_object(args[3])
    local area = sdk.to_managed_object(args[4])
    local sbits = sdk.to_int64(args[5]) & 0xFFFFFFFF
    local eaddr = enemy and enemy:get_address() or nil
    local okey = eaddr or this:get_address()        -- 出错时按怪物计（见 report_error）
    local rec = {
        f = S.f, ctx = fhex(sdk.to_int64(args[1])), ent = fhex(this:get_address()),
        sbits = fhex(sbits), sgl = jnum(bits_to_float(sbits), "%.4f"),
        stk = fhex(sdk.to_int64(args[7])),
    }
    if type(sdk.to_float) == "function" then rec.sgl2 = jnum(opt("F2", nil, sdk.to_float, args[5]), "%.4f") end
    -- 外层 getAttackAreaResult 调用（有的话）：调用编号、目标是不是主角
    local g = GSTACK[#GSTACK]
    if g then
        rec.gar, rec.tme = g.id, g.tme
        g.n_init = g.n_init + 1
    end
    rec.hs_pre = jnum(this:call("get_HitStartRemainFrame"), "%.3f")
    rec.he_pre = jnum(this:call("get_HitEndRemainFrame"), "%.3f")
    if area then
        rec.aad = fhex(area:get_address())
        rec.ast = jnum(area:get_field("AttackStartFrame"), "%.3f")
        rec.aen = jnum(area:get_field("AttackEndFrame"), "%.3f")
        opt("AREA", okey, area_read, area, rec, okey)
    end
    rec.cap = opt("CAP", okey, cap_str, args[6])
    if enemy then
        rec.emaddr = fhex(eaddr)
        local key, idx, src = enemy_key(enemy, now)
        rec.em, rec.idx = key or ("@" .. fhex(eaddr)), idx
        if src == "stale" or src == "none" then rec.ems = src end
        -- 同一帧同一只怪只读一次完整快照（一招常有好几条 initData）
        if S.icache_f ~= S.f then
            S.icache, S.icache_f = {}, S.f
        end
        local snap = S.icache[eaddr]
        if not snap then
            snap = read_snap(enemy, now, true, false, eaddr)
            S.icache[eaddr] = snap
        end
        rec.snap = snap
        -- 快照里的当前动作是不是外层调用要建预告的那个动作（不是 → 快照多半还是上一个动作，审查 F3）
        if g and g.act and snap.act then rec.aeq = (snap.act == g.act) and 1 or 0 end
        mon_touch(idx, rec.em, eaddr, now, nil, rec.tme)
    end
    return { rec = rec, obj = this, t = now, okey = okey }
end

local function snap_into(rec, s)
    if not s then return end
    rec.scomp, rec.gcomp = s.scomp, s.gcomp
    rec.tot, rec.spt, rec.spf = jnum(s.tot, "%.4f"), jnum(s.spt, "%.4f"), jnum(s.spf, "%.4f")
    rec.mf, rec.ms, rec.mid, rec.bank = jnum(s.mf, "%.3f"), jnum(s.ms, "%.4f"), jint(s.mid), jint(s.bank)
    rec.pls, rec.ts = jnum(s.pls, "%.4f"), jnum(s.ts, "%.4f")
    rec.act, rec.aaddr, rec.actn = s.act, s.aaddr and fhex(s.aaddr) or nil, s.actn
    rec.ael, rec.ace = jnum(s.ael, "%.4f"), jnum(s.ace, "%.4f")
    rec.angry, rec.tired = jbool(s.angry), jbool(s.tired)
    rec.ovra, rec.ovrt = jnum(s.ovra, "%.4f"), jnum(s.ovrt, "%.4f")
end

local function init_post_body(item, depth)
    local rec = item.rec
    local obj = item.obj
    item.obj = nil      -- 条目对象只用到这里
    rec.hs = jnum(obj:call("get_HitStartRemainFrame"), "%.3f")
    rec.he = jnum(obj:call("get_HitEndRemainFrame"), "%.3f")
    rec.rt = rt_name(opt("RT", obj:get_address(), obj.call, obj, "get_ResultType"))
    rec.depth = depth
    rec.same = (rec.hs ~= nil and rec.hs == rec.hs_pre and rec.he == rec.he_pre) and 1 or 0
    local snap = rec.snap
    rec.snap = nil
    snap_into(rec, snap)
    emit("INIT", item.t, rec)
    S.n_init_total = S.n_init_total + 1
    S.last_init_t = item.t
    if rec.hs then
        -- 打主角或目标未知的预告「还在倒数」：这段时间不写 JSON（写盘会卡帧，审查 F5）
        if rec.tme ~= 0 then
            local b = item.t + math.min(K.BUSY_MAX, math.max(rec.hs, 0.0) / 60.0 * K.BUSY_SLOW + K.BUSY_PAD)
            if b > S.busy_until then S.busy_until = b end
        end
        -- 按 hs 延长监视（pre 里已经登记过；没拿到位置的不再登记一次，免得 mon_full 重复计）：
        -- 长预告要一直盯到倒数完；下一帧帧开头调一次 calcMotionSpeedTotal
        local m = rec.idx ~= nil and S.mon[rec.idx] or nil
        if m then
            local untl = item.t + math.max(K.WIN, math.min(K.WIN_MAX, rec.hs / 60.0 + K.WIN_PAD))
            if untl > m.until_t then m.until_t = untl end
            m.calc_once = true
        end
    end
end

local function hook_time(t0)
    local P = S.perf
    P.hook_ms = P.hook_ms + (os.clock() - t0) * 1000.0
end

-- 钩子参数里的地址（出错时当对象键用；拿不到就当全局）
local function arg_addr(a)
    local ok, v = pcall(sdk.to_int64, a)
    if ok then return math.tointeger(v) end
    return nil
end

local function init_pre(args)
    -- 第一行：原始调用次数（停用、暂停、守卫以后照样计，PERF 的 init_raw_ps，审查 F7）
    S.perf.init_raw = S.perf.init_raw + 1
    local item = false
    if not init_off then
        local t0 = os.clock()
        S.perf.init = S.perf.init + 1
        local ok, res = pcall(init_pre_body, args)
        if ok then item = res or false else report_error("INIT", res, arg_addr(args[3])) end
        hook_time(t0)
    end
    -- 停用后也照样压栈（压一个 false）：post 每次都会被调用，栈必须配对
    ISTACK[#ISTACK + 1] = item
    ISTACKF[#ISTACKF + 1] = S.f
end

local function init_post(retval)
    local n = #ISTACK
    if n == 0 then return retval end
    local item = ISTACK[n]
    ISTACK[n], ISTACKF[n] = nil, nil
    -- pre 已经读过的记录照样写完（这一条的 pre 发生时模块是开着的）；守卫停掉以后 pre 只压 false
    if item then
        local t0 = os.clock()
        if n > 1 then S.perf.deep = S.perf.deep + 1 end
        local ok, err = pcall(init_post_body, item, n)
        if not ok then report_error("INIT", err, item.okey) end
        hook_time(t0)
    end
    return retval
end

-- ========================================================================
-- getAttackAreaResult / getCurrentAttackAreaResult 钩子（GAR，可选）：只读实参，post 只取返回值地址（不建对象）
-- ========================================================================
local gar_seq = 0

-- Nullable<Single> 实参 → 值（有值时）、状态 "val" / "none"
local function nullable_f(arg)
    if not ptr_ok(arg) then return nil, "bad" end
    local nv = sdk.to_valuetype(arg, "System.Nullable`1<System.Single>")
    if not nv then return nil, "bad" end
    if not nv:get_field("_HasValue") then return nil, "none" end
    return nv:get_field("_Value"), "val"
end

local function nullable_has(arg, tname)
    if not ptr_ok(arg) then return nil end
    local nv = sdk.to_valuetype(arg, tname)
    if not nv then return nil end
    return nv:get_field("_HasValue") == true
end

local function action_id_arg(arg)
    if not ptr_ok(arg) then return nil end
    local id = sdk.to_valuetype(arg, "ace.ACTION_ID")
    return id and act_str(id:get_field("_Category"), id:get_field("_Index")) or nil
end

-- kind = "gar"（任意动作，args[4] 是 ACTION_ID）/ "cur"（当前动作，没有 ACTION_ID）
local function gar_pre_body(args, kind)
    gar_seq = gar_seq + 1
    local tgt = sdk.to_int64(args[3])           -- 目标 CharacterBase 地址（只取数字，不建对象）
    local g = { id = gar_seq, kind = kind, t = os.clock(), f = S.f, det = fhex(sdk.to_int64(args[2])), tgt = fhex(tgt),
        tme = (S.hunter_addr ~= nil and tgt == S.hunter_addr) and 1 or 0, n_init = 0 }
    local i1 = 4
    if kind == "gar" then
        g.act = action_id_arg(args[4])
        i1 = 5
        g.flag = (sdk.to_int64(args[8]) & 1) == 1 and 1 or 0
    end
    g.p1, g.p1s = nullable_f(args[i1])
    g.p2, g.p2s = nullable_f(args[i1 + 1])
    g.pos = nullable_has(args[i1 + 2], "System.Nullable`1<via.vec3>")
    return g
end

local function gar_post_body(g, retval, depth)
    S.n_gar_total = S.n_gar_total + 1
    emit("GAR", g.t, {
        id = g.id, kind = g.kind, f = g.f, det = g.det, tgt = g.tgt, tme = g.tme, act = g.act, flag = g.flag,
        p1 = jnum(g.p1, "%.4f"), p1s = g.p1s, p2 = jnum(g.p2, "%.4f"), p2s = g.p2s, pos = jbool(g.pos),
        res = fhex(sdk.to_int64(retval)), n_init = g.n_init, depth = depth,
    })
end

local function make_gar_hooks(kind)
    local function pre(args)
        S.perf.gar_raw = S.perf.gar_raw + 1     -- 第一行：原始调用次数（审查 F7）
        local g = false
        if not gar_off then
            local t0 = os.clock()
            S.perf.gar = S.perf.gar + 1
            local ok, res = pcall(gar_pre_body, args, kind)
            if ok then g = res or false else report_error("GAR", res, arg_addr(args[2])) end
            hook_time(t0)
        end
        GSTACK[#GSTACK + 1] = g
        GSTACKF[#GSTACKF + 1] = S.f
    end
    local function post(retval)
        local n = #GSTACK
        if n == 0 then return retval end
        local g = GSTACK[n]
        GSTACK[n], GSTACKF[n] = nil, nil
        if g then
            local t0 = os.clock()
            local ok, err = pcall(gar_post_body, g, retval, n)
            if not ok then report_error("GAR", err) end
            hook_time(t0)
        end
        return retval
    end
    return pre, post
end

local gar_pre, gar_post = make_gar_hooks("gar")
local gcar_pre, gcar_post = make_gar_hooks("cur")

-- 主角地址（GAR 判断目标是不是主角用）：帧开头取一次，只存数字。没有主角返回 false（出错时 opt 返回 nil，
-- 调用方据此区分：没有主角就清掉，出错就沿用上一帧的）
local function read_hunter_addr()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    local h = p and p:call("get_Character")
    return h and h:get_address() or false
end

-- 兜底：上一帧（或更早）压进去、还没等到 post 的记录直接丢掉（不让条目对象跨帧）。
-- 每条写一行 ORPH（带它所在的帧号）：这一帧的 pre/post 可能配错了，离线把这一帧的 INIT 全部剔除（审查 F8）
local function clear_stale_stack()
    for _, pair in ipairs({ { ISTACK, ISTACKF, "init" }, { GSTACK, GSTACKF, "gar" } }) do
        local st, sf, kind = pair[1], pair[2], pair[3]
        local n = #st
        if n > 0 and sf[1] < S.f then
            for i = n, 1, -1 do
                local it = st[i]
                if it then
                    S.perf.orphan = S.perf.orphan + 1
                    if S.n_orph < K.ORPH_MAX then
                        S.n_orph = S.n_orph + 1
                        local r = (kind == "init") and it.rec or nil
                        emit("ORPH", S.now, { kind = kind, f = sf[i], ent = r and r.ent or nil, em = r and r.em or nil,
                            id = (kind == "gar") and it.id or nil })
                    end
                    if kind == "init" then it.obj = nil end
                end
                st[i], sf[i] = nil, nil
            end
        end
    end
end

-- ========================================================================
-- 每帧：监视中的怪物各记一条 EMF（+ 分量变化 EMSPD、动作变化 EMACT）
-- ========================================================================
local function emf_value(s, gdt, gfc)
    local v = {
        fnum(s.tot, "%.4f"), fnum(s.ms, "%.4f"), fnum(s.mf, "%.3f"), fint(s.mid), fint(s.bank), fnum(s.pls, "%.4f"),
        fnum(s.ts, "%.4f"), fnum(s.ael, "%.4f"), fnum(s.ace, "%.4f"), s.act or "-", fnum(gdt, "%.4f"), fint(gfc),
        fnum(s.spt, "%.4f"), fnum(s.spf, "%.4f"),
    }
    return table.concat(v, "|")
end

local function mon_tick(idx, m, now, gdt, gfc)
    -- 找怪模块暂停中（或本帧已在 2 只怪上出错）：这一帧什么都不记，也不算 miss（暂停 2 s ≈ 120 帧，
    -- 算 miss 的话暂停一结束所有怪都会因为 MISS_DROP 被踢出监视表）
    if not mod_ok(MODS.FIND) then return end
    local e0 = S.n_err
    local enemy = opt("FIND", idx, find_enemy, idx)
    if not enemy then
        -- 找怪本身抛错算这只怪「坏了」的一帧（多半正在销毁）；只是找不到（返回 nil）算 miss
        if S.n_err > e0 then m.bad = m.bad + 1 else m.miss = m.miss + 1 end
        return
    end
    local eaddr = enemy:get_address()
    if m.eaddr and eaddr ~= m.eaddr then
        -- SystemIndex 已经是另一只怪了：这只不再盯（新怪等它自己的 initData）
        emit("NOTE", now, { what = "reuse", em = m.key, idx = idx, old = fhex(m.eaddr), new = fhex(eaddr) })
        m.until_t = -1
        return
    end
    m.miss = 0
    local calc = S.calc_every_frame or m.calc_once == true
    m.calc_once = nil
    local nb = m.nb
    for i, name in ipairs(SNAP_MODS) do nb[i] = MODS[name].n end
    local s = read_snap(enemy, now, false, calc, eaddr, m.skip)
    -- 按模块数这只怪连续出错的帧数：到 K.OBJ_SKIP_N 就只让这只怪跳过这个模块一阵子（审查 F2：单只怪坏了不停整个模块）
    for i, name in ipairs(SNAP_MODS) do
        if MODS[name].n > nb[i] then
            local c = (m.fail[name] or 0) + 1
            if c >= K.OBJ_SKIP_N then
                m.skip[name] = now + K.OBJ_SKIP_S
                c = 0
                emit("NOTE", now, { what = "obj_skip", em = m.key, mod = name })
            end
            m.fail[name] = c
        elseif not skipped(m.skip, name, now) then
            m.fail[name] = 0
        end
    end
    emit("EMF", now, { f = S.f, em = m.key, v = emf_value(s, gdt, gfc) })
    S.perf.emf = S.perf.emf + 1
    if s.scomp and s.scomp ~= m.spd_sig then
        m.spd_sig = s.scomp
        emit("EMSPD", now, { f = S.f, em = m.key, comp = s.scomp })
    end
    if s.aaddr ~= m.act_addr then
        m.act_addr = s.aaddr
        emit("EMACT", now, { f = S.f, em = m.key, act = s.act, name = s.actn, aaddr = s.aaddr and fhex(s.aaddr) or nil })
    end
    -- 这只怪本帧有 ≥2 个读数出错 → 算「坏了」的一帧，连续 K.MON_BAD_DROP 帧就不再盯（多半正在销毁），别的怪不受影响。
    -- 只有 1 个读数出错多半是那个模块自己的问题（例如 TimeScale 读不了），交给模块的暂停规则，不能因此丢掉这只怪的 EMF
    if S.n_err - e0 >= 2 then m.bad = m.bad + 1 else m.bad = 0 end
end

local function emf_tick(now)
    if S.n_mon == 0 then return end
    local gdt, gfc = opt("CLK", nil, read_clock)
    local t0 = os.clock()
    for idx, m in pairs(S.mon) do
        if now > m.until_t or m.miss >= K.MISS_DROP or m.bad >= K.MON_BAD_DROP then
            if m.bad >= K.MON_BAD_DROP then
                S.perf.mon_bad = S.perf.mon_bad + 1
                emit("NOTE", now, { what = "drop_bad", em = m.key, idx = idx })
            end
            S.mon[idx] = nil
            S.n_mon = S.n_mon - 1
        else
            local e0 = S.n_err
            local ok, err = pcall(mon_tick, idx, m, now, gdt, gfc)
            if not ok then
                report_error("EMF", err, idx)
                if S.n_err > e0 then m.bad = m.bad + 1 end
            end
        end
    end
    local ms = (os.clock() - t0) * 1000.0
    local P = S.perf
    P.frame_ms = P.frame_ms + ms
    P.frame_n = P.frame_n + 1
    if ms > P.frame_max then P.frame_max = ms end
end

-- ========================================================================
-- PERF（每 5 s）与自停守卫
-- ========================================================================
-- 各模块的出错情况：「模块:出错次数/暂停次数[/stop|/guard|/off]」，只列有过错误或停用的（PERF 的 merr）
local function mod_summary()
    local parts = {}
    for _, name in ipairs(MOD_LIST) do
        local m = MODS[name]
        if m.n > 0 or m.n_pause > 0 or not m.on or m.pause_until then
            local st = ""
            if m.perm then
                st = "/stop"
            elseif m.guard then
                st = "/guard"
            elseif not m.on then
                st = "/off"
            elseif m.pause_until then
                st = "/pause"
            end
            parts[#parts + 1] = name .. ":" .. fint(m.n) .. "/" .. fint(m.n_pause) .. st
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ",")
end

local function perf_reset(now)
    local P = S.perf
    P.t0, P.frames, P.init, P.hook_ms, P.frame_ms, P.frame_n, P.frame_max = now, 0, 0, 0, 0, 0, 0
    P.orphan, P.deep, P.emf, P.gar, P.init_raw, P.gar_raw = 0, 0, 0, 0, 0, 0
    P.mon_full, P.mon_evict, P.mon_noidx, P.mon_bad = 0, 0, 0, 0
end

local function perf_tick(now)
    local P = S.perf
    local period = now - P.t0
    if period < K.PERF_PERIOD then return end
    local fps = P.frames / period
    local init_ps = P.init / period
    local gar_ps = P.gar / period
    local hook_ms_ps = P.hook_ms / period
    local frame_avg = P.frame_n > 0 and P.frame_ms / P.frame_n or 0
    S.raw_init_total = S.raw_init_total + P.init_raw
    S.raw_gar_total = S.raw_gar_total + P.gar_raw
    local rec = {
        fps = jnum(fps, "%.1f"), init_ps = jnum(init_ps, "%.1f"), hook_ms_ps = jnum(hook_ms_ps, "%.2f"),
        init_raw_ps = jnum(P.init_raw / period, "%.1f"), gar_raw_ps = jnum(P.gar_raw / period, "%.1f"),
        frame_ms_avg = jnum(frame_avg, "%.3f"), frame_ms_max = jnum(P.frame_max, "%.3f"), mon = S.n_mon,
        emf_ps = jnum(P.emf / period, "%.1f"), buf = #S.jbuf, files = S.files, orphan = P.orphan, deep = P.deep,
        init_off = init_off and 1 or 0, emf_off = mod_ok(MODS.EMF) and 0 or 1, errs = S.n_err,
        gar_ps = jnum(gar_ps, "%.1f"), gar_off = gar_off and 1 or 0, merr = mod_summary(),
        mon_full = P.mon_full, mon_evict = P.mon_evict, mon_noidx = P.mon_noidx, mon_bad = P.mon_bad,
        busy = now < S.busy_until and 1 or 0,
    }
    emit_log("PERF", now, rec, { "fps", "init_ps", "init_raw_ps", "gar_ps", "gar_raw_ps", "hook_ms_ps", "frame_ms_avg",
        "frame_ms_max", "mon", "mon_full", "mon_evict", "emf_ps", "buf", "files", "orphan", "deep", "init_off",
        "gar_off", "emf_off", "errs", "merr" })
    S.perf_text = safe_fmt("fps %.1f | initData %.1f 次/秒（原始 %.1f）钩子 %.2f ms/秒 | 每帧 %.3f ms（最大 %.3f）| 盯 %d 只",
        fps, init_ps, P.init_raw / period, hook_ms_ps, frame_avg, P.frame_max, math.tointeger(S.n_mon) or 0)
    -- initData 频率 / 钩子耗时守卫：连续 2 个周期超限 → 钩子第一行直接 return，写 GUARD（不走 report_error，
    -- 不占 PERF 的出错额度，审查 F7）。钩子耗时是 initData 和 GAR 两组钩子合计，超限时两组一起停
    S.hook_hi = (hook_ms_ps > K.HOOK_MS_LIMIT) and S.hook_hi + 1 or 0
    if MODS.INIT.on then
        S.init_hi = (init_ps > K.INIT_LIMIT) and S.init_hi + 1 or 0
        if S.init_hi >= K.GUARD_PERIODS or S.hook_hi >= K.GUARD_PERIODS then
            guard_stop("INIT", safe_fmt("initData %.0f/s hook %.1f ms/s for %d periods", init_ps, hook_ms_ps,
                math.tointeger(math.max(S.init_hi, S.hook_hi)) or 0), now)
        end
    end
    if MODS.GAR.on then
        S.gar_hi = (gar_ps > K.INIT_LIMIT) and S.gar_hi + 1 or 0
        if S.gar_hi >= K.GUARD_PERIODS or S.hook_hi >= K.GUARD_PERIODS then
            guard_stop("GAR", safe_fmt("getAttackAreaResult %.0f/s hook %.1f ms/s", gar_ps, hook_ms_ps), now)
        end
    end
    -- 每帧模块耗时守卫
    if MODS.EMF.on then
        S.frame_hi = (frame_avg > K.FRAME_MS_LIMIT) and S.frame_hi + 1 or 0
        if S.frame_hi >= K.GUARD_PERIODS then
            guard_stop("EMF", safe_fmt("EMF %.3f ms/frame for %d periods", frame_avg, math.tointeger(S.frame_hi) or 0), now)
        end
    end
    perf_reset(now)
end

-- ========================================================================
-- JSON 写出
-- ========================================================================
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
    local name = "ATP_" .. fint(S.session) .. "_" .. fint(S.seq) .. ".json"
    -- why = idle / valve / hard / button / stop / reset：离线据最后一份的 why 判断这一轮有没有正常收尾
    local data = { kind = "ATP", ver = VERSION, session = S.session, seq = S.seq, why = tostring(why),
        emf_fields = table.concat(EMF_FIELDS, ","), spd_fields = table.concat(SPD_FIELDS, ","),
        spd_getters = table.concat(SPD_GETTERS, ","), records = S.jbuf }
    local ok, res = pcall(json.dump_file, name, data, -1)
    S.last_write_t = os.clock()
    if ok and res then
        S.files = S.files + 1
        S.last_file = name
        S.jbuf = {}
        return true
    end
    -- 写失败：记录留在缓冲里，下次再试；序号已经用掉（离线按序号排序，有缺号说明写失败过）
    report_error("JSON", "dump_file " .. name .. " failed (" .. tostring(why) .. "): " .. tostring(res))
    return false
end

-- 写盘可能卡 0.1~0.3 s：只在没有「打主角或目标未知的预告还在倒数」时写（S.busy_until，审查 F5）。
-- 旧版只要求 1.5 s 内没有 initData，可预告最长约 6.7 s，会压在倒数中途写，卡顿还会落进同时在跑的 APCal 的测量里
local function json_tick(now)
    local n = #S.jbuf
    if n == 0 then return end
    local calm = now >= S.busy_until
    if calm and S.n_mon == 0 and now - S.last_write_t >= K.JSON_IDLE then
        json_flush("idle")
    elseif n >= K.JSON_VALVE and now - S.valve_t >= K.JSON_VALVE_RETRY then
        -- 一直有怪在打的时候等不到空闲：等没有预告在倒数的空档写；缓冲到硬上限后最多再等 JSON_HARD_WAIT 秒，
        -- 到绝对上限无条件写
        if n >= K.JSON_HARD and S.hard_t0 == nil then S.hard_t0 = now end
        local forced = n >= K.JSON_ABS or (S.hard_t0 ~= nil and now - S.hard_t0 >= K.JSON_HARD_WAIT)
        if calm or forced then
            S.valve_t = now
            S.hard_t0 = nil
            json_flush(calm and "valve" or "hard")
        end
    end
end

-- ========================================================================
-- 停止 / 恢复记录
-- ========================================================================
local function set_rec(on, why)
    local now = os.clock()
    if on == S.rec then return end
    if not on then
        emit_log("STOP", now, { why = why }, { "why" })
        S.rec = false
        S.mon, S.n_mon = {}, 0
        refresh_flags()
        json_flush("stop")
    else
        S.rec = true
        S.rec_t0 = now
        S.auto_stopped = false
        perf_reset(now)
        emit_log("RESUME", now, { why = why }, { "why" })
        -- 重新开始记录：出错停用 / 暂停中的模块一起重开（守卫停掉的要点菜单「重开已停用模块」）
        reopen_modules(false, "resume")
    end
end

-- ========================================================================
-- 帧回调
-- ========================================================================
local function frame_body(now)
    if now - S.rec_t0 >= K.AUTO_STOP then
        S.auto_stopped = true
        set_rec(false, "auto90")
        return
    end
    clear_stale_stack()
    if MODS.GAR.on then
        -- 出错（瞬时异常，opt 返回 nil）时沿用上一帧的地址：主角对象不会每帧换；没有主角（false）就清掉
        local h = opt("HUNT", nil, read_hunter_addr)
        if h ~= nil then S.hunter_addr = h or nil end
    end
    if mod_ok(MODS.EMF) then
        local ok, err = pcall(emf_tick, now)
        if not ok then report_error("EMF", err) end
    end
    if mod_ok(MODS.JSON) then
        local ok, err = pcall(json_tick, now)
        if not ok then report_error("JSON", err) end
    end
end

local function on_pre_update()
    local now = os.clock()
    S.f = S.f + 1
    S.now = now
    S.perf.frames = S.perf.frames + 1
    refresh_flags()         -- 暂停到期的模块在这里自动重开
    if S.rec then
        local ok, err = pcall(frame_body, now)
        if not ok then report_error("EMF", err) end
    else
        clear_stale_stack()
    end
    if mod_ok(MODS.PERF) then
        local ok, err = pcall(perf_tick, now)
        if not ok then report_error("PERF", err) end
    end
end

-- ========================================================================
-- 加载自检（类型、方法、字段都在不在）与表头
-- ========================================================================
-- { 模块, 类型, 方法签名, 字段名 }（2026-10-11 MCP 只读 get_type 全部核对过）
local MANIFEST = {
    { "INIT", "app.AttackAreaResult.DetectedData", INIT_SIG },
    { "INIT", "app.AttackAreaResult.DetectedData", "get_HitStartRemainFrame()" },
    { "INIT", "app.AttackAreaResult.DetectedData", "get_HitEndRemainFrame()" },
    { "INIT", "app.AttackAreaData", nil, "AttackStartFrame" },
    { "INIT", "app.AttackAreaData", nil, "AttackEndFrame" },
    { "RT", "app.AttackAreaResult.DetectedData", "get_ResultType()" },
    { "AREA", "app.AttackAreaData", nil, "RequestSetID" },
    { "AREA", "app.AttackAreaData", nil, "ShellIndex" },
    { "AREA", "System.Nullable`1<System.UInt32>", nil, "_HasValue" },
    { "AREA", "System.Nullable`1<System.UInt32>", nil, "_Value" },
    { "CIDS", "app.AttackAreaData", nil, "CollidableIDList" },
    { "CIDS", "System.Collections.Generic.List`1<System.UInt32>", "get_Count()" },
    { "CIDS", "System.Collections.Generic.List`1<System.UInt32>", "get_Item(System.Int32)" },
    { "CAP", "via.Capsule", nil, "p0" },
    { "CAP", "via.Capsule", nil, "p1" },
    { "CAP", "via.Capsule", nil, "r" },
    { "EMID", "app.EnemyCharacter", nil, "_Context" },
    { "EMID", "app.cEnemyContextHolder", nil, "_Em" },
    { "EMID", "app.cEnemyContext", "get_EmID()" },
    { "EMID", "app.cEnemyContext", "get_SystemIndex()" },
    { "FIND", "app.EnemyManager", "findEnemy_SystemIndex(System.Int32)" },
    { "FIND", "app.cEnemyManageInfo", "get_Character()" },
    { "SPDS", "app.EnemyCharacter", nil, "_MotionSpeed" },
    { "SPDS", "app.EnemyCharacter.cMotionSpeed", nil, "_TotalMotionSpeedThisFream" },
    { "SPDS", "app.EnemyCharacter.cMotionSpeed", nil, "_Base" },
    { "SPDS", "app.EnemyCharacter.cMotionSpeed", nil, "_Sequence" },
    { "SPDS", "app.EnemyCharacter.cMotionSpeed", nil, "_CoreState" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_Base()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_Action()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_BlendTree()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_CoreState()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_MoveAction()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_MoveSpeedAdjusted()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_Random()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_Replica()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_ScaleAdjusted()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_Sequence()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_WaitPacket()" },
    { "SPDG", "app.EnemyCharacter", "get_MotionSpeed_WaitPacketReserved()" },
    { "CALC", "app.EnemyCharacter", "calcMotionSpeedTotal(System.Boolean)" },
    { "MOT", "app.CharacterBase", "get_MotionComponent()" },
    { "MOT", "via.motion.Motion", "getLayer(System.UInt32)" },
    { "MOT", "via.motion.Animation", "get_PlaySpeed()" },
    { "MOT", "via.motion.TreeLayer", "get_Frame()" },
    { "MOT", "via.motion.TreeLayer", "get_Speed()" },
    { "MOT", "via.motion.TreeLayer", "get_MotionID()" },
    { "MOT", "via.motion.TreeLayer", "get_MotionBankID()" },
    { "ACT", "app.CharacterBase", "get_BaseActionController()" },
    { "ACT", "ace.cActionController", "get_CurrentActionID()" },
    { "ACT", "ace.cActionController", "get_CurrentAction()" },
    { "ACT", "ace.ACTION_ID", nil, "_Category" },
    { "ACT", "ace.ACTION_ID", nil, "_Index" },
    { "ACT", "app.cCharacterActionBase", nil, "_RawTotalElapsedSecond" },
    { "ACT", "app.cCharacterActionBase", "get_CharaElapsedSecond()" },
    { "TS", "via.Component", "get_GameObject()" },
    { "TS", "via.GameObject", "get_TimeScale()" },
    { "CLK", "via.Application", "get_DeltaTime()" },
    { "CLK", "via.Application", "get_FrameCount()" },
    { "EMST", "app.cEnemyContext", "get_IsAngry()" },
    { "EMST", "app.cEnemyContext", "get_IsTired()" },
    { "EMST", "app.EnemyCharacter", "getOverrideMotionRateAngryCurrentAction()" },
    { "EMST", "app.EnemyCharacter", "getOverrideMotionRateTiredCurrentAction()" },
    { "GAR", "app.mcEnemyAttackAreaDetector", GAR_SIG },
    { "GAR", "app.mcEnemyAttackAreaDetector", GCAR_SIG },
    { "GAR", "System.Nullable`1<System.Single>", nil, "_HasValue" },
    { "GAR", "System.Nullable`1<System.Single>", nil, "_Value" },
    { "GAR", "ace.ACTION_ID", nil, "_Category" },
    { "HUNT", "app.PlayerManager", "getMasterPlayer()" },
    { "HUNT", "app.cPlayerManageInfo", "get_Character()" },
}

local function manifest_check(it)
    local td = sdk.find_type_definition(it[2])
    if not td then return false end
    if it[3] then return td:get_method(it[3]) ~= nil end
    if it[4] then return td:get_field(it[4]) ~= nil end
    return true
end

local function manifest_label(it)
    local tn = it[2]:gsub("^app%.", "")
    local member = it[3] and it[3]:gsub("%(.*%)$", "") or it[4]
    return tn .. "." .. tostring(member)
end

-- 缺核心项（INIT）→ 不装钩子；缺可选项 → 停用该模块（每个模块报一次）
local function selftest()
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
    if next(RT_NAMES) == nil then
        failed[#failed + 1] = "RESULT_TYPE enum"
        if not by_mod.RT then
            by_mod.RT = {}
            order[#order + 1] = "RT"
        end
        table.insert(by_mod.RT, "RESULT_TYPE enum")
    end
    for _, modname in ipairs(order) do
        local m = MODS[modname]
        report_error(modname, "selftest missing: " .. table.concat(by_mod[modname], ","))
        m.on = false        -- 缺项直接停用（report_error 只计次），「重开已停用模块」也不重开
        m.st_missing = true
    end
    refresh_flags()
    S.st = { ok = okn, total = #MANIFEST, failed = failed }
    local fl = table.concat(failed, ",")
    if #fl > 600 then fl = fl:sub(1, 600) .. "..." end
    emit_log("SELFTEST", now, { ok = okn, total = #MANIFEST, failed = fl ~= "" and fl or nil },
        { "ok", "total", "failed" })
end

local function hdr_emit()
    local now = os.clock()
    -- 预告系统的判定参数（静态字段，读不到写 ?；和 APCal HDR 的 det 同一组）
    local det = "?"
    pcall(function()
        local td = sdk.find_type_definition("app.mcEnemyAttackAreaDetector")
        local function sv(n)
            local ok, v = pcall(function() return td:get_field(n):get_data(nil) end)
            if ok and type(v) == "number" then return fnum(v, "%.3f") end
            return "?"
        end
        det = sv("PLAYER_RADIUS") .. "," .. sv("PLAYER_HEIGHT") .. "," .. sv("OTOMO_RADIUS") .. "," ..
            sv("OTOMO_HEIGHT") .. "," .. sv("DETECT_DISTANCE_SQ")
    end)
    emit_log("HDR", now, {
        ver = VERSION, session = S.session, emf_fields = table.concat(EMF_FIELDS, ","),
        spd_fields = table.concat(SPD_FIELDS, ","), spd_getters = table.concat(SPD_GETTERS, ","),
        win = K.WIN, win_pad = K.WIN_PAD, win_max = K.WIN_MAX, mon_max = K.MON_MAX, init_limit = K.INIT_LIMIT,
        hook_ms_limit = K.HOOK_MS_LIMIT, frame_ms_limit = K.FRAME_MS_LIMIT, det = det,
        -- 出错退避和写盘避让的参数（离线对照用）：窗口 s / 帧数 / 暂停 s / 永久停用的连续暂停次数 / 单只怪跳过（帧数/s）/ 踢出帧数
        err_cfg = safe_fmt("%.1f/%d/%.1f/%d/%d/%.1f/%d", K.ERR_WIN, K.ERR_PAUSE_N, K.PAUSE_S, K.PERM_PAUSES, K.OBJ_SKIP_N,
            K.OBJ_SKIP_S, K.MON_BAD_DROP),
        busy_cfg = safe_fmt("%.2f/%.2f/%.1f", K.BUSY_SLOW, K.BUSY_PAD, K.BUSY_MAX),
        rt = (function()
            local parts = {}
            for v, nm in pairs(RT_NAMES) do parts[#parts + 1] = nm .. ":" .. fint(v) end
            table.sort(parts)
            return table.concat(parts, ",")
        end)(),
    }, { "ver", "session", "emf_fields", "win", "win_max", "init_limit", "hook_ms_limit", "frame_ms_limit", "det", "rt" })
end

-- ========================================================================
-- 菜单
-- ========================================================================
local function status_text()
    if not S.rec then
        if S.auto_stopped then return "ATP 已停止记录（加载满 90 分钟；可在下面重新开启）" end
        return "ATP 已停止记录"
    end
    local st = S.st and safe_fmt("自检 %d/%d", math.tointeger(S.st.ok) or 0, math.tointeger(S.st.total) or 0) or "自检未跑"
    return safe_fmt("ATP 记录中 | %s | initData 共 %d 次（钩子被调 %d 次）| 建结果 %d 次 | 盯着 %d 只怪 | 缓冲 %d 条 | 已写 %d 个文件（最近 %s）",
        st, math.tointeger(S.n_init_total) or 0, math.tointeger(S.raw_init_total + S.perf.init_raw) or 0,
        math.tointeger(S.n_gar_total) or 0, math.tointeger(S.n_mon) or 0, #S.jbuf, math.tointeger(S.files) or 0,
        S.last_file)
end

local function draw_menu()
    imgui.text(status_text())
    imgui.text("版本 " .. VERSION .. "  会话 " .. fint(S.session) .. "  帧 " .. fint(S.f))
    local changed, v = imgui.checkbox("停止记录##atp_stop", not S.rec)
    if changed then set_rec(not v, "menu") end
    imgui.same_line()
    if imgui.button("写出数据##atp_dump") then json_flush("button") end
    imgui.same_line()
    if imgui.button("重开已停用模块##atp_reopen") then reopen_modules(true, "button") end
    local c2, v2 = imgui.checkbox("每帧也调用 calcMotionSpeedTotal（默认关）##atp_calc", S.calc_every_frame)
    if c2 then S.calc_every_frame = v2 == true end
    imgui.text("性能：" .. tostring(S.perf_text))
    if init_off and S.rec then imgui.text("initData 钩子现在没在记录（守卫、出错暂停或停用，见下面）") end
    if gar_off and S.rec then imgui.text("建结果（getAttackAreaResult）钩子现在没在记录") end
    if not mod_ok(MODS.EMF) then imgui.text("每帧记录 EMF 现在没在记录（守卫、出错暂停或停用）") end
    local off, paused = {}, {}
    for _, name in ipairs(MOD_LIST) do
        local m = MODS[name]
        if not m.on then
            off[#off + 1] = name .. ((m.guard and "(守卫)") or (m.st_missing and "(自检缺项)") or (m.no_hook and "(钩子没装上)")
                or "(出错)")
        elseif m.pause_until and S.now < m.pause_until then
            paused[#paused + 1] = name
        end
    end
    if #off > 0 then imgui.text("已停用的模块：" .. table.concat(off, " ")) end
    if #paused > 0 then imgui.text("出错暂停中（会自动重开）：" .. table.concat(paused, " ")) end
    if S.st and #S.st.failed > 0 then imgui.text("自检缺：" .. table.concat(S.st.failed, ", "):sub(1, 300)) end
    if #S.err_list > 0 then
        imgui.text(safe_fmt("错误 %d 条（最近 10 条）：", math.tointeger(S.n_err) or 0))
        for _, line in ipairs(S.err_list) do imgui.text("  " .. line) end
    end
end

-- ========================================================================
-- 注册与加载
-- ========================================================================
local function install_hook()
    local td = sdk.find_type_definition("app.AttackAreaResult.DetectedData")
    local m = td and td:get_method(INIT_SIG)
    if not m then error("method not found: DetectedData." .. INIT_SIG) end
    sdk.hook(m, init_pre, init_post)
end

local function install_gar_hooks()
    local td = sdk.find_type_definition("app.mcEnemyAttackAreaDetector")
    local m1 = td and td:get_method(GAR_SIG)
    local m2 = td and td:get_method(GCAR_SIG)
    if not m1 or not m2 then error("method not found: mcEnemyAttackAreaDetector.getAttackAreaResult / getCurrent...") end
    sdk.hook(m1, gar_pre, gar_post)
    sdk.hook(m2, gcar_pre, gcar_post)
end

local function load_main()
    hdr_emit()
    selftest()
    if MODS.INIT.on then
        local ok, err = pcall(install_hook)
        if not ok then
            report_error("INIT", err)
            MODS.INIT.on = false
            MODS.INIT.no_hook = true
        end
    end
    if MODS.GAR.on then
        local ok, err = pcall(install_gar_hooks)
        if not ok then
            report_error("GAR", err)
            MODS.GAR.on = false
            MODS.GAR.no_hook = true
        end
    end
    refresh_flags()
end

local load_ok, load_err = pcall(load_main)
if not load_ok then report_error("MENU", "load: " .. tostring(load_err)) end

re.on_pre_application_entry("UpdateBehavior", function()
    local ok, err = pcall(on_pre_update)
    if not ok then report_error("EMF", err) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("攻击时刻探针##ATP") then return end
    local ok, err = pcall(draw_menu)
    if not ok then report_error("MENU", err) end
    imgui.tree_pop()
end)

-- Reset Scripts：写出最后一份 JSON（钩子由 REF 随脚本卸掉；本探针没有任何 add_ref，不用释放）
re.on_script_reset(function()
    local now = os.clock()
    pcall(emit_log, "STOP", now, { why = "reset" }, { "why" })
    pcall(json_flush, "reset")
end)

-- 纯计算函数和内部状态给离线 / 模拟测试用（REF 运行 autorun 脚本时忽略返回值；模拟测试可以调小 K 里的阈值）
return {
    bits_to_float = bits_to_float,
    fnum = fnum,
    fint = fint,
    emf_fields = EMF_FIELDS,
    _test = { K = K, S = S, MODS = MODS },
}
