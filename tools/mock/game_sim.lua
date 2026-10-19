-- tools/mock/game_sim.lua：简单的「游戏模拟器」（只给模拟测试用）
--
-- 每帧三段，和真实游戏的顺序对齐：
--   pre    ：上一帧决定的动作切换在这里生效（新动作 raw=0），然后跑脚本的 pre-UpdateBehavior
--   update ：处理本帧的 changeActionRequest（下一帧生效）、玩家输入、动作时间线、
--            预告条目倒数（hs/he 按 60×dt 递减）、预告消息（receiveGameMessage 钩子）、机关周期、
--            ColliderSwitcher.activateAttack
--   hit    ：上捞斩砍中怪物（EMHIT）、怪物攻击接触。接触时主角在 (2,23) 且距 (2,23) 开始落在
--            抵消窗口 [W0,W1] 内 → 按真实顺序走刀上接触（日志 16:12:47.045 的顺序）：
--              HunterCharacter.evHit_DamagePreProcess(刀，ATTACK_PARRY_GET) → SUCCESS
--              EnemyCharacter.evHit_AttackParry → onParryHit(WAIT) → 第二个刀碰撞体 → PASS
--              （可选）同帧身体接触 MasterPlayer/ATTACK_GET → SUCCESS
--              cEmModuleHit.onParryDamage(PLAYER/0) 里回调 onParrySuccess(SUCCESS)
--            下一帧主角进 (2,25..27)、怪物进 cDamageParry；否则走身体接触。
--
-- 时间约定（为什么这样定）：请求在第 N 帧 pre 发出 → 第 N+1 帧开头进 (2,23)，raw=0，
--   所以 δ = t_start − t_req = 一帧 ≈ 0.011 s，和 PLAN 里实测 δ≈0.012 一致；
--   条目读数是上一帧 update 之后的值（「帧开头读到的剩余帧略有滞后」）。
--
-- v1.6 起（docs/autoparry/V16.md 第 8.3 节）：
--   · 怪物速度 CoreState：怪物的 core（数值，或时间表 { {t, C}, ... } 阶梯函数）、攻击的 core（按招在进入动作那一帧切换）。
--     默认 core_switch = "after_msg"：切换发生在发消息的同一帧、消息钩子之后，所以钩子里读是旧值，下一帧帧回调读到新值
--     （SPEED 2.1 l）。get_MotionSpeed_CoreState() 返回它；calcMotionSpeedTotal 返回 C × hidden（场景可设隐藏因子
--     hidden ≠ 1，用来抓「误用总速度」）。
--   · 攻击按名义进度到达（设了速度的攻击，或 nominal = true）：激活 = 从发消息起 ∫60·C dτ 走完触发条目 A 的那一刻
--     （用怪物真实的 C，不是 max(1, C)），接触 = 激活 + g（contact.g 或 contact.r，≥ 0）或写死的绝对时刻。
--     没设速度的旧攻击仍按「hs 归零 + r」静态排程（C = 1 时两者一致，旧场景的时序一帧不差）。
--   · 条目 hs/he 按真实时间每帧减 60·min(dt, 0.1333)（游戏 dt 有上限，SPEED 2.1 d），怪物进度用同一个钳制后的 dt。
--   · 结果对象：默认每次攻击新建一个结果和它的条目对象（4 段数据里结果对象从不复用，实测）；游戏持有它，
--     IsAttackFinished 之后 drop_after（默认 0.5 s）放手；被换掉的条目对象当场放手。旧场景要复用的写 reuse_results。
--     怪物对象在怪物存在期间由游戏持有，despawn_at 之后放手；另一只怪可以 spawn_at 接用同一个 SystemIndex。
--   · 该接属性：条目可设 pb（_IsParryBreak）、guard（名字或数值）、dmg、ap = false（get_AttackParam 返回 nil）；
--     字段读取故障走 mock_ref 的故障注入（神谕用 peek_fault 看同一份故障，所以这类故障要用时间段，不要用 max）。
--   · 刀上接触的结局：触发条目 pb=1 或 hit_level = 25 → onParryHit(RECOIL)、下一帧进 (2,25)、同一帧身体挨打；
--     SKILL_GUARD / UNABLE_GUARD（推测，从没测过）/ 抓取 → 不抵消、身体挨打；其余按 hit_level 26（HIT）/ 27（SUCCESS）。
--   · 速度读取故障：怪物或攻击上的 speed_fault（find_nil / char_nil / throw / nan / value），默认只对放刀模块生效。
--   · 神谕（compute_oracle16）按 V16 第 2、3 节独立实现一遍 E5c、该接过滤和否决，不看被测脚本的内部状态；
--     同时给出每帧 FIRE 该写的字段、SKIP / UVIEW 和 STAT 计数的预期。
-- 审查补充（V16 第 14 节）：
--   · 时钟上限随两次读数隔开的时间放宽（CLOCK_DMAX + 60 × 秒数，同放刀模块）；
--   · 场景声明 oracle_hunter_fail = { {from, to}, ... }（读主角抛错、容忍期内整帧跳过）：神谕把这些帧当作不存在（skip_frame）；
--   · 攻击事件 hide_entry / show_entry：条目对象暂时离开条目表、之后原样回来（同一个对象，游戏照样倒数）。
-- 合并版（docs/autoparry/MERGE.md 第 6.2 节第 3 条：放刀逻辑并入 AutoGuardGS v1.5，防御那一半也要模拟到）：
--   · 血量：主角带 cHunterHealth / cHealthManager（MaxHealth 150）；身体挨打经钩子分发调 requestDamage（前置钩子返回
--     SKIP_ORIGINAL 就不登记），下一帧 update 开头结算；场景可设 red_damage（requestRedDamage）、hp_drain（不走 requestDamage
--     的扣血，锁血靠每帧补满兜底）、npc_damage（同场 NPC 的 requestDamage，锁血不该拦）。
--   · 状态标志组 on/off 真的置位、清除；脚本强开了防御标志的那一下按防御结算（不扣血、进防御反应动作）。status_on 按时间窗口开标志。
--   · 普通蓄力 (2,5)→(2,6)→(2,7)→(2,11)（带 SUPER_ARMOR）、肩撞 (2,15)/(2,17)（再加 HYPER_ARMOR）、松手后的蓄力斩
--     （(2,5)/(2,6) 松手进 (2,0)、(2,7) 进 (2,1)、(2,11) 进 (2,12)，实测）；changeActionRequest 接受从普通蓄力请求的肩撞，
--     下一帧生效。玩家事件 charge / release_charge / hold_now（同一帧 update 里就切进抵消蓄力）。
--   · 和实测不符、只作占位的地方（审查补充；实测 = APCal 的 ACT 记录，tools/out/stageA_data/re2_framework_log.txt 和
--     2026-10-11 的游戏日志）：按住不放时 (2,6)→(2,7)→(2,11) 按时间升级是编的 —— 实测 (2,6)→(2,7) 0 次，(2,7) 是从 (2,0) 纵斩
--     84、(2,54) 70、(2,15) 肩撞 60 次接出来的，(2,11) 从 (2,1) 74、(2,42) 41、(2,54) 25、(2,17) 18 次；精确防御反应 (1,146)
--     之后实测多数进 (2,54)（62 次）、偶尔直接进 (2,22)（2 次），这里一律回拔刀待机 (1,14)。两个被测脚本都只按动作编号查
--     「在不在普通蓄力 / 肩撞 / 抵消族」，不看是怎么进来的，所以这些占位不影响防御对 v1.4.2 的逐项比较；以后防御逻辑要按
--     进入路径或反应动作判断时，先按实测补完动作链。
--   · 场景开关（时间窗口）：can_guard（行为表能到防御）、attrs（动作属性，例如 DODGE）、weapon_off（收刀）、weapon_type_at（换武器）。
--   · rc_script：放刀逻辑所在脚本的名字（合并版是 AutoGuardGS），读速度、findEnemy 计数、神谕按脚本看的故障都认它；
--     oracle_cfg：run.lua 按 MERGE 第 3 节算好的放刀配置（合并版从 AutoGuardGS.json 或旧文件迁移，结果和 v1.6 读旧文件相同）。
--   · 地址：预告结果、条目、条目列表、攻击参数放在单独的地址段（mock_ref 的 alloc_addr），只由场景的攻击事件按时间创建，
--     合并版和 v1.6 的 FIRE 才能逐字比 ent / res。

local mock = require("mock_ref")
local f32, vec = mock.f32, mock.vec

local S = {}
S.__index = S

local ACT_NAME = {
    ["1,14"] = "app.Wp00Action.cIdle",
    ["2,21"] = "app.Wp00Action.cIdleToParryCharge",
    ["2,22"] = "app.Wp00Action.cParryCharge",
    ["2,23"] = "app.Wp00Action.cParrySlash",
    ["2,24"] = "app.Wp00Action.cParrySlashForward",
    ["2,25"] = "app.Wp00Action.cParrySlashHitS",
    ["2,26"] = "app.Wp00Action.cParrySlashHitM",
    ["2,27"] = "app.Wp00Action.cParrySlashHitL",
    ["2,28"] = "app.Wp00Action.cCloseMove",
    ["2,29"] = "app.Wp00Action.cCloseSlash",
    ["0,30"] = "app.PlayerCommonAction.cDamage",   -- 受击硬直（模拟用名字）
    -- 普通蓄力、松手后的蓄力斩和肩撞（AutoGuardGS 的自动肩撞，NOTES「大剑动作编号」）；类名都是 APCal ACT 实测
    ["2,0"] = "app.Wp00Action.cVerticalSlash",
    ["2,1"] = "app.Wp00Action.cStrongVerticalSlash",
    ["2,5"] = "app.Wp00Action.cIdleToCharge",
    ["2,6"] = "app.Wp00Action.cCharge",
    ["2,7"] = "app.Wp00Action.cStrongCharge",
    ["2,11"] = "app.Wp00Action.cSpiritCharge",
    ["2,12"] = "app.Wp00Action.cSpiritVerticalSlash",
    ["2,15"] = "app.Wp00Action.cTackle",
    ["2,17"] = "app.Wp00Action.cTackle",
    -- 防御反应（实测：(1,143) Small、(1,144) Middle、(1,145) Large、(1,146) Tech）。模拟里强开 TECHNICAL_GUARD 进 (1,146)，
    -- 强开 GUARD 一律进 (1,144)（真游戏按攻击轻重分 Small / Middle / Large）
    ["1,146"] = "app.Wp00Action.cGuardReaction_Tech",
    ["1,144"] = "app.Wp00Action.cGuardReaction_Middle",
}
S.ACT_NAME = ACT_NAME

local DEFAULT_P = {
    W0 = 0.355, W1 = 0.80,          -- 抵消窗口（相对 (2,23) 开始），CONTRACT 第 5 节默认值
    T_armor = 1.0,                   -- (2,23) 霸体结束（PLAN 要实测的量，这里取 1.0）
    slash_len = 3.6,                 -- 没撞上时 (2,23) 停到玩家输入（复核样本 3.4~3.8 s）
    input_min = 1.2,                 -- 玩家输入最早在这之后结束上捞斩
    emhit_at = 0.32,                 -- 上捞斩约 0.32 s 先砍中目标
    hitstop = 0.05,
    hitl = 1.07, close_move = 0.85, close_slash = 1.0,   -- (2,27)→(2,28)→(2,29) 时长（日志 16:07:28~16:07:30）
    flinch = 0.8,
    -- 普通蓄力（模拟值）：(2,5) 开始蓄力 → (2,6) → (2,7) 强蓄力 → (2,11) 真蓄力，一直带 SUPER_ARMOR（按时间升级是占位，见头注释）；
    -- 松手进蓄力斩 (2,0) / (2,1) / (2,12)；
    -- 肩撞 (2,15)/(2,17) 带 SUPER_ARMOR + HYPER_ARMOR（NOTES「防御」：肩撞会额外加 HYPER_ARMOR），之后回到拔刀待机
    charge5 = 0.25, charge6 = 0.8, charge7 = 0.8, charge_slash = 1.0, tackle = 0.6, guard_react = 0.5,
    hp_max = 150.0,
    atk_lead = 0.15,                 -- 判定激活到接触（NOTES：0.14~0.17 s）
    finish_he = -15.0,               -- 全部条目 he 低于它时 IsAttackFinished
    damage = 35.5,
    dc = 1.135, dc_jitter = 0.008,   -- 机关：cSmallAttack 首帧到接触（实测 1.12~1.15 s）
    to_small = 1.0,                  -- 机关：cSmallAttack → cToSmallAttack（实测约 1.0 s）
    period = 4.6, parried_period = 7.0, period_jitter = 0.05,
}

-- 被测放刀脚本的版本口径（神谕和 run.lua 的断言共用）。场景用 rc_ver 选版本，默认 v16：
--   v16 = 发布版 src/reframework/autorun/AutoParryGS.lua，v1.6（docs/autoparry/V16.md：E5c、L 默认 28（Q 单位）、
--         滑块 23~45、cfg_ver 不是 ≥3 的配置一律迁成 28、该接过滤 g1、候选侧读不准不放、SKILL_GUARD 否决、
--         (2,25) = RECOIL）。神谕是 compute_oracle16
--   v15 = 归档的 v1.5.1（docs/autoparry/V15.md：L_min 22、滑块 22~45；第 9 节：默认 L 30，配置里没有 cfg_ver 键
--         （rc 或 v1.5 写的）→ parry_lead 一律换成 30；抓取条目（DamageType ∈ CATCH/CATCH_ZAKO/CATCH_SLINGER）不进候选，
--         hs ≤ H_veto、he ≥ 0 时和长窗口同一口径否决；联机副本的条目不进候选但照样参与否决；某个结果逐条读取出错 →
--         这个结果本帧既不放刀也不否决，没有 closest 兜底）。只给引用记账的负对照用
--   rc1 = 归档的第 1 轮标定版 tools/archive/AutoParryGS_rc1.lua（CONTRACT 3 节：L_min 18、滑块 20~45、默认 L 28 且轮换；
--         不读 get_IsMaster；逐条读取出错退回 closest，src=FB；没有抓取否决）。只给轮换、机关扫描、FB 兜底、HUD 这些
--         rc 专有场景用
-- 冒烟脚本（tools/mock/smoke）按 rc 的口径写，--smoke 时一律用 rc1
local PROFILES = {
    rc1 = {
        name = "rc1", L_MIN = 18, lead_lo = 20, lead_hi = 45,
        defaults = { auto_parry = true, parry_lead = 28, lead_rotation = true, scan = false, debug_log = true },
        upgrade = nil, master_gate = false, items_fail = "fb", grab_veto = false,
        effect_enum = "group",      -- EAR/WIND/QUAKE 一个 pcall 整组读：缺一个名字就整组不认（effect_known）
        ref_model = "legacy",       -- rc1 会手动 release（V16 第 8.1 节：rc1 场景用旧的按脚本计数）
    },
    v15 = {
        name = "v15", L_MIN = 22, lead_lo = 22, lead_hi = 45,
        defaults = { auto_parry = true, parry_lead = 30, debug_log = false },
        -- v1.5.1 起存配置都带 cfg_ver：没有这个键说明是 rc 或 v1.5 写的，那时的 28/26 不是用户自己调的（V15 第 9 节）
        upgrade = { key = "cfg_ver", to = 30 },
        master_gate = true, items_fail = "skip", grab_veto = true,
        effect_enum = "per_name",   -- 第 1 轮审查后：效果攻击的名字也逐个读，读不到的只少认那一种（effect_known）
        ref_model = "real",         -- 归档的 v1.5.1 只给引用记账的负对照用（V16 第 8.4 节第 41 条）
    },
    -- v16 = 发布版 v1.6（docs/autoparry/V16.md）：E5c（Q 口径）、L 默认 28、滑块 23~45、cfg_ver = 3（读到的配置
    -- cfg_ver 不是 ≥3 的数一律迁成 28）、该接过滤 g1（候选侧读不准不放）、SKILL_GUARD 否决、(2,25) = RECOIL
    v16 = {
        name = "v16", L_MIN = 22, lead_lo = 23, lead_hi = 45,
        defaults = { auto_parry = true, parry_lead = 28, debug_log = false },
        upgrade = { key = "cfg_ver", min = 3, to = 28 },
        master_gate = true, items_fail = "skip", grab_veto = true,
        effect_enum = "per_name", e5c = true, ref_model = "real",
    },
}
S.PROFILES = PROFILES

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function sorted_insert(list, ev)
    local i = #list
    while i >= 1 and list[i].t > ev.t do i = i - 1 end
    table.insert(list, i + 1, ev)
end

local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deep_copy(v) end
    return c
end

function S.new(w, scen, prof)
    local G = setmetatable({}, S)
    G.w, G.scen = w, scen
    G.prof = prof or PROFILES.v16
    G.L_MIN = G.prof.L_MIN
    G.P = {}
    for k, v in pairs(DEFAULT_P) do G.P[k] = v end
    for k, v in pairs(scen.params or {}) do G.P[k] = v end
    G.rng = mock.make_rng(scen.seed or 20261010)
    -- rc 加载时的配置：和被测脚本的 load_config 同一口径（只认默认表里有、类型相同的键；parry_lead 四舍五入后夹到
    -- 版本的滑块范围；v15 读到没有 cfg_ver 的配置时提前量一律换成 30）。之后菜单改开关、滑块由 run.lua 调 apply_ui_cfg 跟进
    local cfg = {}
    for k, v in pairs(G.prof.defaults) do cfg[k] = v end
    local seed = (scen.config or {}).AutoParryGS
    G.cfg_upgraded = false
    if scen.oracle_cfg then
        -- 合并版（run.lua 按 MERGE 第 3 节算好的放刀配置：AutoGuardGS.json 自己的键，或从旧文件迁移的值）
        for k, v in pairs(scen.oracle_cfg) do cfg[k] = v end
        seed = nil
    end
    if type(seed) == "table" then
        for k, v in pairs(seed) do
            if k == "parry_lead" then
                if finite(v) then cfg.parry_lead = G:clamp_lead(v) end
            elseif G.prof.defaults[k] ~= nil and type(v) == type(G.prof.defaults[k]) then
                cfg[k] = v
            end
        end
        local up = G.prof.upgrade
        local cv = seed[up and up.key or "cfg_ver"]
        -- v1.5.1：没有 cfg_ver 键就升级；v1.6：cfg_ver 不是 ≥3 的数（缺失、1、2、字符串 "3"）就迁移（V16 第 2.7 节）
        local need = up and ((up.min == nil and cv == nil)
            or (up.min ~= nil and not (type(cv) == "number" and cv == cv and cv >= up.min)))
        if need then
            cfg.parry_lead = up.to
            G.cfg_upgraded = true
        end
    end
    G.rc_cfg = cfg
    G.cfg0 = deep_copy(cfg)
    G.cfg_changes = {}      -- 菜单真的改了配置的时刻：{ t, auto_parry, parry_lead }（v15 每次写一行 CFG）
    G.truth = { attempts = {}, contacts = {}, attacks = {}, machine = {}, messages = 0, emhits = {}, swaps = {},
        noise = 0, activations = 0 }
    G.oracle = {}
    G.events = {}           -- update 阶段按时间执行的事件
    G.contacts_due = {}     -- hit 阶段按时间结算的接触
    G.monsters, G.by_sysidx, G.mon_order = {}, {}, {}
    G.results = {}
    G.pending_msgs = {}
    G.pending_mon = {}
    G.reject_left = scen.reject_requests or 0
    G.player_present, G.char_present = true, true
    G.last_swap_t = -1e9
    G.parry_state = nil
    G.parry_target = nil
    G.oracle_fb = scen.oracle_fb or false
    -- 放刀模块所在脚本的名字（run.lua 按被测脚本设）：独立的 v1.6 是 AutoParryGS；合并版（MERGE 第 6.2 节）放刀逻辑在
    -- AutoGuardGS.lua 里，读速度、findEnemy 计数、神谕按脚本看的故障都要认这个名字
    G.rc_name = scen.rc_script or "AutoParryGS"
    -- v1.6 神谕的状态（compute_oracle16）：脚本的帧计数、跨帧的统计预期、SKIP 预期、各结果的 E5c 镜像（R.ot）
    G.oc = { frame_no = 0, me_ok = false, gen = nil, fail_streak = 0, n_x5 = 0 }
    G.ostat = { speedfail = 0, speedhold = 0, clockskip = 0, fclosed = 0, excl = 0, failopen = 0, sidmis = 0 }
    G.oskips = {}
    G.find_calls = {}       -- [帧] = { [SystemIndex] = 放刀模块本帧调 findEnemy_SystemIndex 的次数 }（v16_cache）
    G.dyn = {}              -- 按名义进度到达、还没激活的攻击
    G.hp_max = scen.hp_max or G.P.hp_max
    G.hp, G.pending_dmg = G.hp_max, 0.0
    G:init_enums()
    G:build_singletons()
    G:build_hunter()
    for _, key in ipairs(scen.monster_order or {}) do G:build_monster(key, scen.monsters[key]) end
    if scen.monsters then
        local keys = {}
        for k in pairs(scen.monsters) do if not G.monsters[k] then keys[#keys + 1] = k end end
        table.sort(keys)
        for _, k in ipairs(keys) do G:build_monster(k, scen.monsters[k]) end
    end
    if scen.machine then G:build_machine(scen.machine) end
    G:prepare_attacks()
    G:prepare_player()
    G:prepare_hunter_events()
    -- 红血伤害（requestRedDamage，经过钩子分发）和不走 requestDamage 的扣血（持续伤害：锁血靠每帧补满兜底）
    for _, r in ipairs(scen.red_damage or {}) do
        sorted_insert(G.events, { t = r.t or r[1], fn = function() G:request_damage(r.amount or r[2], true) end })
    end
    for _, r in ipairs(scen.hp_drain or {}) do
        sorted_insert(G.events, { t = r.t or r[1], fn = function() G:set_hp(G.hp - (r.amount or r[2]), "drain") end })
    end
    -- 同场 NPC 支援猎人挨打（requestDamage 的 this 是 NPC 自己的 cHunterHealth）：锁血只拦主玩家，NPC 的照常登记
    for _, r in ipairs(scen.npc_damage or {}) do
        sorted_insert(G.events, { t = r.t or r[1], fn = function() G:npc_request_damage(r.amount or r[2]) end })
    end
    return G
end


function S:init_enums()
    local w = self.w
    local E = {}
    E.SAFE = w:enum("app.AttackAreaResult.RESULT_TYPE", "SAFE")
    E.CAUTION = w:enum("app.AttackAreaResult.RESULT_TYPE", "CAUTION")
    E.DANGER = w:enum("app.AttackAreaResult.RESULT_TYPE", "DANGER")
    E.PS_NONE = w:enum("app.HunterDef.PARRY_STATE", "NONE")
    E.PS_WAIT = w:enum("app.HunterDef.PARRY_STATE", "WAIT")
    E.PS_HIT = w:enum("app.HunterDef.PARRY_STATE", "HIT")
    E.PS_SUCCESS = w:enum("app.HunterDef.PARRY_STATE", "SUCCESS")
    E.PS_RECOIL = w:enum("app.HunterDef.PARRY_STATE", "RECOIL")
    E.R_SUCCESS = w:enum("app.Hit.RESULT", "SUCCESS")
    E.R_FAILURE = w:enum("app.Hit.RESULT", "FAILURE")
    E.R_PASS = w:enum("app.Hit.RESULT", "PASS")
    E.ATTACK_GET = w:enum("app.CollisionFilter.LAYER", "ATTACK_GET")
    E.ATTACK_PARRY_GET = w:enum("app.CollisionFilter.LAYER", "ATTACK_PARRY_GET")
    E.SUPER_ARMOR = w:enum("app.HunterDef.STATUS_FLAG", "SUPER_ARMOR")
    E.HYPER_ARMOR = w:enum("app.HunterDef.STATUS_FLAG", "HYPER_ARMOR")
    E.NO_DAMAGE = w:enum("app.HunterDef.STATUS_FLAG", "NO_DAMAGE")
    E.PARRY_IMMDIATE = w:enum("app.HunterDef.CONTINUE_FLAG", "PARRY_IMMDIATE")
    E.WP_ATTACK_COLLISION_ON = w:enum("app.HunterDef.CONTINUE_FLAG", "WP_ATTACK_COLLISION_ON")
    E.PARRY_COMBO = w:enum("app.HunterDef.CONTINUE_FLAG", "PARRY_COMBO")
    E.CAT_PLAYER = w:enum("app.TARGET_ACCESS_KEY.CATEGORY", "PLAYER")
    E.CAT_OTOMO = w:enum("app.TARGET_ACCESS_KEY.CATEGORY", "OTOMO")
    E.DMG = {}
    for _, n in ipairs({ "NORMAL", "QUAKE", "EAR", "WIND", "SOUND_REACT", "FLASH", "CATCH", "CATCH_ZAKO", "CATCH_SLINGER" }) do
        E.DMG[n] = w:enum("app.HitDef.DAMAGE_TYPE", n)
    end
    E.DMG_PARRY = w:enum("app.EnemyDef.Damage.ACTION_TYPE", "PARRY")
    E.DMG_NONE = w:enum("app.EnemyDef.Damage.ACTION_TYPE", "NONE")
    E.EXCL = { [E.DMG.EAR] = true, [E.DMG.WIND] = true, [E.DMG.QUAKE] = true }
    -- 抓取（第 2 轮 em27 实测：刀碰到了也不触发抵消）。名字 → 数值，神谕按「被测脚本读得到的名字」取子集（grab_known）
    E.GRAB_NAMES = { CATCH = E.DMG.CATCH, CATCH_ZAKO = E.DMG.CATCH_ZAKO, CATCH_SLINGER = E.DMG.CATCH_SLINGER }
    E.GRAB = {}
    for _, v in pairs(E.GRAB_NAMES) do E.GRAB[v] = true end
    -- 防御类型（app.Hit.GUARD_TYPE，APCal HDR 实测 5 个值）：v1.6 的该接过滤白名单 NORMAL / ALL_RANGE，
    -- UNABLE_GUARD 只排除（SKIP ug），SKILL_GUARD 家族另外否决（VETO sg）
    E.GUARD = {}
    for _, n in ipairs({ "NORMAL", "ALL_RANGE", "UNABLE_GUARD", "SKILL_GUARD", "SKILL_GUARD_ALL_RANGE" }) do
        E.GUARD[n] = w:enum("app.Hit.GUARD_TYPE", n)
    end
    self.E = E
    self.parry_state = E.PS_NONE
end

-- ---------- 通用对象 ----------

-- space：地址段（mock_ref 的 alloc_addr）。预告结果、条目、条目列表、攻击参数放 "atk"：它们只由场景的攻击事件按时间创建，
-- 地址和被测脚本读了多少次无关，合并版和 v1.6 的 FIRE 才能逐字比 ent / res（MERGE 第 6.3 节）
function S:obj(type_name, methods, fields, getters, data, space)
    return self.w:new_object(type_name, { methods = methods, fields = fields, getters = getters, data = data,
        space = space })
end

function S:component(list, t)
    local w = self.w
    local d = t and getmetatable(t) == mock.OBJ and w:data(t)
    local tname = d and d.typename
    if not tname then
        w:note("BAD_COMPONENT_TYPE", "getComponent 的参数不是 sdk.typeof 返回的 System.Type")
        return nil
    end
    for _, c in ipairs(list) do
        if rawget(c, "__t"):is_a(tname) then return c end
    end
    return nil
end

function S:game_object(name, components_ref, extra)
    local G = self
    local go
    local m = {
        get_Name = function() return name end,
        get_Transform = function() return components_ref.tf end,
        getComponent = function(_, t) return G:component(components_ref.list or {}, t) end,
        get_TimeScale = function() return f32(1.0) end,
        get_Valid = function() return true end,
        get_UpdateSelf = function() return true end,
        get_DrawSelf = function() return true end,
        get_Tag = function() return "" end,
        ToString = function() return name end,
    }
    for k, v in pairs(extra or {}) do m[k] = v end
    go = self:obj("via.GameObject", m)
    return go
end

function S:transform(go_ref, posf, axisz)
    return self:obj("via.Transform", {
        get_GameObject = function() return go_ref.go end,
        get_Position = function() local p = posf() return vec(f32(p.x), f32(p.y), f32(p.z)) end,
        get_AxisZ = function() local a = axisz() return vec(a.x, a.y, a.z) end,
        get_AxisX = function() return vec(1.0, 0.0, 0.0) end,
        get_AxisY = function() return vec(0.0, 1.0, 0.0) end,
        get_Rotation = function() return setmetatable({ x = 0.0, y = 0.0, z = 0.0, w = 1.0 }, mock.VEC) end,
        get_LocalPosition = function() local p = posf() return vec(p.x, p.y, p.z) end,
    })
end

-- Nullable 的三种运行时形态（CONTRACT 1.2：读 _HasValue/_Value，或直接看返回是否 nil）。
-- 场景 nullable="nil" 时，方法调用对「无值」返回 nil；nullable="number" 时无值返回 nil、有值直接返回拆箱后的数字；
-- 字段读（<X>k__BackingField）在 REF 里一定是值类型结构体，所以 as_field=true 时始终返回值类型。
function S:nullable(type_name, v, as_field)
    if not as_field and self.scen.nullable == "number" then return v end
    if v == nil and self.scen.nullable == "nil" and not as_field then return nil end
    local w = self.w
    local vt = w:new_vt(type_name, { _HasValue = v ~= nil, _Value = v or 0 }, { methods = {
        get_HasValue = function(x) return rawget(x, "__f")._HasValue end,
        get_Value = function(x)
            if not rawget(x, "__f")._HasValue then error("InvalidOperationException: Nullable object must have a value.", 0) end
            return rawget(x, "__f")._Value
        end,
        GetValueOrDefault = function(x, d) local f = rawget(x, "__f") if f._HasValue then return f._Value end return d or 0 end,
    } })
    return vt
end

function S:action_id_vt(cat, idx)
    return self.w:new_vt("ace.ACTION_ID", { _Category = cat, _Index = idx })
end

function S:key_vt(cat, idx)
    return self.w:new_vt("app.TARGET_ACCESS_KEY", { Category = cat, UniqueIndex = idx })
end

-- ---------- 单例 ----------

function S:build_singletons()
    local w, G = self.w, self
    G.pinfo = self:obj("app.cPlayerManageInfo", {
        get_Character = function() return G.char_present and G.H.obj or nil end,
        get_Controller = function() return G.H.controller end,
        get_Object = function() return G.H.go end,
    })
    local function master() return G.player_present and G.pinfo or nil end
    G.catalog_charge = {}
    local charge_fields = {}
    for _, n in ipairs({ "_ChargeParam", "_ChargeParam_Strong", "_ChargeParam_Spirit", "_ChargeParam_Parry",
        "_ChargeParam_Fly", "_ChargeParam_Sliding", "_ChargeParam_BattleRide" }) do
        charge_fields[n] = self:obj("app.user_data.Wp00ActionParam.cCharge", nil,
            { _OverheatTime = f32(n == "_ChargeParam_Parry" and 2.5 or 3.0) })
    end
    charge_fields._GuardDegree = f32(70.0)
    charge_fields._AimGuardDegree = f32(70.0)
    G.wp_param = self:obj("app.user_data.Wp00ActionParam", nil, charge_fields)
    G.catalog = self:obj("app.cPlayerCatalogHolder", {
        getWeaponActionParam = function(_, t) if t == 0 then return G.wp_param end return nil end,
    })
    -- 单人任务：NETWORK_POSITION.QUEST
    w.singletons["app.PlayerManager"] = self:obj("app.PlayerManager", {
        getMasterPlayer = master, findMasterPlayer = master,
        get_Catalog = function() return G.catalog end,
    }, { _CurrentNetworkPosition = w:enum("app.PlayerDef.NETWORK_POSITION", self.scen.net or "QUEST") })
    w.singletons["app.EnemyManager"] = self:obj("app.EnemyManager", {
        findEnemy_SystemIndex = function(_, idx)
            local i = math.tointeger(idx) or -1
            local sc = w:cur_script()
            if sc == G.rc_name then
                -- v16_cache：数放刀模块每帧每只怪调了几次（同一帧按 SystemIndex 缓存，最多 1 次）
                local fc = G.find_calls[w.frame]
                if not fc then
                    fc = {}
                    G.find_calls[w.frame] = fc
                end
                fc[i] = (fc[i] or 0) + 1
            end
            local M = G.by_sysidx[i]
            if M and G:speed_fault(M, "find", sc) then return nil end
            return M and M.minfo or nil
        end,
    })
    w.native_types["via.Application"] = true
    w.native_handlers["via.Application.get_DeltaTime"] = function() return f32(w.dt * 60.0) end
    w.native_handlers["via.Application.get_FrameCount"] = function() return w.frame end
    w.native_handlers["via.Application.get_UpTimeSecond"] = function() return w.clock_base + w.t end
end

-- ---------- 主角 ----------

function S:build_hunter()
    local w, G = self.w, self
    local H = { gen = (G.H and G.H.gen or 0) + 1 }
    local refs = { list = {} }
    G.hpos = G.hpos or { x = -1100.25, y = 56.39, z = 518.95 }
    H.go = self:game_object("MasterPlayer", refs)
    local go_ref = { go = H.go }
    H.tf = self:transform(go_ref, function() return G.hpos end, function() return { x = 0.0, y = 0.0, z = 1.0 } end)
    refs.tf = H.tf
    H.act_objs = {}
    H.ctrl = self:obj("ace.cActionController", {
        get_CurrentActionID = function() return G:action_id_vt(G.act.cat, G.act.idx) end,
        get_CurrentAction = function() return G.act.obj end,
        get_PrevActionID = function() return G:action_id_vt(G.prev_cat or 1, G.prev_idx or 14) end,
        get_NextActionID = function() return G:action_id_vt(-1, -1) end,
    })
    -- 状态标志组：on/off 真的置位、清除（AutoGuardGS 在受击前置钩子里强开 GUARD / TECHNICAL_GUARD、后置钩子里关掉；
    -- MERGE 第 6.2 节第 3 条）。副作用由 mock_ref 按「写方法」记账，这里另记真值（时刻、阶段、标志、开 / 关）
    H.forced = {}
    H.flags = self:obj("ace.cSafeContinueFlagGroup", {
        check = function(_, v) return G:status_flag(v) end,
        on = function(_, v) return G:flag_op(v, true) end,
        off = function(_, v) return G:flag_op(v, false) end,
    })
    H.cflags = self:obj("ace.cSafeContinueFlagGroup", {
        check = function(_, v) return G:continue_flag(v) end,
        on = function() return nil end,
        off = function() return nil end,
    })
    H.status = self:obj("app.cHunterStatus", nil, { _HunterStatusFlag = H.flags })
    H.weapon_go = self:game_object("it0000_0002_0", { list = {} })
    H.weapon = self:obj("app.Weapon", { get_GameObject = function() return H.weapon_go end }, nil,
        { _IsAttackColliderOn = function() return G:blade_collider_on() end })
    H.dmginfo = self:obj("app.cHunterDamageInfo", nil, { _TotalDamage = f32(0.0), _GuardReaction = 0, _DamageType = 0 })
    H.holder_list = self:obj("System.Collections.Generic.List`1<app.AttackAreaResult>", {
        get_Count = function() return #G:holder_items() end,
        get_Item = function(_, i)
            local items = G:holder_items()
            local v = items[(math.tointeger(i) or -1) + 1]
            if not v then error("ArgumentOutOfRangeException: Index was out of range.", 0) end
            return v
        end,
    }, nil, { _size = function() return #G:holder_items() end })
    H.holder = self:obj("app.mcHunterAttackAreaResultHolder", nil, nil,
        { _AttackAreaResultList = function() return H.holder_list end })
    local function flagget(fn) return function() return fn() end end
    H.basic = self:obj("app.motion_track.HunterBasic", {
        get_ParryImmdiate = function() return G:continue_flag(G.E.PARRY_IMMDIATE) end,
        get_SuperArmor = function() return G:status_flag(G.E.SUPER_ARMOR) end,
        get_HyperArmor = function() return false end,
        get_NoHit = function() return G:status_flag(G.E.NO_DAMAGE) end,
        get_ActionFlag1 = function() return false end,
        get_WpUniqueFlag1 = function() return false end,
    }, nil, {
        _ParryImmdiate = flagget(function() return G:continue_flag(G.E.PARRY_IMMDIATE) end),
        _SuperArmor = flagget(function() return G:status_flag(G.E.SUPER_ARMOR) end),
        _HyperArmor = flagget(function() return false end),
        _NoHit = flagget(function() return G:status_flag(G.E.NO_DAMAGE) end),
        _ActionFlag1 = flagget(function() return G:blade_collider_on() end),
        _ActionFlag2 = flagget(function() return false end),
        _ActionFlag3 = flagget(function() return false end),
        _WpUniqueFlag1 = flagget(function() return false end),
    })
    H.ms = self:obj("app.HunterCharacter.cMotionSupporter", nil, { _BaseBasicMotionSeq = H.basic })
    H.layer = self:obj("via.motion.TreeLayer", {
        get_Frame = function() return f32(G:chara_elapsed() * 60.0) end,
        get_Speed = function() return f32(1.0) end,
        get_MotionID = function() return 1000 + (G.act.idx or 0) end,
        get_MotionBankID = function() return 2 end,
        get_EndFrame = function() return f32(300.0) end,
    })
    H.motion = self:obj("via.motion.Motion", {
        getLayer = function() return H.layer end,
        get_LayerCount = function() return 1 end,
        get_GameObject = function() return H.go end,
    })
    H.obj = self:obj("app.HunterCharacter", {
        get_GameObject = function() return H.go end,
        get_WeaponType = function() return G:weapon_type_now() end,
        get_IsMaster = function() return true end,
        get_BaseActionController = function() return H.ctrl end,
        get_HunterStatus = function() return H.status end,
        get_WeaponHandling = function() return H.handling end,
        get_DamageInfo = function() return H.dmginfo end,
        get_AttackAreaResult = function() return H.holder end,
        get_Weapon = function() return H.weapon end,
        get_IsWeaponOn = function() return G:weapon_on_now() end,
        isActionAttrCurrentAction = function(_, v) return G:attr_now(v) end,
        get_HunterHealth = function() return H.health end,
        changeActionRequest = function(o, layer, id, flag) return G:on_request(o, layer, id, flag) end,
        changeActionImmediate = function() return false end,
        checkHunterContinueFlag = function(_, v) return G:continue_flag(v) end,
        checkHunterStatusFlag = function(_, v) return G:status_flag(v) end,
        evHit_DamagePreProcess = function() return G.E.R_SUCCESS end,
        evHit_Damage = function() return G.E.R_SUCCESS end,
        evHit_ShellDamagePreProcess = function() return G.E.R_SUCCESS end,
    }, { _HunterMotionSupporter = H.ms, _HunterContinueFlag = H.cflags })
    H.handling = self:obj("app.cHunterWp00Handling", {
        get_ParryState = function() return G.parry_state end,
        get_ParryTarget = function() return G.parry_target end,
        get_IsParryInfoContinue = function() return false end,
        get_Hunter = function() return H.obj end,
        get_Weapon = function() return H.weapon end,
        set_ParryState = function() return nil end,
        set_ParryTarget = function() return nil end,
    }, { _ChargeType = 0, _ChargeContinue = false }, {
        ["<ParryState>k__BackingField"] = function() return G.parry_state end,
        ["<ParryTarget>k__BackingField"] = function() return G.parry_target end,
        ["<Hunter>k__BackingField"] = function() return H.obj end,
        _ChargeLevel = function() return G:charge_level() end,
        _ChargeTimer = function() return f32(G:charge_time()) end,
        _IsOverheat = function() return false end,
    })
    H.ap_pl = self:obj("app.cAttackParamPl", nil, { _Attack = f32(120.0), _DamageType = G.E.DMG.NORMAL, _GuardType = 0 })
    refs.list = { H.obj, H.motion, H.tf }
    H.entity = self:obj("app.cMasterPlayerControllerEntity", {
        receiveGameMessage = function() return nil end,
        -- 行为表里有没有通往防御的路（AutoGuardGS「能不能举剑」的第一层）：默认 false（同 v1.6 起的旧场景），场景按时间窗口打开
        checkContainsActionInCurrentBTable = function() return G:can_guard_now() end,
    })
    -- 血量（NOTES「血量」）：受击时 requestDamage 登记、下一帧 update 开头结算；红血 requestRedDamage。经过钩子分发，
    -- 前置钩子返回 SKIP_ORIGINAL（AutoGuardGS 的【测试】锁血）就不登记
    H.health_mgr = self:obj("app.cHealthManager", {
        get_Health = function() return f32(G.hp) end,
        get_MaxHealth = function() return f32(G.hp_max) end,
        set_Health = function(_, v) G:set_hp(tonumber(v) or G.hp, "set_Health") end,
    }, nil, { _Health = function() return f32(G.hp) end, _MaxHealth = function() return f32(G.hp_max) end })
    G.master_healths = G.master_healths or {}
    H.health = self:obj("app.cHunterHealth", {
        get_HealthMgr = function() return H.health_mgr end,
        requestDamage = function(_, _chara, dmg) G.pending_dmg = G.pending_dmg + (tonumber(dmg) or 0.0) end,
        requestRedDamage = function(_, dmg) G.pending_dmg = G.pending_dmg + (tonumber(dmg) or 0.0) end,
        get_IsNoDamage = function() return false end,
        set_IsNoDamage = function() return nil end,
    }, nil, { _RequestedTotalDamage = function() return f32(G.pending_dmg) end, _IsNoDamage = function() return false end })
    G.master_healths[string.format("app.cHunterHealth@%X", H.health:get_address())] = true
    H.controller = self:obj("app.cPlayerController", { get_ControllerEntity = function() return H.entity end })
    self.H = H
    -- 主角从拔刀待机开始
    self.act = { cat = 1, idx = 14, t_start = w.t, obj = self:action_obj(1, 14), origin = "init" }
end

function S:destroy_hunter()
    local w = self.w
    local H = self.H
    for _, k in ipairs({ "go", "tf", "ctrl", "flags", "cflags", "status", "weapon_go", "weapon", "dmginfo",
        "holder_list", "holder", "basic", "ms", "layer", "motion", "obj", "handling", "ap_pl", "entity", "controller",
        "health", "health_mgr" }) do
        w:destroy(H[k])
    end
    for _, o in pairs(H.act_objs) do w:destroy(o) end
end

function S:action_obj(cat, idx)
    local H = self.H
    local key = cat .. "," .. idx
    local o = H.act_objs[key]
    if o then return o end
    local name = ACT_NAME[key] or string.format("app.Wp00Action.cMockAction_%d_%d", cat, idx)
    if not self.w.types[name] then self.w:declare_type(name, { parent = "app.cHunterActionBase" }) end
    local G = self
    o = self.w:new_object(name, {
        getters = { _RawTotalElapsedSecond = function(self_o) return G:raw_of(self_o) end },
        methods = {
            get_RawTotalElapsedSecond = function(self_o) return G:raw_of(self_o) end,
            get_CharaElapsedSecond = function(self_o) return G:chara_of(self_o) end,
            get_CharaDeltaTime = function() return f32(G.w.dt) end,
            get_SelfObject = function() return G.H.go end,
        },
        data = { cat = cat, idx = idx },
    })
    H.act_objs[key] = o
    return o
end

function S:raw_elapsed() return self.w.t - self.act.t_start end

function S:chara_elapsed()
    local a = self.act
    local raw = self.w.t - a.t_start
    if a.emhit_t then
        raw = raw - math.min(math.max(0.0, self.w.t - a.emhit_t), self.P.hitstop)
    end
    return math.max(0.0, raw)
end

function S:raw_of(o)
    if self.act.obj == o then return f32(self:raw_elapsed()) end
    return f32(self.w:data(o).last_raw or 0.0)
end

function S:chara_of(o)
    if self.act.obj == o then return f32(self:chara_elapsed()) end
    return f32(self.w:data(o).last_chara or 0.0)
end

local function is_charge(a) return a.cat == 2 and (a.idx == 21 or a.idx == 22) end
local function is_slash(a) return a.cat == 2 and (a.idx == 23 or a.idx == 24) end
local function is_phit(a) return a.cat == 2 and a.idx >= 25 and a.idx <= 27 end
S.is_charge, S.is_slash, S.is_phit = is_charge, is_slash, is_phit

local NORMAL_CHARGE = { [5] = true, [6] = true, [7] = true, [11] = true }
-- 松手后的蓄力斩（实测：(2,6)→(2,0) 255 次、(2,7)→(2,1) 194 次、(2,11)→(2,12) 148 次；(2,5) 按 (2,6) 算）
local CHARGE_SLASH = { [5] = 0, [6] = 0, [7] = 1, [11] = 12 }
local CHARGE_SLASH_SET = { [0] = true, [1] = true, [12] = true }
local TACKLE = { [15] = true, [17] = true }
local function is_ncharge(a) return a.cat == 2 and NORMAL_CHARGE[a.idx] == true end
local function is_tackle(a) return a.cat == 2 and TACKLE[a.idx] == true end
S.is_ncharge, S.is_tackle = is_ncharge, is_tackle

-- 场景的时间窗口：true = 一直成立；{ {from, to}, ... } = 这些时段成立；nil / false = 从不
local function in_windows(list, t)
    if list == true then return true end
    if type(list) ~= "table" then return false end
    for _, wd in ipairs(list) do
        if t >= wd[1] - 1e-9 and t < wd[2] - 1e-9 then return true end
    end
    return false
end
S.in_windows = in_windows

function S:status_flag(v)
    local a = self.act
    local e = self.w.t - a.t_start
    local E = self.E
    -- 脚本强开的标志（on/off）和场景按时间窗口开的标志（status_on = { GUARD = { {from, to} } }，比如手动防御中）
    if self.H.forced[v] then return true end
    for name, wins in pairs(self.scen.status_on or {}) do
        if v == self.w:enum("app.HunterDef.STATUS_FLAG", name) and in_windows(wins, self.w.t) then return true end
    end
    if v == E.SUPER_ARMOR then
        if is_charge(a) or is_phit(a) then return true end
        if is_slash(a) then return e < self.P.T_armor end
        if a.cat == 2 and a.idx == 29 then return e < 0.6 end
        if is_ncharge(a) or is_tackle(a) then return true end
        return false
    elseif v == E.HYPER_ARMOR then
        return is_tackle(a)
    elseif v == E.NO_DAMAGE then
        return is_phit(a)
    end
    return false
end

-- 脚本对状态标志组 on/off：真的置位、清除，并记真值
function S:flag_op(v, on)
    local w = self.w
    local iv = math.tointeger(v)
    if iv == nil then return nil end
    if on then self.H.forced[iv] = true else self.H.forced[iv] = nil end
    self.truth.flag_ops = self.truth.flag_ops or {}
    self.truth.flag_ops[#self.truth.flag_ops + 1] = { t = w.t, frame = w.frame, phase = w.phase, on = on, v = iv,
        name = w:enum_name("app.HunterDef.STATUS_FLAG", iv), script = w:cur_script() }
    return nil
end

-- 这一下受击按防御结算：脚本强开了 GUARD / TECHNICAL_GUARD（或场景开着防御标志）
function S:guard_forced()
    local w = self.w
    for _, n in ipairs({ "GUARD", "TECHNICAL_GUARD" }) do
        if self:status_flag(w:enum("app.HunterDef.STATUS_FLAG", n)) then return n end
    end
    return nil
end

function S:can_guard_now() return in_windows(self.scen.can_guard, self.w.t) end
function S:weapon_on_now() return not in_windows(self.scen.weapon_off, self.w.t) end
function S:attr_now(v)
    local name = self.w:enum_name("app.HunterDef.ACTION_ATTR", v)
    return in_windows((self.scen.attrs or {})[name], self.w.t)
end
-- 武器类型：场景的 weapon_type（默认大剑 0），weapon_type_at = { {t, 值}, ... } 按时刻切换（无限蓄力换武器要还原）
function S:weapon_type_now()
    local v = self.scen.weapon_type or 0
    for _, c in ipairs(self.scen.weapon_type_at or {}) do
        if self.w.t >= c[1] - 1e-9 then v = c[2] end
    end
    return v
end

-- 血量
function S:set_hp(v, why)
    local w = self.w
    local old = self.hp
    self.hp = math.max(0.0, math.min(self.hp_max, v))
    if self.hp ~= old then
        self.truth.hp_log = self.truth.hp_log or {}
        self.truth.hp_log[#self.truth.hp_log + 1] = { t = w.t, frame = w.frame, phase = w.phase, hp = self.hp, why = why }
    end
end

local REQ_DMG_SIG = "requestDamage(app.HunterCharacter, System.Single, System.Single, System.Boolean, System.Boolean, "
    .. "System.Boolean, System.Boolean, System.Boolean, System.Boolean)"
-- 受击登记伤害（经过钩子分发：前置钩子返回 SKIP_ORIGINAL 就不登记）；red = 红血
function S:request_damage(dmg, red)
    local w = self.w
    self.truth.dmg_req = self.truth.dmg_req or {}
    local rec = { t = w.t, frame = w.frame, amount = dmg, red = red == true, applied = false }
    self.truth.dmg_req[#self.truth.dmg_req + 1] = rec
    local orig = function()
        rec.applied = true
        self.pending_dmg = self.pending_dmg + dmg
        return nil
    end
    if red then
        w:fire(self.H.health, "app.cHunterHealth", "requestRedDamage(System.Single)", { f32(dmg), n = 1 }, orig)
    else
        w:fire(self.H.health, "app.cHunterHealth", REQ_DMG_SIG,
            { self.H.obj, f32(dmg), f32(0.0), false, false, false, false, false, false, n = 9 }, orig)
    end
end

-- 同场 NPC 支援猎人挨打：this 是 NPC 自己的 cHunterHealth（不是主玩家的），锁血只拦主玩家（v1.4.2 按地址比），这一份照常登记
function S:npc_request_damage(dmg)
    local w = self.w
    if not self.npc then
        local G = self
        local npc = { hp = 150.0 }
        npc.chara = self:obj("app.HunterCharacter", { get_IsMaster = function() return false end,
            get_WeaponType = function() return 0 end })
        npc.health = self:obj("app.cHunterHealth", {
            requestDamage = function(_, _c, d) npc.hp = npc.hp - (tonumber(d) or 0.0) end,
            get_HealthMgr = function() return nil end,
        })
        self.npc = npc
        G.truth.npc_health = string.format("%X", npc.health:get_address())
    end
    self.truth.npc_dmg_req = self.truth.npc_dmg_req or {}
    local rec = { t = w.t, amount = dmg, applied = false }
    self.truth.npc_dmg_req[#self.truth.npc_dmg_req + 1] = rec
    local npc = self.npc
    w:fire(npc.health, "app.cHunterHealth", REQ_DMG_SIG,
        { npc.chara, f32(dmg), f32(0.0), false, false, false, false, false, false, n = 9 },
        function()
            rec.applied = true
            npc.hp = npc.hp - dmg
            return nil
        end)
end

-- 登记的伤害在下一帧 update 开头结算（NOTES：requestDamage 登记、update 里结算）
function S:settle_damage()
    if self.pending_dmg > 0 then
        local d = self.pending_dmg
        self.pending_dmg = 0.0
        self:set_hp(self.hp - d, "damage")
    end
end

function S:continue_flag(v)
    local a = self.act
    local e = self.w.t - a.t_start
    local E = self.E
    if v == E.PARRY_IMMDIATE then return is_slash(a) and e >= self.P.W0 and e <= self.P.W1 end
    if v == E.WP_ATTACK_COLLISION_ON then return self:blade_collider_on() end
    if v == E.PARRY_COMBO then return is_phit(a) and e > 0.5 end
    return false
end

-- 蓄力等级：按住抵消蓄力每 0.6 s 升一级（模拟值），放刀后保持放刀那一刻的等级
function S:charge_time()
    local a = self.act
    if is_charge(a) then return self.w.t - a.t_start end
    return self.last_charge_t or 0.0
end

function S:charge_level()
    return math.min(3, math.floor(self:charge_time() / 0.6))
end

function S:blade_collider_on()
    local a = self.act
    local e = self.w.t - a.t_start
    return is_slash(a) and e >= 0.30 and e <= 0.45
end

function S:holder_items()
    if self.scen.holder == "empty" then return {} end
    local out = {}
    for _, R in ipairs(self.results) do
        if R.target == "me" and not R.fin and #R.entries > 0 then out[#out + 1] = R.obj end
    end
    return out
end

-- ---------- 动作请求与切换 ----------

function S:on_request(hunter_obj, layer, id, flag)
    local w = self.w
    local rec = { frame = w.frame, t = w.t, phase = w.phase, script = w:cur_script() or "game", accepted = false,
        layer = layer, flag = flag, from = string.format("(%d,%d)", self.act.cat, self.act.idx) }
    if getmetatable(id) == mock.VT then
        local f = rawget(id, "__f")
        rec.cat, rec.idx = f._Category, f._Index
        rec.id_type = rawget(id, "__t").name
    else
        rec.bad_id = true
    end
    if hunter_obj ~= self.H.obj then
        rec.reason = "不是当前主角"
    elseif rec.bad_id or rec.id_type ~= "ace.ACTION_ID" or layer ~= 0 or type(flag) ~= "boolean" then
        rec.reason = "参数不对"
    elseif self.reject_left > 0 then
        self.reject_left = self.reject_left - 1
        rec.reason = "场景设定拒绝"
    elseif self.next then
        rec.reason = "本帧已有切换"
    elseif is_charge(self.act) and rec.cat == 2 and (rec.idx == 23 or rec.idx == 24) then
        rec.accepted = true
        self.next = { cat = 2, idx = rec.idx, origin = "request", req = rec, frame = w.frame + 1 }
    elseif is_ncharge(self.act) and rec.cat == 2 and TACKLE[rec.idx] then
        -- 自动肩撞（AutoGuardGS）：普通蓄力 (2,5)/(2,6)/(2,7)/(2,11) 里请求 (2,15)/(2,17)，下一帧生效（记法同 (2,23)）
        rec.accepted = true
        self.next = { cat = 2, idx = rec.idx, origin = "request", req = rec, frame = w.frame + 1 }
        self.holding_n = false
    else
        rec.reason = "当前动作不接受"
    end
    w.requests[#w.requests + 1] = rec
    return rec.accepted
end

function S:schedule(cat, idx, origin, override)
    if self.next and not override then return false end
    self.next = { cat = cat, idx = idx, origin = origin, frame = self.w.frame + 1 }
    return true
end

function S:apply_transition(n)
    local w = self.w
    local a = self.act
    local d = w:data(a.obj)
    d.last_raw = w.t - a.t_start
    d.last_chara = self:chara_elapsed()
    if is_charge(a) then self.last_charge_t = w.t - a.t_start end
    self.prev_cat, self.prev_idx = a.cat, a.idx
    self.act = { cat = n.cat, idx = n.idx, t_start = w.t, obj = self:action_obj(n.cat, n.idx), origin = n.origin }
    local na = self.act
    if not is_phit(na) and not is_slash(na) then
        self.parry_state = self.E.PS_NONE
        self.parry_target = nil
    end
    if is_slash(na) then
        local at = { id = #self.truth.attempts + 1, t_start = w.t, frame = w.frame, origin = n.origin,
            t_req = n.req and n.req.t or nil, req_frame = n.req and n.req.frame or nil,
            from = string.format("(%d,%d)", a.cat, a.idx), contacts = {}, blade = 0, body = 0, outcome = "none",
            emhit = false }
        self.truth.attempts[#self.truth.attempts + 1] = at
        self.attempt = at
        self.parried_now = false
        if self.player.auto then
            self:player_event(w.t + self.player.auto.release_after, "release_soft")
            self:player_event(w.t + self.player.auto.input_after, "input")
        end
    elseif self.attempt and not (na.cat == 2 and na.idx >= 23 and na.idx <= 29) then
        self.attempt.t_end = w.t
        self.attempt = nil
    end
    if is_phit(na) and self.attempt then
        self.attempt.outcome = "parry"
        self.attempt.hit_level = na.idx
        self.attempt.hit_t = w.t
    end
    local au = self.player.auto
    if na.cat == 1 and na.idx == 14 and au and (not au.stop_at or w.t < au.stop_at) then
        self:player_event(w.t + au.rehold, "hold")
    end
end

-- ---------- 玩家 ----------

function S:prepare_player()
    local p = self.scen.player or {}
    self.player = { events = {}, auto = nil }
    self.holding = false
    self.charge_idx = 21
    self.input_pending = false
    for _, ev in ipairs(p.events or {}) do
        sorted_insert(self.player.events, { t = ev.t or ev[1], op = ev.op or ev[2], idx = ev.idx })
    end
    if p.policy == "auto" then
        self.player.auto = {
            release_after = p.release_after or 0.2,
            input_after = p.input_after or 1.5,
            rehold = p.rehold or 0.4,
            charge_idx = p.charge_idx or 21,
            stop_at = p.stop_at,
        }
        self:player_event(p.first_hold or 1.0, "hold", p.charge_idx)
    end
end

function S:player_event(t, op, idx)
    sorted_insert(self.player.events, { t = t, op = op, idx = idx })
end

function S:player_input()
    local w = self.w
    local list = self.player.events
    while #list > 0 and list[1].t <= w.t do
        local ev = table.remove(list, 1)
        if ev.op == "hold" then
            self.holding = true
            self.charge_idx = ev.idx or (self.player.auto and self.player.auto.charge_idx) or 21
        elseif ev.op == "release" then
            self.holding = false
            if is_charge(self.act) and not self.next then self:schedule(2, 23, "manual") end
        elseif ev.op == "release_soft" then
            -- 上捞斩出来后松键（不触发新动作）
            self.holding = false
        elseif ev.op == "input" then
            self.input_pending = true
        elseif ev.op == "charge" then
            -- 普通蓄力（自动肩撞的场景）：拔刀待机时下一帧进 (2,5)，之后按时间线升级
            self.holding_n = true
        elseif ev.op == "release_charge" then
            self.holding_n = false
            if is_ncharge(self.act) and not self.next then self:schedule(2, CHARGE_SLASH[self.act.idx], "release_charge") end
        elseif ev.op == "hold_now" then
            -- 这一帧 update 里就切进抵消蓄力（不等下一帧开头）：造出「帧开头不在抵消族、受击钩子时已在抵消族」的时刻
            -- （MERGE 第 6.7 节变异「钩子里改用帧开头的动作快照」；真游戏里动作控制器在 UpdateBehavior 里切动作）
            if self.act.cat == 1 and self.act.idx == 14 and self.char_present then
                self.next = nil
                self:apply_transition({ cat = 2, idx = ev.idx or 21, origin = "hold_now" })
            end
            self.holding = true
            self.charge_idx = ev.idx or 21
        end
    end
    if self.holding and not self.next and self.act.cat == 1 and self.act.idx == 14 and self.char_present then
        self:schedule(2, self.charge_idx, "hold")
    elseif self.holding_n and not self.next and self.act.cat == 1 and self.act.idx == 14 and self.char_present then
        self:schedule(2, 5, "charge")
    end
end

function S:hunter_timeline()
    local a = self.act
    local e = self.w.t - a.t_start
    local P = self.P
    if self.next then return end
    if is_slash(a) then
        if self.input_pending and e >= P.input_min then
            self.input_pending = false
            self:schedule(1, 14, "input")
        elseif e >= P.slash_len then
            self:schedule(1, 14, "slash_end")
        end
    else
        self.input_pending = false
        if is_phit(a) and e >= P.hitl then
            self:schedule(2, 28, "timeline")
        elseif a.cat == 2 and a.idx == 28 and e >= P.close_move then
            self:schedule(2, 29, "timeline")
        elseif a.cat == 2 and a.idx == 29 and e >= P.close_slash then
            self:schedule(1, 14, "timeline")
        elseif a.cat == 0 and a.idx == 30 and e >= P.flinch then
            self:schedule(1, 14, "timeline")
        elseif a.cat == 2 and a.idx == 5 and e >= P.charge5 then
            self:schedule(2, 6, "timeline")
        elseif a.cat == 2 and a.idx == 6 and e >= P.charge6 then
            self:schedule(2, 7, "timeline")
        elseif a.cat == 2 and a.idx == 7 and e >= P.charge7 then
            self:schedule(2, 11, "timeline")
        elseif (is_tackle(a) and e >= P.tackle) or (a.cat == 2 and CHARGE_SLASH_SET[a.idx] and e >= P.charge_slash)
            or (a.cat == 1 and (a.idx == 144 or a.idx == 146) and e >= P.guard_react) then
            self:schedule(1, 14, "timeline")
        end
    end
end

-- 主角消失 / 换对象（切场景）
function S:prepare_hunter_events()
    self.hunter_events = {}
    for _, ev in ipairs(self.scen.hunter_events or {}) do sorted_insert(self.hunter_events, deep_copy(ev)) end
end

function S:apply_hunter_events()
    local w = self.w
    local list = self.hunter_events
    while #list > 0 and list[1].t <= w.t do
        local ev = table.remove(list, 1)
        if ev.op ~= "restore" then
            self.truth.hunter_events = self.truth.hunter_events or {}
            self.truth.hunter_events[#self.truth.hunter_events + 1] = { t = w.t, op = ev.op }
        end
        if ev.op == "gap_char" then
            self.char_present = false
            sorted_insert(list, { t = w.t + (ev.dur or 1.0), op = "restore" })
        elseif ev.op == "gap_player" then
            self.player_present = false
            sorted_insert(list, { t = w.t + (ev.dur or 1.0), op = "restore" })
        elseif ev.op == "restore" then
            self.char_present, self.player_present = true, true
        elseif ev.op == "swap" then
            local old = self.H.obj
            self:destroy_hunter()
            self:build_hunter()
            self.next = nil
            self.attempt = nil
            self.last_swap_t = w.t
            self.truth.swaps[#self.truth.swaps + 1] = { t = w.t, frame = w.frame,
                old = string.format("%X", old:get_address()), new = string.format("%X", self.H.obj:get_address()) }
        end
    end
end

-- ---------- 怪物 ----------

function S:build_monster(key, spec)
    local w, G = self.w, self
    local M = { key = key, spec = spec, emid = spec.emid, sysidx = spec.sysidx, cls = spec.cls or "app.Em0020_00Action",
        action = spec.idle or "cWait", idle = spec.idle or "cWait", speed = spec.speed or 1.0,
        cur_target = spec.target or "me", act_objs = {}, stocked = false, delay_frame = 0.0,
        -- CoreState：数值，或时间表 { {t, C}, ... }（阶梯函数，t 是绝对时刻，在 update 阶段倒数之后切换）
        core_cur = type(spec.core) == "number" and spec.core or 1.0, core_table = {},
        speed_faults = {}, present = spec.spawn_at == nil }
    if type(spec.core) == "table" then
        for _, c in ipairs(spec.core) do
            if c[1] <= 0 then M.core_cur = c[2] else M.core_table[#M.core_table + 1] = { t = c[1], C = c[2] } end
        end
        table.sort(M.core_table, function(a, b) return a.t < b.t end)
    end
    M.has_speed = spec.core ~= nil
    for _, f in ipairs(spec.speed_fault or {}) do M.speed_faults[#M.speed_faults + 1] = f end
    local p = spec.pos or { x = G.hpos.x, y = G.hpos.y, z = G.hpos.z + 4.0 }
    M.pos = { x = p.x, y = p.y, z = p.z }
    local refs = { list = {} }
    M.go = self:game_object(spec.go_name or (key .. "_go"), refs)
    local go_ref = { go = M.go }
    M.tf = self:transform(go_ref, function() return M.pos end, function() return { x = 0.0, y = 0.0, z = -1.0 } end)
    refs.tf = M.tf
    M.scar_go = self:game_object("EnemyScarCollider_" .. tostring(spec.sysidx) .. "8416409601", { list = {} })
    M.shell_go = self:game_object((spec.go_name or key) .. "_Shell", { list = {} })
    M.dpi = self:obj("app.cEmModuleHit.cParryInfo", nil, { ConditionStockDamage = f32(0.0) }, {
        DelayFrame = function() return f32(M.delay_frame) end,
        Target = function() return M.delay_target end,
        Direction = function() return nil end,
    })
    M.hit = self:obj("app.cEmModuleHit", {
        onParryDamage = function() return nil end,
    }, { DelayParryInfo = M.dpi, IsExternalDamageActionRequested = false }, {
        IsParryStocked = function() return M.stocked end,
        DamageActionType = function() return M.stocked and G.E.DMG_PARRY or G.E.DMG_NONE end,
        DamageActionID = function() return M.stocked and G:action_id_vt(0, 11) or G:action_id_vt(-1, -1) end,
    })
    M.tgt = self:obj("app.cEmModuleTarget", {
        getTarget = function()
            local cat = M.cur_target == "otomo" and G.E.CAT_OTOMO or G.E.CAT_PLAYER
            return G:key_vt(cat, 0)
        end,
        get_This = function() return G:key_vt(w:enum("app.TARGET_ACCESS_KEY.CATEGORY", "ENEMY"), M.sysidx) end,
    })
    M.ctx = self:obj("app.cEnemyContext", {
        get_EmID = function() return M.emid end,
        get_SystemIndex = function() return M.sysidx end,
    },
        { Hit = M.hit, Target = M.tgt }, { ThisKey = function() return G:key_vt(1, M.sysidx) end })
    M.holder = self:obj("app.cEnemyContextHolder", {
        get_IsMaster = function() return spec.master ~= false end,
        get_Em = function() return M.ctx end,
        get_IsHealthZero = function() return false end,
    }, { _Em = M.ctx })
    M.enemy = self:obj("app.EnemyCharacter", {
        get_GameObject = function() return M.go end,
        getCurrentAction = function() return G:em_action_obj(M) end,
        -- 总速度含招式里的隐藏因子（已经算进名义帧，SPEED 2.1 g）：误用它的实现会被 hidden ≠ 1 的场景抓到
        calcMotionSpeedTotal = function() return f32(M.core_cur * (spec.hidden or 1.0) * M.speed) end,
        get_MotionSpeed_Action = function() return f32(1.0) end,
        get_MotionSpeed_Base = function() return f32(1.0) end,
        get_MotionSpeed_CoreState = function() return G:core_read(M, w:cur_script()) end,
        get_MotionSpeed_Random = function() return f32(M.speed) end,
        get_MotionSpeed_Replica = function() return f32(1.0) end,
        get_MotionSpeed_ScaleAdjusted = function() return f32(1.0) end,
        get_MotionSpeed_WaitPacket = function() return f32(1.0) end,
        get_EffectController = function() return nil end,
        evHit_DamagePreProcess = function() return G.E.R_SUCCESS end,
        evHit_AttackParry = function() return nil end,
    }, { _Context = M.holder })
    M.minfo = self:obj("app.cEnemyManageInfo", {
        get_Character = function()
            if G:speed_fault(M, "char", w:cur_script()) then return nil end
            return M.enemy
        end,
        get_CharacterValid = function() return true end,
        get_Pos = function() return vec(f32(M.pos.x), f32(M.pos.y), f32(M.pos.z)) end,
        get_Context = function() return M.holder end,
        get_ContextValid = function() return true end,
        get_Object = function() return M.go end,
    })
    M.hc = self:obj("app.HitController", {
        get_Owner = function() return M.go end,
        get_GameObject = function() return M.go end,
    })
    M.cs = self:obj("app.ColliderSwitcher", { get_GameObject = function() return M.go end }, { _HitController = M.hc })
    refs.list = { M.enemy, M.cs, M.tf }
    M.default_ap = self:new_attack_param(M, { name = "Default" })
    M.results = {}
    self.monsters[key] = M
    if M.present then
        self.by_sysidx[M.sysidx] = M
        self.mon_order[#self.mon_order + 1] = M
    end
    M.res_me = self:new_result(M, "me")
    return M
end

-- 怪物用到的全部游戏对象（消失时游戏一起放手）
function S:monster_objects(M)
    local list = { M.go, M.tf, M.scar_go, M.shell_go, M.dpi, M.hit, M.tgt, M.ctx, M.holder, M.enemy, M.minfo, M.hc, M.cs,
        M.default_ap }
    for _, o in pairs(M.act_objs) do list[#list + 1] = o end
    return list
end

-- 怪物出现 / 消失（spawn_at / despawn_at，update 阶段在攻击事件之后处理：同一帧先发消息、再换怪，
-- 这样下一帧帧回调按 SystemIndex 找到的已经是新怪（v16_sidmis））
function S:monster_lifecycle()
    local w = self.w
    for _, M in pairs(self.monsters) do
        local sp = M.spec
        if not M.present and not M.gone and sp.spawn_at and w.t >= sp.spawn_at - 1e-9 then
            M.present = true
            self.by_sysidx[M.sysidx] = M
            self.mon_order[#self.mon_order + 1] = M
        end
        if M.present and not M.gone and sp.despawn_at and w.t >= sp.despawn_at - 1e-9 then
            M.present, M.gone = false, true
            if self.by_sysidx[M.sysidx] == M then self.by_sysidx[M.sysidx] = nil end
            for i, x in ipairs(self.mon_order) do
                if x == M then
                    table.remove(self.mon_order, i)
                    break
                end
            end
            for _, o in ipairs(self:monster_objects(M)) do w:game_release(o) end
        end
    end
end

-- 速度读取故障（怪物 spec.speed_fault 或攻击的 speed_fault，换算成绝对时刻）：
--   { from, to, mode = "find_nil" | "char_nil" | "throw" | "nan" | "value", value =, scripts = { 脚本名 = true } }
-- 默认只对放刀模块生效（探针的 EMINFO 照常，免得探针的可选模块跟着报黄）。kind = "find" / "char" / "core"
local FAULT_KIND = { find_nil = "find", char_nil = "char", throw = "core", nan = "core", value = "core" }
function S:speed_fault(M, kind, script)
    local t = self.w.t
    for _, f in ipairs(M.speed_faults) do
        if FAULT_KIND[f.mode] == kind and (not f.from or t >= f.from - 1e-9) and (not f.to or t < f.to - 1e-9) then
            local scs = f.scripts or { [self.rc_name] = true }
            if script and scs[script] then return f end
        end
    end
    return nil
end

-- get_MotionSpeed_CoreState 的返回值（System.Single）；故障时抛错 / NaN / 指定值
function S:core_read(M, script)
    local f = self:speed_fault(M, "core", script)
    if f then
        if f.mode == "throw" then error(f.msg or "mock: get_MotionSpeed_CoreState threw", 0) end
        if f.mode == "nan" then return 0.0 / 0.0 end
        if f.mode == "value" then return f32(f.value) end
    end
    return f32(M.core_cur)
end

function S:em_action_obj(M)
    local name = M.cls .. "." .. M.action
    local o = M.act_objs[name]
    if o then return o end
    if not self.w.types[name] then self.w:declare_type(name, { parent = "app.cEnemyActionBase" }) end
    local G = self
    o = self.w:new_object(name, {
        methods = { get_Chara = function() return M.enemy end },
        getters = { _RawTotalElapsedSecond = function() return f32(G.w.t - (M.action_t or 0.0)) end },
    })
    M.act_objs[name] = o
    return o
end

function S:set_em_action(M, action)
    if M.action ~= action then
        M.action = action
        M.action_t = self.w.t
    end
end

-- 防御类型：名字（"UNABLE_GUARD"）按枚举取值，数字原样（枚举外的值，比如 7，用来测「未知值」）
function S:guard_value(g)
    if g == nil then return self.E.GUARD.NORMAL end
    if type(g) == "string" then return self.E.GUARD[g] or self.w:enum("app.Hit.GUARD_TYPE", g) end
    return g
end

function S:new_attack_param(M, spec)
    local E = self.E
    local name = spec.name or "Atk"
    local ud = self:obj("app.col_user_data.AttackParam", { get_Name = function() return "EmAtk_" .. M.key .. "_" .. name end },
        nil, nil, nil, "atk")
    local ap = self:obj("app.cAttackParamEm", { get_UserData = function() return ud end }, {
        _GuardType = self:guard_value(spec.guard),
        _DamageType = E.DMG[spec.dmg or "NORMAL"] or E.DMG.NORMAL,
        _DamageTypeCustom = 0,
        _DamageLevel = spec.dmglv or 2,
        _AttackFilterType = 0,
        _VersusGuardPower = f32(spec.vguard or 10.0),
        _Attack = f32(spec.attack or 40.0),
        _IsParryBreak = spec.pbreak or false,
        _IsParryFix = false,
        _IsParryStockOnly = false,
        _IsTechGuardBreak = false,
        _IsBlockEnable = true,
        _UserData = ud,
    }, nil, nil, "atk")
    self.w:data(ap).ud = ud
    return ap
end

function S:target_obj(target)
    if target == "me" then return self.H.obj end
    if not self.other_chara then
        local G = self
        local go = self:game_object("Otomo_000", { list = {} })
        self.other_chara = self:obj("app.CharacterBase", { get_GameObject = function() return go end })
        G.other_go = go
    end
    return self.other_chara
end

function S:new_result(M, target, opts)
    local w, G = self.w, self
    opts = opts or {}
    local R = { M = M, target = target, entries = {}, fin = true, type = self.E.SAFE, keep = { 0, 0 }, closest = nil,
        t_msg = nil, delivered = false, n_msg = 0, merged = { 0.0, 0.0 },
        msg_times = {}, fin_changes = { { t = w.t, fin = true } }, reuse = opts.reuse ~= false,
        is_local = opts.is_local == true }
    local function item(i)
        local ii = math.tointeger(i)
        if not ii then error("get_Item: 参数必须是整数", 0) end
        local e = R.entries[ii + 1]
        if not e then error("ArgumentOutOfRangeException: Index was out of range.", 0) end
        return e.obj
    end
    local function filtered_list(want)
        local items = {}
        for _, e in ipairs(R.entries) do if e.type == want then items[#items + 1] = e.obj end end
        return G:obj("System.Collections.Generic.List`1<app.AttackAreaResult.DetectedData>", {
            get_Count = function() return #items end,
            get_Item = function(_, i)
                local v = items[(math.tointeger(i) or -1) + 1]
                if not v then error("ArgumentOutOfRangeException: Index was out of range.", 0) end
                return v
            end,
        }, nil, nil, nil, "aux")
    end
    -- data.R：场景的故障可以只作用于某只怪的列表（scenarios.lua 的 of_em）
    R.list = self:obj("System.Collections.Generic.List`1<app.AttackAreaResult.DetectedData>", {
        get_Count = function() return #R.entries end,
        get_Item = function(_, i) return item(i) end,
        get_Capacity = function() return math.max(4, #R.entries) end,
    }, { _version = 1 }, { _size = function() return #R.entries end }, { R = R }, "atk")
    R.area = self:obj("app.AttackAreaData", nil, nil, {
        AttackStartFrame = function() return f32(R.merged[1]) end,
        AttackEndFrame = function() return f32(R.merged[2]) end,
    }, nil, "atk")
    R.obj = self:obj("app.AttackAreaResult", {
        get_TargetCharacter = function() return G:target_obj(R.target) end,
        get_ResultType = function() return R.type end,
        get_IsAttackFinished = function() return R.fin end,
        get_KeepActionID = function() return G:action_id_vt(R.keep[1], R.keep[2]) end,
        get_EmID = function() return M.emid end,
        get_EmSystemIndex = function() return M.sysidx end,
        getClosestDetectedData = function()
            local e = R.closest and R.entries[R.closest]
            return e and e.obj or nil
        end,
        get_DetectedDataList = function() return R.list end,
        get_MergedAreaData = function() return R.area end,
        getDangerousDetectedDataList = function() return filtered_list(G.E.DANGER) end,
        getCautionDetectedDataList = function() return filtered_list(G.E.CAUTION) end,
        getClosestAttackParam = function()
            local e = R.closest and R.entries[R.closest]
            return e and e.ap or nil
        end,
        get_TargetCapsuleRadius = function() return f32(0.45) end,
    }, nil, {
        ["<TargetCharacter>k__BackingField"] = function() return G:target_obj(R.target) end,
        ["<ResultType>k__BackingField"] = function() return R.type end,
        ["<EmID>k__BackingField"] = function() return M.emid end,
        ["<EmSystemIndex>k__BackingField"] = function() return M.sysidx end,
        ["<DetectedDataList>k__BackingField"] = function() return R.list end,
        ["<MergedAreaData>k__BackingField"] = function() return R.area end,
        ["<KeepActionID>k__BackingField"] = function() return G:action_id_vt(R.keep[1], R.keep[2]) end,
    }, { R = R }, "atk")
    if R.is_local then
        -- 局部对象（V16 第 8.4 节第 42 条）：游戏不持有、REF 推入时不加引用；这一帧结束（end_scope）后只有 add_ref 能保活
        rawset(R.obj, "__local", true)
        rawset(R.obj, "__grefs", 0)
    end
    if not R.reuse then rawset(R.obj, "__on_destroy", function() G:release_children(R) end) end
    M.results[target] = R
    self.results[#self.results + 1] = R
    return R
end

-- 游戏放手一个结果（IsAttackFinished 之后 drop_after）。结果自己拥有的条目列表、合并数据、条目、攻击参数，要等结果
-- 真的销毁（游戏放手且没有 Lua 引用）时才一起放：脚本还拿着结果的时候，通过它读到的子对象必须还活着
function S:drop_result(R)
    if R.dropped or R.reuse then return end
    R.dropped = true
    R.dropped_t = self.w.t
    if not R.is_local then self.w:game_release(R.obj) end
end

-- 结果对象销毁的那一刻：它拥有的子对象游戏一起放手（被换掉的条目在换掉时已经放过，game_release 到 0 为止，重复无害）
function S:release_children(R)
    local w = self.w
    w:game_release(R.list)
    w:game_release(R.area)
    for _, o in ipairs(R.all_entry_objs or {}) do w:game_release(o) end
    for _, ap in ipairs(R.all_aps or {}) do
        w:game_release(ap)
        w:game_release(w:data(ap).ud)
    end
end

-- 条目对象：怪物会复用（PLAN P04 / 探针注释「结果对象和条目对象都会被怪物复用」）。场景 reuse_entries=true 时，
-- 同一个结果的第 i 个条目沿用同一个 DetectedData 对象（地址不变），只换掉里面的数值和 AttackParam
function S:new_entry(R, spec, index)
    local G = self
    local E = self.E
    local e = { spec = spec, type = E[spec.type or "DANGER"] or E.DANGER, hs = spec.hs + 0.0, he = (spec.he or spec.hs + 20) + 0.0,
        shell = spec.shell, reqset = spec.reqset, dmg = E.DMG[spec.dmg or "NORMAL"] or E.DMG.NORMAL, index = index,
        pb = (spec.pb or spec.pbreak) == true, guard = self:guard_value(spec.guard), ap_nil = spec.ap == false }
    e.ap = self:new_attack_param(R.M, { name = string.format("%d_%d_%d", R.keep[1], R.keep[2], index), dmg = spec.dmg,
        guard = spec.guard, pbreak = e.pb, dmglv = spec.dmglv })
    R.all_aps = R.all_aps or {}
    R.all_aps[#R.all_aps + 1] = e.ap
    R.pool = R.pool or {}
    local slot = self.scen.reuse_entries and R.pool[index] or nil
    if slot then
        slot.e = e
        e.obj = slot.obj
        return e
    end
    slot = { e = e }
    R.pool[index] = slot
    local M = R.M
    e.obj = self:obj("app.AttackAreaResult.DetectedData", {
        get_ResultType = function() return slot.e.type end,
        get_HitStartRemainFrame = function() return f32(slot.e.hs) end,
        get_HitEndRemainFrame = function() return f32(slot.e.he) end,
        get_ShellIndex = function() return G:nullable("System.Nullable`1<System.Int32>", slot.e.shell) end,
        get_RequestSetID = function() return G:nullable("System.Nullable`1<System.UInt32>", slot.e.reqset) end,
        get_AttackParam = function()
            if slot.e.ap_nil then return nil end
            return slot.e.ap
        end,
        get_Obb = function()
            return G.w:new_vt("via.OBB", { extent = vec(1.2, 1.0, 2.0) }, { methods = {
                get_Position = function() return vec(f32(M.pos.x), f32(M.pos.y + 1.0), f32(M.pos.z - 1.5)) end,
                get_Extent = function() return vec(1.2, 1.0, 2.0) end,
            } })
        end,
    }, nil, {
        ["<HitStartRemainFrame>k__BackingField"] = function() return f32(slot.e.hs) end,
        ["<HitEndRemainFrame>k__BackingField"] = function() return f32(slot.e.he) end,
        ["<ResultType>k__BackingField"] = function() return slot.e.type end,
        ["<AttackParam>k__BackingField"] = function()
            if slot.e.ap_nil then return nil end
            return slot.e.ap
        end,
        ["<ShellIndex>k__BackingField"] = function()
            return G:nullable("System.Nullable`1<System.Int32>", slot.e.shell, true)
        end,
        ["<RequestSetID>k__BackingField"] = function()
            return G:nullable("System.Nullable`1<System.UInt32>", slot.e.reqset, true)
        end,
    }, { entry = e }, "atk")
    slot.obj = e.obj
    R.all_entry_objs = R.all_entry_objs or {}
    R.all_entry_objs[#R.all_entry_objs + 1] = e.obj
    return e
end

function S:recompute_type(R)
    local E = self.E
    local t = E.SAFE
    for _, e in ipairs(R.entries) do
        if e.type == E.DANGER then
            t = E.DANGER
            break
        elseif e.type == E.CAUTION then
            t = E.CAUTION
        end
    end
    R.type = t
end

function S:send_result_msg(R)
    local w, G = self.w, self
    local M = R.M
    local msg = self:obj("app.game_message.cMsgEmAttackAreaResult", {
        get_AttackAreaResult = function() return R.obj end,
        get_SendGameObject = function() return M.go end,
    }, { _SendGameObject = M.go, ["<AttackAreaResult>k__BackingField"] = R.obj })
    R.t_msg = w.t
    R.delivered = true
    R.n_msg = R.n_msg + 1
    R.msg_times[#R.msg_times + 1] = w.t
    if self.prof.e5c and R.target == "me" then self:oracle_register(R) end
    self.truth.messages = self.truth.messages + 1
    if R.target == "me" and R.type == self.E.DANGER then
        self.truth.danger_msgs = (self.truth.danger_msgs or 0) + 1
        if R.owner_attack and not R.owner_attack.danger_counted then
            R.owner_attack.danger_counted = true
            self.truth.danger_attacks = (self.truth.danger_attacks or 0) + 1
        end
    end
    w:fire(G.H.entity, "app.cMasterPlayerControllerEntity", "receiveGameMessage(ace.cGameMessage)", { msg, n = 1 })
    -- 局部对象：游戏这次调用结束，之后只剩 REF 的引用（脚本 add_ref 过的话）能保活
    if R.is_local then w:end_scope(R.obj) end
end

function S:send_parry_msg(state, M)
    local w, G = self.w, self
    local msg = self:obj("app.game_message.cMsgParrySuccess", {
        get_State = function() return state end,
        get_SendGameObject = function() return M and M.go or nil end,
    }, { ["<State>k__BackingField"] = state })
    w:fire(G.H.entity, "app.cMasterPlayerControllerEntity", "receiveGameMessage(ace.cGameMessage)", { msg, n = 1 })
end

function S:send_noise()
    local msg = self:obj("app.game_message.cMsgMockNoise", {})
    self.truth.noise = self.truth.noise + 1
    self.w:fire(self.H.entity, "app.cMasterPlayerControllerEntity", "receiveGameMessage(ace.cGameMessage)", { msg, n = 1 })
end

local ATK_SIG = "activateAttack(System.Boolean, System.UInt32, System.UInt32, System.Nullable`1<System.Boolean>, "
    .. "app.Hit.HIT_ID_GROUP, System.Nullable`1<System.Single>, System.Nullable`1<System.Single>)"

function S:activate(M, on, reqset)
    if on then self.truth.activations = self.truth.activations + 1 end
    self.w:fire(M.cs, "app.ColliderSwitcher", ATK_SIG, { on, reqset or 0, on and 7 or 0, nil, 0, nil, nil, n = 7 })
end

-- ---------- 攻击（场景脚本） ----------

-- 攻击：{ id, em, at, keep = {c,i}, target = "me"|"otomo", entries = {...}, closest = n,
--        resend = {t...}, events = { {at, op = "downgrade"|"switch"|"finish"|"retype"|"em_target", ...} },
--        contact = { r = 秒（相对触发条目 hs 归零） } | { at = 绝对时刻 } | false,
--        contacts = { ... 多次接触 }, body_same_frame = true, hit_level = 25|26|27, in_reach = true,
--        finish = "never" | 秒（绝对时刻）, shell = true（接触走弹体路径）, interrupt = true（被 EMHIT 打断） }
function S:prepare_attacks()
    for i, spec in ipairs(self.scen.attacks or {}) do
        local A = deep_copy(spec)
        A.id = A.id or ("a" .. i)
        A.M = self.monsters[A.em]
        if not A.M then error("场景攻击 " .. A.id .. " 引用了不存在的怪物 " .. tostring(A.em)) end
        self.truth.attacks[#self.truth.attacks + 1] = { id = A.id, em = A.em, at = A.at, contact = nil, outcome = nil }
        A.truth = self.truth.attacks[#self.truth.attacks]
        sorted_insert(self.events, { t = A.at, fn = function() self:start_attack(A) end })
    end
end

function S:result_for(M, target)
    local R = M.results[target]
    if not R then R = self:new_result(M, target) end
    return R
end

function S:fill_entries(R, A, entries, closest)
    -- 每次攻击新建结果时（默认），被换掉的条目对象游戏当场放手（脚本不该跨帧持有条目，V16 第 5.2 节）；
    -- 攻击参数留到结果放手时一起放（受击信息里还会用到）
    if not R.reuse and not self.scen.reuse_entries then
        for _, e in ipairs(R.entries or {}) do self.w:game_release(e.obj) end
    end
    R.entries = {}
    for i, es in ipairs(entries or {}) do R.entries[i] = self:new_entry(R, es, i) end
    R.closest = (#R.entries > 0) and (closest or 1) or nil
    self:recompute_type(R)
    local lo, hi
    for _, e in ipairs(R.entries) do
        lo = (not lo or e.hs < lo) and e.hs or lo
        hi = (not hi or e.he > hi) and e.he or hi
    end
    R.merged = { lo or 0.0, hi or 0.0 }
end

function S:start_attack(A)
    local w = self.w
    local M = A.M
    local target = A.target or "me"
    local R
    if self.scen.reuse_results or A.reuse_result then
        R = self:result_for(M, target)
    else
        -- 默认每次攻击一个新结果（4 段数据 1620 个结果对象从不复用，实测）
        R = self:new_result(M, target, { reuse = false, is_local = A.local_result })
    end
    A.R = R
    if R.fin then R.fin_changes[#R.fin_changes + 1] = { t = w.t, fin = false } end
    R.fin = false
    R.keep = A.keep or { 0, 1 }
    R.owner_attack = A
    self:fill_entries(R, A, A.entries, A.closest)
    if A.em_target then M.cur_target = A.em_target end
    self:set_em_action(M, A.action or string.format("cAttack%02d", R.keep[2]))
    A.started_t = w.t
    -- 接触时刻：相对「触发条目」hs 归零的时刻（按发消息这一刻的读数推算）
    local trig
    for _, e in ipairs(R.entries) do
        if e.type == self.E.DANGER and (not trig or e.hs < trig.hs) then trig = e end
    end
    trig = trig or R.entries[1]
    -- 场景指定触发条目（同一结果里另有不是这次攻击本身的条目，比如手势的 UNABLE_GUARD 条目）
    if A.trig_entry and R.entries[A.trig_entry] then trig = R.entries[A.trig_entry] end
    A.t_hs0 = trig and (w.t + trig.hs / 60.0) or w.t
    A.he0 = trig and trig.he or 0
    A.trig_dmg = trig and trig.dmg     -- 触发条目的伤害类型：抓取的接触抵消不了（parryable）
    A.trig = trig
    local contacts = A.contacts or (A.contact and { A.contact }) or {}
    A.contact_times = {}
    -- 攻击上的速度读取故障（相对攻击开始的时刻）→ 怪物的绝对时刻
    for _, f in ipairs(A.speed_fault or {}) do
        local g = {}
        for k, v in pairs(f) do g[k] = v end
        g.from = w.t + (f.from or 0.0)
        g.to = f.to and (w.t + f.to) or nil
        M.speed_faults[#M.speed_faults + 1] = g
    end
    -- 设了速度（怪物或攻击的 core）或 nominal = true：按名义进度到达（V16 第 8.3 节），激活时刻在倒数里动态算
    local dynamic = A.nominal == true or A.core ~= nil or M.has_speed
    if dynamic and trig then
        A.dyn = { A0 = trig.hs, P = 0.0, contacts = contacts }
        self.dyn[#self.dyn + 1] = A
        contacts = {}
    end
    for _, c in ipairs(contacts) do
        local tc = c.at or (A.t_hs0 + (c.r or 0.0))
        A.contact_times[#A.contact_times + 1] = tc
        local entry = { t = tc, A = A, c = c }
        sorted_insert(self.contacts_due, entry)
        sorted_insert(self.events, { t = tc - self.P.atk_lead, fn = function()
            if not A.cancelled and not M.gone then self:activate(M, true, trig and trig.reqset) end
        end })
    end
    if #contacts == 0 and A.activate ~= false and trig and not A.dyn then
        -- 「激活但没打中」：判定照常激活，只是没碰到主角
        sorted_insert(self.events, { t = A.t_hs0, fn = function()
            if not A.cancelled and not M.gone then self:activate(M, true, trig.reqset) end
        end })
    end
    A.truth.contact = A.contact_times[1]
    A.truth.t_hs0 = A.t_hs0
    for _, t in ipairs(A.resend or {}) do
        sorted_insert(self.events, { t = t, fn = function() if R.owner_attack == A then self:send_result_msg(R) end end })
    end
    for _, ev in ipairs(A.events or {}) do
        sorted_insert(self.events, { t = ev.at, fn = function() self:attack_event(A, ev) end })
    end
    if type(A.finish) == "number" then
        sorted_insert(self.events, { t = A.finish, fn = function() self:finish_attack(A) end })
    end
    -- CoreState 按招切换：默认在发消息之后（钩子里读到的是旧值，下一帧帧回调才读到新值，SPEED 2.1 l）
    local switch_after = (A.core_switch or self.scen.core_switch or "after_msg") == "after_msg"
    if A.core and not switch_after then M.core_cur = A.core end
    self:send_result_msg(R)
    if A.core and switch_after then M.core_cur = A.core end
end

function S:attack_event(A, ev)
    local R = A.R
    if not R or R.owner_attack ~= A then return end
    local E = self.E
    if ev.op == "downgrade" or ev.op == "retype" then
        local e = R.entries[ev.entry or 1]
        if e then
            e.type = E[ev.to or "CAUTION"] or E.CAUTION
            if ev.hs then e.hs = ev.hs + 0.0 end
            if ev.he then e.he = ev.he + 0.0 end
        end
        self:recompute_type(R)
        if ev.msg then self:send_result_msg(R) end
    elseif ev.op == "switch" then
        R.keep = ev.keep or R.keep
        self:fill_entries(R, A, ev.entries or {}, ev.closest)
        self:set_em_action(A.M, ev.action or string.format("cAttack%02d", R.keep[2]))
        if ev.cancel_contacts then A.cancelled = true end
        self:send_result_msg(R)
    elseif ev.op == "set_entries" then
        -- 条目在不发新消息的情况下出现/改变（结果对象是活的，脚本每帧自己读）：
        -- 例如未结束的结果先是空列表，之后才冒出 DANGER 条目
        self:fill_entries(R, A, ev.entries or {}, ev.closest)
        if ev.trigger and A.dyn then self:retrigger(A) end
        if ev.msg then self:send_result_msg(R) end
    elseif ev.op == "drop_entry" then
        -- 某一条条目消失（其余条目对象不变）：v16_clock_switch 用它让时钟条目中途消失
        local e = table.remove(R.entries, ev.entry or 1)
        if e and not R.reuse and not self.scen.reuse_entries then self.w:game_release(e.obj) end
        self:recompute_type(R)
    elseif ev.op == "hide_entry" then
        -- 条目对象暂时从条目表里消失、之后原样回来（同一个对象，地址不变，游戏照样倒数）：v16_x0_keep 用它核对
        -- 「条目地址第一次出现就记 X0，之后不重置（即使中途消失再出现）」（V16 第 2.3 节）
        local e = table.remove(R.entries, ev.entry or 1)
        if e then
            R.hidden = R.hidden or {}
            R.hidden[#R.hidden + 1] = e
        end
        self:recompute_type(R)
    elseif ev.op == "show_entry" then
        local e = R.hidden and table.remove(R.hidden, 1)
        if e then
            table.insert(R.entries, math.min(ev.pos or (#R.entries + 1), #R.entries + 1), e)
            self:recompute_type(R)
        end
    elseif ev.op == "add_entry" then
        -- 登记之后才冒出来的条目（不发新消息）：v16_late_entry。trigger = true 时攻击改按这条的名义进度到达
        local e = self:new_entry(R, ev.spec, #R.entries + 1)
        R.entries[#R.entries + 1] = e
        self:recompute_type(R)
        if ev.trigger and A.dyn then
            A.trig = e
            self:retrigger(A)
        end
    elseif ev.op == "finish" then
        self:finish_attack(A)
    elseif ev.op == "em_target" then
        A.M.cur_target = ev.value
    elseif ev.op == "resend" then
        self:send_result_msg(R)
    end
end

function S:finish_attack(A)
    local R = A.R
    if not R or R.owner_attack ~= A or R.fin then return end
    R.fin = true
    R.fin_changes[#R.fin_changes + 1] = { t = self.w.t, fin = true }
    R.type = self.E.SAFE
    R.entries = {}
    R.closest = nil
    A.finished_t = self.w.t
    A.truth.finished = self.w.t
    if A.M.action ~= "cDamageParry" then self:set_em_action(A.M, A.M.idle) end
    if not R.reuse then
        -- 游戏在 IsAttackFinished 之后放手（默认 0.5 s；drop_after = 0 = 结束那一帧就放手）
        local da = A.drop_after or self.scen.drop_after or 0.5
        if da <= 0 then
            self:drop_result(R)
        else
            sorted_insert(self.events, { t = self.w.t + da, fn = function() self:drop_result(R) end })
        end
    end
end

-- 游戏的单帧 dt 有上限（SPEED 2.1 d：2a 最长一对 Δt = 0.158 s 只扣了 8.0 帧）：预告倒数和怪物进度都按钳制后的 dt
local DT_CLAMP = 0.1333

-- 按名义进度到达的攻击：怪物按真实 C 推进名义帧，走完触发条目的初值 A 的那一刻激活（V16 第 8.3 节）。
-- 这一帧的推进用的是帧开头（脚本帧回调读到）的 C：本帧 update 里的切换从下一帧起生效
function S:progress()
    local w = self.w
    local dtc = math.min(w.dt, DT_CLAMP)
    local keep = {}
    for _, A in ipairs(self.dyn) do
        local d = A.dyn
        if A.cancelled or (A.R and A.R.owner_attack ~= A) or A.M.gone then
            -- 转招取消 / 结果换主 / 怪物已经消失：不再激活
        else
            local inc = 60.0 * A.M.core_cur * dtc
            if d.P + inc >= d.A0 then
                local frac = inc > 0 and (d.A0 - d.P) / inc or 1.0
                local t_act = (w.t - w.dt) + frac * w.dt
                d.t_act = t_act
                A.truth.t_act = t_act
                if A.activate ~= false then self:activate(A.M, true, A.trig and A.trig.reqset) end
                for _, c in ipairs(d.contacts) do
                    local tc = c.at or (t_act + (c.g or c.r or 0.0))
                    A.contact_times[#A.contact_times + 1] = tc
                    sorted_insert(self.contacts_due, { t = tc, A = A, c = c })
                end
                A.truth.contact = A.contact_times[1]
            else
                d.P = d.P + inc
                keep[#keep + 1] = A
            end
        end
    end
    self.dyn = keep
end

-- 按名义进度到达的攻击换触发条目（条目中途出现 / 换掉）：从这一刻起按新触发条目的 hs 重新走名义进度
function S:retrigger(A)
    local trig = A.trig
    if A.trig == nil or not A.R then return end
    for _, e in ipairs(A.R.entries) do
        if e == trig then
            A.dyn.A0, A.dyn.P = e.hs, 0.0
            return
        end
    end
    -- 触发条目已不在表里：取最小 hs 的 DANGER 条目
    local best
    for _, e in ipairs(A.R.entries) do
        if e.type == self.E.DANGER and (not best or e.hs < best.hs) then best = e end
    end
    if best then
        A.trig = best
        A.dyn.A0, A.dyn.P = best.hs, 0.0
    end
end

-- 怪物的 CoreState 时间表：倒数和进度之后切换（本帧的推进已经用旧值算过）
function S:core_tables()
    local t = self.w.t
    for _, M in pairs(self.monsters) do
        local tab = M.core_table
        while #tab > 0 and tab[1].t <= t + 1e-9 do
            M.core_cur = table.remove(tab, 1).C
        end
    end
end

function S:countdown()
    local step = 60.0 * math.min(self.w.dt, DT_CLAMP)
    for _, R in ipairs(self.results) do
        -- 暂时不在条目表里的条目（hide_entry）游戏照样倒数
        if not R.fin then
            for _, e in ipairs(R.hidden or {}) do
                e.hs = e.hs - step
                e.he = e.he - step
            end
        end
        if not R.fin and #R.entries > 0 then
            local all_done = true
            for _, e in ipairs(R.entries) do
                e.hs = e.hs - step
                e.he = e.he - step
                if e.he > self.P.finish_he then all_done = false end
            end
            local A = R.owner_attack
            if all_done and A and A.finish == nil then self:finish_attack(A) end
        end
    end
end

function S:run_events()
    local w = self.w
    local list = self.events
    while #list > 0 and list[1].t <= w.t + 1e-9 do
        local ev = table.remove(list, 1)
        ev.fn()
    end
end

-- ---------- 训练机关（Em0165_00：cSmallAttack/cToSmallAttack 周期，没有预告数据） ----------

function S:build_machine(spec)
    local key = spec.key or "em165"
    local mspec = {
        emid = 33, sysidx = spec.sysidx or 1, cls = "app.Em0165_00Action", idle = "cWait",
        go_name = "Em0165_00_0_284164096_349", pos = spec.pos,
    }
    self.scen.monsters = self.scen.monsters or {}
    local M = self:build_monster(key, mspec)
    self.mach = { M = M, spec = spec, next_t0 = spec.start or 2.0, cycle = 0, contact_t = nil, to_small_t = nil,
        wait_t = nil }
    -- 机关只发「已结束、SAFE、空列表」的预告（PLAN 安全-5）
    M.res_me.fin = true
end

local MACH_KEEP = { cWait = 0, cSmallAttack = 5, cToSmallAttack = 6, cDamageParry = 11, cDamageParalyse = 12 }

function S:mach_set(action)
    local mc = self.mach
    local M = mc.M
    self:set_em_action(M, action)
    local R = M.res_me
    R.fin = true
    R.type = self.E.SAFE
    R.entries = {}
    R.closest = nil
    R.keep = { 0, MACH_KEEP[action] or 0 }
    self:send_result_msg(R)
end

function S:machine_update()
    local mc = self.mach
    if not mc then return end
    local w = self.w
    local P = self.P
    local spec = mc.spec
    if spec.stop and w.t >= spec.stop then return end
    if w.t >= mc.next_t0 and not mc.contact_t then
        mc.cycle = mc.cycle + 1
        mc.t0 = w.t
        local rec = { cycle = mc.cycle, t0 = w.t, parried = false, paralysed = false }
        self.truth.machine[#self.truth.machine + 1] = rec
        mc.rec = rec
        local para = false
        for _, c in ipairs(spec.paralyse_cycles or {}) do if c == mc.cycle then para = true end end
        if para then
            rec.paralysed = true
            self:mach_set("cSmallAttack")
            sorted_insert(self.events, { t = w.t + 0.5, fn = function() self:mach_set("cDamageParalyse") end })
            mc.wait_t = w.t + 3.0
            mc.next_t0 = w.t + P.period + 2.5 + self.rng.range(-P.period_jitter, P.period_jitter)
        else
            self:mach_set("cSmallAttack")
            mc.to_small_t = w.t + P.to_small
            mc.contact_t = w.t + P.dc + self.rng.range(-P.dc_jitter, P.dc_jitter)
            rec.contact = mc.contact_t
            mc.next_t0 = w.t + P.period + self.rng.range(-P.period_jitter, P.period_jitter)
            local tact = mc.contact_t - 0.14
            sorted_insert(self.events, { t = tact, fn = function() self:activate(mc.M, true, 1) end })
            local A = { id = "mach" .. mc.cycle, M = mc.M, machine = true, truth = rec }
            sorted_insert(self.contacts_due, { t = mc.contact_t, A = A, c = {} })
        end
    end
    if mc.to_small_t and w.t >= mc.to_small_t then
        mc.to_small_t = nil
        self:mach_set("cToSmallAttack")
    end
    if mc.wait_t and w.t >= mc.wait_t then
        mc.wait_t = nil
        self:mach_set("cWait")
    end
end

-- ---------- 命中 ----------

function S:hitinfo(spec)
    local G = self
    local pos = spec.pos or { x = G.hpos.x, y = G.hpos.y + 1.2, z = G.hpos.z + 0.6 }
    return self:obj("app.HitInfo", {
        get_AttackOwner = function() return spec.owner end,
        getActualAttackOwner = function() return spec.actual or spec.owner end,
        get_AttackObj = function() return spec.owner end,
        get_DamageObj = function() return spec.dmgobj end,
        get_DamageOwner = function() return spec.dmgowner end,
        getActualDamageOwner = function() return spec.dmgowner end,
        get_CollisionLayer = function() return spec.layer end,
        get_AttackData = function() return spec.ap end,
        get_DamageAttackData = function() return spec.ap end,
        get_DamageData = function() return nil end,
        get_Position = function() return vec(f32(pos.x), f32(pos.y), f32(pos.z)) end,
        get_Normal = function() return vec(0.0, 1.0, 0.0) end,
        get_HitID = function() return spec.hit_id or 0 end,
    })
end

function S:hunter_fire(sig, info, original, tag)
    -- 真值：探针 CT/DMG 应该逐次记录的受击调用
    if tag then
        local list = self.truth[tag.list]
        if not list then
            list = {}
            self.truth[tag.list] = list
        end
        list[#list + 1] = { t = self.w.t, cls = tag.cls, shell = tag.shell or false }
    end
    return self.w:fire(self.H.obj, "app.HunterCharacter", sig, { info, n = 1 }, original)
end

function S:ap_of(A)
    if A.machine then return A.M.default_ap end
    local R = A.R
    if R and R.dropped then return A.M.default_ap end   -- 游戏已经放手的结果：受击信息里不再带它的攻击参数
    local e = R and R.entries and R.entries[1]
    if A.ap_obj then return A.ap_obj end
    A.ap_obj = e and e.ap or A.M.default_ap
    return A.ap_obj
end

function S:parryable(A)
    if A.machine then return true end
    if A.shell or A.unparryable then return false end
    local dmg = self.E.DMG[A.dmg or "NORMAL"]
    -- 抓取（攻击自己标的或触发条目的伤害类型）：刀碰到了也不触发抵消，打在身上（第 2 轮 em27 实测，V15 第 9 节）
    if self.E.GRAB[dmg] or (A.trig_dmg and self.E.GRAB[A.trig_dmg]) then return false end
    -- 防御类型：SKILL_GUARD 家族怪物侧闸门拒绝（G1 实测，只见于抓取）；UNABLE_GUARD 按不抵消、身体挨打（推测，
    -- 从没测过；只有脚本错放时才会走到，V16 第 12 节第 9 条）
    local g = A.trig and A.trig.guard
    local GT = self.E.GUARD
    if g == GT.SKILL_GUARD or g == GT.SKILL_GUARD_ALL_RANGE or g == GT.UNABLE_GUARD then return false end
    return not self.E.EXCL[dmg]
end

function S:emhit()
    local a = self.act
    if not is_slash(a) or a.emhit_t then return end
    local e = self.w.t - a.t_start
    if e < self.P.emhit_at then return end
    -- 找一个够得着的怪：有待结算接触且 in_reach 不为 false 的攻击，或者机关
    local target_M, target_A
    for _, c in ipairs(self.contacts_due) do
        if not c.A.machine and c.A.in_reach ~= false and not c.A.cancelled then
            target_M, target_A = c.A.M, c.A
            break
        end
        if c.A.machine and (self.mach.spec.in_reach ~= false) then
            target_M, target_A = c.A.M, c.A
            break
        end
    end
    if not target_M then
        -- 按名义进度到达、还没激活的攻击（接触还没排进 contacts_due）
        for _, A in ipairs(self.dyn) do
            if A.in_reach ~= false and not A.cancelled and #A.dyn.contacts > 0 then
                target_M, target_A = A.M, A
                break
            end
        end
    end
    if not target_M and self.mach and self.mach.spec.in_reach ~= false and self.scen.emhit_machine_idle ~= false then
        target_M = self.mach.M
    end
    if not target_M then return end
    a.emhit_t = self.w.t
    local H = self.H
    local info = self:hitinfo({ owner = H.go, dmgobj = target_M.scar_go, dmgowner = target_M.go, layer = self.E.ATTACK_GET,
        ap = H.ap_pl, pos = target_M.pos })
    self.w:fire(target_M.enemy, "app.EnemyCharacter", "evHit_DamagePreProcess(app.HitInfo)", { info, n = 1 },
        function() return self.E.R_SUCCESS end)
    self.truth.emhits[#self.truth.emhits + 1] = { t = self.w.t, em = target_M.key, attempt = self.attempt and self.attempt.id }
    if self.attempt then self.attempt.emhit = true end
    if target_A and target_A.interrupt then
        -- 上捞斩先砍中把怪物打断：这一招不再落下（PLAN 的 INTERRUPTED），结果同一帧结束；怪物进受击动作
        -- 1 s 后回到待机。先结束再设受击动作：finish_attack 会把怪物动作改回待机
        target_A.cancelled = true
        self:finish_attack(target_A)
        self:set_em_action(target_M, "cDamageFlinch")
        sorted_insert(self.events, { t = self.w.t + self.P.flinch, fn = function()
            if target_M.action == "cDamageFlinch" then self:set_em_action(target_M, target_M.idle) end
        end })
        target_A.truth.interrupted = self.w.t
    end
end

function S:contacts()
    local w = self.w
    local list = self.contacts_due
    while #list > 0 and list[1].t <= w.t + 1e-9 do
        local c = table.remove(list, 1)
        if not c.A.cancelled and not c.A.M.gone then self:resolve_contact(c.A, c.c) end
    end
end

function S:resolve_contact(A, c)
    local w = self.w
    local a = self.act
    local e = w.t - a.t_start
    local P = self.P
    local rec = { t = w.t, frame = w.frame, attack = A.id, em = A.M.key, act = string.format("(%d,%d)", a.cat, a.idx),
        elapsed = e, attempt = self.attempt and self.attempt.id or nil }
    if not self.char_present then
        rec.kind = "absent"
    elseif is_slash(a) and self:parryable(A) and not self.parried_now and e >= P.W0 and e <= P.W1 and not c.body_only then
        self:blade_contact(A, c)
        rec.kind = "blade"
    elseif is_phit(a) then
        self:body_contact(A, c, true)
        rec.kind = "ignored"
    else
        self:body_contact(A, c, false)
        rec.kind = "body"
    end
    self.truth.contacts[#self.truth.contacts + 1] = rec
    if A.truth then
        A.truth.contacts = A.truth.contacts or {}
        A.truth.contacts[#A.truth.contacts + 1] = rec.kind
        if rec.kind == "blade" then A.truth.parried = true end
        if A.machine then A.truth.contact_kind = rec.kind end
    end
    if self.attempt then
        local at = self.attempt
        at.contacts[#at.contacts + 1] = { t = w.t, kind = rec.kind, attack = A.id, elapsed = e }
        if rec.kind == "blade" then at.blade = at.blade + 1 elseif rec.kind == "body" then at.body = at.body + 1 end
    end
end

function S:body_contact(A, c, no_damage)
    local H = self.H
    local E = self.E
    local M = A.M
    local owner = A.shell and M.shell_go or M.go
    local info = self:hitinfo({ owner = owner, actual = M.go, dmgobj = H.go, dmgowner = H.go, layer = E.ATTACK_GET,
        ap = self:ap_of(A) })
    if A.shell then
        self:hunter_fire("evHit_ShellDamagePreProcess(app.HitInfo)", info, function() return E.R_SUCCESS end)
    end
    local res = no_damage and E.R_FAILURE or E.R_SUCCESS
    self:hunter_fire("evHit_DamagePreProcess(app.HitInfo)", info, function() return res end,
        { list = "ct", cls = "BODY", shell = A.shell })
    if no_damage then return end
    -- 受击前置钩子里脚本强开了防御标志（AutoGuardGS 的自动防御）：游戏按防御结算，不扣血、不硬直，进防御反应动作
    local guarded = self:guard_forced()
    local dmg = c.damage or A.damage or self.P.damage
    self.truth.body_hits = self.truth.body_hits or {}
    self.truth.body_hits[#self.truth.body_hits + 1] = { t = self.w.t, frame = self.w.frame, attack = A.id, guarded = guarded,
        act = string.format("(%d,%d)", self.act.cat, self.act.idx), skip_post = c.skip_damage_hook == true }
    -- 场景让这一下的 evHit_Damage 根本没被调用（后置钩子缺席：防御标志、角度要靠下一帧开头的兜底还原，MERGE 第 6.5 节 guard_angle）
    if c.skip_damage_hook then return end
    H.dmginfo:set_field("_TotalDamage", f32(guarded and 0.0 or dmg))
    self:hunter_fire("evHit_Damage(app.HitInfo)", info, function()
        if not guarded then self:request_damage(dmg) end
        return E.R_SUCCESS
    end, { list = "dmg", cls = "DMG" })
    if guarded then
        if self.act.cat == 1 and self.act.idx == 14 then
            self:schedule(1, guarded == "TECHNICAL_GUARD" and 146 or 144, "guard", true)
        end
    elseif not self:status_flag(E.SUPER_ARMOR) and not self:status_flag(E.HYPER_ARMOR) then
        self:schedule(0, 30, "flinch", true)
    end
end

function S:blade_contact(A, c)
    local w = self.w
    local H = self.H
    local E = self.E
    local M = A.M
    local ap = self:ap_of(A)
    -- 结局（G1：怪物端 evHit_AttackParry 决定）：触发条目 pb=1 或场景强制 hit_level = 25 → RECOIL
    local level = A.hit_level or ((A.trig and A.trig.pb) and 25) or 27
    local recoil = level == 25 or A.recoil == true
    local blade = { owner = M.go, dmgobj = H.weapon_go, dmgowner = H.go, layer = E.ATTACK_PARRY_GET, ap = ap }
    local info1 = self:hitinfo(blade)
    self:hunter_fire("evHit_DamagePreProcess(app.HitInfo)", info1, function() return E.R_SUCCESS end,
        { list = "ct", cls = "BLADE" })
    w:fire(M.enemy, "app.EnemyCharacter", "evHit_AttackParry(app.HitInfo, app.cAttackParamEm)", { info1, ap, n = 2 })
    self.truth.ph = self.truth.ph or {}
    self.truth.ph[#self.truth.ph + 1] = { t = w.t }
    local ph_state = recoil and E.PS_RECOIL or E.PS_WAIT
    w:fire(H.handling, "app.cHunterWeaponHandlingBase", "onParryHit(app.HunterDef.PARRY_STATE, via.GameObject, via.vec3)",
        { ph_state, M.go, vec(f32(self.hpos.x), f32(self.hpos.y + 1.2), f32(self.hpos.z + 0.8)), n = 3 },
        function()
            self.parry_state = ph_state
            self.parry_target = M.go
        end)
    if A.second_blade ~= false then
        local info2 = self:hitinfo(blade)
        self:hunter_fire("evHit_DamagePreProcess(app.HitInfo)", info2, function() return E.R_PASS end,
            { list = "ct", cls = "BLADE" })
    end
    if A.body_same_frame then
        -- 手动抵消实测（16:12:47.045）：同一帧里还有一次身体 ATTACK_GET 接触
        self:body_contact(A, { damage = A.body_damage or 12.5 }, false)
        self.truth.contacts[#self.truth.contacts + 1] = { t = w.t, frame = w.frame, attack = A.id, em = M.key,
            act = "(2,23)", kind = "body_same_frame", attempt = self.attempt and self.attempt.id }
        if self.attempt then self.attempt.body = self.attempt.body + 1 end
    end
    local state = E.PS_SUCCESS
    if level == 26 then state = E.PS_HIT end     -- G1：WAIT→HIT 进 (2,26) HitM；WAIT→SUCCESS 进 (2,27) HitL
    if not recoil then
        w:fire(M.hit, "app.cEmModuleHit", "onParryDamage(app.TARGET_ACCESS_KEY, System.Boolean, via.GameObject)",
            { self:key_vt(E.CAT_PLAYER, 0), true, M.go, n = 3 },
            function()
                -- 怪物的 onParryDamage 会回调猎人的 onParrySuccess（AGPCall 第 6 轮实测）
                self.truth.ps = self.truth.ps or {}
                self.truth.ps[#self.truth.ps + 1] = { t = w.t }
                w:fire(H.handling, "app.cHunterWeaponHandlingBase", "onParrySuccess(app.HunterDef.PARRY_STATE)",
                    { state, n = 1 }, function() self.parry_state = state end)
            end)
    end
    self.parried_now = true
    self:schedule(2, level, "parry", true)
    if recoil then
        -- RECOIL（G1 实测）：怪物不进 cDamageParry，主角下一帧进 (2,25) HitS，同一帧身体挨打（伤害 70~103）
        self:body_contact(A, { damage = A.recoil_damage or 80.0 }, false)
        self.truth.contacts[#self.truth.contacts + 1] = { t = w.t, frame = w.frame, attack = A.id, em = M.key,
            act = "(2,23)", kind = "recoil_body", attempt = self.attempt and self.attempt.id }
        if self.attempt then self.attempt.body = self.attempt.body + 1 end
        if A.R then sorted_insert(self.events, { t = w.t + 0.05, fn = function() self:finish_attack(A) end }) end
        return
    end
    local G = self
    self.pending_mon[#self.pending_mon + 1] = function()
        if A.machine then G:mach_set("cDamageParry") else G:set_em_action(M, "cDamageParry") end
        M.stocked = true
        G.pending_mon[#G.pending_mon + 1] = function() M.stocked = false end
    end
    if level == 27 then
        -- 实测：进 cParrySlashHitL 时收到 cMsgParrySuccess(SUCCESS)，HitM 时没有
        self.pending_msgs[#self.pending_msgs + 1] = function() G:send_parry_msg(state, M) end
    end
    if A.machine then
        self.mach.contact_parried = true
    elseif A.R then
        sorted_insert(self.events, { t = w.t + 0.05, fn = function() self:finish_attack(A) end })
    end
end

-- ---------- 每帧 ----------

function S:pre_frame()
    self:apply_hunter_events()
    if self.next and self.next.frame <= self.w.frame then
        local n = self.next
        self.next = nil
        self:apply_transition(n)
    end
    local pm = self.pending_mon
    if #pm > 0 then
        self.pending_mon = {}
        for _, fn in ipairs(pm) do fn() end
    end
    self.oracle[self.w.frame] = self.prof.e5c and self:compute_oracle16() or self:compute_oracle()
end

function S:update()
    self:settle_damage()
    self:player_input()
    self:hunter_timeline()
    self:countdown()
    self:progress()
    self:core_tables()
    self:run_events()
    self:monster_lifecycle()
    self:machine_update()
    local pmsg = self.pending_msgs
    if #pmsg > 0 then
        self.pending_msgs = {}
        for _, fn in ipairs(pmsg) do fn() end
    end
    if self.scen.noise ~= false then self:send_noise() end
    for _, M in ipairs(self.mon_order) do self:activate(M, false) end
end

function S:hit()
    self:emhit()
    self:contacts()
    local mc = self.mach
    if mc and mc.contact_t and self.w.t >= mc.contact_t then
        mc.contact_t = nil
        if mc.contact_parried then
            mc.contact_parried = false
            if mc.rec then mc.rec.parried = true end
            mc.wait_t = self.w.t + 3.2
            mc.next_t0 = mc.t0 + self.P.parried_period + self.rng.range(-self.P.period_jitter, self.P.period_jitter)
        else
            mc.wait_t = self.w.t + 0.35
        end
    end
end

-- ---------- 判定神谕：按 PLAN「DECISION RULE · A」算这一帧 rc 应不应该放刀 ----------
-- 只用模拟器知道的真值（条目、弹体、伤害类型、怪物是不是联机副本）和场景声明的读取故障，不看 rc 的内部状态。
-- L_min 按版本（G.L_MIN）；W_long、H_veto 两个版本相同。

local W_LONG, H_VETO = 60, 90
S.L_MIN, S.W_LONG, S.H_VETO = PROFILES.v15.L_MIN, W_LONG, H_VETO

-- 提前量：四舍五入后夹到版本的滑块范围（和两个版本的 clamp_lead 一致）
function S:clamp_lead(v)
    return math.max(self.prof.lead_lo, math.min(self.prof.lead_hi, math.floor(v + 0.5)))
end

-- 菜单改了 rc 的启用开关 / 提前量（run.lua 在每帧 UI 阶段之后调用）：和被测脚本一样先夹范围，值没变就不算改动。
-- 改动在 UI 阶段生效，所以影响的是下一帧开头的求值；返回 true = 真的改了（v15 应该写一行 CFG）
function S:apply_ui_cfg(key, value)
    local cfg = self.rc_cfg
    local v = value
    if key == "parry_lead" then
        if not finite(v) then return false end
        v = self:clamp_lead(v)
    elseif key == "auto_parry" then
        v = v == true
    elseif key == "debug_log" then
        -- 调试日志开关不是参数改动（V15 第 4 节：CFG 只记启用开关和提前量）：只跟进存配置的预期，不算 CFG
        cfg.debug_log = v == true
        return false
    else
        return false
    end
    if cfg[key] == v then return false end
    cfg[key] = v
    self.cfg_changes[#self.cfg_changes + 1] = { t = self.w.t, auto_parry = cfg.auto_parry, parry_lead = cfg.parry_lead }
    return true
end

-- 模拟时刻 t（帧开头）rc 在用的提前量：加载时的配置，之后按菜单改动逐条更新（改动那一帧的 UI 阶段晚于帧开头）
function S:lead_at(t)
    local L = self.cfg0.parry_lead
    for _, c in ipairs(self.cfg_changes) do
        if c.t < t - 1e-9 then L = c.parry_lead else break end
    end
    return L
end

-- 场景声明 rc 读不到这个结果的条目（oracle_fb = 全部结果，rc1 的 FB 场景沿用；oracle_items_fail = true 或 { 怪物键 = true }）
-- 怪物键对应的值也可以是时间段 { from, to }：只有这段时间里读不出（限次的故障神谕预测不了，场景把那一帧写出来）
function S:items_fail(R)
    local f = self.scen.oracle_items_fail
    if self.oracle_fb or f == true then return true end
    local x = type(f) == "table" and f[R.M.key]
    if type(x) == "table" then return self.w.t >= x[1] and self.w.t < x[2] end
    return x == true
end

-- 联机副本：发送者怪物 get_IsMaster() 为 false。场景声明 rc 读不到（oracle_master_failopen）时按主机处理（fail-open）
function S:is_replica(R)
    return R.M.spec.master == false and not self.scen.oracle_master_failopen
end

-- 被测脚本认得出的抓取类型（数值集合）：场景用故障 missing "field:app.HitDef.DAMAGE_TYPE.<名字>" 把某个名字从枚举里
-- 拿掉时，rc 读不到这个名字、跳过它（V15 第 9 节「读不到的名字跳过」），这种条目对 rc 来说就是普通攻击
function S:grab_known()
    if self._grab_known then return self._grab_known end
    local set = {}
    for name, v in pairs(self.E.GRAB_NAMES) do
        if not self.w.missing["field:app.HitDef.DAMAGE_TYPE." .. name] then set[v] = true end
    end
    self._grab_known = set
    return set
end

-- 被测脚本认得出的效果攻击类型（EAR/WIND/QUAKE 的数值集合），同 grab_known 用故障 missing 拿掉名字。
-- v15 逐个名字读：缺 QUAKE 只是不认 QUAKE（那种条目对 rc 就是普通攻击，fail-open），EAR/WIND 照样过滤，抓取否决照常；
-- rc1 整组一个 pcall：缺一个名字整组都不认（rc1 没有这种故障场景，口径写全）
function S:effect_known()
    if self._effect_known then return self._effect_known end
    local set, any_missing = {}, false
    for _, name in ipairs({ "EAR", "WIND", "QUAKE" }) do
        if self.w.missing["field:app.HitDef.DAMAGE_TYPE." .. name] then
            any_missing = true
        else
            set[self.E.DMG[name]] = true
        end
    end
    if any_missing and self.prof.effect_enum == "group" then set = {} end
    self._effect_known = set
    return set
end

-- 场景声明 rc 读不到伤害类型（oracle_dmgtype_failopen = true 或 { 怪物键 = true }）：fail-open，不是抓取、也不是效果攻击
function S:dmgtype_unknown(R)
    local f = self.scen.oracle_dmgtype_failopen
    return f == true or (type(f) == "table" and f[R.M.key] == true)
end

-- 预告跟踪的释放（PLAN 参数表「预告跟踪与释放」、CONTRACT 3.3）：距 t_msg ≥8 s，或非空条目全部 he<−30 且距 t_msg ≥1 s。
-- 有状态：释放过的结果（released_msg = 释放时的 t_msg）在收到新消息之前不再跟踪 —— rc 也是这样，放掉以后
-- 不重发消息就再也看不到它（之后不发消息冒出来的 DANGER 条目不放刀）。每帧都要判（compute_oracle 开头），
-- 和 rc 一样不管主角在不在蓄力
function S:tracked(R)
    local now = self.w.t
    if not R.delivered or not R.t_msg or R.t_msg < self.last_swap_t then return false end
    if R.released_msg == R.t_msg then return false end
    if now - R.t_msg >= 8.0 then
        R.released_msg = R.t_msg
        return false
    end
    if #R.entries > 0 and now - R.t_msg >= 1.0 then
        local all_old = true
        for _, e in ipairs(R.entries) do
            if f32(e.he) >= -30 then all_old = false break end
        end
        if all_old then
            R.released_msg = R.t_msg
            return false
        end
    end
    return true
end

function S:compute_oracle()
    local w = self.w
    local a = self.act
    -- L / auto：这一帧开头 rc 在用的提前量和启用开关（菜单改动从下一帧起生效，见 apply_ui_cfg）；
    -- cat / idx：这一帧开头主角的动作（run.lua 核对 JSON 只在空闲帧写出）
    local rec = { frame = w.frame, t = w.t, L = self.rc_cfg.parry_lead, auto = self.rc_cfg.auto_parry,
        cat = a.cat, idx = a.idx }
    for _, R in ipairs(self.results) do
        if R.target == "me" and not R.fin then self:tracked(R) end
    end
    rec.charging = self.char_present and self.player_present and is_charge(a) and self:weapon_type_now() == 0
    if not rec.charging or not self.rc_cfg.auto_parry then return rec end
    local E = self.E
    local prof = self.prof
    local L_MIN = self.L_MIN
    local veto, q, best, best_R
    local v_hs, v_why     -- 触发否决的条目里 hs 最小的那条和原因（VETO 的 hs、why；同一个 hs 两种原因都有时记 long）
    local function vote(hs, why)
        veto = true
        if not v_hs or hs < v_hs or (hs == v_hs and why == "long" and v_why ~= "long") then v_hs, v_why = hs, why end
    end
    local fb = false
    for _, R in ipairs(self.results) do
        if R.target == "me" and not R.fin and self:tracked(R) then
            local list = R.entries
            if self:items_fail(R) then
                list = {}
                if prof.items_fail == "fb" then
                    -- rc1：逐条读取出错、整体是 DANGER 时退回 closest（src=FB）
                    local ce = R.closest and R.entries[R.closest]
                    if R.type == E.DANGER and ce then
                        list = { ce }
                        fb = true
                    end
                end
                -- v15：closest 兜底已删，这个结果本帧不参与（既不放刀也不否决）
            end
            -- v15：联机副本的条目照样参与否决（偏保守），只是不进候选
            local replica = prof.master_gate and self:is_replica(R)
            -- v15（1.5.1）：伤害类型读不到按「不是抓取、不是效果攻击」（fail-open）；rc1 没有这条读取的故障场景
            local dmg_known = not (prof.grab_veto and self:dmgtype_unknown(R))
            for _, e in ipairs(list) do
                if e.type == E.DANGER then
                    local hs, he = f32(e.hs), f32(e.he)
                    local span = he - hs
                    local grab = prof.grab_veto and dmg_known and self:grab_known()[e.dmg] == true
                    local effect = dmg_known and self:effect_known()[e.dmg] == true
                    if hs <= H_VETO and he >= 0 then
                        if span > W_LONG then vote(hs, "long") end
                        if grab then vote(hs, "grab") end
                    end
                    if not replica and not grab and hs >= L_MIN and span >= 0 and span <= W_LONG and e.shell == nil
                        and not effect then
                        if not q or hs < q then q, best, best_R = hs, e, R end
                    end
                end
            end
        end
    end
    rec.veto = veto or false
    rec.veto_hs, rec.veto_why = v_hs, v_why
    rec.q = q
    rec.fb = fb
    if best then
        rec.entry = string.format("%X", best.obj:get_address())
        rec.result = string.format("%X", best_R.obj:get_address())
        rec.he = f32(best.he)
    end
    return rec
end

-- ---------- v1.6 神谕（docs/autoparry/V16.md 第 2、3 节）：E5c、该接过滤、否决，独立于被测脚本再实现一遍 ----------
-- 只用模拟器知道的真值（条目、怪物的 CoreState、条目属性）和场景注入的故障（peek_fault，不消耗次数），按脚本
-- 读到的口径（System.Single 取整、帧回调时刻、消息钩子时刻）逐帧推一遍被测脚本「应该」有的状态：
--   · 每个被跟踪的结果一份 E5c 镜像 R.ot（登记 = 消息钩子；释放 = 8 s、IsAttackFinished、全部 he<−30 且距消息 ≥1 s、
--     主角消失 / 换人、关开关）；登记后每个帧回调都推一步（不论在不在蓄力，V16 第 2.2 节「每帧都读」）。
--   · 在蓄力中时求值：否决（原始 hs）、Q、候选（按 Q 取最小）、SKIP（每个结果的每条条目一次）、vetoq、U（UVIEW）。
--   · rec.fire = 这一帧若是放刀 streak 的第一帧，FIRE 该写的 C1 / Cf / mf / nchg / dX / A0 / Q0 / Qp / Qe1 / vq。
--   · ostat = 跨帧累计的 STAT 预期（speedfail / speedhold / clockskip / fclosed / excl / failopen（否决侧）/ sidmis）。
-- 读取顺序有歧义的地方（同一条目同时有好几种不该接的属性），场景只给一种属性，不靠这里的先后。

local C_LO, C_HI, CLOCK_DMAX = 0.5, 2.0, 30
local VETO_RANK = { long = 3, grab = 2, sg = 1 }

local function hexaddr(o) return string.format("%X", o:get_address()) end
S.hexaddr = hexaddr

-- 消息钩子里登记（脚本 on_message 的镜像）：已在跟踪的只刷新 t_msg；否则开关开、主角在且拿大剑、结果没结束才登记
function S:oracle_register(R)
    local w = self.w
    local t_msg = w.t + (w.phase_offset[w.phase] or 0.0)
    local o = R.ot
    if o and o.live then
        o.t_msg = t_msg
        return
    end
    if not (self.oc.me_ok and self.rc_cfg.auto_parry) or R.fin then return end
    -- EmSystemIndex：钩子里读一次存数值（V16 第 2.2 节）；场景可以用故障让它读成别的值
    local idx = R.M.sysidx
    local f = w:peek_fault(rawget(R.obj, "__t"), "get_EmSystemIndex", R.obj, self.rc_name)
    if f then
        if f.mode == "value" then idx = f.value else idx = nil end
    end
    -- get_EmID 抛错：脚本的 on_message 在登记之前就失败（ERR msg 红），这条预告不登记、不放刀（MERGE 第 2.7 节：get_EmID
    -- 必须在登记时照读；审查补充）。神谕用 peek_fault，所以场景要用时间段、不要用 max
    local fe = w:peek_fault(rawget(R.obj, "__t"), "get_EmID", R.obj, self.rc_name)
    if fe and fe.mode == "throw" then return end
    R.ot = { live = true, t_msg = t_msg, idx = idx, snd = R.M.enemy:get_address(),
        master = not (R.M.spec.master == false and not self.scen.oracle_master_failopen),
        first = true, m = nil, X = 0.0, x0 = {}, a0 = {}, hs_prev = nil, clock = nil, nchg = 0, c1 = nil, cf = nil,
        nofire = false, qlast = {}, fo = {}, skipped = {}, t_reg = w.t, frame_reg = w.frame }
end

-- 放刀模块此刻读到的 C（findEnemy_SystemIndex → get_Character → get_MotionSpeed_CoreState，同一帧按 idx 缓存）
-- 返回 C（合法：有限、0.5~2.0）或 nil，以及找到的怪物地址（sidmis 用）
function S:core16(o, cache)
    local idx = o.idx
    if idx == nil then return nil, nil end
    local c = cache[idx]
    if c then return c.C, c.addr end
    local C, addr = nil, nil
    local M = self.by_sysidx[idx]
    local RC = self.rc_name
    if M and not self:speed_fault(M, "find", RC) and not self:speed_fault(M, "char", RC) then
        addr = M.enemy:get_address()
        local v
        local f = self:speed_fault(M, "core", RC)
        if f then
            if f.mode == "nan" then v = 0.0 / 0.0 elseif f.mode == "value" then v = f32(f.value) end
        else
            v = f32(M.core_cur)
        end
        if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v >= C_LO and v <= C_HI then
            C = v
        end
    end
    cache[idx] = { C = C, addr = addr }
    return C, addr
end

-- 时钟条目：优先上一帧用过的那条；不在了按条目表顺序找第一条两帧都有的，并改记
function S:clock16(o, list, cur)
    local prev = o.hs_prev
    if o.clock and cur[o.clock] ~= nil and prev[o.clock] ~= nil then return prev[o.clock] - cur[o.clock] end
    for _, e in ipairs(list) do
        local k = e.obj:get_address()
        if prev[k] ~= nil then
            o.clock = k
            return prev[k] - cur[k]
        end
    end
    return nil
end

-- speed_step（V16 第 2.3 节伪代码的逐行镜像）。now = 脚本这一帧 os.clock 的模拟时刻：时钟一对读数之间 hs 递减的上限是
-- CLOCK_DMAX + 60 × 两次读数隔开的秒数（读条目出错、读主角抛错的容忍期让这一对跨好几帧时放宽，V16 第 2.1 节审查修订）
function S:speed_step16(o, list, cache, now)
    local C, faddr = self:core16(o, cache)
    local cur
    if list then
        cur = {}
        for _, e in ipairs(list) do cur[e.obj:get_address()] = f32(e.hs) end
    end
    if cur and o.hs_prev and o.m then
        local d = self:clock16(o, list, cur)
        if d == nil or d < 0 or d > CLOCK_DMAX + 60.0 * (now - o.t_prev) then
            self.ostat.clockskip = self.ostat.clockskip + 1
        else
            o.X = o.X + d * (o.m - 1.0)
        end
    end
    if o.first then
        o.first = false
        if C then
            o.m, o.c1 = math.max(1.0, C), C
            self.oc.fail_streak = 0
        else
            o.nofire = true
            self.ostat.speedfail = self.ostat.speedfail + 1
            self.oc.fail_streak = self.oc.fail_streak + 1
            if self.oc.fail_streak == 5 then self.oc.n_x5 = self.oc.n_x5 + 1 end
        end
        if faddr and o.snd and faddr ~= o.snd then self.ostat.sidmis = self.ostat.sidmis + 1 end
    elseif o.m then
        if C then
            local m = math.max(1.0, C)
            if math.abs(m - o.m) > 1e-4 then o.nchg = o.nchg + 1 end
            o.m = m
        else
            self.ostat.speedhold = self.ostat.speedhold + 1
        end
    end
    o.cf = C
    if cur then
        for _, e in ipairs(list) do
            local k = e.obj:get_address()
            if o.x0[k] == nil then o.x0[k], o.a0[k] = o.X, f32(e.hs) end
        end
        o.hs_prev, o.t_prev = cur, now
    end
end

-- 被测脚本读得到的防御类型名字（场景用故障 missing "field:app.Hit.GUARD_TYPE.<名字>" 拿掉）
function S:guard_known()
    if self._guard_known then return self._guard_known end
    local E = self.E
    local k = { white = {}, ug = {}, sg = {}, missing = {} }
    local function have(n) return not self.w.missing["field:app.Hit.GUARD_TYPE." .. n] end
    for _, n in ipairs({ "NORMAL", "ALL_RANGE" }) do if have(n) then k.white[E.GUARD[n]] = true else k.missing[n] = true end end
    if have("UNABLE_GUARD") then k.ug[E.GUARD.UNABLE_GUARD] = true else k.missing.UNABLE_GUARD = true end
    for _, n in ipairs({ "SKILL_GUARD", "SKILL_GUARD_ALL_RANGE" }) do
        if have(n) then k.sg[E.GUARD[n]] = true else k.missing[n] = true end
    end
    self._guard_known = k
    return k
end

function S:effect_missing()
    for _, n in ipairs({ "EAR", "WIND", "QUAKE" }) do
        if self.w.missing["field:app.HitDef.DAMAGE_TYPE." .. n] then return true end
    end
    return false
end

-- 放刀模块此刻读一条条目的属性会读到什么（"err" = 抛错或类型不对）：
--   shell = true / false / "err"；ap = "nil" / "err" / true；dmg / pb / guard = 值或 "err"
function S:read16(e)
    local w = self.w
    local rd = {}
    local function fv(obj, name, normal)
        local f = w:peek_fault(rawget(obj, "__t"), name, obj, self.rc_name)
        if not f then return normal end
        if f.mode == "throw" then return "err" end
        if f.mode == "nil" then return nil end
        if f.mode == "value" then
            if type(f.value) == "function" then return f.value(w) end
            return f.value
        end
        return normal
    end
    local sv = fv(e.obj, "get_ShellIndex", e.shell)
    if sv == "err" then rd.shell = "err"
    elseif sv == nil then rd.shell = false
    elseif type(sv) == "number" then rd.shell = true
    else rd.shell = "err" end
    local apv = fv(e.obj, "get_AttackParam", (not e.ap_nil) and e.ap or nil)
    if apv == "err" then rd.ap = "err" elseif apv == nil then rd.ap = "nil" else rd.ap = true end
    if rd.ap == true then
        local d = fv(e.ap, "_DamageType", e.dmg)
        rd.dmg = "err"
        if math.type(d) == "integer" then rd.dmg = d end
        local pb = fv(e.ap, "_IsParryBreak", e.pb)
        rd.pb = "err"
        if type(pb) == "boolean" then rd.pb = pb end
        local g = fv(e.ap, "_GuardType", e.guard)
        rd.guard = "err"
        if math.type(g) == "integer" then rd.guard = g end
    else
        rd.dmg, rd.pb, rd.guard = "err", "err", "err"
    end
    return rd
end

-- 候选侧（V16 第 3 节）：true = 该接；"shell" / "effect" / "grab" / "sg" = 旧规则或否决家族，静默排除；
-- "pb" / "ug" / "fc" = 写 SKIP。读不准（fc）：攻击参数为空、字段抛错或类型不对、效果名缺、防御类型是未知值、ShellIndex 读不准。
-- 一条条目有几种属性时「确定的原因优先」（V16 第 3.2 节的集成澄清）：读到的值能确定的旧排除 / 否决家族（弹体、抓取、效果、
-- SKILL_GUARD 家族）> pb=1 > UNABLE_GUARD > 读不准（fc 只记「只因读不准才没放」的条目）
function S:catch16(rd)
    local gk = self:guard_known()
    local dmg_ok = rd.ap == true and rd.dmg ~= "err"
    local guard_ok = rd.ap == true and rd.guard ~= "err"
    if rd.shell == true then return "shell" end
    if dmg_ok and self:grab_known()[rd.dmg] then return "grab" end
    if dmg_ok and self:effect_known()[rd.dmg] then return "effect" end
    if guard_ok and gk.sg[rd.guard] then return "sg" end
    if rd.ap == true and rd.pb == true then return "pb" end
    if guard_ok and gk.ug[rd.guard] then return "ug" end
    if rd.shell == "err" or not dmg_ok or self:effect_missing() or rd.pb == "err" or not guard_ok then return "fc" end
    if gk.white[rd.guard] then return true end
    return "fc"
end

-- 否决侧（V16 第 3.2、3.4 节）：读不到伤害 / 防御类型 → 读不到的那一项不触发否决、failopen（每条一次）；抓取三名 → grab；
-- SKILL_GUARD 家族且伤害类型不是抓取 → sg（伤害类型读不到按不是抓取：防御类型读得到、是 SKILL_GUARD 家族照样否决）
function S:veto_kind16(rd)
    local unread = rd.ap ~= true or rd.dmg == "err" or rd.guard == "err"
    if rd.ap ~= true then return nil, unread end
    if rd.dmg ~= "err" and self:grab_known()[rd.dmg] then return "grab", unread end
    if rd.guard ~= "err" and self:guard_known().sg[rd.guard] then return "sg", unread end
    return nil, unread
end

function S:vote16(ev, hs, he, why, R, e)
    local v = ev.veto
    if not v or hs < v.hs or (hs == v.hs and VETO_RANK[why] > VETO_RANK[v.why]) then
        ev.veto = { hs = hs, he = he, why = why, R = R, e = e }
    end
end

function S:consider16(o, R, list, ev, now)
    local E = self.E
    local oc = self.oc
    for _, e in ipairs(list) do
        if e.type == E.DANGER then
            local hs, he = f32(e.hs), f32(e.he)
            local wdt = he - hs
            local key = e.obj:get_address()
            local inview = hs <= self.H_VETO and he >= 0
            local rd
            if inview then
                if wdt > self.W_LONG then self:vote16(ev, hs, he, "long", R, e) end
                rd = self:read16(e)
                local vwhy, unread = self:veto_kind16(rd)
                if vwhy then self:vote16(ev, hs, he, vwhy, R, e) end
                if unread and not o.fo[key] then
                    o.fo[key] = true
                    self.ostat.failopen = self.ostat.failopen + 1
                end
            end
            local Q, Qp
            if o.m and not o.nofire and o.x0[key] ~= nil then
                Q = (hs - (o.X - o.x0[key])) / o.m
                local ql = o.qlast[key]
                if ql and ql.f == oc.frame_no - 1 then Qp = ql.q end
                o.qlast[key] = { f = oc.frame_no, q = Q }
            end
            -- vetoq（只记录）：长窗口条目按真实时间已在 1.5 s 内、按原始 hs 还不在否决视野里
            if wdt > self.W_LONG and he >= 0 and Q and Q <= self.H_VETO and hs > self.H_VETO then ev.vq = true end
            -- U（只记录，UVIEW）：视野内、非弹体（读不到也算）、pb=1 或 UNABLE_GUARD；pb 优先
            if inview and rd.shell ~= true then
                local uwhy = (rd.pb == true and "pb") or (rd.guard ~= "err" and self:guard_known().ug[rd.guard] and "ug") or nil
                if uwhy and (not ev.u or hs < ev.u.hs) then ev.u = { hs = hs, he = he, why = uwhy, R = R, e = e } end
            end
            if Q and o.master and wdt >= 0 and wdt <= self.W_LONG and Q >= self.L_MIN and Q <= ev.L then
                rd = rd or self:read16(e)
                local verdict = self:catch16(rd)
                if verdict == true then
                    if not ev.best or Q < ev.best.Q then
                        ev.best = { o = o, R = R, e = e, Q = Q, Qp = Qp, hs = hs, he = he, dX = o.X - o.x0[key],
                            A0 = o.a0[key] }
                    end
                elseif (verdict == "pb" or verdict == "ug" or verdict == "fc") and not o.skipped[key] then
                    o.skipped[key] = true
                    if verdict == "fc" then
                        self.ostat.fclosed = self.ostat.fclosed + 1
                    else
                        self.ostat.excl = self.ostat.excl + 1
                    end
                    self.oskips[#self.oskips + 1] = { frame = self.w.frame, t = now, why = verdict, hs = hs, he = he, Q = Q,
                        res = hexaddr(R.obj), ent = hexaddr(e.obj), em = R.M.key }
                end
            end
        end
    end
end

-- 场景声明的「读主角抛错」时段（oracle_hunter_fail = { {from, to}, ... }，每段要短于脚本的容忍期 1.5 s）：脚本这一帧整帧
-- 跳过（frame_logic 在读主角那一步就返回：不求值、不放刀、E5c 的帧计数和状态都不动，V16 第 2.1 节「这一帧不存在」）
function S:hunter_fail_now()
    for _, wd in ipairs(self.scen.oracle_hunter_fail or {}) do
        if self.w.t >= wd[1] and self.w.t < wd[2] then return true end
    end
    return false
end

function S:compute_oracle16()
    local w = self.w
    local a = self.act
    local oc = self.oc
    local rec = { frame = w.frame, t = w.t, L = self.rc_cfg.parry_lead, auto = self.rc_cfg.auto_parry, cat = a.cat,
        idx = a.idx, v16 = true, present = self.char_present and self.player_present, wtype = self:weapon_type_now() }
    if self:hunter_fail_now() then
        rec.skip_frame = true
        return rec
    end
    local me_ok = self.char_present and self.player_present
    -- 主角不在、换了人（地址变了）、开关关着：脚本全部丢掉（lose_hunter / 关开关时 release_all_tracks）
    if not me_ok or (oc.gen and oc.gen ~= self.H.gen) or not self.rc_cfg.auto_parry then
        for _, R in ipairs(self.results) do
            if R.ot then R.ot.live = false end
        end
    end
    local gs = self:weapon_type_now() == 0
    oc.me_ok = me_ok and gs
    if not me_ok then return rec end
    oc.gen = self.H.gen
    oc.frame_no = oc.frame_no + 1
    local now = w.t + (w.phase_offset.pre or 0.0)
    rec.charging = gs and is_charge(a)
    local ev = (rec.charging and self.rc_cfg.auto_parry) and { L = rec.L } or nil
    local cache = {}
    rec.tracked = {}
    for _, R in ipairs(self.results) do
        local o = R.ot
        if o and o.live then
            local age = now - o.t_msg
            if age >= 8.0 or R.fin then
                o.live = false
            else
                local list = (not self:items_fail(R)) and R.entries or nil
                self:speed_step16(o, list, cache, now)
                local past = false
                if list and age >= 1.0 and #list > 0 then
                    past = true
                    for _, e in ipairs(list) do
                        if not (f32(e.he) < -30) then
                            past = false
                            break
                        end
                    end
                end
                if past then
                    o.live = false
                else
                    if o.idx ~= nil then rec.tracked[#rec.tracked + 1] = o.idx end
                    if ev and list then self:consider16(o, R, list, ev, now) end
                end
            end
        end
    end
    if not ev then return rec end
    if ev.veto then
        rec.veto, rec.veto_hs, rec.veto_why = true, ev.veto.hs, ev.veto.why
    else
        rec.veto = false
    end
    rec.vq = ev.vq == true
    if ev.u then
        rec.u = { hs = ev.u.hs, he = ev.u.he, why = ev.u.why, res = hexaddr(ev.u.R.obj), ent = hexaddr(ev.u.e.obj),
            em = ev.u.R.M.key, R = ev.u.R }
    end
    local b = ev.best
    if b then
        rec.q = b.Q
        rec.hs, rec.he = b.hs, b.he
        rec.entry, rec.result = hexaddr(b.e.obj), hexaddr(b.R.obj)
        local c1 = b.o.c1
        rec.fire = { C1 = c1, Cf = b.o.cf, mf = b.o.m, nchg = b.o.nchg, dX = b.dX, A0 = b.A0, Q0 = b.Q, Qp = b.Qp,
            Qe1 = b.hs - b.A0 * (1.0 - 1.0 / math.max(1.0, c1)), vq = rec.vq, R = b.R }
        if rec.u then rec.u.same = rec.u.R == b.R end
    end
    return rec
end

-- 给离线分析和人看的「真值」（写成 mock_truth.json）
function S:truth_table()
    local t = self.truth
    local out = { attempts = {}, contacts = {}, attacks = {}, machine = {}, emhits = t.emhits, swaps = t.swaps,
        messages = t.messages, activations = t.activations, params = self.P }
    for _, a in ipairs(t.attempts) do
        local cs = {}
        for _, c in ipairs(a.contacts) do cs[#cs + 1] = { t = c.t + self.w.clock_base, kind = c.kind, attack = c.attack,
            elapsed = c.elapsed } end
        out.attempts[#out.attempts + 1] = { id = a.id, t_start = a.t_start + self.w.clock_base, origin = a.origin,
            t_req = a.t_req and (a.t_req + self.w.clock_base) or nil, from = a.from, outcome = a.outcome,
            hit_level = a.hit_level, blade = a.blade, body = a.body, emhit = a.emhit, contacts = cs }
    end
    for _, c in ipairs(t.contacts) do
        out.contacts[#out.contacts + 1] = { t = c.t + self.w.clock_base, kind = c.kind, attack = c.attack, em = c.em,
            act = c.act, elapsed = c.elapsed, attempt = c.attempt }
    end
    for _, a in ipairs(t.attacks) do
        out.attacks[#out.attacks + 1] = { id = a.id, em = a.em, at = a.at + self.w.clock_base,
            t_hs0 = a.t_hs0 and (a.t_hs0 + self.w.clock_base) or nil,
            contact = a.contact and (a.contact + self.w.clock_base) or nil, parried = a.parried or false,
            interrupted = a.interrupted and (a.interrupted + self.w.clock_base) or nil }
    end
    for _, m in ipairs(t.machine) do
        out.machine[#out.machine + 1] = { cycle = m.cycle, t0 = m.t0 + self.w.clock_base,
            contact = m.contact and (m.contact + self.w.clock_base) or nil, parried = m.parried, paralysed = m.paralysed,
            contact_kind = m.contact_kind }
    end
    return out
end

return S
