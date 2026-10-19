-- tools/mock/scenarios.lua：模拟测试场景（CONTRACT 第 5 节要求的全部场景 + 几个补充 + V15 第 8 节的 v1.5 场景
-- + V15 第 9 节的 v1.5.1 场景 + docs/autoparry/V16.md 第 8.4 节的 v1.6 场景）
--
-- 放刀模块按场景的 rc_ver 选（V16 第 8.5 节）：
--   不写 = v16（归档的 v1.6 tools/archive/AutoParryGS_v1.6.lua，参照组 A0；放刀逻辑已并入 AutoGuardGS v1.5，MERGE.md：
--          E5c、L 默认 28（Q 单位）、滑块 23~45、cfg_ver = 3、该接过滤 g1、SKILL_GUARD 否决、(2,25) = RECOIL）。
--          旧的 v1.5 / v1.5.1 场景按 V16 第 8.5 节迁移后照跑（L 30 → 28、配置迁移、候选侧 fail-closed、效果名缺失一刀不放、
--          STAT 23 个字段）。run.lua --merged 时这些场景（merged_equiv = false 的两个引用负对照除外）另用合并脚本跑 B（调试日志开）、
--          C（调试日志关）两组，和 A0 逐刀比（MERGE 第 6.3 节）；场景按别名改写（脚本名 AutoParryGS → AutoGuardGS、菜单按 ID 匹配、
--          「写出数据」丢掉、旧配置写成 AutoParryGS.json 走迁移，见 run.lua 头注释）；
--   merged_only = true 的场景（文件末尾，MERGE 第 6.5 节）只在 --merged 下跑，按场景的 runs 跑几种跑法、按 mexpect 跨跑法核对；
--   rc_ver = "v15" = 归档的 v1.5.1：只给引用记账的负对照用（v16_ref_neg_gs）；
--   rc_ver = "rc1" = 归档的标定版 tools/archive/AutoParryGS_rc1.lua：只给 rc 专有的功能（L 轮换、机关扫描、
--   closest 兜底 src=FB、HUD）继续跑，配置用 rc 的格式（rc1cfg），引用记账用旧的按脚本计数模型。
-- 探针按 probe_ver 选：不写 = probes/AutoParryCalib.lua（apcal-1.1：只 add_ref、不 release）；"1.0.1" = 归档的会手动
--   release 的旧版（只给负对照用）；false = 不载入探针。
--
-- 时间单位：秒，从 0 开始（脚本里的 os.clock() = 1000 + t）。默认 90 fps（dt = 1/90）。
-- 时序速算（90 fps，怪物速度 C = 1）：条目 hs 降到 L 的那一帧请求，下一帧进 (2,23)，接触相对 (2,23) 开始
--   ≈ L/60 − 0.02 + r 秒（r = 接触时刻 − hs 归零时刻）：L=28 时 ≈ 0.447 + r，L=30 时 ≈ 0.48 + r，L=26 时 ≈ 0.414 + r。
--   抵消窗口默认 [0.355, 0.80]，所以 L=28 时 r ∈ (−0.09, 0.35) 会接住，r 更小 = 攻击早到（先挨打），r 更大 = 晚到。
--   刚出现的条目：攻击开始那一帧登记，下一帧 rc 第一次读到的就是初值 hs0，之后每帧少 0.667（60/90）。
-- 设了速度的怪（core = C）：攻击按名义进度到达（激活 = 发消息后 A/(60·C) 秒，接触 = 激活 + g），Q = A/C − 已过帧数；
--   Q 降到 L 的那一帧请求，接触相对 (2,23) 开始 ≈ L/60 − 0.02 + g（C ≥ 1 时和速度无关，这就是 E5c 要做到的）。
--
-- 每个场景的字段：
--   name / desc / duration / dt / hitches = { {at=, dt=} } / rc_ver = "rc1"（不写 = v15）
--   config  = { AutoParryGS = {...}, AutoGuardGS = {...} }   写进输出目录（= reframework/data）
--   player  = { policy = "auto", first_hold, rehold, release_after, input_after, stop_at }
--             或 { events = { {t, "hold"|"release"|"input", idx=22} } }
--   monsters = { key = {emid, sysidx, cls, go_name, pos} }，machine = { start, paralyse_cycles, ... }
--   attacks  = 见 game_sim.lua 的 prepare_attacks 注释
--   faults   = 故障注入（见 mock_ref.lua 的 add_fault；where = of_em("怪物键") 只作用于那只怪的预告结果和条目列表；
--              key = "imgui.<函数>" / "json.dump_file" 是 REF 自带 API 的故障，json 的可加 path=文件名模式、phase="reset"）
--   ui       = { {t=, kind="button"|"checkbox"|"slider", match="文字", value=, script=, cfg_key=} }
--              cfg_key = "auto_parry" | "parry_lead"：这次操作改 rc 的启用开关 / 提前量，神谕从下一帧起按新值算，
--              v15 每次真的改了要写一行 CFG；cfg_key = "debug_log"：只跟进存配置的预期，不算 CFG
--   神谕的读取故障声明（神谕不看 rc 内部，读取出错的结果要场景告诉它）：
--     oracle_fb = true          rc1：全部结果逐条读取出错、退回 closest
--     oracle_items_fail = true | { 怪物键 = true }   v15：这些结果逐条读取出错，既不放刀也不否决
--     oracle_master_failopen    v15：get_IsMaster 读不到，联机副本也按主机处理（fail-open）
--     oracle_dmgtype_failopen = true | { 怪物键 = true }   v1.5.1：伤害类型读不到，抓取、效果攻击都按普通条目（fail-open）
--     oracle_hunter_fail = { {from, to}, ... }   v1.6：这些时段放刀模块读主角抛错、在容忍期内整帧跳过（每段 < 1.5 s，
--                               配合只对 AutoParryGS 的 HunterCharacter.get_WeaponType 抛错故障；审查补充）
--     （枚举名读不到不用声明：故障 missing "field:app.HitDef.DAMAGE_TYPE.<名字>" 神谕自己认，见 game_sim 的
--     grab_known / effect_known）
--   条目的 dmg = "EAR"|"WIND"|"QUAKE"|"CATCH"|"CATCH_ZAKO"|"CATCH_SLINGER"…：AttackParam._DamageType；抓取的攻击
--     打到 (2,23) 的刀上也抵消不了（game_sim 的 parryable 看攻击的 dmg 或触发条目的 dmg）
--   v1.6 的条目属性：pb = true（_IsParryBreak，刀上接触 → RECOIL）、guard = "UNABLE_GUARD" | "SKILL_GUARD" | 数值
--     （_GuardType）、ap = false（get_AttackParam 返回 nil）；攻击事件 hide_entry / show_entry（条目暂离条目表再回来，
--     同一个对象，审查补充）；怪物的 core（CoreState，数值或 { {t, C}, ... }）、hidden
--     （calcMotionSpeedTotal 里的隐藏因子）、speed_fault、spawn_at / despawn_at；攻击的 core（按招切换）、speed_fault
--     （相对攻击开始）、contact = { g = 激活后几秒 }、hit_level = 25（强制 RECOIL）、drop_after（游戏放手的延迟）、
--     local_result（局部对象）；场景的 reuse_results = true（旧场景复用结果对象）、holder = "empty"
--   expect   = 断言（见 run.lua：rc = "oracle"|"scan"|"none"，err = 允许/要求的 ERR（可按 mod 分），fires，pt 等；
--              另有 pt_swing（空挥样本数）、saved_config（re.on_config_save 存下的字段）、scan_done_reason、
--              json_files_min（数字或 { APCal = n }）、red_why（要求的 RED 原因）；
--              发布版另有 stat（最后一行 STAT 的计数：数字或 {min=,max=}，没写的 fb/failopen/replica/readerr 默认 0；
--              v1.6 的 speedfail/speedhold/clockskip/fclosed/excl/uview/vetoq/sidmis/failopen 默认取神谕）、
--              dbg_events / dbg_absent（要求出现 / 不许出现的 DBG 事件）、dbg_max（DBG 行数上限）、veto_why（VETO 的 why 依次是什么）、
--              fire_props（第 i 刀的性质，见 run.lua 的 check_v16_fire）、menu_seen / menu_final / menu_absent（菜单文字）、
--              res_recoil（RES RECOIL 次数）、find_once（每帧每只怪 findEnemy 至多一次、跟踪中每帧都读）、
--              dead_object = "required"（负对照：必须出现 DEAD_OBJECT）、probe_checks = false（不核对探针的测量计数）、
--              add_ref_min = { 脚本 = { 类型名 = 次数 } }（这条跨帧持有的路径真的走到了，审查补充））；
--              max_held（同时持有的峰值必须恰好等于它）、json_fail（{ 标签 = 次数 }：场景注入的写盘失败必须恰好这么多次）、
--              res_forced（{ {from, to}, ... }：这些时段里结算的 RES 是提前结算的 —— 主角消失、CREDIT 内又放了一刀 —— dt 按
--              结算那一刻核对，不按 1.3 s；合并后审查补充）。
--              每个场景都另查：VETO 行和 STAT 的 vetoes = 神谕里的否决 streak 段数（v15 另按神谕逐行核对 why、hs）；
--              why=idle 的 JSON 写出在空闲帧
--   smoke    = false：冒烟脚本（tools/mock/smoke）没实现这项功能，--smoke 时跳过
--   smoke_drop = { 断言名 }：--smoke 时去掉这几项断言（场景本身仍跑，只是冒烟脚本没实现这几项）

local M = {}

local EM20 = { emid = 156, sysidx = 3, cls = "app.Em0020_00Action", go_name = "Em0020_00_0_7340032_12",
    pos = { x = -1100.25, y = 56.39, z = 522.95 } }
local EM1 = { emid = 0, sysidx = 4, cls = "app.Em0001_00Action", go_name = "Em0001_00_0_7471104_13",
    pos = { x = -1096.80, y = 56.39, z = 521.40 } }

-- 测量轮的配置写死（PLAN 测量协议）：大剑自动防御关、角度 360、无限蓄力开
local GUARD_CFG = { enabled = false, guard_type = 1, guard_angle = 360.0, respect_armor = true, auto_tackle = true,
    infinite_charge = true, debug_log = true }

-- v1.6 的配置格式（三个键 + cfg_ver = 3，V16 第 2.7 节）。场景默认用发布版的默认提前量 28，调试日志开着
-- （DBG 的格式也要查）。cfg_ver = 3：不迁移，场景写的 parry_lead（夹到 23~45）原样生效
local function cfg(over)
    local c = { auto_parry = true, parry_lead = 28, debug_log = true, cfg_ver = 3 }
    for k, v in pairs(over or {}) do c[k] = v end
    return { AutoParryGS = c, AutoGuardGS = GUARD_CFG }
end

-- v1.5.1 存的配置（cfg_ver = 2、默认 30）：v1.6 读到 cfg_ver 不是 ≥3 的数一律迁成 28（V16 第 2.7 节），写 DBG cfg_upgrade
local function v151_written(over)
    local c = { auto_parry = true, parry_lead = 30, debug_log = true, cfg_ver = 2 }
    for k, v in pairs(over or {}) do c[k] = v end
    return { AutoParryGS = c, AutoGuardGS = GUARD_CFG }
end
-- 归档的 v1.5.1 自己用的配置（负对照 v16_ref_neg_gs）：带 cfg_ver = 2，它不升级
local v151cfg = v151_written

-- v1.5 写出的配置（三个键、没有 cfg_ver）：v1.6 读到时提前量一律迁成 28，写 DBG cfg_upgrade
local function v15_written(over)
    local c = { auto_parry = true, parry_lead = 26, debug_log = true }
    for k, v in pairs(over or {}) do c[k] = v end
    return { AutoParryGS = c, AutoGuardGS = GUARD_CFG }
end

-- rc1 场景的配置（rc 的格式，CONTRACT 3.1）：不轮换、L=28
local function rc1cfg(over)
    local c = { auto_parry = true, parry_lead = 28, lead_rotation = false, scan = false, debug_log = true }
    for k, v in pairs(over or {}) do c[k] = v end
    return { AutoParryGS = c, AutoGuardGS = GUARD_CFG }
end

-- rc 的 on_config_save 写出的配置（五个键，rc 默认值，没有 cfg_ver）：v1.6 读到时忽略旧键，parry_lead 一律迁成 28
local function rc_written(over)
    local c = { auto_parry = true, parry_lead = 28, lead_rotation = true, scan = false, debug_log = true }
    for k, v in pairs(over or {}) do c[k] = v end
    return { AutoParryGS = c, AutoGuardGS = GUARD_CFG }
end

-- 故障只作用于某只怪的预告结果 / 条目列表（game_sim 给这两种对象挂了 data.R）
local function of_em(key)
    return function(o)
        local d = rawget(o, "__d")
        local R = d and d.R
        return R ~= nil and R.M.key == key
    end
end

local function auto(over)
    local p = { policy = "auto", first_hold = 1.0, rehold = 0.4, release_after = 0.2, input_after = 1.5 }
    for k, v in pairs(over or {}) do p[k] = v end
    return p
end

local function D(hs, he, extra)
    local e = { type = "DANGER", hs = hs, he = he }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end

local function C(hs, he) return { type = "CAUTION", hs = hs, he = he } end

-- ---------------------------------------------------------------------------
M[#M + 1] = {
    name = "two_entries",
    desc = "两条条目 hs 不同：closest 是晚的那条、另有一条 CAUTION 更早；按 DANGER 中最小 hs 放刀",
    duration = 20,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "two_d", em = "em20", at = 3.0, keep = { 0, 72 }, closest = 1,
            entries = { D(95.2, 104.7, { reqset = 3 }), D(71.6, 80.3, { reqset = 4 }) }, contact = { r = 0.03 } },
        { id = "d_c", em = "em20", at = 10.0, keep = { 0, 41 }, closest = 2,
            entries = { D(50.33, 58.9, { reqset = 7 }), C(40.1, 45.0) }, contact = { r = 0.05 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 } },
}

M[#M + 1] = {
    name = "downgrade",
    desc = "中途降级：DANGER 在进入区间前降成 CAUTION（含 hs 变 -1）不放；放刀之后才降级的照常；转招成 CAUTION 不放。"
        .. "本场景的 Nullable 无值时直接返回 nil（另一种运行时形态）",
    duration = 30,
    nullable = "nil",
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "down_early", em = "em20", at = 3.0, keep = { 0, 30 }, entries = { D(80.0, 90.0) },
            events = { { at = 3.5, op = "downgrade", entry = 1, to = "CAUTION" } }, contact = { r = 0.0 } },
        { id = "down_after_fire", em = "em20", at = 9.0, keep = { 0, 31 }, entries = { D(60.0, 68.5) },
            events = { { at = 9.62, op = "downgrade", entry = 1, to = "CAUTION" } }, contact = { r = 0.02 } },
        { id = "down_minus1", em = "em20", at = 15.0, keep = { 0, 32 }, entries = { D(60.0, 70.0) },
            events = { { at = 15.45, op = "downgrade", entry = 1, to = "CAUTION", hs = -1, he = -1 } },
            contact = { r = 0.0 } },
        { id = "switch_caution", em = "em20", at = 21.0, keep = { 0, 33 }, entries = { D(70.0, 78.0) },
            events = { { at = 21.4, op = "switch", keep = { 0, 80 }, entries = { C(45.0, 52.0) }, cancel_contacts = true } },
            contact = { r = 0.0 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 } },
}

-- 每个参数都要被场景「夹住」：参数改了（L_min / W_long / H_veto / he≥0 条件）至少有一处放刀结果会变
M[#M + 1] = {
    name = "long_veto",
    desc = "长窗口否决：he−hs>60 的 DANGER 在 1.5 s 内到来或进行中（hs≤90 且 he≥0）别的条目进区间也不放；"
        .. "视野外（hs≈102）、已打完（he<0 但没结束）照常放；span 65 不触发只否决，span 59.7 照常放",
    duration = 36,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    attacks = {
        { id = "long1", em = "em20", at = 3.0, keep = { 0, 50 }, entries = { D(40.0, 150.0) }, contact = { r = 0.6 } },
        { id = "short_vetoed", em = "em1", at = 3.2, keep = { 0, 12 }, entries = { D(35.0, 45.0) }, contact = { r = 0.0 } },
        -- 短条目进区间（L=28）时长窗口 hs≈102 > 90：不否决（H_veto 改大会漏放）
        { id = "long_far", em = "em20", at = 9.0, keep = { 0, 51 }, entries = { D(120.0, 200.0) }, contact = false,
            events = { { at = 10.0, op = "finish" } } },
        { id = "short_before_horizon", em = "em1", at = 9.1, keep = { 0, 13 }, entries = { D(40.0, 50.0) },
            contact = { r = 0.04 } },
        -- 长窗口已经打完（he<0）但结果没结束：不否决（漏了 he≥0 条件会漏放）
        { id = "long3_open", em = "em20", at = 16.0, keep = { 0, 52 }, entries = { D(30.0, 140.0) }, contact = false,
            finish = "never" },
        { id = "short_after_long", em = "em1", at = 18.6, keep = { 0, 14 }, entries = { D(40.0, 49.0) },
            contact = { r = 0.03 } },
        -- 短条目进区间（L=28）时长窗口 hs≈87 ≤ 90：否决（H_veto 改小会误放）
        { id = "long_near", em = "em20", at = 23.5, keep = { 0, 53 }, entries = { D(105.0, 200.0) }, contact = false,
            events = { { at = 25.0, op = "finish" } } },
        { id = "short_vetoed2", em = "em1", at = 23.6, keep = { 0, 15 }, entries = { D(40.0, 49.0) }, contact = { r = 0.0 } },
        -- he−hs=65：不是候选，自己否决自己（W_long 改大会误放）
        { id = "span65", em = "em20", at = 27.0, keep = { 0, 54 }, entries = { D(40.0, 105.0) }, contact = false },
        -- he−hs=59.7：照常放（W_long 改小会漏放）
        { id = "span59_7", em = "em1", at = 30.5, keep = { 0, 16 }, entries = { D(40.0, 99.7) }, contact = { r = 0.03 } },
    },
    -- 否决 streak 4 段（long1、long3_open 还在进行时（he≥0）、long_near、span65 各一段）：VETO 行和 STAT 的 vetoes
    -- 都恰好 4（每个 streak 一行，不是每个否决帧一行；run.lua 另按神谕逐段核对）
    expect = { rc = "oracle", fires = 3, vetoes_min = 3, veto_frames_min = 1, stat = { vetoes = 4 } },
}

-- v1.6 的 L_min=22、L=28（V16 第 1 节；C = 1 时 Q 就是 hs）两头都要被夹住：21.6 不放、22.4 立刻放（L_min 改大改小
-- 都会被发现）；27.6 立刻放、28.4 要等下一帧降到 27.7 才放（L 改小到 27.6 以下、改大到 28.4 以上都会差一帧被神谕抓到）
M[#M + 1] = {
    name = "remain_zero",
    smoke = false,      -- 按发布版的 L_min=22 设计，冒烟 rc（rc1 口径 18）对不上
    desc = "remain≈0：刚出现就 hs≈0、负值、略低于 L_min=22（21.6）的 DANGER 都不放；刚出现就在 [22, 28] 内的"
        .. "（27.6、22.4）立刻放；刚出现在 28.4 的等降到 28 以下那一帧才放",
    duration = 25,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "hs_0_4", em = "em20", at = 3.0, keep = { 0, 60 }, entries = { D(0.4, 12.0) }, contact = { r = 0.0 } },
        { id = "hs_neg", em = "em20", at = 5.0, keep = { 0, 61 }, entries = { D(-2.0, 8.0) }, contact = { r = 0.0 } },
        { id = "hs_21_6", em = "em20", at = 7.0, keep = { 0, 62 }, entries = { D(21.6, 30.0) }, contact = { r = 0.02 } },
        { id = "hs_27_6", em = "em20", at = 10.0, keep = { 0, 63 }, entries = { D(27.6, 36.0) }, contact = { r = 0.12 } },
        { id = "hs_22_4", em = "em20", at = 15.0, keep = { 0, 64 }, entries = { D(22.4, 31.0) }, contact = { r = 0.20 } },
        { id = "hs_28_4", em = "em20", at = 20.0, keep = { 0, 65 }, entries = { D(28.4, 37.0) }, contact = { r = 0.05 } },
    },
    expect = { rc = "oracle", fires = 3, pt = { catch = 3 } },
}

M[#M + 1] = {
    name = "multi_results",
    desc = "多个结果：两只怪各一个结果取最小；打别人的结果、已结束的结果不算；请求前两次被拒（streak 合并）；永不结束的结果靠 he<-30 释放"
        .. "；同一只怪复用结果对象（reuse_results，旧场景的口径）",
    duration = 30,
    reuse_results = true,
    config = cfg(),
    player = auto(),
    reject_requests = 2,
    monsters = { em20 = EM20, em1 = EM1 },
    attacks = {
        { id = "em20_a", em = "em20", at = 3.0, keep = { 0, 70 }, entries = { D(70.0, 80.0) }, contact = { r = 0.04 } },
        { id = "em1_b", em = "em1", at = 3.1, keep = { 0, 20 }, entries = { D(55.0, 62.0) }, contact = { r = 0.06 } },
        { id = "otomo", em = "em20", target = "otomo", at = 3.0, keep = { 0, 70 }, entries = { D(30.0, 38.0) },
            contact = false },
        { id = "finished_early", em = "em1", at = 9.0, keep = { 0, 21 }, entries = { D(60.0, 70.0) }, contact = false,
            events = { { at = 9.5, op = "finish" } } },
        { id = "after_finish", em = "em20", at = 9.4, keep = { 0, 71 }, entries = { D(45.0, 53.0) }, contact = { r = 0.03 } },
        { id = "never_finish", em = "em20", at = 15.0, keep = { 0, 72 }, entries = { D(50.0, 60.0) }, contact = false,
            finish = "never" },
        { id = "reuse_obj", em = "em20", at = 22.0, keep = { 0, 73 }, entries = { D(55.0, 63.0) }, contact = { r = 0.05 } },
    },
    expect = { rc = "oracle", fires = 4, streak_n_min = 3 },
}

M[#M + 1] = {
    name = "machine_scan",
    rc_ver = "rc1",     -- 机关扫描只在 rc 里（v1.5 已删，V15 第 3 节）
    desc = "训练机关：只发 fin=true 的空预告；rc 扫描模式认机关、学 D_c、按 X 调度放刀，作废规则（麻痹周期、卡顿）",
    duration = 660,
    config = rc1cfg({ scan = true }),
    player = auto({ first_hold = 1.0, rehold = 0.4, input_after = 1.25 }),
    machine = { start = 2.0, paralyse_cycles = { 6 } },
    hitches = { { at = 120.0, dt = 0.045 } },
    noise = true,
    stop_on_log = "%[AutoParryGS%] SCAN .*phase=done",
    stop_tail = 6.0,
    expect = { rc = "scan", scan_done = true },
}

M[#M + 1] = {
    name = "manual_release",
    desc = "手动放刀：玩家自己松手（攻击还没进区间），rc 不发请求；第二次手动空挥",
    duration = 16,
    config = cfg(),
    player = { events = { { 1.0, "hold" }, { 3.70, "release" }, { 6.5, "hold" }, { 9.0, "release" },
        { 10.6, "input" } } },
    monsters = { em20 = EM20 },
    attacks = {
        { id = "manual_catch", em = "em20", at = 3.0, keep = { 0, 44 }, entries = { D(85.0, 93.0) }, contact = { r = 0.0 } },
    },
    expect = { rc = "oracle", fires = 0, requests = 0, pt = { catch = 1, whiff = 1 } },
}

M[#M + 1] = {
    name = "whiff",
    desc = "空放：攻击没来（没出手 / 转招）、上捞斩先砍中把怪打断（INTERRUPTED）；RES 记 NOCATCH",
    duration = 26,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "no_attack", em = "em20", at = 3.0, keep = { 0, 90 }, entries = { D(60.0, 70.0) }, contact = false },
        { id = "switched", em = "em20", at = 10.0, keep = { 0, 91 }, entries = { D(58.0, 66.0) }, contact = { r = 0.02 },
            events = { { at = 10.62, op = "switch", keep = { 0, 95 }, entries = { C(40.0, 48.0) }, cancel_contacts = true } } },
        { id = "interrupted", em = "em20", at = 17.0, keep = { 0, 92 }, entries = { D(60.0, 70.0) },
            contact = { r = 0.10 }, interrupt = true },
    },
    expect = { rc = "oracle", fires = 3, pt = { whiff = 3 }, res_nocatch_min = 3, emstate_after_interrupt = true },
    smoke_drop = { "emstate_after_interrupt" },   -- 冒烟脚本没实现 EMHIT 后盯怪物动作
}

M[#M + 1] = {
    name = "catch_with_body",
    desc = "接住那一帧同时有身体接触（16:12:47.045 实测）：结局必须是接住；HitM 档没有 cMsgParrySuccess",
    duration = 18,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "catch_body", em = "em20", at = 3.0, keep = { 0, 15 }, entries = { D(65.0, 74.0) }, contact = { r = 0.03 },
            body_same_frame = true, body_damage = 12.5 },
        { id = "catch_m", em = "em20", at = 10.0, keep = { 0, 16 }, entries = { D(60.0, 69.0) }, contact = { r = 0.08 },
            hit_level = 26 },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 }, res_catch_min = 2 },
}

M[#M + 1] = {
    name = "shell",
    desc = "弹体与效果攻击：ShellIndex 有值、EAR/WIND/QUAKE 的 DANGER 都不放；同一结果里的非弹体条目照常放",
    duration = 26,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "shell_only", em = "em20", at = 3.0, keep = { 1, 5 }, entries = { D(60.0, 70.0, { shell = 2 }) },
            contact = { r = 0.0 }, shell = true },
        { id = "roar", em = "em20", at = 7.0, keep = { 1, 6 }, entries = { D(60.0, 75.0, { dmg = "EAR" }) }, contact = false },
        { id = "wind", em = "em20", at = 10.0, keep = { 1, 7 }, entries = { D(55.0, 70.0, { dmg = "WIND" }) }, contact = false },
        { id = "quake", em = "em20", at = 13.0, keep = { 1, 8 }, entries = { D(58.0, 66.0, { dmg = "QUAKE" }) },
            contact = false },
        { id = "mixed", em = "em20", at = 18.0, keep = { 1, 9 }, closest = 1,
            entries = { D(60.0, 68.0, { shell = 1 }), D(75.0, 82.0) },
            contact = { at = 18.0 + 75.0 / 60.0 + 0.03 } },
    },
    expect = { rc = "oracle", fires = 1 },
}

M[#M + 1] = {
    name = "fb_fallback",
    rc_ver = "rc1",     -- closest 兜底只在 rc 里（v1.5 已删，见 v15_items_* 场景）
    desc = "逐条读取异常（List.get_Item 抛错）：rc 退回 getClosestDetectedData（src=FB）；探针的条目序列模块退回 closest 并标黄",
    duration = 18,
    config = rc1cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "DetectedDataList.get_Item", mode = "throw" } },
    oracle_fb = true,
    attacks = {
        { id = "fb_single", em = "em20", at = 3.0, keep = { 0, 25 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "fb_closest_late", em = "em20", at = 9.0, keep = { 0, 26 }, closest = 2,
            entries = { D(50.0, 58.0), D(70.0, 78.0) }, contact = { r = 0.0 } },
    },
    expect = {
        rc = "oracle", fires = 2, src_fb = true,
        err = { { tag = "APCal", level = "yellow", max = 99 }, { tag = "AutoParryGS", level = "yellow", max = 99 } },
    },
}

M[#M + 1] = {
    name = "optional_fault",
    desc = "探针的可选模块出错自停（黄）：怪物速度、目标、朝向、动画层、主从接口抛错；测量照常（PT/CT/MSG 继续写）。"
        .. "get_IsMaster 只对探针抛错：放刀模块读它出错的处理见 v15_master_throw",
    duration = 20,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = {
        { key = "EnemyCharacter.calcMotionSpeedTotal", mode = "throw" },
        { key = "EmModuleTarget.getTarget", mode = "throw" },
        { key = "via.Transform.get_AxisZ", mode = "throw" },
        { key = "via.motion.TreeLayer.get_Frame", mode = "throw" },
        { key = "EnemyContextHolder.get_IsMaster", mode = "throw", scripts = { AutoParryCalib = true } },
    },
    attacks = {
        { id = "opt1", em = "em20", at = 3.0, keep = { 0, 35 }, entries = { D(66.0, 74.0) }, contact = { r = 0.03 } },
        { id = "opt2", em = "em20", at = 11.0, keep = { 0, 36 }, entries = { D(60.0, 68.0) }, contact = { r = 0.06 } },
    },
    expect = {
        rc = "oracle", fires = 2, pt = { catch = 2 },
        err = { { tag = "APCal", level = "yellow", min = 1, max = 99 } },
        probe_kinds_after_err = { "PT", "MSG" },
    },
}

M[#M + 1] = {
    name = "core_fault",
    desc = "核心模块连续出错（红）：从 8 s 起读当前动作 ID 每次都抛错；rc 连续 30 帧出错自停，探针 10 s 内 ≥3 次标红",
    duration = 22,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    faults = { { key = "ActionController.get_CurrentActionID", mode = "throw", from = 8.0 } },
    oracle_until = 8.0,
    attacks = {
        { id = "before_fault", em = "em20", at = 3.0, keep = { 0, 37 }, entries = { D(64.0, 72.0) }, contact = { r = 0.03 } },
        -- 读主角抛错的容忍期里到达的预告（rc 照样登记）：自停那一刻还在跟踪，必须当场释放（run.lua 的 check_holds 查）
        { id = "in_flight_stop", em = "em1", at = 9.0, keep = { 0, 39 }, entries = { D(120.0, 128.0) }, contact = false },
        { id = "after_fault", em = "em20", at = 13.0, keep = { 0, 38 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
    },
    -- v1.5：读主角抛错先容忍 1.5 s，之后帧逻辑每帧出错 → 10 s 内第 3 次标红（RED why=3in10s）→ 连续 30 帧自停
    -- （RED why=self_stop，释放全部引用、不再请求）；菜单显示红色出错提示（v1.5 没有 HUD，run.lua 的 check_v15 查菜单）。
    -- 容忍期的帧只计 readfail、不算错误，所以帧逻辑错误恰好 30 条（钉住 STOP_FRAMES=30；RED_COUNT 见 v15_red_msg）
    expect = {
        rc = "oracle", fires = 1, no_requests_after = 8.5, stat = { errors = 30, red = 30 },
        err = {
            { tag = "APCal", level = "red", min = 1, max = 99 }, { tag = "APCal", level = "yellow", max = 99 },
            { tag = "AutoParryGS", level = "red", min = 1, max = 99 }, { tag = "AutoParryGS", level = "yellow", max = 99 },
        },
        red = { "APCal", "AutoParryGS" },
        red_why = { AutoParryGS = { "3in10s", "self_stop" } },
        hud_red = true,
    },
    smoke_drop = { "red", "red_why" },     -- 冒烟脚本不写 RED
}

-- ---------- 补充场景 ----------

M[#M + 1] = {
    name = "rotation",
    rc_ver = "rc1",     -- L 轮换只在 rc 里（v1.5 已删，V15 第 3 节）
    desc = "L 轮换 {20,24,28,32,36}：每 5 次一组组内乱序、只有进了 (2,23) 才换档；菜单「写出数据」、空闲 ≥60 s 自动写 JSON",
    duration = 140,
    config = rc1cfg({ lead_rotation = true }),
    player = auto({ stop_at = 66.0 }),
    monsters = { em20 = EM20 },
    attacks = (function()
        local list = {}
        local rs = { 0.03, 0.10, -0.05, 0.20, 0.06, 0.0, 0.12, -0.02, 0.15, 0.04, 0.08, 0.01 }
        for i = 1, 12 do
            list[#list + 1] = { id = "rot" .. i, em = "em20", at = 3.0 + (i - 1) * 5.0, keep = { 0, 100 + i },
                entries = { D(70.0 + (i % 3) * 0.37, 79.0 + (i % 3) * 0.37) }, contact = { r = rs[i] } }
        end
        return list
    end)(),
    ui = { { t = 40.0, kind = "button", match = "写出数据" } },
    expect = { rc = "oracle_rotation", fires_min = 10, json_files_min = 2, rotation = true },
}

M[#M + 1] = {
    name = "charge22",
    desc = "从 (2,22) cParryCharge 放刀（14:57:01.594 实测被接受）：FIRE 的 from 记 (2,22)",
    duration = 12,
    config = cfg(),
    player = auto({ charge_idx = 22 }),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "from22", em = "em20", at = 3.0, keep = { 0, 18 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, fire_from = "2_22" },
}

M[#M + 1] = {
    name = "player_swap",
    desc = "主角为 nil 一段时间、主角对象换新（切场景）：全部 release，换人后照常放刀，不访问旧对象",
    duration = 26,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    hunter_events = { { t = 6.0, op = "gap_char", dur = 1.0 }, { t = 12.0, op = "swap" } },
    attacks = {
        { id = "before", em = "em20", at = 2.0, keep = { 0, 52 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
        { id = "in_flight", em = "em20", at = 11.5, keep = { 0, 53 }, entries = { D(70.0, 78.0) }, contact = false },
        { id = "after", em = "em20", at = 16.0, keep = { 0, 54 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2 },
}

M[#M + 1] = {
    name = "hud_fallback",
    rc_ver = "rc1",     -- HUD 只在 rc 里（v1.5 已删，V15 第 3 节；发布版场景都查「不画 HUD」）；探针的 HUD 退回照样测
    desc = "draw.text 不可用（抛错）：HUD 退回 imgui.begin_window 窗口，测量和放刀照常",
    duration = 12,
    config = rc1cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    -- 错误文本故意带一段非 UTF-8 的字节（GBK 的「不可用」）：游戏路径、系统消息可能是本机代码页。
    -- 两个脚本写 ERR 进 JSON 时都要先洗掉，否则 json.dump_file 整份失败（mock 的 json 拒绝坏 UTF-8）
    faults = { { key = "draw.text", mode = "throw", msg = "mock: draw.text \xB2\xBB\xBF\xC9\xD3\xC3" } },
    attacks = {
        { id = "hud1", em = "em20", at = 3.0, keep = { 0, 19 }, entries = { D(62.3, 70.3) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 1, pt = { catch = 1 }, hud_window = true,
        err = { { tag = "APCal", level = "yellow", max = 99 }, { tag = "AutoParryGS", level = "yellow", max = 99 } },
    },
}

M[#M + 1] = {
    name = "ui_toggle",
    desc = "菜单关掉「启用（实验）」：立刻全部 release、不再请求；再打开后照常放刀；关、开各写一行 CFG",
    duration = 22,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    ui = {
        { t = 7.5, kind = "checkbox", match = "启用", value = false, script = "AutoParryGS", cfg_key = "auto_parry" },
        { t = 14.0, kind = "checkbox", match = "启用", value = true, script = "AutoParryGS", cfg_key = "auto_parry" },
    },
    -- 关着的时候 rc 不收消息：重新打开后，关闭期间到达的预告要等它重发才会被跟踪，神谕不知道这一点，这段跳过
    oracle_skip = { { 7.5, 14.2 } },
    attacks = {
        { id = "on1", em = "em20", at = 3.0, keep = { 0, 81 }, entries = { D(60.4, 68.4) }, contact = { r = 0.03 } },
        -- 关开关时这条预告还在跟踪（hs 还没到 L）：必须当场释放
        { id = "in_flight_off", em = "em20", at = 7.2, keep = { 0, 82 }, entries = { D(80.0, 88.0) }, contact = { r = 0.0 } },
        { id = "off2", em = "em20", at = 10.0, keep = { 0, 83 }, entries = { D(60.0, 68.0) }, contact = { r = 0.0 } },
        { id = "on3", em = "em20", at = 16.0, keep = { 0, 84 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 2, no_requests_between = { { 7.6, 14.0 } },
        release_all_at = { { t = 7.52, what = "菜单关掉自动放刀", script = "AutoParryGS" } },
    },
}

M[#M + 1] = {
    name = "other_weapon",
    desc = "主角不是大剑（WeaponType≠0）：rc 一刀都不放",
    duration = 10,
    weapon_type = 3,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "tachi", em = "em20", at = 3.0, keep = { 0, 85 }, entries = { D(60.0, 68.0) }, contact = { r = 0.0 } },
    },
    expect = { rc = "oracle", fires = 0, requests = 0 },
}

M[#M + 1] = {
    name = "hitch",
    desc = "卡顿：dt 0.05（HITCH）和 0.15（GAP）；倒数中途一帧 0.35 s（游戏把扣减钳在 0.1333 s = 8 帧）把 hs 从 ~29"
        .. " 直接跳到 ~21（越过 [22,28]），不放（不做外推）",
    duration = 24,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    -- 卡顿帧之前 rc 读到 hs≈29（>28 不放），卡顿帧一次只减 8（dt 钳在 0.1333 s，SPEED 2.1 d）→ ≈21（<22 不放），前后差一帧也越得过
    hitches = { { at = 5.0, dt = 0.05 }, { at = 8.0, dt = 0.15 }, { at = 12.50, dt = 0.35 } },
    attacks = {
        { id = "jumped", em = "em20", at = 12.0, keep = { 0, 77 }, entries = { D(58.3, 66.1) }, contact = { r = 0.0 } },
        { id = "normal", em = "em20", at = 17.0, keep = { 0, 78 }, entries = { D(60.0, 68.0) }, contact = { r = 0.04 } },
    },
    expect = { rc = "oracle", fires = 1, probe_kinds = { "HITCH", "GAP" } },
    -- 冒烟 rc 按 rc1 口径（L_min 18）：钳制后一帧只跳 8，跳不过 [18, 28]，落在 ~21 会放（神谕照样逐帧核对），不数 FIRE
    smoke_drop = { "fires" },
}

-- PLAN 第 1 轮第一步 A1：训练场离机关 10 m 以上，按住抵消蓄力约 1 s 松开，之后不按键等角色自己停住，做 3 次。
-- 没有怪物、没有接触：(2,23) 停满 slash_len（3.6 s）。探针每次 PT 记 swing=1、PROG 的 swings 数到 3；
-- 离线按 ARM 里 (2,23) 的 SUPER_ARMOR 结束时刻得到 T_armor（模拟器设定 1.0 s）
M[#M + 1] = {
    name = "a1_swing",
    smoke = false,      -- 冒烟脚本没实现这项功能，--smoke 时跳过
    desc = "A1 空挥 3 次：没有怪，手动松手后不按键，(2,23) 停 3.6 s；探针 PT swing=1 共 3 次（空挥 3/3），离线据 ARM 得 T_armor",
    duration = 22,
    config = cfg(),
    player = { events = { { 1.0, "hold" }, { 2.0, "release" }, { 7.5, "hold" }, { 8.5, "release" },
        { 14.0, "hold" }, { 15.0, "release" } } },
    expect = { rc = "oracle", fires = 0, requests = 0, pt = { whiff = 3 }, pt_swing = 3, probe_kinds = { "ARM" } },
}

-- 探针菜单「停止记录」（P22；加载 90 分钟后自停走的是同一条路径）：停的那一刻结算回合、释放全部 add_ref、
-- 写出 JSON，日志写 STOP；恢复时写 RESUME，之后照常记录。停的期间 rc 不受影响。
-- 停的时候正跟踪着一条 CAUTION 预告（rc 和探针都持有它，rc 不会对它放刀），用来核对探针当场释放
M[#M + 1] = {
    name = "probe_stop",
    smoke = false,      -- 冒烟脚本没实现这项功能，--smoke 时跳过
    desc = "探针菜单「停止记录」再恢复：停时结算回合、释放全部对象、写出 JSON（STOP/RESUME）；恢复后照常记录，rc 不受影响",
    duration = 20,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    ui = {
        { t = 7.5, kind = "checkbox", match = "停止记录", value = true, script = "AutoParryCalib" },
        { t = 11.0, kind = "checkbox", match = "停止记录", value = false, script = "AutoParryCalib" },
    },
    attacks = {
        { id = "rec1", em = "em20", at = 3.0, keep = { 0, 88 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
        { id = "held_caution", em = "em20", at = 7.0, keep = { 0, 89 }, entries = { C(100.0, 110.0) }, contact = false,
            finish = 9.0 },
        { id = "rec2", em = "em20", at = 13.0, keep = { 0, 90 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 2, pt = { catch = 2 }, json_files_min = { APCal = 2 }, probe_kinds = { "STOP", "RESUME" },
        release_all_at = { { t = 7.52, what = "探针菜单「停止记录」", script = "AutoParryCalib" } },
    },
}

-- 机关扫描做到一半就结束（扫描途中退出游戏 / Reset Scripts）：配置里不能存下 scan=true，
-- 否则下次一加载就又进扫描模式，会把第一只打到主角的真怪当成机关；SCAN 写 phase=done reason=reset
M[#M + 1] = {
    name = "scan_abort",
    rc_ver = "rc1",
    smoke = false,      -- 冒烟脚本没实现这项功能，--smoke 时跳过
    desc = "机关扫描中途结束（退出游戏 / Reset）：存配置时 scan 写 false，SCAN 收尾 phase=done reason=reset",
    duration = 20,
    config = rc1cfg({ scan = true }),
    player = auto({ first_hold = 1.0, rehold = 0.4, input_after = 1.25 }),
    machine = { start = 2.0 },
    expect = { rc = "scan", saved_config = { AutoParryGS = { scan = false } }, scan_done_reason = "reset" },
}

-- 跟踪上限（PLAN 参数表「预告跟踪与释放」：最多 32 条，满了丢最旧的）：34 只怪几乎同时发来打我的预告。
-- 两个脚本都要先丢掉最旧的（release）再登记新的，任何时刻同时持有都不超过 32。
-- 用 CAUTION 条目，rc 不会放刀；60 fps，让 34 只怪每帧的 activateAttack(false) 不触发探针的频率守卫（3000 次/秒）
M[#M + 1] = (function()
    local monsters, attacks = {}, {}
    for i = 1, 34 do
        local key = string.format("m%02d", i)
        monsters[key] = { emid = 100 + i, sysidx = 10 + i, cls = "app.Em0020_00Action",
            go_name = string.format("EmMock_%02d", i), pos = { x = -1100.25 + i * 0.5, y = 56.39, z = 530.0 } }
        attacks[#attacks + 1] = { id = "c" .. i, em = key, at = 2.0 + i * 0.05, keep = { 0, 200 + i },
            entries = { C(300.0, 310.0) }, contact = false, finish = 9.0 }
    end
    return {
        name = "track_full",
        smoke = false,      -- 冒烟脚本没实现跟踪上限，--smoke 时跳过
        desc = "34 条打我的预告几乎同时到（超过跟踪上限 32）：两个脚本都丢掉最旧的并 release，同时持有不超过 32",
        duration = 20,      -- 留一段平静期：日志预算（≤5 行/秒）是长时间平均，2 s 内涌进 34 条预告的突发不代表常态
        dt = 1 / 60,
        config = cfg(),
        player = auto(),
        monsters = monsters,
        attacks = attacks,
        expect = { rc = "oracle", fires = 0, requests = 0, max_held = 32 },
    }
end)()

-- 切场景、加载的头几帧：主角对象已经在，动作控制器还没建好（get_BaseActionController 返回 nil）。
-- 两个脚本都应按「这一帧读不到主角动作」跳过：不报错、rc 不因「帧逻辑连续 30 帧出错」自停，恢复后照常放刀。
-- 窗口 1.5 s（135 帧 > 30 帧），正好盖住第一刀接住后的收尾和重新按住
M[#M + 1] = {
    name = "action_gap",
    desc = "主角在、但动作控制器暂时读不到（get_BaseActionController 返回 nil 1.5 s）：rc 和探针都不报错、"
        .. "rc 不自停，恢复后照常放刀",
    duration = 18,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "HunterCharacter.get_BaseActionController", mode = "nil", from = 6.0, to = 7.5 } },
    oracle_skip = { { 6.0, 7.6 } },
    attacks = {
        { id = "before_gap", em = "em20", at = 3.0, keep = { 0, 86 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
        { id = "after_gap", em = "em20", at = 10.0, keep = { 0, 87 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 } },
}

-- ---------- 审查第 1 轮后补的场景 ----------

-- 未结束的结果先是空列表，之后不重发消息就冒出 DANGER 条目（结果对象是活的，脚本每帧自己读）。
-- 「全部条目 he<-30 且距消息 ≥1 s 就释放」只对非空列表成立：rc 以前空列表按空真处理，1 s 就放掉，后面的 DANGER 漏放；
-- 探针（n_ent>0）和神谕都继续持有到 8 s
M[#M + 1] = {
    name = "empty_then_danger",
    desc = "未结束的结果先是空列表、1.6 s 后不发新消息就冒出 DANGER 条目：两个脚本都要继续持有（空列表不算「全部 he<-30」），照常放刀",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "empty_first", em = "em20", at = 3.0, keep = { 0, 46 }, entries = {},
            events = { { at = 4.6, op = "set_entries", entries = { D(60.0, 68.0) } } },
            contact = { at = 4.6 + 60.0 / 60.0 + 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 } },
}

-- Nullable 的第三种形态：有值时直接返回拆箱后的数字（CONTRACT 1.2「或直接看返回是否 nil」）。
-- rc 以前在 v:get_field 抛错 → shell 停用 → 之后弹体条目全按 fail-open 放刀
M[#M + 1] = {
    name = "shell_num",
    smoke = false,      -- 冒烟脚本没实现数字形态的 Nullable，--smoke 时跳过
    desc = "弹体条目，Nullable 有值时直接返回数字、无值返回 nil：弹体照样不放、不报错；同一结果里的非弹体条目照常放",
    duration = 26,
    nullable = "number",
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "shell_only", em = "em20", at = 3.0, keep = { 1, 5 }, entries = { D(60.0, 70.0, { shell = 2 }) },
            contact = { r = 0.0 }, shell = true },
        { id = "mixed", em = "em20", at = 18.0, keep = { 1, 9 }, closest = 1,
            entries = { D(60.0, 68.0, { shell = 1 }), D(75.0, 82.0) },
            contact = { at = 18.0 + 75.0 / 60.0 + 0.03 } },
    },
    expect = { rc = "oracle", fires = 1 },
}

-- 逐条读取失败的另一种形态：get_Item 返回 nil 而不抛错（REF 调泛型实例方法失败时可能这样）。
-- 探针以前静默当成「没有条目」：没有 SER、没有首次 DANGER 和自检2、B 段不触发，也不标黄
M[#M + 1] = {
    name = "fb_nil",
    rc_ver = "rc1",
    smoke = false,      -- 冒烟脚本没实现 get_Item 返回 nil 的处理，--smoke 时跳过
    desc = "List.get_Item 返回 nil（不抛错）：rc 退回 closest（src=FB）；探针的 ITEM 模块标黄、退回 closest，SER/自检2 照常",
    duration = 18,
    config = rc1cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "DetectedDataList.get_Item", mode = "nil" } },
    oracle_fb = true,
    attacks = {
        { id = "fbn_single", em = "em20", at = 3.0, keep = { 0, 27 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "fbn_closest_late", em = "em20", at = 9.0, keep = { 0, 28 }, closest = 2,
            entries = { D(50.0, 58.0), D(70.0, 78.0) }, contact = { r = 0.0 } },
    },
    expect = {
        rc = "oracle", fires = 2, src_fb = true,
        err = { { tag = "APCal", level = "yellow", min = 1, max = 99 }, { tag = "AutoParryGS", level = "yellow", min = 1, max = 99 } },
    },
}

-- 扫描中途切场景（主角对象换新）：扫描就此结束（SCAN done reason=lost），自动关扫描、放掉机关。
-- 以前只放掉机关对象、扫描还开着，之后第一只打到主角的怪会被认成机关
M[#M + 1] = {
    name = "scan_swap",
    rc_ver = "rc1",
    smoke = false,
    desc = "机关扫描中途主角对象换新（切场景）：SCAN 收尾 reason=lost、自动关扫描、释放机关，之后不再请求",
    duration = 32,
    config = rc1cfg({ scan = true }),
    player = auto({ first_hold = 1.0, rehold = 0.4, input_after = 1.25 }),
    machine = { start = 2.0 },
    hunter_events = { { t = 20.0, op = "swap" } },
    expect = { rc = "scan", scan_done_reason = "lost", saved_config = { AutoParryGS = { scan = false } } },
}

-- 扫描开着、机关出招之前先有一只真怪打到主角：认机关要核对类名（只认 app.Em0165_00Action.*），
-- 不能把第一只打到主角的怪当成机关（否则一直等不到 cSmallAttack，扫描白跑 10 分钟）
M[#M + 1] = {
    name = "scan_realfirst",
    rc_ver = "rc1",
    smoke = false,
    desc = "扫描模式下真怪先打到主角（CAUTION，rc 不放刀）：不认它当机关；之后照常认出机关、学 D_c。"
        .. "中途主角对象短暂为 nil（同一个对象又回来）：放掉机关、扫描不结束，下次被打到按类名重新认机关",
    duration = 30,
    config = rc1cfg({ scan = true }),
    player = auto({ first_hold = 1.0, rehold = 0.4, input_after = 1.25 }),
    machine = { start = 6.0 },
    hunter_events = { { t = 22.0, op = "gap_char", dur = 0.5 } },
    monsters = { em20 = EM20 },
    attacks = {
        { id = "real_first", em = "em20", at = 2.0, keep = { 0, 57 }, entries = { C(60.0, 68.0) }, contact = { r = 0.0 } },
    },
    expect = { rc = "scan", scan_learn_min = 2, scan_done_reason = "reset" },
}

-- 读主角动作的接口瞬时抛错（不是返回 nil）：切场景时对象可能正在销毁。0.1 s 的瞬时异常以前会在 3 帧内
-- 标红（探针）、HUD 永久提示停下，这一轮作废；现在两个脚本都按「这一帧不存在」跳过，持续 >1.5 s 才算错误
M[#M + 1] = {
    name = "transient_throw",
    desc = "HunterCharacter.get_WeaponType 抛错 0.1 s（瞬时异常）：两个脚本都不报错、不标红，前后照常放刀",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "HunterCharacter.get_WeaponType", mode = "throw", from = 7.0, to = 7.1 } },
    oracle_skip = { { 7.0, 7.12 } },
    attacks = {
        { id = "before_t", em = "em20", at = 3.0, keep = { 0, 48 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
        { id = "after_t", em = "em20", at = 9.0, keep = { 0, 49 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 } },
}

-- 条目对象被怪物复用：同一结果的第 1 个条目地址不变，上一招是弹体、这一招是近战。
-- rc 按当前读到的属性判断（近战照常放）；探针每个新回合重写 ENT，离线要按回合取属性
M[#M + 1] = {
    name = "entry_reuse",
    desc = "条目对象复用（地址不变）：上一招弹体不放，下一招近战照常放；探针每回合重写 ENT",
    duration = 18,
    reuse_entries = true,
    reuse_results = true,       -- 条目复用以结果复用为前提（旧场景的口径；v1.6 起默认每次攻击一个新结果）
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "shell_first", em = "em20", at = 3.0, keep = { 1, 10 }, entries = { D(60.0, 70.0, { shell = 3 }) },
            contact = { r = 0.0 }, shell = true },
        { id = "melee_reuse", em = "em20", at = 10.0, keep = { 0, 55 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 } },
}

-- 同一帧连出两条错误（逐条读取出错 → 退回 closest，closest 也读坏）：rc 以前限频是直接丢弃，
-- 第二条（frame 红）日志和 JSON 里都没有，离线的关键错误统计看不到。现在每条都进 JSON，日志排队补写
M[#M + 1] = {
    name = "err_burst",
    rc_ver = "rc1",     -- 靠 closest 兜底出第二条错；v1.5 的同帧两条错误见 v15_items_partial
    smoke = false,      -- 冒烟脚本没实现错误排队写日志、STAT 补写，--smoke 时跳过
    desc = "同一帧 items 出错（黄）后 closest 也出错（帧逻辑红）：两条 ERR 都进 rc 的 JSON，STAT 的错误数和 JSON 对得上",
    duration = 16,
    config = rc1cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = {
        { key = "DetectedDataList.get_Item", mode = "throw" },
        { key = "AttackAreaResult.getClosestDetectedData", mode = "throw", max = 1, scripts = { AutoParryGS = true } },
    },
    oracle_fb = true,
    oracle_skip = { { 3.0, 4.6 } },
    attacks = {
        { id = "lost_to_err", em = "em20", at = 3.0, keep = { 0, 58 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "fb_after", em = "em20", at = 8.0, keep = { 0, 59 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 1, src_fb = true, rc_err_complete = true,
        err = { { tag = "AutoParryGS", level = "yellow", min = 1, max = 1 }, { tag = "AutoParryGS", level = "red", min = 1, max = 1 },
            { tag = "APCal", level = "yellow", min = 1, max = 99 } },
    },
}

-- 跟踪满了按 t_msg 淘汰（最久没收到消息的那条），两个脚本一致：第 1 只怪先登记、后来又重发了消息，
-- 第 33 条到来时该丢的是第 2 只（t_msg 最旧），不是第 1 只（登记最早）
M[#M + 1] = (function()
    local monsters, attacks = {}, {}
    for i = 1, 33 do
        local key = string.format("m%02d", i)
        monsters[key] = { emid = 100 + i, sysidx = 10 + i, cls = "app.Em0020_00Action",
            go_name = string.format("EmMock_%02d", i), pos = { x = -1100.25 + i * 0.5, y = 56.39, z = 530.0 } }
        attacks[#attacks + 1] = { id = "e" .. i, em = key, at = 2.0 + i * 0.05, keep = { 0, 300 + i },
            entries = { C(300.0, 310.0) }, contact = false, finish = 9.0, resend = (i == 1) and { 3.0 } or nil }
    end
    return {
        name = "track_evict",
        smoke = false,
        desc = "33 条打我的预告，第 1 条中途重发过：满 32 条时两个脚本都丢 t_msg 最旧的第 2 条，不丢登记最早的第 1 条",
        duration = 14,
        dt = 1 / 60,
        config = cfg(),
        player = auto(),
        monsters = monsters,
        attacks = attacks,
        expect = { rc = "oracle", fires = 0, requests = 0, max_held = 32,
            held_at = { { t = 4.0, em = "m01", held = true }, { t = 4.0, em = "m02", held = false } } },
    }
end)()

-- ---------- v1.5 起的发布版场景（docs/autoparry/V15.md 第 8 节；按 V16 第 8.5 节迁移到 v1.6 照跑） ----------
-- 每个发布版场景（上面的通用场景也是）run.lua 都另查：HDR 值、CFG 和菜单改动一一对应、STAT 计数（默认 fb/failopen/
-- replica/readerr 为 0，v1.6 新字段默认取神谕）、存配置只剩三个键加 cfg_ver、没有 HUD 和 SCAN、DBG 不刷屏、菜单文字
-- （check_release）。下面的场景都是发布版才有的行为，冒烟 rc（rc1 口径）对不上，--smoke 时跳过

-- 联机副本（get_IsMaster()=false）的怪：除了主从，其余同 EM20
local EM20R = {}
for k, v in pairs(EM20) do EM20R[k] = v end
EM20R.master = false

-- 错误文本带一段非 UTF-8 的字节（GBK 的「不可用」）：ERR 进 JSON 前要洗掉，否则整份 JSON 写失败
local GBK_MSG = "mock: get_IsMaster \xB2\xBB\xBF\xC9\xD3\xC3"

M[#M + 1] = {
    name = "v15_default",
    smoke = false,
    desc = "没有配置文件：默认 L=28、L_min=22（HDR lead=28）；60 穿越 28 放、27.6 立刻放、21.6 不放、22.4 立刻放、"
        .. "28.5 要降到 28 以下那一帧才放；debug_log 默认关，一行 DBG 都没有（不算迁移）；存配置三个键加 cfg_ver=3",
    duration = 25,
    config = { AutoGuardGS = GUARD_CFG },
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "cross60", em = "em20", at = 3.0, keep = { 0, 110 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
        { id = "imm27_6", em = "em20", at = 8.0, keep = { 0, 111 }, entries = { D(27.6, 36.0) }, contact = { r = 0.03 } },
        { id = "low21_6", em = "em20", at = 12.0, keep = { 0, 112 }, entries = { D(21.6, 30.0) }, contact = { r = 0.0 } },
        { id = "imm22_4", em = "em20", at = 15.0, keep = { 0, 113 }, entries = { D(22.4, 31.0) }, contact = { r = 0.10 } },
        { id = "cross28_5", em = "em20", at = 20.0, keep = { 0, 114 }, entries = { D(28.5, 36.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 4, pt = { catch = 4 }, dbg_max = 0 },
}

-- 配置迁移（V16 第 2.7 节，沿用 V15 第 9 节的写法）：cfg_ver 不是 ≥3 的数（没有这个键、2、字符串）的配置提前量一律迁成 28、
-- 写 DBG cfg_upgrade。run.lua 的 check_release 另查 DBG cfg_upgrade 恰好在迁移时出现、存配置带 cfg_ver=3
M[#M + 1] = {
    name = "v15_upgrade28",
    smoke = false,
    desc = "rc 留下的配置（五个键、parry_lead=28、没有 cfg_ver）：旧键忽略，迁成 28（HDR lead=28、按 28 放刀、"
        .. "DBG cfg_upgrade from=28 to=28），存配置只剩三个键加 cfg_ver=3",
    duration = 10,
    config = rc_written(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 115 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_events = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v151_upgrade26",
    smoke = false,
    desc = "v1.5 存的配置（三个键、parry_lead=26、没有 cfg_ver）：迁成 28（HDR lead=28、按 28 放刀、DBG cfg_upgrade）",
    duration = 10,
    config = v15_written(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 116 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_events = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v151_upgrade35",
    smoke = false,
    desc = "v1.5 存的配置里 parry_lead=35（没有 cfg_ver）：「一律」迁成 28，不看原来是多少",
    duration = 10,
    config = v15_written({ parry_lead = 35 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 117 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_events = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v151_keep26",
    smoke = false,
    desc = "v1.5.1 自己存的配置（cfg_ver=2）里 parry_lead=26：v1.6 起滑块的含义变成真实剩余帧，cfg_ver 不是 ≥3 一律迁成 28"
        .. "（V16 第 8.5 节：v151_keep26 这类场景现在也迁移），DBG cfg_upgrade from=26 to=28",
    duration = 10,
    config = v151_written({ parry_lead = 26 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 117 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_events = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v15_clamp_hi",
    smoke = false,
    desc = "配置（cfg_ver=3）parry_lead=50 夹到 45；auto_parry 写成字符串、debug_log 写成数字（类型不对）都忽略、用默认值",
    duration = 10,
    config = { AutoParryGS = { auto_parry = "yes", parry_lead = 50, debug_log = 1, cfg_ver = 3 }, AutoGuardGS = GUARD_CFG },
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 118 }, entries = { D(62.0, 70.0) }, contact = { r = 0.0 } },
    },
    expect = { rc = "oracle", fires = 1, dbg_max = 0 },
}

M[#M + 1] = {
    name = "v15_clamp_lo",
    smoke = false,
    desc = "配置（cfg_ver=3）parry_lead=21：夹到 v1.6 的下限 23（v1.5 是 22、rc 是 20）；L=23 时 hs 正好 22.0 的条目放刀",
    duration = 10,
    config = cfg({ parry_lead = 21 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "imm22", em = "em20", at = 3.0, keep = { 0, 119 }, entries = { D(22.0, 30.0) }, contact = { r = 0.10 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 } },
}

-- 联机副本闸门（V15 第 4 节）：副本怪的条目不进候选（计 replica，每登记一次计一次），但长窗口照样否决；
-- 同一帧里主机怪的条目照常放（FIRE 选的是主机怪的条目，神谕逐帧核对）
M[#M + 1] = {
    name = "v15_replica",
    smoke = false,
    desc = "联机副本（get_IsMaster=false）的怪不放刀、它的长窗口照样否决主机怪的条目；同时有副本和主机的条目时放主机的",
    duration = 24,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20R, em1 = EM1 },
    attacks = {
        { id = "rep1", em = "em20", at = 3.0, keep = { 0, 120 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "mst1", em = "em1", at = 8.0, keep = { 0, 121 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "rep_long", em = "em20", at = 13.0, keep = { 0, 122 }, entries = { D(40.0, 150.0) }, contact = false,
            events = { { at = 16.5, op = "finish" } } },
        { id = "mst_vetoed", em = "em1", at = 13.2, keep = { 0, 123 }, entries = { D(35.0, 45.0) }, contact = { r = 0.0 } },
        { id = "rep_mix", em = "em20", at = 19.0, keep = { 0, 124 }, entries = { D(60.0, 68.0) }, contact = false },
        { id = "mst_mix", em = "em1", at = 19.0, keep = { 0, 125 }, entries = { D(64.0, 72.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, vetoes_min = 1, veto_frames_min = 1, stat = { replica = 3, vetoes = 1 } },
}

-- get_IsMaster 抛错（错误文本带非 UTF-8 字节）：master 模块标黄一次并停用，之后登记的都按主机处理、计 fail-open。
-- 怪物其实是副本：照样放刀才说明真的 fail-open 了（换成主机怪就分不出来）
M[#M + 1] = {
    name = "v15_master_throw",
    smoke = false,
    desc = "副本怪 + get_IsMaster 抛错：标黄一次（ERR mod=master）、按主机处理照常放刀，fail-open 每次登记计一次",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20R },
    faults = { { key = "EnemyContextHolder.get_IsMaster", mode = "throw", msg = GBK_MSG, scripts = { AutoParryGS = true } } },
    oracle_master_failopen = true,
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 126 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "a2", em = "em20", at = 9.0, keep = { 0, 127 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 2, pt = { catch = 2 }, stat = { failopen = 2 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "master", min = 1, max = 1 } },
    },
}

-- 读取链上取到 nil（发送者对象拿不到）：按主机处理、计 fail-open，不算错误（不写 ERR、不停用，下次登记照样再读）
M[#M + 1] = {
    name = "v15_master_nil",
    smoke = false,
    desc = "副本怪 + get_SendGameObject 返回 nil：按主机处理照常放刀，不写 ERR，fail-open 每次登记计一次",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20R },
    faults = { { key = "ace.cGameMessage.get_SendGameObject", mode = "nil", scripts = { AutoParryGS = true } } },
    oracle_master_failopen = true,
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 128 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "a2", em = "em20", at = 9.0, keep = { 0, 129 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 }, stat = { failopen = 2 } },
}

-- 逐条读取一直出错（V15 第 3 节）：closest 兜底已删 → 一刀都不放；items 第一次出错标黄、只报一次（之后照样每帧重读、
-- 不再报）；readerr 每个结果（每次登记）计一次。两个脚本都读坏：探针退回 closest、标黄
M[#M + 1] = {
    name = "v15_items_throw",
    smoke = false,
    desc = "List.get_Item 一直抛错：不放刀（没有 closest 兜底），ERR mod=items 只标黄一次，readerr 按结果计",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "DetectedDataList.get_Item", mode = "throw" } },
    oracle_items_fail = true,
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 130 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "a2", em = "em20", at = 9.0, keep = { 0, 131 }, closest = 1, entries = { D(50.0, 58.0) }, contact = { r = 0.0 } },
    },
    expect = {
        rc = "oracle", fires = 0, requests = 0, stat = { readerr = 2 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "items", min = 1, max = 1 },
            { tag = "APCal", level = "yellow", max = 99 } },
    },
}

-- 逐条读取只出错一次：标黄但不停用逐条读取（停用就再也放不了刀），下一帧起照常放
M[#M + 1] = {
    name = "v15_items_once",
    smoke = false,
    desc = "List.get_Item 只抛错一次：标黄一次但不停用，之后照常放刀；readerr=1",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "DetectedDataList.get_Item", mode = "throw", max = 1, scripts = { AutoParryGS = true } } },
    -- 唯一那次抛错落在登记后的第一个帧回调（t≈3.011）：那一帧 v1.6 读不到条目、不记 X0/A0（V16 第 2.3 节），
    -- 下一帧才记，FIRE 的 A0 是 61.33 而不是 62
    oracle_items_fail = { em20 = { 3.005, 3.016 } },
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 132 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "a2", em = "em20", at = 9.0, keep = { 0, 133 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 2, pt = { catch = 2 }, stat = { readerr = 1 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "items", min = 1, max = 1 } },
    },
}

-- 只有一只怪的结果读不出条目，同一帧另一只怪的结果读到一半出错（帧逻辑红，单条预告丢掉）：
--   ① 两条 ERR 同一帧，都进 JSON（STAT 的错误数对得上），日志排队补写；10 s 内只有 1 次核心错误，不标红；
--   ② 读不出条目的结果本帧既不放刀也不否决（V15 只写了「这个结果本帧不参与」，实现取「也不否决」）：
--      它的长窗口条目挡不住主机怪的放刀；别的结果照常放刀
M[#M + 1] = {
    name = "v15_items_partial",
    smoke = false,
    desc = "em20 的条目一直读不出（黄）+ 同一帧 em1 的预告读到一半出错（帧逻辑红）：两条 ERR 都进 JSON；"
        .. "em20 的长窗口不参与否决，em1 重发的预告照常放刀",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    faults = {
        { key = "DetectedDataList.get_Item", mode = "throw", where = of_em("em20"), scripts = { AutoParryGS = true } },
        { key = "AttackAreaResult.get_TargetCharacter", mode = "throw", where = of_em("em1"), from = 3.005, max = 1,
            scripts = { AutoParryGS = true } },
    },
    oracle_items_fail = { em20 = true },
    attacks = {
        { id = "unreadable_long", em = "em20", at = 3.0, keep = { 0, 134 }, entries = { D(40.0, 150.0) }, contact = false,
            events = { { at = 6.0, op = "finish" } } },
        { id = "dropped", em = "em1", at = 3.0, keep = { 0, 135 }, entries = { C(60.0, 68.0) }, contact = false },
        { id = "after_drop", em = "em1", at = 3.2, keep = { 0, 136 }, entries = { D(35.0, 45.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { readerr = 1 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "items", min = 1, max = 1 },
            { tag = "AutoParryGS", level = "red", mod = "frame", min = 1, max = 1 } },
    },
}

-- 写出时机不变（V15 第 2 节、CONTRACT 2 节）：「写出数据」按钮立刻写一份（why=button，先补一行 STAT）；
-- 空闲（不在 (2,21)~(2,29)、没有未结束的放刀）且距上次写出 ≥60 s 写一份（idle）；Reset 写最后一份（reset）。
-- STAT 每 60 s 一行（从上一行 STAT 算起）：20 s 按钮、80 s 定时、100 s Reset，共 3 行。50 s 后玩家不再按住，才有空闲帧
M[#M + 1] = {
    name = "v15_json",
    smoke = false,
    desc = "JSON 写出时机：按钮（button）、空闲 ≥60 s（idle）、Reset（reset）三份；STAT 按钮、定时、Reset 共 3 行",
    duration = 100,
    config = cfg(),
    player = auto({ stop_at = 50.0 }),
    monsters = { em20 = EM20 },
    attacks = (function()
        local list = {}
        for i = 1, 7 do
            list[i] = { id = "j" .. i, em = "em20", at = 3.0 + (i - 1) * 8.0, keep = { 0, 150 + i },
                entries = { D(62.0, 70.0) }, contact = { r = 0.03 } }
        end
        return list
    end)(),
    ui = { { t = 20.0, kind = "button", match = "写出数据", script = "AutoParryGS" } },
    expect = {
        rc = "oracle", fires = 7, pt = { catch = 7 }, rc_counts = { STAT = 3 },
        json_why = { AutoParryGS = { "button", "idle", "reset" } },
    },
}

-- 菜单改启用开关和提前量（V15 第 4 节）：每次真的改了写一行 CFG（总写，不受 debug_log 控制），值没变不写；
-- 滑块改动从下一帧起生效（之后的 FIRE 用新 L，神谕逐帧按新 L 核对）；滑块值夹到 45；关开关当场释放全部预告。
-- 调试日志关着（发布版默认）：CFG 照写，DBG 一行都没有（debug_log 开着时的 CFG 见 ui_toggle）
M[#M + 1] = {
    name = "v15_cfg",
    smoke = false,
    desc = "调试日志关着：滑块 28→26、开关关再开、滑块再拖到 26（没变）和 50（夹到 45）：CFG 恰好 4 行、没有 DBG；"
        .. "FIRE 的 L 依次 28/26/26/45",
    duration = 25,
    config = cfg({ debug_log = false }),
    player = auto(),
    monsters = { em20 = EM20 },
    ui = {
        { t = 6.0, kind = "slider", match = "提前量", value = 26, script = "AutoParryGS", cfg_key = "parry_lead" },
        { t = 12.0, kind = "checkbox", match = "启用", value = false, script = "AutoParryGS", cfg_key = "auto_parry" },
        { t = 14.0, kind = "checkbox", match = "启用", value = true, script = "AutoParryGS", cfg_key = "auto_parry" },
        { t = 18.5, kind = "slider", match = "提前量", value = 26, script = "AutoParryGS", cfg_key = "parry_lead" },
        { t = 19.0, kind = "slider", match = "提前量", value = 50, script = "AutoParryGS", cfg_key = "parry_lead" },
    },
    attacks = {
        { id = "at28", em = "em20", at = 2.5, keep = { 0, 137 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "at26", em = "em20", at = 8.0, keep = { 0, 138 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        -- 关开关时这条预告还在跟踪（hs 还没到 L）：必须当场释放；之后穿过 [22, 26] 时开关关着，不放
        { id = "in_flight_off", em = "em20", at = 11.7, keep = { 0, 139 }, entries = { D(80.0, 88.0) }, contact = { r = 0.0 } },
        { id = "at26_on", em = "em20", at = 16.0, keep = { 0, 140 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "at45", em = "em20", at = 21.0, keep = { 0, 141 }, entries = { D(62.0, 70.0) }, contact = { r = 0.0 } },
    },
    expect = {
        rc = "oracle", fires = 4, no_requests_between = { { 12.02, 14.0 } }, dbg_max = 0,
        release_all_at = { { t = 12.02, what = "菜单关掉自动放刀", script = "AutoParryGS" } },
    },
}

-- ---------- 审查第 2 轮后补的 v1.5 场景 ----------

-- 核心模块 10 s 内出错 3 次标红、但不是帧逻辑连续出错：只有 RED why=3in10s，不自停，之后照常放刀；菜单照样显示红色
-- 出错提示（check_v15）。钉住 RED_COUNT=3、消息钩子是核心模块、红色提示不只在自停时显示
M[#M + 1] = {
    name = "v15_red_msg",
    smoke = false,
    desc = "预告消息钩子里 get_AttackAreaResult 抛错 3 次（3 条 CAUTION 预告）：10 s 内第 3 次标红（RED 3in10s）但不自停，"
        .. "之后的 DANGER 照常放刀",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "app.game_message.cMsgEmAttackAreaResult.get_AttackAreaResult", mode = "throw", max = 3, from = 2.0,
        scripts = { AutoParryGS = true } } },
    attacks = {
        { id = "c1", em = "em20", at = 2.5, keep = { 0, 160 }, entries = { C(100.0, 110.0) }, contact = false, finish = 4.0 },
        { id = "c2", em = "em20", at = 4.5, keep = { 0, 161 }, entries = { C(100.0, 110.0) }, contact = false, finish = 6.0 },
        { id = "c3", em = "em20", at = 6.5, keep = { 0, 162 }, entries = { C(100.0, 110.0) }, contact = false, finish = 8.0 },
        { id = "d1", em = "em20", at = 9.0, keep = { 0, 163 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { errors = 3, red = 3 },
        err = { { tag = "AutoParryGS", level = "red", mod = "msg", min = 3, max = 3 } },
        red = { "AutoParryGS" }, red_why = { AutoParryGS = { "3in10s" } },
    },
}

-- 过滤字段读取失败（V16 第 3.2 节，v1.5.1 时是按通过放刀）：候选侧读不准就不放（fail-closed），每条条目 SKIP why=fc、
-- fclosed + 1；报黄 filter 一次但不停用读取（每帧照读）。弹体只在候选侧读，否决侧不读，所以 failopen 不变
M[#M + 1] = {
    name = "v15_filter_throw",
    smoke = false,
    desc = "get_ShellIndex 一直抛错：v1.6 候选侧读不准就不放（SKIP fc、fclosed 每条一次），filter 标黄一次、不停用；"
        .. "弹体只在候选侧读，failopen 不变",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "app.AttackAreaResult.DetectedData.get_ShellIndex", mode = "throw", scripts = { AutoParryGS = true } } },
    attacks = {
        { id = "f1", em = "em20", at = 3.0, keep = { 0, 164 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "f2", em = "em20", at = 9.0, keep = { 0, 165 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 0, requests = 0, stat = { fclosed = 2, failopen = 0 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } },
    },
}

-- 另两种读不准：get_AttackParam 返回 nil（数据情况，不写 ERR）；_DamageType 读取抛错（filter 标黄一次）。v1.6：候选侧都不放
-- （SKIP fc）；否决侧读不到伤害类型 → 按不是抓取、每条计一次 failopen（V16 第 3.2 节「否决侧不变」）
M[#M + 1] = {
    name = "v15_filter_nil",
    smoke = false,
    desc = "第一招 get_AttackParam 返回 nil（不写 ERR），第二招 _DamageType 抛错（filter 标黄一次）：v1.6 都不放（SKIP fc，"
        .. "fclosed 2），否决侧 failopen 共 2",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = {
        { key = "app.AttackAreaResult.DetectedData.get_AttackParam", mode = "nil", to = 8.0, scripts = { AutoParryGS = true } },
        { key = "app.cAttackParamEm._DamageType", mode = "throw", from = 8.0, scripts = { AutoParryGS = true } },
    },
    attacks = {
        { id = "f1", em = "em20", at = 3.0, keep = { 0, 166 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "f2", em = "em20", at = 9.0, keep = { 0, 167 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 0, requests = 0, stat = { failopen = 2, fclosed = 2 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } },
    },
}

-- 预告跟踪 8 s 释放（TRACK_STALE）：hs=600 的预告只发一次消息、不重发；距消息 8 s rc 就放掉了，之后 hs 降进 [22,30]
-- 也看不到、不放刀（神谕同一口径）。这一招的 he 一直 ≥0，「全部 he<-30」那条释放规则盖不住它
M[#M + 1] = {
    name = "v15_stale",
    smoke = false,
    desc = "hs=600 的预告不重发消息：距消息 8 s 释放，9.5 s 后 hs 降进 [22,30] 时已不跟踪，不放刀",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "far", em = "em20", at = 2.0, keep = { 0, 168 }, entries = { D(600.0, 610.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 0, requests = 0 },
}

-- 「非空条目全部 he<-30 且距消息 ≥1 s」释放（PAST_HE、PAST_AGE）：一招早就打完了但结果没结束（finish=never），rc 放掉它；
-- 之后不发新消息就冒出 DANGER 条目 → rc 已经不跟踪、不放刀（神谕有状态：释放过的结果收到新消息才重新跟踪）。
-- 这一招离消息不到 8 s，「8 s 释放」盖不住它
M[#M + 1] = {
    name = "v15_past",
    smoke = false,
    desc = "结果没结束、条目全部 he<-30 后满 1 s 释放；之后不发消息冒出 DANGER（hs 60）：已释放、不放刀",
    duration = 12,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "past", em = "em20", at = 2.0, keep = { 0, 169 }, entries = { D(10.0, 15.0) }, contact = false,
            finish = "never", events = { { at = 4.5, op = "set_entries", entries = { D(60.0, 68.0) } } } },
    },
    expect = { rc = "oracle", fires = 0, requests = 0 },
}

-- JSON 只在空闲帧写（CONTRACT 2 写出时机①，V15 第 2 节「写出时机不变」）：不点按钮，60 s 计时到期时主角正在上捞斩的
-- 后续动作里；rc 要等回到 (1,14) 的空闲帧才写（run.lua 的 check_json_idle 核对写出那一帧的动作、有没有未结算的放刀）
M[#M + 1] = {
    name = "v15_json_busy",
    smoke = false,
    desc = "一直在打（每 6 s 一招）：60 s 计时到期时主角在接住后的 (2,28)/(2,29) 里，等回到 (1,14) 才写 idle",
    duration = 75,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = (function()
        local list = {}
        for i = 1, 11 do
            list[i] = { id = "b" .. i, em = "em20", at = 3.0 + (i - 1) * 6.0, keep = { 0, 170 + i },
                entries = { D(62.0, 70.0) }, contact = { r = 0.03 } }
        end
        return list
    end)(),
    expect = { rc = "oracle", fires = 11, pt = { catch = 11 }, json_why = { AutoParryGS = { "idle", "reset" } } },
}

-- 菜单「清零统计」「调试日志」（V15 第 6 节）：清零后 STAT 从 0 重新计（只算清零之后的一刀）、不出错、照常放刀；
-- 切调试日志不写 CFG，DBG 随开关出现（关着时的动作 ID 断档不写 DBG，打开之后的写 no_action / action_back）
M[#M + 1] = {
    name = "v15_menu_misc",
    smoke = false,
    desc = "菜单点「清零统计」（之后 STAT 只算清零后的 1 刀）、打开「调试日志」（不写 CFG；打开前的动作 ID 断档没有 DBG，"
        .. "打开后的有）",
    duration = 16,
    config = cfg({ debug_log = false }),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = {
        { key = "HunterCharacter.get_BaseActionController", mode = "nil", from = 5.0, to = 5.2, scripts = { AutoParryGS = true } },
        { key = "HunterCharacter.get_BaseActionController", mode = "nil", from = 13.5, to = 13.7,
            scripts = { AutoParryGS = true } },
    },
    oracle_skip = { { 5.0, 5.25 }, { 13.5, 13.75 } },
    ui = {
        { t = 6.0, kind = "button", match = "清零统计", script = "AutoParryGS" },
        { t = 7.0, kind = "checkbox", match = "调试日志", value = true, script = "AutoParryGS", cfg_key = "debug_log" },
    },
    attacks = {
        { id = "m1", em = "em20", at = 2.0, keep = { 0, 185 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "m2", em = "em20", at = 9.0, keep = { 0, 186 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 2, pt = { catch = 2 }, stat = { fires = 1, catches = 1 },
        dbg_events = { "no_action", "action_back" }, dbg_max = 2,
    },
}

-- 完整菜单出错（ui 标黄）后只画简化菜单：状态、「写出数据」、最近的错误（和 rc1 的 draw_menu_min 一样）。
-- 简化之后「写出数据」照样能用（why=button），不必靠 Reset 收尾，也看得到错误文本
M[#M + 1] = {
    name = "v15_ui_degrade",
    smoke = false,
    desc = "菜单的提前量滑块抛错一次：ui 标黄、之后画简化菜单；简化菜单里点「写出数据」照样写出（why=button），"
        .. "看得到错误文本",
    duration = 12,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "imgui.slider_int", mode = "throw", max = 1, from = 4.0, scripts = { AutoParryGS = true } } },
    ui = { { t = 6.0, kind = "button", match = "写出数据", script = "AutoParryGS" } },
    attacks = {
        { id = "u1", em = "em20", at = 2.0, keep = { 0, 187 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 1, pt = { catch = 1 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "ui", min = 1, max = 1 } },
        json_why = { AutoParryGS = { "button", "reset" } },
    },
}

-- 帧逻辑自停时（V15 第 2 节）：还在等结局的那一刀当场结算（每个 FIRE 都有 RES，NOCATCH）；自停后不再读主角，
-- 动作不能停在最后读到的 (2,23) —— 否则之后永远等不到空闲帧、不再自动写出 JSON
M[#M + 1] = {
    name = "v15_stop_idle",
    smoke = false,
    desc = "空放进 (2,23) 后读动作 ID 一直抛错：1.5 s 容忍后帧逻辑连续 30 帧出错自停，当场补 RES NOCATCH；"
        .. "自停后 60 s 计时到期照样空闲写出（idle）",
    duration = 75,
    config = cfg(),
    player = auto({ stop_at = 5.0 }),
    monsters = { em20 = EM20 },
    faults = { { key = "ActionController.get_CurrentActionID", mode = "throw", from = 4.0, scripts = { AutoParryGS = true } } },
    oracle_until = 4.0,
    attacks = {
        { id = "whiff_fault", em = "em20", at = 3.0, keep = { 0, 188 }, entries = { D(62.0, 70.0) }, contact = false },
    },
    -- 帧逻辑错误 30 条（STAT 和 JSON），日志只写前 20 条
    expect = {
        rc = "oracle", fires = 1, pt = { whiff = 1 }, no_requests_after = 4.0, stat = { errors = 30, red = 30 },
        err = { { tag = "AutoParryGS", level = "red", mod = "frame", min = 20, max = 20 } },
        red = { "AutoParryGS" }, red_why = { AutoParryGS = { "3in10s", "self_stop" } },
        json_why = { AutoParryGS = { "idle", "reset" } },
    },
}

-- Reset 收尾（CONTRACT 2.1「Reset 时把排队的一次写完」、第 1 节「不许静默吞错」）：最后一份 JSON 写盘失败时，那条
-- ERR mod=json 也要进日志 —— 先写 JSON、最后才把排队的 ERR 一次写完；0.5 s 前刚写过一行 ERR（限频 1 行/秒），
-- 顺序反了它就留在队列里随 Lua 状态一起销毁。之前点过「写出数据」，所以数据只丢 Reset 时的那一份
M[#M + 1] = {
    name = "v15_reset_json",
    smoke = false,
    desc = "Reset 时最后一份 JSON 写盘失败（0.5 s 前刚因 get_IsMaster 抛错写过一行 ERR）：写失败的 ERR mod=json 照样进日志",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = {
        { key = "EnemyContextHolder.get_IsMaster", mode = "throw", from = 9.4, scripts = { AutoParryGS = true } },
        { key = "json.dump_file", mode = "false", phase = "reset", path = "^AutoParryGS_", scripts = { AutoParryGS = true } },
    },
    ui = { { t = 6.0, kind = "button", match = "写出数据", script = "AutoParryGS" } },
    attacks = {
        { id = "r1", em = "em20", at = 2.0, keep = { 0, 190 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "late_msg", em = "em20", at = 9.5, keep = { 0, 191 }, entries = { C(100.0, 110.0) }, contact = false },
    },
    expect = {
        rc = "oracle", fires = 1, pt = { catch = 1 }, json_fail = { AutoParryGS = 1 },
        json_why = { AutoParryGS = { "button" } },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "master", min = 1, max = 1 },
            { tag = "AutoParryGS", level = "red", mod = "json", min = 1, max = 1 } },
    },
}

-- Reset Scripts 时还在等结局的那一刀（进 (2,23) 不到 1.3 s）：当场结算 RES NOCATCH（每个 FIRE 都有 RES，口径同 lose_hunter）
M[#M + 1] = {
    name = "v15_reset_pending",
    smoke = false,
    desc = "空放进 (2,23) 后 0.5 s 就 Reset：Reset 时补一行 RES NOCATCH（dt = Reset 那一刻距 FIRE）",
    duration = 4.1,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "pending", em = "em20", at = 3.0, keep = { 0, 189 }, entries = { D(62.0, 70.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 1 },
}

-- ---------- v1.5.1 场景（docs/autoparry/V15.md 第 9 节第 5 条） ----------
-- 抓取：条目的 DamageType ∈ {CATCH, CATCH_ZAKO, CATCH_SLINGER}（按名字读）。抓取永远不进候选；DANGER 抓取条目
-- hs ≤ H_veto 且 he ≥ 0 → 本帧否决，和长窗口同一个 streak 口径，VETO 追加 why=long|grab（取触发 hs 最小的那条）。
-- 抓取的攻击打到刀上也抵消不了（第 2 轮 em27 实测；game_sim 的 parryable），放了刀就是挨抓。
-- 神谕按同一规则逐帧算，run.lua 另按神谕逐行核对 VETO 的 why 和 hs

-- 抓取单独来：三种抓取各来一次，都不放、各一个否决 streak（why=grab，三个名字都读到了）；之后的普通攻击照常放、接住
M[#M + 1] = {
    name = "v151_grab_alone",
    smoke = false,
    desc = "CATCH / CATCH_ZAKO / CATCH_SLINGER 各来一招（不放刀、蓄力中挨抓；霸体挡不挡得住抓取未验证，第 2 轮那次"
        .. "霸体开着也被抓了）：都不放，VETO why=grab 各一行；之后的普通攻击照常放刀接住",
    duration = 22,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "g_catch", em = "em20", at = 3.0, keep = { 0, 200 }, dmg = "CATCH", entries = { D(62.0, 70.0, { dmg = "CATCH" }) },
            contact = { r = 0.03 } },
        { id = "g_zako", em = "em20", at = 8.0, keep = { 0, 201 }, dmg = "CATCH_ZAKO",
            entries = { D(62.0, 70.0, { dmg = "CATCH_ZAKO" }) }, contact = { r = 0.03 } },
        { id = "g_slinger", em = "em20", at = 13.0, keep = { 0, 202 }, dmg = "CATCH_SLINGER",
            entries = { D(62.0, 70.0, { dmg = "CATCH_SLINGER" }) }, contact = { r = 0.03 } },
        { id = "normal_after", em = "em20", at = 18.0, keep = { 0, 203 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, veto_why = { "grab", "grab", "grab" }, stat = { vetoes = 3 } },
}

-- 抓取即将到来（hs ≤ 90、he ≥ 0）时，另一条普通条目进 [L_min, L] 也不放：同一结果的两段（c1）、另一只怪（c2）；
-- 抓取还在 1.5 s 视野外（hs≈114 > 90）不否决、照常放（c3，H_veto 对抓取一样生效）；同一个 hs 既是长窗口又是抓取 → why=long
-- （c4，抓取排在前面也记 long）；抓取的 hs 比长窗口小 → why=grab（c5，取 hs 最小的那条）
M[#M + 1] = {
    name = "v151_grab_veto",
    smoke = false,
    desc = "抓取在 1.5 s 内到来时普通条目进 [22,30] 也不放（同结果 / 跨怪）；视野外（hs>90）的抓取不否决、照常放；"
        .. "VETO why：同 hs 的长窗口和抓取记 long，抓取 hs 更小记 grab",
    duration = 31,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    attacks = {
        { id = "c1_same", em = "em20", at = 3.0, keep = { 0, 210 },
            entries = { D(50.0, 58.0), D(75.0, 85.0, { dmg = "CATCH" }) }, contact = { r = 0.03 } },
        { id = "c2_grab", em = "em20", at = 9.0, keep = { 0, 211 }, dmg = "CATCH_ZAKO",
            entries = { D(80.0, 90.0, { dmg = "CATCH_ZAKO" }) }, contact = false },
        { id = "c2_normal", em = "em1", at = 9.2, keep = { 0, 212 }, entries = { D(40.0, 48.0) }, contact = { r = 0.0 } },
        { id = "c3_far_grab", em = "em20", at = 15.0, keep = { 0, 213 }, dmg = "CATCH",
            entries = { D(130.0, 140.0, { dmg = "CATCH" }) }, contact = false },
        { id = "c3_normal", em = "em1", at = 15.1, keep = { 0, 214 }, entries = { D(40.0, 48.0) }, contact = { r = 0.03 } },
        { id = "c4_tie", em = "em20", at = 21.0, keep = { 0, 215 },
            entries = { D(50.0, 58.0, { dmg = "CATCH" }), D(50.0, 120.0) }, contact = false },
        { id = "c5_long", em = "em1", at = 27.0, keep = { 0, 216 }, entries = { D(70.0, 140.0) }, contact = false },
        { id = "c5_grab", em = "em20", at = 27.0, keep = { 0, 217 }, dmg = "CATCH",
            entries = { D(65.0, 73.0, { dmg = "CATCH" }) }, contact = false },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, veto_frames_min = 1, veto_why = { "grab", "grab", "long", "grab" },
        stat = { vetoes = 4 } },
}

-- 抓取 he<0 之后恢复放刀：A 同一个 [22,28] 窗口里先被正在进行的抓取否决（he 3 → 0），抓取一过（he<0）就放（晚触发，
-- R0≈26.3）；B 抓取打完（he<0、结果没结束）以后另一只怪的普通攻击照常放。两段否决都是 why=grab
M[#M + 1] = {
    name = "v151_grab_past",
    smoke = false,
    desc = "正在进行的抓取（he 3→0）否决到 he<0 为止，同一个区间里接着就放（晚触发）；抓取打完（he<0）但结果没结束，"
        .. "之后的普通攻击照常放",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    attacks = {
        { id = "a_grab", em = "em20", at = 3.0, keep = { 0, 220 }, dmg = "CATCH",
            entries = { D(-6.0, 3.0, { dmg = "CATCH" }) }, contact = false, finish = "never" },
        { id = "a_normal", em = "em1", at = 3.0, keep = { 0, 221 }, entries = { D(29.6, 37.6) }, contact = { r = 0.05 } },
        { id = "b_grab", em = "em20", at = 8.0, keep = { 0, 222 }, dmg = "CATCH_SLINGER",
            entries = { D(10.0, 20.0, { dmg = "CATCH_SLINGER" }) }, contact = { r = 0.0 }, finish = "never" },
        { id = "b_normal", em = "em1", at = 8.5, keep = { 0, 223 }, entries = { D(45.0, 53.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 }, veto_frames_min = 1, veto_why = { "grab", "grab" },
        stat = { vetoes = 2 } },
}

-- DamageType 读取抛错：否决侧按「不是抓取」处理（fail-open、每条计一次 failopen、没有 VETO，V16 第 3.2 节「否决侧不变」）；
-- 候选侧读不准就不放（v1.5.1 时抓取那刀照常放、挨抓）：两刀都 SKIP fc。filter 标黄一次、不停用
M[#M + 1] = {
    name = "v151_dmgtype_throw",
    smoke = false,
    desc = "_DamageType 读取一直抛错：否决侧按不是抓取（没有 VETO、failopen 每条一次）；v1.6 候选侧读不准不放"
        .. "（两刀都 SKIP fc，抓取那刀不再白挨抓）；filter 标黄一次",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "app.cAttackParamEm._DamageType", mode = "throw", scripts = { AutoParryGS = true } } },
    oracle_dmgtype_failopen = true,
    attacks = {
        { id = "grab_unseen", em = "em20", at = 3.0, keep = { 0, 230 }, dmg = "CATCH",
            entries = { D(62.0, 70.0, { dmg = "CATCH" }) }, contact = { r = 0.03 } },
        { id = "normal", em = "em20", at = 9.0, keep = { 0, 231 }, entries = { D(60.0, 68.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 0, requests = 0, stat = { failopen = 2, vetoes = 0, fclosed = 2 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } },
    },
}

-- 枚举名读不到就跳过（V15 第 9 节）：模拟游戏更新删了 CATCH_SLINGER 这个名字 —— rc 加载时总写一行 DBG grab_enum
-- （skipped=CATCH_SLINGER），不报错、不停用伤害类型读取：CATCH 照样否决；CATCH_SLINGER 条目 rc 认不出来、当普通攻击放刀
-- （游戏里它还是抓取，挨抓）。debug_log 关着也要有这一行
M[#M + 1] = {
    name = "v151_grab_enum",
    smoke = false,
    desc = "app.HitDef.DAMAGE_TYPE 里没有 CATCH_SLINGER：加载时 DBG grab_enum 一行、不报错；CATCH 照样否决，"
        .. "认不出的 CATCH_SLINGER 条目照常放刀（挨抓）",
    duration = 14,
    config = cfg({ debug_log = false }),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "field:app.HitDef.DAMAGE_TYPE.CATCH_SLINGER", mode = "missing" } },
    attacks = {
        { id = "catch", em = "em20", at = 3.0, keep = { 0, 240 }, dmg = "CATCH", entries = { D(62.0, 70.0, { dmg = "CATCH" }) },
            contact = { r = 0.03 } },
        { id = "slinger_unknown", em = "em20", at = 8.0, keep = { 0, 241 }, dmg = "CATCH_SLINGER",
            entries = { D(62.0, 70.0, { dmg = "CATCH_SLINGER" }) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { fail = 1 }, veto_why = { "grab" }, stat = { vetoes = 1 },
        dbg_events = { "grab_enum" }, dbg_max = 1 },
}

-- ---------- 第 1 轮审查后补的 v1.5.1 场景 ----------

-- 效果攻击的枚举名读不到（模拟游戏更新删了 QUAKE）：v1.6 报黄 filter_enum，任何条目都无法确认「不是效果攻击」，
-- 一刀都不放（V16 第 3.2、8.5 节：取代 v1.5.1 的 fail-open 预期）—— 认不出的 QUAKE、普通攻击都 SKIP fc；
-- 读到的抓取名照样否决（CATCH 一段 VETO grab），读到的 EAR 照样静默排除
M[#M + 1] = {
    name = "v151_effect_enum",
    smoke = false,
    desc = "app.HitDef.DAMAGE_TYPE 里没有 QUAKE：filter_enum 标黄一次，一刀都不放（QUAKE、普通攻击 SKIP fc）；"
        .. "CATCH 照样否决，EAR 照样不放；菜单写清缺 QUAKE",
    duration = 24,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "field:app.HitDef.DAMAGE_TYPE.QUAKE", mode = "missing" } },
    attacks = {
        { id = "catch", em = "em20", at = 3.0, keep = { 0, 250 }, dmg = "CATCH", entries = { D(62.0, 70.0, { dmg = "CATCH" }) },
            contact = { r = 0.03 } },
        { id = "ear", em = "em20", at = 8.0, keep = { 0, 251 }, dmg = "EAR", entries = { D(62.0, 70.0, { dmg = "EAR" }) },
            contact = false },
        { id = "quake_unknown", em = "em20", at = 13.0, keep = { 0, 252 }, dmg = "QUAKE",
            entries = { D(62.0, 70.0, { dmg = "QUAKE" }) }, contact = { r = 0.03 } },
        { id = "normal", em = "em20", at = 19.0, keep = { 0, 253 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 0, requests = 0, veto_why = { "grab" }, stat = { vetoes = 1, failopen = 0, fclosed = 2 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter_enum", min = 1, max = 1 } },
        menu_final = { "缺 QUAKE" },
    },
}

-- 同一个条目既是长窗口（he−hs=80 > 60）又是抓取：why 记 long（V15 第 9 节「同 hs 记 long」）。v151_grab_veto 的 c4 是
-- 两条分开的条目；这里钉住同一条目先记 long、再读出是抓取时不能被后到的 grab 覆盖
M[#M + 1] = {
    name = "v151_grab_long_entry",
    smoke = false,
    desc = "一条 DANGER 既是长窗口（he−hs=80）又是抓取：否决一段、不放刀，VETO why=long（同 hs 记 long）",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "long_grab", em = "em20", at = 3.0, keep = { 0, 260 }, dmg = "CATCH",
            entries = { D(70.0, 150.0, { dmg = "CATCH" }) }, contact = false },
    },
    expect = { rc = "oracle", fires = 0, veto_why = { "long" }, stat = { vetoes = 1 } },
}

-- 联机副本（get_IsMaster=false）的抓取照样否决（V15 第 9 节澄清，口径同长窗口）：副本怪的抓取正在来时，主机怪的
-- 普通条目进 [22,30] 也不放
M[#M + 1] = {
    name = "v151_grab_replica",
    smoke = false,
    desc = "联机副本怪的抓取（hs≤90、he≥0）正在来时，主机怪的普通条目进 [22,30] 也不放：VETO why=grab，replica 计 1",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20R, em1 = EM1 },
    attacks = {
        { id = "rep_grab", em = "em20", at = 3.0, keep = { 0, 261 }, dmg = "CATCH",
            entries = { D(80.0, 90.0, { dmg = "CATCH" }) }, contact = false },
        { id = "mst_normal", em = "em1", at = 3.2, keep = { 0, 262 }, entries = { D(40.0, 48.0) }, contact = { r = 0.0 } },
    },
    expect = { rc = "oracle", fires = 0, veto_frames_min = 1, veto_why = { "grab" }, stat = { vetoes = 1, replica = 1 } },
}

-- 只有 DANGER 的抓取条目才否决（V15 第 9 节，和长窗口一样只看 DANGER）：CAUTION 的抓取在 1.5 s 内也不否决，
-- 另一只怪的普通条目照常放
M[#M + 1] = {
    name = "v151_grab_caution",
    smoke = false,
    desc = "CAUTION 的抓取条目（hs=80）不否决：另一只怪的普通条目进 [22,30] 照常放刀接住，没有 VETO",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    attacks = {
        { id = "caution_grab", em = "em20", at = 3.0, keep = { 0, 263 }, dmg = "CATCH",
            entries = { { type = "CAUTION", hs = 80.0, he = 90.0, dmg = "CATCH" } }, contact = false },
        { id = "normal", em = "em1", at = 3.2, keep = { 0, 264 }, entries = { D(40.0, 48.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, veto_why = {}, stat = { vetoes = 0 } },
}

-- failopen 按 1.5 s 内到来或进行中的 DANGER 条目计，不只是候选（V15 第 9 节澄清，v1.6 否决侧不变）：_DamageType 一直
-- 抛错时，不进候选的长窗口条目（he−hs=80，只否决）也计一次；之后的普通条目再计一次（它在候选侧读不准，v1.6 不放：SKIP fc）
M[#M + 1] = {
    name = "v151_failopen_long",
    smoke = false,
    desc = "_DamageType 一直抛错：先来一条只否决的长窗口条目（VETO why=long，failopen 也计它），再来一招普通攻击（候选侧"
        .. "读不准，v1.6 不放、SKIP fc）；failopen 共 2，filter 标黄一次",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "app.cAttackParamEm._DamageType", mode = "throw", scripts = { AutoParryGS = true } } },
    oracle_dmgtype_failopen = true,
    attacks = {
        { id = "long_only", em = "em20", at = 3.0, keep = { 0, 265 }, entries = { D(70.0, 150.0) }, contact = false },
        { id = "normal", em = "em20", at = 9.0, keep = { 0, 266 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = {
        rc = "oracle", fires = 0, requests = 0, veto_why = { "long" }, stat = { failopen = 2, vetoes = 1, fclosed = 1 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } },
    },
}

-- 配置迁移的 DBG（V15 第 9 节澄清，V16 同一口径）：和别的调试行一样只在「调试日志」开着时写（这里关着：照样迁成 28、一行 DBG 都不写）；
-- from 记文件里的原值（run.lua 的 check_v15 逐行核对 from / to）：非整数按 %.1f、没有 parry_lead 键写 "-"
M[#M + 1] = {
    name = "v151_upgrade_nodbg",
    smoke = false,
    desc = "v1.5 存的配置（parry_lead=26、debug_log=false、没有 cfg_ver）：迁成 28 照常放刀，但一行 DBG 都不写",
    duration = 10,
    config = v15_written({ debug_log = false }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 267 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_max = 0 },
}

M[#M + 1] = {
    name = "v151_upgrade_frac",
    smoke = false,
    desc = "没有 cfg_ver 的配置里 parry_lead=27.5：迁成 28，DBG cfg_upgrade from=27.5 to=28",
    duration = 10,
    config = v15_written({ parry_lead = 27.5 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 268 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_events = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v151_upgrade_nolead",
    smoke = false,
    desc = "没有 cfg_ver、也没有 parry_lead 键的配置：照样算迁移（读到了配置文件），用 28，DBG cfg_upgrade from=- to=28",
    duration = 10,
    config = { AutoParryGS = { auto_parry = true, debug_log = true }, AutoGuardGS = GUARD_CFG },
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "a1", em = "em20", at = 3.0, keep = { 0, 269 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_events = { "cfg_upgrade" } },
}

-- ---------- v1.6 场景（docs/autoparry/V16.md 第 8.4 节） ----------
-- 每个 v1.6 场景（上面迁移过的旧场景也是）run.lua 都另查：神谕逐帧核对请求帧（E5c 的 Q、该接过滤、否决）、FIRE 新字段
-- （C1/Cf/mf/nchg/dX/A0/Q0/Qp/Qe1/vq）、UVIEW、SKIP、RES 的 to、STAT 23 个字段（新字段默认取神谕）、HDR、存配置 cfg_ver=3、
-- 菜单、引用记账（真实模型：不许手动 release、DEAD_OBJECT = 0、Reset 后不泄漏、持有时长）。下面只写各场景的要点。

-- 设了速度的怪（core = C）：攻击按名义进度到达，C 按 V16 第 2.2 节从登记后第一个帧回调起每帧读
local function EMC(C, over)
    local m = { emid = 160, sysidx = 7, cls = "app.Em0160_00Action", go_name = "Em0160_00_0_9437184_21",
        pos = { x = -1100.25, y = 56.39, z = 523.4 }, core = C }
    for k, v in pairs(over or {}) do m[k] = v end
    return m
end
local EM1C = { emid = 0, sysidx = 4, cls = "app.Em0001_00Action", go_name = "Em0001_00_0_7471104_13",
    pos = { x = -1096.80, y = 56.39, z = 521.40 }, core = 1.0 }

-- ---- 时机：E5c ----

-- 1. C 恒为 1.134、A = 150：Q = A/m − 已过帧数，在 Q 进 [22, 28] 的第一帧放（这时原始 hs ≈ 45，v1.5.1 还不会放），接住。
-- hidden = 1.3：calcMotionSpeedTotal 返回 1.474，误用总速度的实现放刀帧会错
M[#M + 1] = {
    name = "v16_e5c_const",
    smoke = false,
    desc = "C 恒 1.134、A=150：Q 进 [22,28] 的第一帧放（原始 hs≈45），接住；FIRE nchg=0、Qe1=Q0；calcMotionSpeedTotal 含隐藏因子 1.3",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.134, { hidden = 1.3 }) },
    attacks = {
        { id = "e1", em = "em27", at = 3.0, keep = { 0, 82 }, entries = { D(150.0, 158.0) }, contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 },
        fire_props = { { nchg = 0, qe1_q0 = true, r0_gt = 40, C1 = 1.134, mf = 1.134, A0 = 150.0 } } },
}

-- 2. 存活期间 C 1.025 → 1.076（仿 (0,131) 接替链）：X 按帧累加、nchg = 1、Q 在切换那一帧跳变；Qe1 ≠ Q0
M[#M + 1] = {
    name = "v16_e5c_change",
    smoke = false,
    desc = "存活期间 C 1.025→1.076（仿 (0,131) 接替链）：X 按帧累加、nchg=1、放刀帧按神谕；Qe1≠Q0，接住",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC({ { 0, 1.025 }, { 3.6, 1.076 } }) },
    attacks = {
        { id = "chain", em = "em27", at = 3.0, keep = { 0, 131 }, entries = { D(120.0, 128.0) }, contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, fire_props = { { nchg = 1, qe1_q0 = false, C1 = 1.025, mf = 1.076 } } },
}

-- 3. C 在发消息的那一帧按招切换（1.0 → 1.2，切换在消息钩子之后）：C1 必须是下一帧帧回调读到的 1.2，钩子时刻的 1.0 不能出现
M[#M + 1] = {
    name = "v16_c_hook_old",
    smoke = false,
    desc = "C 在发消息那一帧切换（钩子里还是旧值 1.0）：FIRE 的 C1 = 下一帧帧回调读到的 1.200",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.0) },
    attacks = {
        { id = "switch", em = "em27", at = 3.0, keep = { 0, 79 }, core = 1.2, entries = { D(120.0, 128.0) },
            contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, fire_props = { { C1 = 1.2, mf = 1.2, nchg = 0 } } },
}

-- 4. C = 0.92（疲劳）→ m = max(1, C) = 1：放刀时刻就是 v1.5.1 在 L = 28 时的时刻（Q = hs）；攻击比 Q 预计的晚到，接触落在窗口后段
M[#M + 1] = {
    name = "v16_c_below1",
    smoke = false,
    desc = "C=0.92：m 按 1，放刀时刻同 v1.5.1@28（Q=hs）；C1=0.920、mf=1.000；攻击晚到、接触落在窗口后段仍接住",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(0.92) },
    attacks = {
        { id = "tired", em = "em27", at = 3.0, keep = { 0, 76 }, entries = { D(100.3, 108.3) }, contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, fire_props = { { C1 = 0.92, mf = 1.0, dX = 0.0, qe1_q0 = true } } },
}

-- 5. 首帧 findEnemy 返回 nil：这个结果永不放刀（之后读得到也不放；它后面那条普通条目进窗口时 v1.5.1 式实现会放），
-- 但它的长窗口条目照样否决另一只怪；speedfail = 1。之后另一招照常放刀接住
M[#M + 1] = {
    name = "v16_c_first_fail",
    smoke = false,
    desc = "首帧找不到怪（findEnemy=nil）：这个结果永不放刀（后面读得到也不放），长窗口条目照样否决另一只怪；speedfail=1",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.1), em1 = EM1, em20 = EM20 },
    attacks = {
        { id = "nofire", em = "em27", at = 3.0, keep = { 0, 107 },
            entries = { D(70.0, 150.0), D(230.0, 238.0) }, contact = false,
            speed_fault = { { from = 0.0, to = 0.02, mode = "find_nil" } } },
        { id = "vetoed", em = "em1", at = 3.1, keep = { 0, 12 }, entries = { D(40.0, 48.0) }, contact = false },
        { id = "normal", em = "em20", at = 10.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, veto_why = { "long" }, veto_frames_min = 1,
        stat = { speedfail = 1 }, dbg_events = { "speed_fail" } },
}

-- 6. 中途几帧 CoreState 抛错：沿用上一帧的 m 照常放刀；speedhold = 失败帧数；第一次抛错报黄 speed；不进 frame 的红计数、不自停
M[#M + 1] = {
    name = "v16_c_mid_fail",
    smoke = false,
    desc = "中途约 5 帧 CoreState 抛错：沿用 m 照常放刀接住；speedhold=失败帧数（神谕）；speed 报黄一次，不算帧逻辑错误",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.1) },
    attacks = {
        { id = "hold", em = "em27", at = 3.0, keep = { 0, 125 }, entries = { D(120.0, 128.0) }, contact = { g = 0.03 },
            speed_fault = { { from = 0.5, to = 0.555, mode = "throw", msg = "mock: CoreState threw" } } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { speedhold = { min = 4, max = 6 }, red = 0 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "speed", min = 1, max = 1 } } },
}

-- 7. C 依次为 NaN、0、3.0：都按读不到。前三招首帧就是这些值 → 永不放刀（speedfail 3）；第四招中途各几帧 → 沿用 m（speedhold）
M[#M + 1] = {
    name = "v16_c_bad",
    smoke = false,
    desc = "CoreState 读到 NaN / 0 / 3.0 都按读不到：首帧就是坏值的三招不放（speedfail=3），中途是坏值的一招沿用 m 照常放刀",
    duration = 20,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.1) },
    attacks = {
        { id = "nan", em = "em27", at = 3.0, keep = { 0, 85 }, entries = { D(90.0, 98.0) }, contact = false,
            speed_fault = { { from = 0.0, to = 0.02, mode = "nan" } } },
        { id = "zero", em = "em27", at = 6.0, keep = { 0, 86 }, entries = { D(90.0, 98.0) }, contact = false,
            speed_fault = { { from = 0.0, to = 0.02, mode = "value", value = 0.0 } } },
        { id = "three", em = "em27", at = 9.0, keep = { 0, 87 }, entries = { D(90.0, 98.0) }, contact = false,
            speed_fault = { { from = 0.0, to = 0.02, mode = "value", value = 3.0 } } },
        { id = "mid", em = "em27", at = 13.0, keep = { 0, 88 }, entries = { D(120.0, 128.0) }, contact = { g = 0.03 },
            speed_fault = { { from = 0.3, to = 0.33, mode = "nan" }, { from = 0.4, to = 0.43, mode = "value", value = 0.0 },
                { from = 0.5, to = 0.53, mode = "value", value = 3.0 } } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { speedfail = 3, speedhold = { min = 6 } } },
}

-- 8. 连续 5 个新结果首帧都读不到 → 报黄（ERR speed first_frame_fail_x5）、菜单「速度读不到，已停止自动放刀」；
-- 第 6 个读得到 → 放刀，状态行改为「速度曾读不到（n 个预告没放刀），已恢复」。
-- 审查补充（V16 第 2.5 节「计数清零」，tests-analysis #5 第 2 条）：恢复之后再来一个首帧读不到的结果（f7）：连续计数从 0 重新
-- 数（只到 1），不再报黄、状态行仍是「已恢复」。恢复时不清零的实现会第二次报黄、状态行又变回「已停止」
M[#M + 1] = (function()
    local attacks = {}
    for i = 1, 5 do
        attacks[#attacks + 1] = { id = "f" .. i, em = "em27", at = 2.0 + (i - 1) * 1.5, keep = { 0, 90 + i },
            entries = { C(150.0, 160.0) }, contact = false, finish = 2.0 + (i - 1) * 1.5 + 1.0,
            speed_fault = { { from = 0.0, to = 0.02, mode = "find_nil" } } }
    end
    attacks[#attacks + 1] = { id = "ok6", em = "em27", at = 11.0, keep = { 0, 96 }, entries = { D(90.0, 98.0) },
        contact = { g = 0.03 } }
    attacks[#attacks + 1] = { id = "f7", em = "em27", at = 14.0, keep = { 0, 97 }, entries = { C(150.0, 160.0) },
        contact = false, finish = 15.0, speed_fault = { { from = 0.0, to = 0.02, mode = "find_nil" } } }
    return {
        name = "v16_c_fail5",
        smoke = false,
        desc = "连续 5 个新结果首帧都读不到 C：报黄 speed（first_frame_fail_x5）、菜单「速度读不到，已停止自动放刀」；"
            .. "第 6 个读得到照常放刀，状态行改成「已恢复」；恢复后再有 1 个读不到：不再报黄、仍是「已恢复」",
        duration = 16,
        config = cfg(),
        player = auto(),
        monsters = { em27 = EMC(1.1) },
        attacks = attacks,
        expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { speedfail = 6 },
            err = { { tag = "AutoParryGS", level = "yellow", mod = "speed", min = 1, max = 1 } },
            menu_seen = { "速度读不到，已停止自动放刀" }, menu_final = { "速度曾读不到", "已恢复" },
            menu_absent = { "自动放刀照常" } },
    }
end)()

-- 9. 一只怪两个结果 + 另一只怪：每帧每只怪 findEnemy 只调一次（同一帧按 SystemIndex 缓存），跟踪中的结果每帧都读 C
M[#M + 1] = {
    name = "v16_cache",
    smoke = false,
    desc = "em27 两个同时活着的结果 + em1 一个：同一帧每只怪 findEnemy 至多一次；跟踪着的每一帧都读（不论在不在蓄力：3.6 s 才按住，"
        .. "之前的 0.6 s 结果已在跟踪、距消息不到 1 s）",
    duration = 10,
    config = cfg(),
    player = auto({ first_hold = 3.6 }),
    monsters = { em27 = EMC(1.1), em1 = EM1C },
    attacks = {
        { id = "a", em = "em27", at = 3.0, keep = { 0, 131 }, entries = { D(150.0, 158.0) }, contact = false },
        { id = "b", em = "em27", at = 3.05, keep = { 0, 132 }, entries = { D(110.0, 118.0) }, contact = { g = 0.03 } },
        { id = "c", em = "em1", at = 3.1, keep = { 0, 20 }, entries = { C(200.0, 210.0) }, contact = false, finish = 5.0 },
    },
    expect = { rc = "oracle", fires_min = 1, find_once = true },
}

-- 10. 结果在不蓄力时登记、不蓄力期间 C 变化（1.0 → 1.25），之后才按住蓄力：Q 用的是从登记起累加的 X
-- （v1.5.1 式「只在蓄力时读」会算错，放刀帧差约 6 帧，神谕抓得到）
M[#M + 1] = {
    name = "v16_noncharge",
    smoke = false,
    desc = "不蓄力时登记、不蓄力期间 C 1.0→1.25，4 s 才按住蓄力：Q 按从登记起累加的 X 算，放刀帧按神谕，接住",
    duration = 10,
    config = cfg(),
    player = auto({ first_hold = 4.0 }),
    monsters = { em27 = EMC({ { 0, 1.0 }, { 3.5, 1.25 } }) },
    attacks = {
        { id = "pre", em = "em27", at = 3.0, keep = { 0, 78 }, entries = { D(150.0, 158.0) }, contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, fire_props = { { nchg = 1 } } },
}

-- 11. 一帧 dt = 0.2 s（游戏把扣减钳在 0.1333 s = 8 帧，怪物也按同一个 dt 走）：X 按 hs 的递减累加，放刀帧与神谕一致
-- （按 os.clock 墙钟算的实现在这一帧会多算 4 帧）
M[#M + 1] = {
    name = "v16_hitch",
    smoke = false,
    desc = "倒数中途一帧 dt=0.2 s（扣减钳在 8 帧）：X 按 hs 的递减累加，放刀帧按神谕，接住",
    duration = 10,
    config = cfg(),
    player = auto(),
    hitches = { { at = 3.5, dt = 0.2 } },
    monsters = { em27 = EMC(1.15) },
    attacks = {
        { id = "h", em = "em27", at = 3.0, keep = { 0, 80 }, entries = { D(150.0, 158.0) }, contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, probe_kinds = { "HITCH" } },
}

-- 12. 条目在登记后 0.5 s 才出现（不发新消息）：X0、A0 记在它首次出现的那一帧（A0 = 110）
M[#M + 1] = {
    name = "v16_late_entry",
    smoke = false,
    desc = "DANGER 条目在登记后 0.5 s 才冒出来（hs=110）：X0、A0 记在它第一次出现的那一帧，FIRE 的 A0=110，接住",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.2) },
    attacks = {
        { id = "late", em = "em27", at = 3.0, keep = { 0, 83 }, entries = { C(200.0, 210.0) }, contact = { g = 0.03 },
            events = { { at = 3.5, op = "add_entry", spec = D(110.0, 118.0), trigger = true } } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, fire_props = { { A0 = 110.0, nchg = 0 } } },
}

-- 13. 时钟条目中途消失 → 换用另一条（不跳过）；之后某一帧条目全部换成新对象（两帧没有共同条目）→ 本帧不累加、clockskip + 1
M[#M + 1] = {
    name = "v16_clock_switch",
    smoke = false,
    desc = "时钟条目中途消失：换用另一条；之后条目整批换成新对象，那一帧两边没有共同条目 → 不累加、clockskip+1",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.15) },
    attacks = {
        { id = "clk", em = "em27", at = 3.0, keep = { 0, 84 }, entries = { C(150.0, 160.0), D(130.0, 138.0) },
            contact = { g = 0.03 },
            events = { { at = 3.3, op = "drop_entry", entry = 1 },
                { at = 3.6, op = "set_entries", entries = { D(94.0, 102.0) } } } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { clockskip = { min = 1 } } },
}

-- 14. A = 400、C = 1.2：Q 进窗口时原始 hs ≈ 95 > 90，照样放（不再有 hs ≤ 90 的外层门）
M[#M + 1] = {
    name = "v16_q_outer",
    smoke = false,
    desc = "A=400、C=1.2：Q 进 [22,28] 时原始 hs≈95 > 90，照样放刀接住（v1.5.1 的 hs≤90 外层门已去掉）",
    duration = 12,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.2) },
    attacks = {
        { id = "far", em = "em27", at = 3.0, keep = { 0, 79 }, entries = { D(400.0, 408.0) }, contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, fire_props = { { r0_gt = 90 } } },
}

-- 15. 两只怪各一条候选，原始 hs 小的那条 Q 反而大：em1（C=1）A=45、em27（C=1.4）A=60。长窗口条目一直否决到两条都在窗口里，
-- 否决一结束按 Q 取最小（em27 的，hs≈42），不是 hs 最小的 em1（hs≈27）；FIRE 的 ent / res 是 em27 的（神谕逐字段核对）
M[#M + 1] = {
    name = "v16_min_by_q",
    smoke = false,
    desc = "两条候选同时在窗口里：原始 hs 小的那条 Q 反而大，按 Q 取最小（em27，hs≈42），不按 hs（em1，hs≈27）",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em1 = EM1C, em27 = EMC(1.4), em20 = EM20 },
    attacks = {
        { id = "small_hs", em = "em1", at = 3.0, keep = { 0, 21 }, entries = { D(45.0, 53.0) }, contact = false },
        { id = "small_q", em = "em27", at = 3.0, keep = { 0, 81 }, entries = { D(60.0, 68.0) }, contact = { g = 0.03 } },
        { id = "long_now", em = "em20", at = 3.0, keep = { 0, 50 }, entries = { D(-43.5, 17.5) }, contact = false,
            finish = "never" },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, veto_why = { "long" }, veto_frames_min = 1,
        fire_props = { { r0_gt = 35 } } },
}

-- 16. 长窗口条目 Q ≤ 90 < hs（按真实时间已在 1.5 s 内、按原始 hs 还不在否决视野里）时另一条候选放刀：照样放
-- （否决仍按原始 hs），FIRE vq = 1、STAT vetoq = 1
M[#M + 1] = {
    name = "v16_vetoq",
    smoke = false,
    desc = "长窗口条目 Q≈88 ≤ 90 < hs≈138 时另一只怪的候选放刀：照样放（否决按原始 hs），vq=1、vetoq=1",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.5), em1 = EM1 },
    attacks = {
        { id = "long_q", em = "em27", at = 3.0, keep = { 0, 132 }, entries = { D(150.0, 211.0) }, contact = false },
        { id = "cand", em = "em1", at = 3.0, keep = { 0, 22 }, entries = { D(40.0, 48.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { vetoq = 1, vetoes = 0 }, fire_props = { { vq = 1 } } },
}

-- 17. 默认 L = 28 只在 [22, 28] 的第一帧请求；滑块拖到 23、45 各一次（各一行 CFG，下一帧起按新值）
M[#M + 1] = {
    name = "v16_window",
    smoke = false,
    desc = "默认 L=28 只在 [22,28] 第一帧请求；滑块拖到 23 和 45 各一次（CFG 各一行，下一帧起按新值）；FIRE 的 L 依次 28/23/45",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    ui = {
        { t = 6.0, kind = "slider", match = "提前量", value = 23, script = "AutoParryGS", cfg_key = "parry_lead" },
        { t = 11.0, kind = "slider", match = "提前量", value = 45, script = "AutoParryGS", cfg_key = "parry_lead" },
    },
    attacks = {
        { id = "w28", em = "em20", at = 3.0, keep = { 0, 142 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "w23", em = "em20", at = 8.0, keep = { 0, 143 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "w45", em = "em20", at = 13.0, keep = { 0, 144 }, entries = { D(62.0, 70.0) }, contact = { r = 0.0 } },
    },
    expect = { rc = "oracle", fires = 3, pt = { catch = 3 } },
}

-- ---- 该接过滤（V16 第 3 节） ----

-- 18. pb=1 的条目单独来：不放；SKIP why=pb 一行、excl = 1（对照：放了的话 game_sim 给 RECOIL）。之后普通攻击照常放
M[#M + 1] = {
    name = "v16_pb",
    smoke = false,
    desc = "_IsParryBreak=1 的条目：不放刀，SKIP why=pb、excl=1（放了的话会 RECOIL）；之后的普通攻击照常放刀接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "pb", em = "em20", at = 3.0, keep = { 0, 113 }, entries = { D(62.0, 70.0, { pb = true }) }, contact = { r = 0.03 } },
        { id = "normal", em = "em20", at = 8.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { excl = 1 } },
}

-- 19. UNABLE_GUARD 的条目：不放，SKIP why=ug
M[#M + 1] = {
    name = "v16_ug",
    smoke = false,
    desc = "GuardType=UNABLE_GUARD 的条目：不放刀，SKIP why=ug、excl=1；之后的普通攻击照常放刀接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "ug", em = "em20", at = 3.0, keep = { 0, 79 }, entries = { D(62.0, 70.0, { guard = "UNABLE_GUARD" }) },
            contact = { r = 0.03 } },
        { id = "normal", em = "em20", at = 8.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { excl = 1 } },
}

-- 20. SKILL_GUARD（伤害类型不是抓取）：不放，进视野就否决 why=sg（也挡住另一只怪的候选）；SKILL_GUARD_ALL_RANGE 同样
M[#M + 1] = {
    name = "v16_sg",
    smoke = false,
    desc = "SKILL_GUARD（不是抓取）不放、进视野否决 why=sg；SKILL_GUARD_ALL_RANGE 同样，还挡住另一只怪进窗口的候选；"
        .. "之后普通攻击照常放",
    duration = 20,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    attacks = {
        { id = "sg1", em = "em20", at = 3.0, keep = { 0, 135 }, entries = { D(62.0, 70.0, { guard = "SKILL_GUARD" }) },
            contact = false },
        { id = "sg2", em = "em20", at = 8.0, keep = { 0, 136 },
            entries = { D(80.0, 90.0, { guard = "SKILL_GUARD_ALL_RANGE" }) }, contact = false },
        { id = "blocked", em = "em1", at = 8.2, keep = { 0, 23 }, entries = { D(40.0, 48.0) }, contact = false },
        { id = "normal", em = "em20", at = 14.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, veto_why = { "sg", "sg" }, veto_frames_min = 1,
        stat = { vetoes = 2, excl = 0 } },
}

-- 21. 同一结果里可接条目 + 视野内的短窗口 UNABLE_GUARD 条目（仿 (0,131)/(0,132)）：UG 条目先进窗口（SKIP ug），
-- 可接条目放刀，FIRE 后紧跟 UVIEW（why=ug、same=1），uview = 1
M[#M + 1] = {
    name = "v16_mixed_result",
    smoke = false,
    desc = "同一结果：可接条目 + 视野内短窗口 UNABLE_GUARD 条目：UG 先进窗口 SKIP ug，可接条目放刀接住，FIRE 后紧跟 UVIEW why=ug same=1",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "mixed", em = "em20", at = 3.0, keep = { 0, 131 }, trig_entry = 1,
            entries = { D(62.0, 70.0), D(50.0, 55.0, { guard = "UNABLE_GUARD" }) },
            contact = { at = 3.0 + 62.0 / 60.0 + 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { uview = 1, excl = 1 },
        fire_props = { { uview = { why = "ug", same = true } } } },
}

-- 22. 另一只怪的 pb=1 条目在视野内时可接条目放刀：放刀、UVIEW why=pb、same=0；pb=1 的条目是弹体时不写 UVIEW（也不写 SKIP）
M[#M + 1] = {
    name = "v16_uview_other",
    smoke = false,
    desc = "另一只怪的 pb=1 条目在视野内时放刀：UVIEW why=pb same=0；那条 pb=1 是弹体时不写 UVIEW（弹体静默排除）",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    attacks = {
        { id = "pb_other", em = "em1", at = 3.0, keep = { 0, 24 }, entries = { D(55.0, 60.0, { pb = true }) }, contact = false },
        { id = "cand1", em = "em20", at = 3.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "pb_shell", em = "em1", at = 9.0, keep = { 1, 25 }, entries = { D(55.0, 60.0, { pb = true, shell = 1 }) },
            contact = false },
        { id = "cand2", em = "em20", at = 9.0, keep = { 0, 42 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 }, stat = { uview = 1, excl = 1 },
        fire_props = { { uview = { why = "pb", same = false } }, { uview = false } } },
}

-- 23. 候选的 get_AttackParam 返回 nil：不放，SKIP why=fc、fclosed = 1，不报黄（数据情况）；否决侧读不到类型计 failopen
M[#M + 1] = {
    name = "v16_fc_ap_nil",
    smoke = false,
    desc = "候选的 get_AttackParam 返回 nil：不放刀，SKIP fc、fclosed=1，不报黄；否决侧读不到计 failopen；之后普通攻击照常放",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "apnil", em = "em20", at = 3.0, keep = { 0, 78 }, entries = { D(62.0, 70.0, { ap = false }) }, contact = false },
        { id = "normal", em = "em20", at = 8.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { fclosed = 1, failopen = 1 },
        -- 探针的自检 2 读第一个 DANGER 条目的攻击参数，读到空的报黄 AP（探针自己的可选模块，预期内）
        err = { { tag = "APCal", level = "yellow", mod = "AP", max = 1 } } },
}

-- 24. 读 _GuardType 抛错（3~6 s）：报黄 filter 一次、不停用；后面的条目照样每帧读，读得到的照常放刀
M[#M + 1] = {
    name = "v16_fc_throw",
    smoke = false,
    desc = "_GuardType 读取抛错（3~6 s）：那一招 SKIP fc 不放，filter 报黄一次、不停用；8 s 的一招读得到，照常放刀接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "app.cAttackParamEm._GuardType", mode = "throw", from = 3.0, to = 6.0, scripts = { AutoParryGS = true } } },
    attacks = {
        { id = "throw", em = "em20", at = 3.0, keep = { 0, 77 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "after", em = "em20", at = 8.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { fclosed = 1 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } } },
}

-- 25. ShellIndex 抛错：fc，不放
M[#M + 1] = {
    name = "v16_fc_shell",
    smoke = false,
    desc = "get_ShellIndex 抛错（3~6 s）：那一招 SKIP fc 不放，filter 报黄一次；之后照常放刀接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "app.AttackAreaResult.DetectedData.get_ShellIndex", mode = "throw", from = 3.0, to = 6.0,
        scripts = { AutoParryGS = true } } },
    attacks = {
        { id = "shell_throw", em = "em20", at = 3.0, keep = { 0, 74 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "after", em = "em20", at = 8.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { fclosed = 1, failopen = 0 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } } },
}

-- 26. GuardType = 7（枚举外的值，游戏更新多出来的新值）：fc（白名单写法的意义），不报黄
M[#M + 1] = {
    name = "v16_guard_unknown",
    smoke = false,
    desc = "GuardType=7（枚举外）：按不该接，SKIP fc、不报黄；之后照常放刀接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "g7", em = "em20", at = 3.0, keep = { 0, 70 }, entries = { D(62.0, 70.0, { guard = 7 }) }, contact = false },
        { id = "normal", em = "em20", at = 8.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { fclosed = 1 } },
}

-- 27a. 枚举里拿掉 NORMAL：报黄 filter_enum，NORMAL 的条目全部 fc，ALL_RANGE 的照常放；菜单写清缺 NORMAL
M[#M + 1] = {
    name = "v16_guard_enum_normal",
    smoke = false,
    desc = "app.Hit.GUARD_TYPE 里没有 NORMAL：filter_enum 报黄，NORMAL 条目全部 SKIP fc；ALL_RANGE 的照常放刀接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "field:app.Hit.GUARD_TYPE.NORMAL", mode = "missing" } },
    attacks = {
        { id = "normal_fc", em = "em20", at = 3.0, keep = { 0, 71 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "all_range", em = "em20", at = 8.0, keep = { 0, 72 }, entries = { D(62.0, 70.0, { guard = "ALL_RANGE" }) },
            contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { fclosed = 1 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter_enum", min = 1, max = 1 } },
        menu_final = { "缺 NORMAL" } },
}

-- 27b. 枚举里拿掉 UNABLE_GUARD：加载时总写 DBG guard_enum（不看调试开关）；UG 条目 SKIP 记 fc；候选侧照常
M[#M + 1] = {
    name = "v16_guard_enum_ug",
    smoke = false,
    desc = "app.Hit.GUARD_TYPE 里没有 UNABLE_GUARD：加载时 DBG guard_enum（调试日志关着也写）、不报黄；UG 条目 SKIP fc；"
        .. "普通攻击照常放",
    duration = 14,
    config = cfg({ debug_log = false }),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "field:app.Hit.GUARD_TYPE.UNABLE_GUARD", mode = "missing" } },
    attacks = {
        { id = "ug_fc", em = "em20", at = 3.0, keep = { 0, 73 }, entries = { D(62.0, 70.0, { guard = "UNABLE_GUARD" }) },
            contact = false },
        { id = "normal", em = "em20", at = 8.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { fclosed = 1, excl = 0 }, dbg_events = { "guard_enum" },
        dbg_max = 1 },
}

-- 28. 拿掉效果名 QUAKE：报黄 filter_enum，一刀都不放（任何条目都无法确认不是效果攻击），菜单写「缺 QUAKE」
M[#M + 1] = {
    name = "v16_effect_enum_missing",
    smoke = false,
    desc = "app.HitDef.DAMAGE_TYPE 里没有 QUAKE：filter_enum 报黄，普通攻击也不放（SKIP fc），菜单写「缺 QUAKE」",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "field:app.HitDef.DAMAGE_TYPE.QUAKE", mode = "missing" } },
    attacks = {
        { id = "n1", em = "em20", at = 3.0, keep = { 0, 61 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "q1", em = "em20", at = 8.0, keep = { 0, 62 }, entries = { D(62.0, 70.0, { dmg = "QUAKE" }) }, contact = false },
    },
    expect = { rc = "oracle", fires = 0, requests = 0, stat = { fclosed = 2 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter_enum", min = 1, max = 1 } },
        menu_final = { "缺 QUAKE", "这些攻击一律不放刀" }, menu_absent = { "自动放刀照常" } },
}

-- 29. 视野内条目的伤害类型读不到（抓取条目的攻击参数为空）：否决侧当作不是抓取、不否决（另一条候选照放），failopen + 1
M[#M + 1] = {
    name = "v16_veto_failopen",
    smoke = false,
    desc = "视野内的抓取条目攻击参数为空（读不到伤害类型）：否决侧按不是抓取、不否决，另一只怪的候选照常放刀；failopen=1",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    attacks = {
        { id = "grab_unread", em = "em20", at = 3.0, keep = { 0, 230 }, dmg = "CATCH",
            entries = { D(80.0, 90.0, { dmg = "CATCH", ap = false }) }, contact = false },
        { id = "cand", em = "em1", at = 3.0, keep = { 0, 26 }, entries = { D(40.0, 48.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { failopen = 1, vetoes = 0 },
        err = { { tag = "APCal", level = "yellow", mod = "AP", max = 1 } } },
}

-- 29b（集成补充，V16 第 3.2 节「确定的原因优先」）：一条条目同时有几种不该接的属性。读到的值能确定的旧排除 / 否决家族
-- （弹体、抓取、效果、SKILL_GUARD 家族）静默排除、不写 SKIP > pb=1（SKIP pb）> UNABLE_GUARD（SKIP ug）> 读不准（SKIP fc，
-- 只记「只因读不准才没放」的条目）。否决侧：防御类型读得到、是 SKILL_GUARD 家族时，伤害类型读不到照样否决 why=sg
-- （读不到的伤害类型按不是抓取，只是它自己不触发否决），failopen +1。各招隔开 2 s，字段故障只罩住自己那一招
M[#M + 1] = {
    name = "v16_multi_attr",
    smoke = false,
    desc = "一条条目几种属性并存：pb=1+SKILL_GUARD → 否决 sg、不写 SKIP；UNABLE_GUARD+pb 读不到 → SKIP ug；SKILL_GUARD+伤害类型"
        .. "读不到 → 照样否决 sg、failopen=1；pb=1+ShellIndex 读不到 → SKIP pb；之后普通攻击照常放刀接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = {
        { key = "app.cAttackParamEm._IsParryBreak", mode = "throw", from = 5.0, to = 6.4, scripts = { AutoParryGS = true } },
        { key = "app.cAttackParamEm._DamageType", mode = "throw", from = 7.0, to = 8.4, scripts = { AutoParryGS = true } },
        { key = "app.AttackAreaResult.DetectedData.get_ShellIndex", mode = "throw", from = 9.0, to = 10.4,
            scripts = { AutoParryGS = true } },
    },
    attacks = {
        { id = "pb_sg", em = "em20", at = 3.0, keep = { 0, 141 }, entries = { D(62.0, 70.0, { pb = true, guard = "SKILL_GUARD" }) },
            contact = false },
        { id = "ug_pberr", em = "em20", at = 5.0, keep = { 0, 142 }, entries = { D(62.0, 70.0, { guard = "UNABLE_GUARD" }) },
            contact = false },
        { id = "sg_dmgerr", em = "em20", at = 7.0, keep = { 0, 143 }, entries = { D(62.0, 70.0, { guard = "SKILL_GUARD" }) },
            contact = false },
        { id = "pb_shellerr", em = "em20", at = 9.0, keep = { 0, 144 }, entries = { D(62.0, 70.0, { pb = true }) },
            contact = false },
        { id = "normal", em = "em20", at = 11.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, veto_why = { "sg", "sg" },
        stat = { excl = 2, fclosed = 0, failopen = 1, vetoes = 2 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } } },
}

-- 29c（同上）：效果名 QUAKE 读不到时，能确定的原因照样优先：pb=1 → SKIP pb、UNABLE_GUARD → SKIP ug、SKILL_GUARD → 否决 sg
-- 不写 SKIP；只有普通条目（认不出是不是效果攻击）才记 fc。一刀都不放
M[#M + 1] = {
    name = "v16_multi_attr_enum",
    smoke = false,
    desc = "缺 QUAKE 时确定的原因优先：pb=1 → SKIP pb，UNABLE_GUARD → SKIP ug，SKILL_GUARD → 否决 sg（不写 SKIP），"
        .. "普通条目 SKIP fc；一刀都不放",
    duration = 12,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "field:app.HitDef.DAMAGE_TYPE.QUAKE", mode = "missing" } },
    attacks = {
        { id = "pb", em = "em20", at = 3.0, keep = { 0, 151 }, entries = { D(62.0, 70.0, { pb = true }) }, contact = false },
        { id = "ug", em = "em20", at = 5.0, keep = { 0, 152 }, entries = { D(62.0, 70.0, { guard = "UNABLE_GUARD" }) },
            contact = false },
        { id = "sg", em = "em20", at = 7.0, keep = { 0, 153 }, entries = { D(62.0, 70.0, { guard = "SKILL_GUARD" }) },
            contact = false },
        { id = "plain", em = "em20", at = 9.0, keep = { 0, 154 }, entries = { D(62.0, 70.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 0, requests = 0, veto_why = { "sg" },
        stat = { excl = 2, fclosed = 1, vetoes = 1 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter_enum", min = 1, max = 1 } },
        menu_final = { "缺 QUAKE" } },
}

-- ---- 结局（V16 第 4 节） ----

-- 31. pb=0 但场景强制刀上结局为 RECOIL（hit_level = 25）：RES RECOIL、to=(2,25)；catches 不加、recoils + 1；菜单「被弹 1」
M[#M + 1] = {
    name = "v16_recoil",
    smoke = false,
    desc = "刀上结局强制 RECOIL（进 (2,25)、同一帧身体挨打）：RES RECOIL、to=(2,25)，catches=0、recoils=1，菜单「被弹 1」",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "recoil", em = "em20", at = 3.0, keep = { 0, 113 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 },
            hit_level = 25 },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, res_recoil = 1, stat = { catches = 0, recoils = 1 },
        menu_final = { "被弹 1" } },
}

-- 32. CATCH26、CATCH27 各一次（catches = 2，to 分别是 (2,26)、(2,27)）；攻击没来、CREDIT 到点还在 (2,23) 的 NOCATCH 的 to = -
M[#M + 1] = {
    name = "v16_catch_tiers",
    smoke = false,
    desc = "CATCH26（to=(2,26)）、CATCH27（to=(2,27)）各一次，catches=2；攻击没来的 NOCATCH 到点时还在 (2,23)，to=-",
    duration = 18,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "m26", em = "em20", at = 3.0, keep = { 0, 31 }, entries = { D(62.0, 70.0) }, contact = { r = 0.05 }, hit_level = 26 },
        { id = "l27", em = "em20", at = 8.0, keep = { 0, 32 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "none", em = "em20", at = 13.0, keep = { 0, 33 }, entries = { D(62.0, 70.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 3, pt = { catch = 2, whiff = 1 }, res_catch_min = 2, res_nocatch_min = 1,
        stat = { catches = 2, recoils = 0 } },
}

-- ---- 配置迁移（V16 第 2.7 节） ----

local function one_attack(keep)
    return { { id = "a1", em = "em20", at = 3.0, keep = { 0, keep }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } } }
end

M[#M + 1] = {
    name = "v16_cfg_from_v151",
    smoke = false,
    desc = "v1.5.1 存的配置（cfg_ver=2、parry_lead=26，用户自己调的）：迁成 28、DBG cfg_upgrade from=26 to=28；存配置 cfg_ver=3",
    duration = 10,
    config = v151_written({ parry_lead = 26 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = one_attack(270),
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_events = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v16_cfg_from_v15",
    smoke = false,
    desc = "没有 cfg_ver 的配置（v1.5 / rc 写的）parry_lead=30：迁成 28、DBG cfg_upgrade from=30 to=28",
    duration = 10,
    config = v15_written({ parry_lead = 30 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = one_attack(271),
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_events = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v16_cfg_keep",
    smoke = false,
    desc = "cfg_ver=3、parry_lead=35：保持 35（不迁移、没有 DBG cfg_upgrade），按 35 放刀",
    duration = 10,
    config = cfg({ parry_lead = 35 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = one_attack(272),
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_absent = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v16_cfg_clamp_lo",
    smoke = false,
    desc = "cfg_ver=3、parry_lead=22：夹到滑块下限 23（[L_min, L] 至少 1 帧宽）",
    duration = 10,
    config = cfg({ parry_lead = 22 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = one_attack(273),
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_absent = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v16_cfg_clamp_hi",
    smoke = false,
    desc = "cfg_ver=3、parry_lead=50：夹到滑块上限 45",
    duration = 10,
    config = cfg({ parry_lead = 50 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = { { id = "a1", em = "em20", at = 3.0, keep = { 0, 274 }, entries = { D(62.0, 70.0) }, contact = { r = 0.0 } } },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_absent = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v16_cfg_nofile",
    smoke = false,
    desc = "没有配置文件：默认 28，不算迁移（没有 DBG cfg_upgrade）",
    duration = 10,
    config = { AutoGuardGS = GUARD_CFG },
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = one_attack(275),
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_absent = { "cfg_upgrade" } },
}

M[#M + 1] = {
    name = "v16_cfg_bad_ver",
    smoke = false,
    desc = "cfg_ver=\"3\"（字符串）、parry_lead=35：视为需要迁移，改成 28、DBG cfg_upgrade from=35 to=28",
    duration = 10,
    config = cfg({ cfg_ver = "3", parry_lead = 35 }),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = one_attack(276),
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, dbg_events = { "cfg_upgrade" } },
}

-- ---- 引用记账（真实模型，V16 第 5、8.4 节第 39~42 条） ----

-- 39. v1.6 + APCal（1.1，只 add_ref、不 release）同时持有同一批结果，游戏在 IsAttackFinished 那一帧就放手（drop_after = 0）：
-- 34 条预告超过上限、APCal「停止记录」、关开关、主角换人、帧逻辑自停各一段。两边都不 release；一边先丢掉引用时对象仍由另一边
-- 的句柄保活；DEAD_OBJECT = 0；持有时长都合规；Reset 后 REF 的共享计数全 0、无泄漏
M[#M + 1] = (function()
    local monsters, attacks = { em20 = EM20 }, {}
    for i = 1, 34 do
        local key = string.format("m%02d", i)
        monsters[key] = { emid = 100 + i, sysidx = 10 + i, cls = "app.Em0020_00Action",
            go_name = string.format("EmMock_%02d", i), pos = { x = -1100.25 + i * 0.5, y = 56.39, z = 530.0 } }
        attacks[#attacks + 1] = { id = "c" .. i, em = key, at = 2.0 + i * 0.05, keep = { 0, 300 + i },
            entries = { C(300.0, 310.0) }, contact = false, finish = 6.0 }
    end
    -- 每一段都有一条预告在两个脚本手里（hs 还没到 L）的时候发生「丢掉」
    attacks[#attacks + 1] = { id = "fire", em = "em20", at = 8.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } }
    attacks[#attacks + 1] = { id = "probe_stop", em = "em20", at = 11.5, keep = { 0, 42 }, entries = { C(100.0, 110.0) },
        contact = false, finish = 13.0 }
    attacks[#attacks + 1] = { id = "switch_off", em = "em20", at = 15.5, keep = { 0, 43 }, entries = { C(100.0, 110.0) },
        contact = false, finish = 17.0 }
    attacks[#attacks + 1] = { id = "swap", em = "em20", at = 19.5, keep = { 0, 44 }, entries = { C(100.0, 110.0) },
        contact = false, finish = 21.0 }
    attacks[#attacks + 1] = { id = "self_stop", em = "em20", at = 23.0, keep = { 0, 45 }, entries = { C(150.0, 160.0) },
        contact = false, finish = 27.0 }
    return {
        name = "v16_ref_shared",
        smoke = false,
        desc = "v1.6 + APCal 1.1 同时持有同一批结果、游戏结束那一帧就放手：超上限、停止记录、关开关、换人、自停各一段；"
            .. "两边都不 release，DEAD_OBJECT=0，持有时长合规，Reset 后不泄漏",
        duration = 30,
        dt = 1 / 60,
        drop_after = 0,
        config = cfg(),
        player = auto(),
        monsters = monsters,
        attacks = attacks,
        hunter_events = { { t = 20.0, op = "swap" } },
        ui = {
            { t = 12.0, kind = "checkbox", match = "停止记录", value = true, script = "AutoParryCalib" },
            { t = 14.0, kind = "checkbox", match = "停止记录", value = false, script = "AutoParryCalib" },
            { t = 16.0, kind = "checkbox", match = "启用", value = false, script = "AutoParryGS", cfg_key = "auto_parry" },
            { t = 18.0, kind = "checkbox", match = "启用", value = true, script = "AutoParryGS", cfg_key = "auto_parry" },
        },
        -- 自停：24 s 起读动作 ID 一直抛错（只对放刀模块），1.5 s 容忍后连续 30 帧出错自停
        faults = { { key = "ActionController.get_CurrentActionID", mode = "throw", from = 24.0, scripts = { AutoParryGS = true } } },
        oracle_skip = { { 16.0, 18.3 } },
        oracle_until = 24.0,
        expect = {
            rc = "oracle", fires = 1, pt = { catch = 1 }, max_held = 32, no_requests_after = 24.0, kept_alive_min = 2,
            stat = { errors = 30, red = 30 },
            release_all_at = { { t = 12.02, what = "探针菜单「停止记录」", script = "AutoParryCalib" },
                { t = 16.02, what = "菜单关掉自动放刀", script = "AutoParryGS" } },
            err = { { tag = "AutoParryGS", level = "red", mod = "frame", min = 20, max = 20 } },
            red = { "AutoParryGS" }, red_why = { AutoParryGS = { "3in10s", "self_stop" } },
            probe_kinds = { "STOP", "RESUME" },
        },
    }
end)()

-- 40. 负对照：v1.6 + 归档的 APCal 1.0.1（会手动 release）。两边都在跟踪同一个结果时 APCal「停止记录」（release 全部 → REF 的
-- 共享计数扣到 0），之后游戏在结束那一帧放手 → 对象销毁 → v1.6 下一帧读 IsAttackFinished 就是 DEAD_OBJECT（2c 那类故障）。
-- holder = "empty"：免得探针的 HOLD 模块把对象重新推入（新一代、计数又变 1）把故障盖住
M[#M + 1] = {
    name = "v16_ref_neg_probe",
    smoke = false,
    -- 合并模式不比等价（MERGE 第 6.3 节）：负对照本来就要求出现悬空访问，访问之后的行为没有可比性；合并版另有 merge_ref_neg_probe
    merged_equiv = false,
    probe_ver = "1.0.1",
    desc = "负对照：v1.6 + 归档 APCal 1.0.1。探针停止记录（手动 release）后游戏放手：v1.6 下一帧访问已回收对象 → 必须出现 DEAD_OBJECT",
    duration = 10,
    drop_after = 0,
    holder = "empty",
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    ui = { { t = 5.0, kind = "checkbox", match = "停止记录", value = true, script = "AutoParryCalib" } },
    attacks = {
        -- he 要到 8.7 s 才跌破 -30：游戏 6.0 s 放手时两个脚本都还在跟踪（不会先按「全部 he<-30」丢掉）
        { id = "shared", em = "em20", at = 3.0, keep = { 0, 89 }, entries = { C(300.0, 310.0) }, contact = false, finish = 6.0 },
    },
    oracle_until = 6.0,
    expect = {
        rc = "oracle", fires = 0, dead_object = "required", probe_checks = false, stat_oracle = false,
        err = { { tag = "AutoParryGS", level = "red", mod = "frame", min = 1, max = 2 } },
        stat = { errors = { min = 1, max = 2 }, red = { min = 1, max = 2 } },
    },
}

-- 41. 负对照：归档的 v1.5.1 + APCal 1.1。两边都在跟踪时在菜单里关掉 v1.5.1 的开关（它会 release 全部），之后游戏放手 →
-- 必须出现 DEAD_OBJECT（这回是探针访问）。也说明 B 阶段 v1.5.1 不能开着开关和新探针同跑（V16 第 5.4 节）
M[#M + 1] = {
    name = "v16_ref_neg_gs",
    smoke = false,
    rc_ver = "v15",
    desc = "负对照：归档 v1.5.1 + APCal 1.1。关 v1.5.1 的开关（手动 release 全部）后游戏放手：探针访问已回收对象 → 必须出现 DEAD_OBJECT",
    duration = 10,
    drop_after = 0,
    holder = "empty",
    config = v151cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    ui = { { t = 5.0, kind = "checkbox", match = "启用", value = false, script = "AutoParryGS", cfg_key = "auto_parry" } },
    attacks = {
        -- he 要到 8.7 s 才跌破 -30：游戏 6.0 s 放手时两个脚本都还在跟踪（不会先按「全部 he<-30」丢掉）
        { id = "shared", em = "em20", at = 3.0, keep = { 0, 89 }, entries = { C(300.0, 310.0) }, contact = false, finish = 6.0 },
    },
    expect = {
        rc = "oracle", fires = 0, dead_object = "required", probe_checks = false,
        err = { { tag = "APCal", level = "red", min = 1, max = 3 }, { tag = "APCal", level = "yellow", max = 9 } },
        release_all_at = { { t = 5.02, what = "菜单关掉自动放刀", script = "AutoParryGS" } },
    },
}

-- 42. 结果是局部对象（REF 推入时不加引用）：v1.6 登记时的 add_ref 让它活到被丢掉，读得到、照常放刀。另由测试脚本生成一份去掉
-- add_ref 的 v1.6 副本跑同一场景（v16_ref_local_noaddref），要求出现 DEAD_OBJECT（证明 add_ref 必须保留）。
-- 不载入探针：探针也 add_ref，会替放刀模块把对象保活
local REF_LOCAL = {
    smoke = false,
    probe_ver = false,
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "local", em = "em20", at = 3.0, keep = { 0, 47 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 },
            local_result = true },
    },
}
M[#M + 1] = (function()
    local s = {}
    for k, v in pairs(REF_LOCAL) do s[k] = v end
    s.name = "v16_ref_local"
    s.desc = "结果是局部对象（推入时不加引用）：v1.6 登记时 add_ref 让它活到丢掉，照常放刀接住，没有 DEAD_OBJECT"
    s.expect = { rc = "oracle", fires = 1 }
    return s
end)()
M[#M + 1] = (function()
    local s = {}
    for k, v in pairs(REF_LOCAL) do s[k] = v end
    s.name = "v16_ref_local_noaddref"
    s.rc_transform = "strip_add_ref"
    s.merged_equiv = false      -- 同上，合并版另有 merge_ref_local_noaddref
    s.desc = "同 v16_ref_local，但被测脚本是测试生成的去掉 add_ref 的副本：消息钩子一结束对象就销毁，下一帧访问 → 必须 DEAD_OBJECT"
    s.oracle_until = 3.0
    s.expect = { rc = "oracle", fires = 0, requests = 0, dead_object = "required", stat_oracle = false,
        err = { { tag = "AutoParryGS", level = "red", mod = "frame", min = 1, max = 2 } },
        stat = { errors = { min = 1, max = 2 }, red = { min = 1, max = 2 } } }
    return s
end)()

-- ---- 其他 ----

-- SystemIndex 被复用（sidmis，V16 第 2.5 节）：em27 发完消息的同一帧消失、另一只怪接用同一个 SystemIndex（C=1.3）：首帧按
-- SystemIndex 找到的是新怪，和钩子里记的发送者地址不一致 → sidmis = 1（只记录，不拦放刀），DBG sidmis；C1 是新怪的 1.3
M[#M + 1] = {
    name = "v16_sidmis",
    smoke = false,
    desc = "发消息的怪同一帧消失、新怪接用同一个 SystemIndex：首帧找到的怪物地址≠发送者 → sidmis=1、DBG sidmis；C1 是新怪的",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = {
        em27 = EMC(1.1, { despawn_at = 3.0 }),
        em27b = EMC(1.3, { emid = 161, go_name = "Em0161_00_0_9437185_22", spawn_at = 3.0 }),
    },
    attacks = {
        { id = "orphan", em = "em27", at = 3.0, keep = { 0, 99 }, entries = { D(120.0, 128.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 1, stat = { sidmis = 1 }, dbg_events = { "sidmis" }, fire_props = { { C1 = 1.3 } } },
}

-- ---------- 审查补充（V16 第 14 节）：两次审查指出的覆盖缺口，每个场景对应一个当时存活的变异 ----------

-- 再几只设了速度的怪（SystemIndex 互不相同）：同一个场景里分两段测，故障和神谕的声明按怪分开
local function EMC2(C, n)
    return EMC(C, { emid = 161 + n, sysidx = 8 + n, go_name = string.format("Em%04d_00_0_94371%02d_%d", 161 + n, 85 + n, 22 + n) })
end

-- 43. 断档后时钟照常累加（审查 spec-runtime #1）：C=1.264、A=150，条目读取连续出错 0.6 s / 1.0 s（约 36 / 60 名义帧，
-- 超过单帧上限 30）。恢复那一帧的 Δ 跨好几帧，按最后的 m 照常累加（上限 = 30 + 60 × 两次读数隔开的秒数）：X 不丢、
-- Q0 = Qe1（C 不变）、接住。固定 30 的旧写法这两刀都会整段不累加：Q0 比 Qe1 大约 7.5 / 12.5、放刀晚 0.12 / 0.21 s
M[#M + 1] = {
    name = "v16_gap_items",
    smoke = false,
    desc = "C=1.264、A=150，条目读取连续出错 0.6 s 和 1.0 s（Δ 跨好几帧、超过 30）：恢复后照常累加 X，Q0=Qe1，放刀帧按神谕，两刀都接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.264), em28 = EMC2(1.264, 1) },
    faults = {
        { key = "DetectedDataList.get_Item", mode = "throw", where = of_em("em27"), scripts = { AutoParryGS = true },
            from = 3.3, to = 3.9 },
        { key = "DetectedDataList.get_Item", mode = "throw", where = of_em("em28"), scripts = { AutoParryGS = true },
            from = 8.3, to = 9.3 },
    },
    oracle_items_fail = { em27 = { 3.3, 3.9 }, em28 = { 8.3, 9.3 } },
    attacks = {
        { id = "gap06", em = "em27", at = 3.0, keep = { 0, 79 }, entries = { D(150.0, 158.0) }, contact = { g = 0.03 } },
        { id = "gap10", em = "em28", at = 8.0, keep = { 0, 80 }, entries = { D(150.0, 158.0) }, contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 }, stat = { readerr = 2, clockskip = 0 },
        fire_props = { { nchg = 0, qe1_q0 = true }, { nchg = 0, qe1_q0 = true } },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "items", min = 1, max = 1 } } },
}

-- 44. 同上，断档来自读主角抛错的容忍期（整帧跳过，V16 第 2.1 节「这一帧不存在」）：0.6 s、1.0 s，都短于容忍期 1.5 s，
-- 不报错。神谕按 oracle_hunter_fail 把这些帧当作不存在
M[#M + 1] = {
    name = "v16_gap_hunter",
    smoke = false,
    desc = "C=1.264、A=150，读主角抛错 0.6 s 和 1.0 s（容忍期内整帧跳过）：之后照常累加 X，Q0=Qe1，两刀都接住，不报错",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.264), em28 = EMC2(1.264, 1) },
    faults = {
        { key = "HunterCharacter.get_WeaponType", mode = "throw", from = 3.3, to = 3.9, scripts = { AutoParryGS = true } },
        { key = "HunterCharacter.get_WeaponType", mode = "throw", from = 8.3, to = 9.3, scripts = { AutoParryGS = true } },
    },
    oracle_hunter_fail = { { 3.3, 3.9 }, { 8.3, 9.3 } },
    attacks = {
        { id = "tol06", em = "em27", at = 3.0, keep = { 0, 79 }, entries = { D(150.0, 158.0) }, contact = { g = 0.03 } },
        { id = "tol10", em = "em28", at = 8.0, keep = { 0, 80 }, entries = { D(150.0, 158.0) }, contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 }, stat = { readfail = { min = 140, max = 148 }, clockskip = 0, errors = 0 },
        fire_props = { { nchg = 0, qe1_q0 = true }, { nchg = 0, qe1_q0 = true } }, dbg_events = { "read_fail", "read_back" } },
}

-- 45. 只有 _IsParryBreak 读不准（审查 spec-runtime #2）：其余字段都正常（NORMAL、不是抓取 / 效果 / 弹体）。抛错（真值 pb=1，
-- 放了就是 RECOIL 加挨打）和读到非布尔值两种，都要 SKIP fc、fclosed、filter 报黄一次（会话里只报一次）、不放；之后普通攻击照常放
M[#M + 1] = {
    name = "v16_pb_unreadable",
    smoke = false,
    desc = "只有 _IsParryBreak 读不准：抛错（真值 pb=1）、读到数字 1 各一招，都 SKIP fc、不放刀，filter 报黄一次；之后普通攻击照常放刀接住",
    duration = 16,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = {
        { key = "app.cAttackParamEm._IsParryBreak", mode = "throw", from = 3.0, to = 6.0, scripts = { AutoParryGS = true } },
        { key = "app.cAttackParamEm._IsParryBreak", mode = "value", value = 1, from = 7.0, to = 10.0,
            scripts = { AutoParryGS = true } },
    },
    attacks = {
        { id = "pb_throw", em = "em20", at = 3.0, keep = { 0, 113 }, entries = { D(62.0, 70.0, { pb = true }) }, contact = false },
        { id = "pb_number", em = "em20", at = 7.0, keep = { 0, 114 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "normal", em = "em20", at = 11.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { fclosed = 2, excl = 0 },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } } },
}

-- 46. L_min 按 Q 比（审查 spec-runtime #3）。① C=1.264、A=150，4.66 s 才按住蓄力：这时 hs≈50 ≥ 22、Q≈19 < 22，太晚了，不放；
-- ② C 在 Q（= hs，C=1）≈36 时从 1.0 跳到 1.8：下一帧 Q≈19.6，一帧跳过整个 [22, 28]，不放。按原始 hs 比 L_min 的实现两段都会误放
M[#M + 1] = {
    name = "v16_lmin_q",
    smoke = false,
    desc = "L_min 按 Q 比：按住蓄力时 Q 已 <22（hs≈50）不放；C 1.0→1.8 让 Q 一帧从 ≈36 跳到 ≈19.6（跳过窗口）不放",
    duration = 12,
    config = cfg(),
    player = auto({ first_hold = 4.66 }),
    monsters = { em27 = EMC(1.264), em29 = EMC2({ { 0, 1.0 }, { 8.40, 1.8 } }, 2) },
    attacks = {
        { id = "late_hold", em = "em27", at = 3.0, keep = { 0, 79 }, entries = { D(150.0, 158.0) }, contact = false },
        { id = "m_jump", em = "em29", at = 8.0, keep = { 0, 81 }, entries = { D(60.0, 68.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 0, requests = 0 },
}

-- 47. UVIEW 取 hs 最小的 U（审查 spec-runtime #3 顺带项、tests-analysis #5 第 5 条）。① 同一结果里条目表顺序是 触发条目、
-- pb=1（hs 大）、UNABLE_GUARD（hs 小）：UVIEW 记 hs 小的 UNABLE_GUARD（why=ug），取第一个的实现会记 pb；② 一条条目同时
-- pb=1 和 UNABLE_GUARD：why=pb（pb 优先，V16 第 13.3 节第 4 条）
M[#M + 1] = {
    name = "v16_uview_min",
    smoke = false,
    desc = "UVIEW 取视野内 hs 最小的 U（表里先 pb 后 UNABLE_GUARD，记 ug）；同时 pb=1 和 UNABLE_GUARD 的条目记 pb；两刀都接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "umin", em = "em20", at = 3.0, keep = { 0, 61 }, trig_entry = 1,
            entries = { D(62.0, 70.0), D(80.0, 85.0, { pb = true }), D(50.0, 55.0, { guard = "UNABLE_GUARD" }) },
            contact = { at = 3.0 + 62.0 / 60.0 + 0.03 } },
        { id = "pbug", em = "em20", at = 8.0, keep = { 0, 62 }, trig_entry = 1,
            entries = { D(62.0, 70.0), D(50.0, 55.0, { pb = true, guard = "UNABLE_GUARD" }) },
            contact = { at = 8.0 + 62.0 / 60.0 + 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 2 }, stat = { uview = 2 },
        fire_props = { { uview = { why = "ug", same = true } }, { uview = { why = "pb", same = true } } } },
}

-- 48. U 不看所在结果是不是 nofire（V16 第 13.3 节第 4 条；tests-analysis #5 第 5 条）：em1 的结果首帧读不到 C（永不放刀），
-- 它的 UNABLE_GUARD 条目在 em20 放刀那一帧在视野内 → 照样写 UVIEW（why=ug、same=0）
M[#M + 1] = {
    name = "v16_u_nofire",
    smoke = false,
    desc = "首帧读不到 C 的结果（nofire）里的 UNABLE_GUARD 条目在视野内时另一只怪放刀：照样写 UVIEW why=ug same=0；speedfail=1",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1C },
    attacks = {
        { id = "nofire_ug", em = "em1", at = 3.0, keep = { 0, 25 }, entries = { D(40.0, 45.0, { guard = "UNABLE_GUARD" }) },
            contact = false, speed_fault = { { from = 0.0, to = 0.02, mode = "find_nil" } } },
        { id = "cand", em = "em20", at = 3.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, stat = { uview = 1, speedfail = 1 },
        fire_props = { { uview = { why = "ug", same = false } } } },
}

-- 49. 条目消失再出现时 X0 不重置（V16 第 2.3 节；审查 spec-runtime #3 顺带项、tests-analysis #5 第 3 条）：C=1.3，触发条目
-- 在 3.3~3.6 s 从条目表里消失（同一个对象，游戏照样倒数），CAUTION 条目当时钟一直在：回来之后 dX 仍从首见算起，
-- Q0 = Qe1、A0 = 120。重记 X0 的实现会把 A0 记成 ≈84、晚约 8 帧放刀
M[#M + 1] = {
    name = "v16_x0_keep",
    smoke = false,
    desc = "C=1.3，触发条目中途消失 0.3 s 再出现（同一对象）：X0、A0 不重置（A0=120、Q0=Qe1），放刀帧按神谕，接住",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(1.3) },
    attacks = {
        { id = "hide", em = "em27", at = 3.0, keep = { 0, 83 }, entries = { C(200.0, 210.0), D(120.0, 128.0) },
            contact = { g = 0.03 },
            events = { { at = 3.3, op = "hide_entry", entry = 2 }, { at = 3.6, op = "show_entry", pos = 2 } } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, fire_props = { { qe1_q0 = true, nchg = 0, A0 = 120.0 } } },
}

-- 50. Qp 只取上一个求值帧（V16 第 2.4 节第 2 条、第 6.2 节；tests-analysis #5 第 4 条）：蓄力中算过 Q（≈100），3.2 s 松手
-- （手动上捞斩，空挥）、约 4.43 s 回到蓄力时这条条目已在窗口里（Q≈26.7）→ 那一帧就放刀，上一帧没在蓄力，Qp 写 -
M[#M + 1] = {
    name = "v16_qp_rehold",
    smoke = false,
    desc = "蓄力中算过 Q，松手（手动上捞斩）再按住时同一条条目已在窗口里：回到蓄力那一帧放刀，Qp=-（上一帧没在蓄力）",
    duration = 10,
    config = cfg(),
    player = { events = { { 1.0, "hold" }, { 3.2, "release" }, { 3.3, "input" }, { 4.0, "hold" } } },
    monsters = { em20 = EM20 },
    attacks = {
        { id = "rehold", em = "em20", at = 3.0, keep = { 0, 63 }, entries = { D(112.0, 120.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1, whiff = 1 }, fire_props = { { qp = false } } },
}

-- 51. 读条目出错的帧照样读 C（V16 第 2.3 节第 3 步；tests-analysis #5 第 1 条）：em27 的条目在 3.3~3.5 s 读不出来，C 在 3.4 s
-- 从 1.1 变成 1.3：出错那几帧 m 照常更新（nchg=1），恢复后那一对读数乘的是出错期间最后的 m；跟踪中每帧都读 C
M[#M + 1] = {
    name = "v16_items_speed",
    smoke = false,
    desc = "条目读不出来的那几帧照样读 C（find_once）：C 在出错期间 1.1→1.3，m 照常更新、恢复后按最后的 m 累加，放刀帧按神谕，接住",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC({ { 0, 1.1 }, { 3.4, 1.3 } }) },
    faults = { { key = "DetectedDataList.get_Item", mode = "throw", where = of_em("em27"), scripts = { AutoParryGS = true },
        from = 3.3, to = 3.5 } },
    oracle_items_fail = { em27 = { 3.3, 3.5 } },
    attacks = {
        { id = "gap", em = "em27", at = 3.0, keep = { 0, 85 }, entries = { D(150.0, 158.0) }, contact = { g = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 }, find_once = true, stat = { readerr = 1 },
        fire_props = { { nchg = 1 } },
        err = { { tag = "AutoParryGS", level = "yellow", mod = "items", min = 1, max = 1 } } },
}

-- 52. sidmis 不管 C 合不合法（V16 第 13.3 节第 5 条；tests-analysis #5 第 6 条）：同 v16_sidmis，但接用 SystemIndex 的新怪
-- C = 3.0（超出 [0.5, 2.0]）：首帧读不到 C（speedfail，永不放刀），找到的怪物地址照样和发送者比 → sidmis = 1
M[#M + 1] = {
    name = "v16_sidmis_badc",
    smoke = false,
    desc = "SystemIndex 被新怪接用、新怪 C=3.0（不合法）：speedfail=1、不放刀，sidmis 照样计 1（只要两边地址都有就比）",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = {
        em27 = EMC(1.1, { despawn_at = 3.0 }),
        em27b = EMC(3.0, { emid = 161, go_name = "Em0161_00_0_9437185_22", spawn_at = 3.0 }),
    },
    attacks = {
        { id = "orphan", em = "em27", at = 3.0, keep = { 0, 99 }, entries = { D(120.0, 128.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 0, requests = 0, stat = { sidmis = 1, speedfail = 1 }, dbg_events = { "sidmis", "speed_fail" } },
}

-- 53. 同 hs 的抓取和 SKILL_GUARD 同时在视野内：VETO why=grab（同 hs 时 long > grab > sg，V16 第 2.4 节；tests-analysis #5 第 7 条）
M[#M + 1] = {
    name = "v16_veto_tie",
    smoke = false,
    desc = "同一结果里 hs 相同的 SKILL_GUARD 条目和抓取条目同时进视野：VETO 记 grab（同 hs 时 grab 排在 sg 前）",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "tie", em = "em20", at = 3.0, keep = { 0, 135 }, dmg = "CATCH",
            entries = { D(62.0, 70.0, { guard = "SKILL_GUARD" }), D(62.0, 70.0, { dmg = "CATCH" }) }, contact = false },
    },
    expect = { rc = "oracle", fires = 0, requests = 0, veto_why = { "grab" }, stat = { vetoes = 1 } },
}

-- 54. C 的合法范围是闭区间 [0.5, 2.0]（V16 第 1 节；tests-analysis #5 第 8 条）：C = 2.0 照常放刀（mf=2.000）；C = 0.5 按 m=1
-- 放刀（C1=0.500、mf=1.000，怪物慢、攻击晚到，空挥）。开区间的实现两刀都按读不到、不放
M[#M + 1] = {
    name = "v16_c_bounds",
    smoke = false,
    desc = "C 恰好 2.0、0.5 都合法：2.0 的一刀按 m=2 放刀接住；0.5 的一刀按 m=1 放刀（攻击晚到，空挥）",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(2.0), em30 = EMC2(0.5, 3) },
    attacks = {
        { id = "c2", em = "em27", at = 3.0, keep = { 0, 86 }, entries = { D(150.0, 158.0) }, contact = { g = 0.03 } },
        { id = "c05", em = "em30", at = 8.0, keep = { 0, 87 }, entries = { D(62.0, 70.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 1, whiff = 1 },
        fire_props = { { C1 = 2.0, mf = 2.0, nchg = 0 }, { C1 = 0.5, mf = 1.0, nchg = 0 } } },
}

-- 55. 探针 findEnemy 不可用时的退路缓存（V16 第 5.3 节表的第二行；tests-analysis #6）：只对探针让 findEnemy_SystemIndex
-- 抛错 → FIND 报黄停用，之后从发送者记住怪物对象（S.ems[*].ref，add_ref、不 release）。依次走到：同一个 SystemIndex 换成
-- 新怪（换对象，只丢旧的 Lua 引用）、「停止记录」（em_release_all）、60 s 没再见到（过期）、Reset（em_release_all）。
-- 要求探针一次都不手动 release、没有 DEAD_OBJECT、Reset 后不泄漏；add_ref_min 证明这条持有路径真的走到了
M[#M + 1] = {
    name = "v16_probe_em_ref",
    smoke = false,
    desc = "探针 findEnemy 抛错（FIND 停用）→ 从发送者记住怪物对象：换对象、停止记录、60 s 过期、Reset 都只删 Lua 引用，"
        .. "探针不手动 release、无 DEAD_OBJECT、不泄漏",
    duration = 78,
    dt = 1 / 30,
    config = cfg(),
    player = auto(),
    monsters = {
        em20 = { emid = 156, sysidx = 3, cls = "app.Em0020_00Action", go_name = "Em0020_00_0_7340032_12",
            pos = { x = -1100.25, y = 56.39, z = 522.95 }, despawn_at = 6.0 },
        em20b = { emid = 157, sysidx = 3, cls = "app.Em0020_00Action", go_name = "Em0020_00_0_7340033_13",
            pos = { x = -1100.25, y = 56.39, z = 522.95 }, spawn_at = 6.5 },
    },
    faults = { { key = "app.EnemyManager.findEnemy_SystemIndex", mode = "throw", scripts = { AutoParryCalib = true } } },
    ui = {
        { t = 10.0, kind = "checkbox", match = "停止记录", value = true, script = "AutoParryCalib" },
        { t = 11.0, kind = "checkbox", match = "停止记录", value = false, script = "AutoParryCalib" },
    },
    attacks = {
        { id = "first", em = "em20", at = 3.0, keep = { 0, 41 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "remember", em = "em20", at = 4.5, keep = { 0, 42 }, entries = { C(100.0, 110.0) }, contact = false, finish = 5.5 },
        { id = "swap", em = "em20b", at = 8.0, keep = { 0, 43 }, entries = { C(100.0, 110.0) }, contact = false, finish = 9.0 },
        { id = "again", em = "em20b", at = 12.0, keep = { 0, 44 }, entries = { C(100.0, 110.0) }, contact = false, finish = 13.0 },
        { id = "last", em = "em20b", at = 75.0, keep = { 0, 45 }, entries = { C(100.0, 110.0) }, contact = false, finish = 76.0 },
    },
    expect = { rc = "oracle", fires = 1, add_ref_min = { AutoParryCalib = { ["app.EnemyCharacter"] = 4 } },
        probe_kinds = { "STOP", "RESUME" },
        err = { { tag = "APCal", level = "yellow", mod = "FIND", min = 1, max = 1 } } },
}


-- ---------- 合并后审查补充（2026-10-12，MERGE.md 实现记录「审查修订」）：逐刀等价测试原来管不住的放刀边界 ----------
-- 每个场景对应一个当时全套场景都抓不住的变异（审查报告里的编号写在括号里）；--merged 时照样和 A0 逐刀比

-- 56. 登记时 get_EmID 抛错（P60 / M37）：v1.6 的 on_message 没给它单独包 pcall，抛错整条预告不登记（ERR msg 红一条），这一招
-- 不放刀。合并版必须照读（MERGE 第 2.7 节）：挪到写 FIRE 时才读、或者包上 pcall，都会多放这一刀。之后的预告照常
M[#M + 1] = {
    name = "v16_emid_throw",
    smoke = false,
    desc = "登记时 get_EmID 抛错：这条预告不登记、不放刀（ERR msg 红一条）；下一招照常放刀接住",
    duration = 12,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    -- 神谕用 peek_fault 看同一份故障，所以用时间段（只盖住第一招发消息的那一帧），不用 max
    faults = { { key = "app.AttackAreaResult.get_EmID", mode = "throw", from = 2.95, to = 3.05, scripts = { AutoParryGS = true } } },
    attacks = {
        { id = "emid_fail", em = "em20", at = 3.0, keep = { 0, 170 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "after", em = "em20", at = 8.0, keep = { 0, 171 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 },
        err = { { tag = "AutoParryGS", level = "red", mod = "msg", min = 1, max = 1 } } },
}

-- 57. 否决视野的上沿（M11 / M11b）：长窗口条目在短条目进区间那一帧原始 hs ≈ 92（> H_veto = 90），不否决，照常放。
-- 把视野放宽到 ≤95 / ≤100 的实现会否决、一刀不放（long_veto 只取了 87、102 两个点）
M[#M + 1] = {
    name = "v16_horizon92",
    smoke = false,
    desc = "长窗口条目 hs≈92（略大于 H_veto=90）时短条目进区间：不否决，照常放刀接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20, em1 = EM1 },
    attacks = {
        { id = "long92", em = "em20", at = 9.0, keep = { 0, 172 }, entries = { D(110.0, 200.0) }, contact = false,
            events = { { at = 10.5, op = "finish" } } },
        { id = "short", em = "em1", at = 9.1, keep = { 0, 173 }, entries = { D(40.0, 50.0) }, contact = { r = 0.04 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 } },
}

-- 58. 长预告（M18）：400 帧（实测最长 402 帧），登记后约 6.2 s 才进区间。8 s 过期的规则下照常放；过期改成 6 s 的实现在进区间
-- 之前就把它丢了（v15_stale 的攻击 9.5 s 才进区间，6 s、8 s 过期结果一样，抓不住）
M[#M + 1] = {
    name = "v16_long_warning",
    smoke = false,
    desc = "400 帧的长预告，登记后约 6.2 s 进区间：8 s 过期的规则下照常放刀接住",
    duration = 14,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "w400", em = "em20", at = 3.0, keep = { 0, 174 }, entries = { D(400.0, 408.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 } },
}

-- 59. 候选侧的窗口宽度上限（M12b）：C = 2、A = 200、he − hs = 65。Q 进 [22, 28] 时原始 hs ≈ 122~128（> 90，不在否决视野里），
-- 只有候选条件 w ≤ 60 挡住它：不放。把上限放宽的实现会放（窗口宽度只在否决视野外才单独起作用，原来没有场景造出这种条目）
M[#M + 1] = {
    name = "v16_cand_w65",
    smoke = false,
    desc = "C=2、A=200、窗口 65 帧的条目在否决视野外进 Q 区间：候选要求 w≤60，不放",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em27 = EMC(2.0) },
    attacks = {
        { id = "w65", em = "em27", at = 3.0, keep = { 0, 175 }, entries = { D(200.0, 265.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 0 },
}

-- 60. 没进 (2,23) 就结束的放刀（M43 / M44）：请求在区间内一直被拒，streak 结束时 entered = 0，当场一行 RES NOCATCH。
-- 合并版的 RES 带 entered=0，菜单「没接住」+1。原来全部场景里一次都没走到这条路
M[#M + 1] = {
    name = "v16_entered0",
    smoke = false,
    desc = "放刀请求在区间内一直被拒，streak 没进 (2,23) 就结束：entered=0、当场 RES NOCATCH",
    duration = 10,
    reject_requests = 60,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "rej", em = "em20", at = 3.0, keep = { 0, 176 }, entries = { D(62.0, 70.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 1 },
}

-- 61. 该接过滤的读取顺序（N47）：ShellIndex 一直抛错。先来的效果攻击（EAR）在读弹体之前就判不该接，v1.6 不读它的 ShellIndex；
-- 后来的普通攻击进区间时才读、才报 filter 黄。把弹体提到最前面读的实现会在第一招就报黄（报黄时刻在等价测试里逐条比）
M[#M + 1] = {
    name = "v16_shell_order",
    smoke = false,
    desc = "ShellIndex 一直抛错：先来效果攻击（不读弹体）、后来普通攻击（读弹体、读不准不放）：filter 报黄在普通攻击进区间时",
    duration = 12,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "app.AttackAreaResult.DetectedData.get_ShellIndex", mode = "throw", from = 2.0,
        scripts = { AutoParryGS = true } } },
    attacks = {
        { id = "ear", em = "em20", at = 3.0, keep = { 0, 177 }, entries = { D(40.0, 48.0, { dmg = "EAR" }) }, contact = false },
        { id = "norm", em = "em20", at = 7.0, keep = { 0, 178 }, entries = { D(62.0, 70.0) }, contact = false },
    },
    expect = { rc = "oracle", fires = 0,
        err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } } },
}

-- 62. 帧逻辑「连续」出错才自停（P47）：读主角间歇抛错（每隔一帧）3 s，1.5 s 容忍期过后出错的帧按帧逻辑出错计（红、3in10s），
-- 但中间成功的帧把连续计数清零，永远凑不满 30 帧：不自停，之后照常放刀。成功帧不清零的实现约 0.7 s 后就自停
local function every_other_frame(_, w) return w.frame % 2 == 0 end
M[#M + 1] = {
    name = "v16_intermittent_err",
    smoke = false,
    desc = "读主角每隔一帧抛错 3 s：容忍期过后出错帧计帧逻辑红错误（3in10s），成功帧把连续计数清零、不自停；之后照常放刀接住",
    duration = 12,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "HunterCharacter.get_WeaponType", mode = "throw", from = 3.0, to = 6.0, where = every_other_frame,
        scripts = { AutoParryGS = true } } },
    attacks = {
        { id = "after", em = "em20", at = 8.0, keep = { 0, 179 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 },
        err = { { tag = "AutoParryGS", level = "red", mod = "frame", min = 20, max = 20 } },
        red = { "AutoParryGS" }, red_why = { AutoParryGS = { "3in10s" } } },
}

-- 63. 主角消失时结算还在等结局的那一刀（P55）：放刀进了 (2,23)、还在 CREDIT 1.3 s 里，主角消失 1 s：当场 RES NOCATCH
-- （dt ≈ 0.43），每次放刀都有结局。不在这里结算的实现要等主角回来、按 CREDIT 超时才结算（RES 的时刻和 dt 都不同）
M[#M + 1] = {
    name = "v16_lose_res",
    smoke = false,
    desc = "放刀进了 (2,23)、还在等结局时主角消失 1 s：当场结算成 NOCATCH；主角回来后照常放刀接住",
    duration = 12,
    probe_ver = false,      -- 探针在主角消失、回来时会把同一次上捞斩记成两段 PT，和这里要测的放刀结局无关
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    hunter_events = { { t = 4.0, op = "gap_char", dur = 1.0 } },
    attacks = {
        { id = "whiff", em = "em20", at = 3.0, keep = { 0, 180 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "after", em = "em20", at = 7.0, keep = { 0, 181 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, res_forced = { { 3.99, 4.02 } } },
}

-- 64. CREDIT 内又放了一刀（P31）：一直按着键，第一刀空放进 (2,23)，0.35 s 后玩家输入、回拔刀待机、马上又进 (2,21)，约 0.6 s 时
-- 第二招进区间：新 streak 开头就把上一刀结算成 NOCATCH（「又回到蓄力了，上一刀不可能再接住」），to = (1,14)。不在这里结算的
-- 实现要到第二刀进 (2,23) 那一帧才结算（RES 晚一帧）。玩家不用 auto：auto 每一刀都 0.35 s 输入，第二刀会在接触之前就收掉
M[#M + 1] = {
    name = "v16_rehold_res",
    smoke = false,
    desc = "第一刀空放后不到 0.5 s 就回到抵消蓄力、第二刀在 CREDIT 内放出：新 streak 开头结算上一刀（NOCATCH，to=(1,14)）",
    duration = 10,
    params = { input_min = 0.3 },
    config = cfg(),
    player = { events = { { 1.0, "hold" }, { 3.94, "input" } } },
    monsters = { em20 = EM20 },
    attacks = {
        { id = "first", em = "em20", at = 3.0, keep = { 0, 182 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "second", em = "em20", at = 3.7, keep = { 0, 183 }, entries = { D(56.0, 64.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 2, pt = { catch = 1 }, res_forced = { { 4.1, 4.3 } } },
}

-- 65. 拿的不是大剑时不放刀（P49）：登记时还是大剑，0.2 s 后换成别的武器（动作编号照样停在 (2,21)），条目进区间时不放；
-- 换回大剑后照常。active 里去掉「拿大剑」的实现会在别的武器上放刀（别的武器的 (2,21) 是别的动作）
M[#M + 1] = {
    name = "v16_weapon_switch",
    smoke = false,
    desc = "预告登记后换成别的武器、动作编号仍是 (2,21)：条目进区间时不放；换回大剑后的预告照常放刀接住",
    duration = 10,
    config = cfg(),
    player = auto(),
    weapon_type_at = { { 3.2, 3 }, { 4.6, 0 } },
    monsters = { em20 = EM20 },
    attacks = {
        { id = "other_weapon", em = "em20", at = 3.0, keep = { 0, 184 }, entries = { D(62.0, 70.0) }, contact = false },
        { id = "back_to_gs", em = "em20", at = 6.0, keep = { 0, 185 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 } },
}

-- 66. 窗口宽度为负的条目（P03）：he < hs。候选要求 0 ≤ he − hs，不放；之后正常的条目照常。候选条件去掉 w ≥ 0 的实现会放
M[#M + 1] = {
    name = "v16_negative_window",
    smoke = false,
    desc = "DANGER 条目 he < hs（窗口宽度为负）：不进候选、不放；之后正常的条目照常放刀接住",
    duration = 10,
    config = cfg(),
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "neg", em = "em20", at = 3.0, keep = { 0, 186 }, entries = { D(62.0, 50.0) }, contact = false },
        { id = "normal", em = "em20", at = 6.0, keep = { 0, 187 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    expect = { rc = "oracle", fires = 1, pt = { catch = 1 } },
}

-- ---------------------------------------------------------------------------
-- ---------- 合并模式的新场景（docs/autoparry/MERGE.md 第 6.5 节；只在 run.lua --merged 下跑） ----------
-- merged_only = true；runs 列出要跑的跑法（key 是输出子目录）：
--   kind = "guard"  归档的 v1.4.2 单独加载（防御的参照组 G-ref）；kind = "merged" 合并脚本；kind = "a0" 归档的 v1.6 单独加载
--   另可带 debug（合并版的调试日志开关，没写 config.AutoGuardGS 时用）、config / config_raw / faults_add / ui / drop_ui /
--   rc_transform / expect（覆盖场景的同名项，只对这一个跑法）
-- mexpect = 跨跑法的期望（run.lua 的 check_merged_only）：same_guard（防御副作用轨迹、防御计数逐项相同）、same_req（(2,23) 请求
--   序列相同）、same_fire（FIRE 的 t / Q0 / ent 相同）、same_fire_ids（按时刻对齐 FIRE 的 id 相同）、same_saved8（存下的防御 8 个键
--   和菜单读出来的值相同）、trace（防御轨迹里按顺序出现 / 不许出现 / 出现次数，Lua 模式，不含帧号）、gcounts / pcounts（菜单的
--   防御 / 放刀计数）、log、menu、final（Reset 之后共享参数的值、血量）、parry_cfg（配置迁移后的放刀配置）、hooks_partial
--   （初始化失败时钩子只要求是子集）、migrate（覆盖 run.lua 推算的「要不要迁移」）
-- 防御的场景都不载入探针（probe_ver = false）、预告只用 CAUTION：放刀那一半不会出手，G-ref 和合并版的游戏过程完全相同

-- 防御部分的配置（v1.4.2 的 8 个键里除 guard_angle 以外的 7 个），场景按需覆盖。没有 auto_parry / parry_lead，也没有旧的
-- AutoParryGS.json：合并版的放刀用默认值（开、28），不迁移
local function gcfg(over)
    local c = { enabled = true, guard_type = 1, respect_armor = true, auto_tackle = true, infinite_charge = false,
        lock_health = false, debug_log = true }
    for k, v in pairs(over or {}) do c[k] = v end
    return { AutoGuardGS = c }
end
local GUARD_RUNS = { { key = "guard_ref", kind = "guard" }, { key = "merged", kind = "merged" } }
-- 一招 CAUTION 预告 + 一次身体接触（at 时刻）；opts 可加 skip_damage_hook（这一下的 evHit_Damage 根本没被调用）
local function body_hit(id, at, keep, extra)
    local a = { id = id, em = "em20", at = at - 1.0, keep = { 0, keep }, entries = { C(100.0, 110.0) },
        contact = { at = at }, finish = at + 1.0 }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end

M[#M + 1] = {
    name = "guard_basic",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "拔刀待机、行为表能到防御（can_guard）时被打中：前置钩子开 TECHNICAL_GUARD、后置钩子关掉，自动防御 +1；"
        .. "G-ref（归档 v1.4.2 单独加载）和合并版的防御副作用轨迹、防御计数逐项相同",
    duration = 6,
    config = gcfg(),
    can_guard = true,
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 3.0, 60) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", has = { "^hit evHit_DamagePreProcess/pre on TECHNICAL_GUARD$", "^hit evHit_Damage/post off TECHNICAL_GUARD$" },
            count = { [" on "] = 1, [" off "] = 1 } } },
        gcounts = { merged = { guarded = 1, tackled = 0, already = 0, armor = 0, state = 0 } },
    },
}

M[#M + 1] = {
    name = "guard_type_normal",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "同 guard_basic，防御类型选普通防御（guard_type = 2）：开的是 GUARD",
    duration = 6,
    config = gcfg({ guard_type = 2 }),
    can_guard = true,
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 3.0, 61) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", has = { "^hit evHit_DamagePreProcess/pre on GUARD$", "^hit evHit_Damage/post off GUARD$" },
            absent = { "TECHNICAL_GUARD" } } },
        gcounts = { merged = { guarded = 1 } },
    },
}

M[#M + 1] = {
    name = "guard_armor_skip",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "带 SUPER_ARMOR（按住抵消蓄力）时挨打：不开标志、「跳过：霸体」+1（行为表照样能到防御，跳过的原因只能是霸体）",
    duration = 6,
    config = gcfg(),
    can_guard = true,
    player = { events = { { 1.0, "hold" } } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 3.0, 62) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", absent = { " on " } } },
        gcounts = { merged = { guarded = 0, armor = 1, state = 0 } },
    },
}

M[#M + 1] = {
    name = "guard_already",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "GUARD 已经开着（手动防御中）时挨打：「本来就在防御」+1，不再强开",
    duration = 6,
    config = gcfg(),
    can_guard = true,
    status_on = { GUARD = { { 2.5, 3.5 } } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 3.0, 63) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", absent = { " on " } } },
        gcounts = { merged = { guarded = 0, already = 1 } },
    },
}

M[#M + 1] = {
    name = "guard_blocked_attr",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "动作属性 DODGE 为真时挨打、收刀（weapon_on = false）时再打一次：「不能举剑」各 +1，不开标志",
    duration = 7,
    config = gcfg(),
    can_guard = true,
    attrs = { DODGE = { { 2.5, 3.5 } } },
    weapon_off = { { 4.5, 5.5 } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("dodge", 3.0, 64), body_hit("sheathed", 5.0, 65) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", absent = { " on " } } },
        gcounts = { merged = { guarded = 0, state = 2 } },
    },
}

M[#M + 1] = {
    name = "guard_tackle_lv1",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "(2,6) 蓄力中挨打：下一帧帧开头请求 (2,15) 肩撞，进入后「自动肩撞」+1；不开防御标志",
    duration = 6,
    config = gcfg(),
    can_guard = true,
    player = { events = { { 1.0, "charge" } } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 1.6, 66) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", has = { "^pre request %(2,15%) layer=0 flag=false$" }, absent = { " on ", "%(2,17%)" },
            count = { ["request %(2,15%)"] = 1 } } },
        gcounts = { merged = { tackled = 1, guarded = 0 } },
    },
}

M[#M + 1] = {
    name = "guard_tackle_lv3",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "(2,7) 强蓄力中挨打：请求 (2,17)，进入后「自动肩撞」+1",
    duration = 6,
    config = gcfg(),
    can_guard = true,
    player = { events = { { 1.0, "charge" } } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 2.4, 67) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", has = { "^pre request %(2,17%) layer=0 flag=false$" }, absent = { "%(2,15%)" },
            count = { ["request %(2,17%)"] = 1 } } },
        gcounts = { merged = { tackled = 1 } },
    },
}

M[#M + 1] = {
    name = "guard_tackle_cancel",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "蓄力中挨打的同一帧就松手（下一帧已离开蓄力，进 (2,0) 纵斩）：不请求，肩撞取消",
    duration = 6,
    config = gcfg(),
    can_guard = true,
    -- 玩家事件按 t ≤ 模拟时刻处理、接触按 t ≤ 模拟时刻 + 1e-9：同一帧要写早一点（模拟时刻累加有浮点误差）
    player = { events = { { 1.0, "charge" }, { 1.595, "release_charge" } } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 1.6, 68) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", absent = { "request" } } },
        gcounts = { merged = { tackled = 0 } },
    },
}

-- 防御角度：前置钩子改成设定值、后置钩子还原；抵消动作族里不改写（按钩子那一刻现读的动作，不是帧开头的快照）；
-- 后置钩子缺席时下一帧开头还原。9.0 s 那一下：帧开头还是拔刀待机，同一帧 update 里就切进了 (2,21)（hold_now），挨打时
-- 已经在抵消族里 —— 钩子里改用帧开头快照的实现会在这里改写角度（MERGE 第 6.7 节变异，副作用白名单抓）
M[#M + 1] = {
    name = "guard_angle",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "防御角度 120：前置钩子改两个角度字段、后置钩子还原成 70；(2,21) 里挨打、(2,23) 刀上接触都不改写；后置钩子没被调用"
        .. "时下一帧开头还原；同一帧刚切进 (2,21) 时挨打也不改写",
    duration = 11,
    config = gcfg({ guard_angle = 120 }),
    can_guard = true,
    player = { events = { { 3.0, "hold" }, { 4.5, "release" }, { 8.995, "hold_now" } } },
    monsters = { em20 = EM20 },
    attacks = {
        body_hit("idle", 2.0, 70),
        body_hit("in_charge", 4.0, 71),
        -- (2,23) 从约 4.51 s 开始，抵消窗口 [0.355, 0.80]：4.95 s 的接触打在刀上（ATTACK_PARRY_GET 也走受击前置钩子）
        { id = "blade", em = "em20", at = 4.3, keep = { 0, 72 }, entries = { C(100.0, 110.0) }, contact = { at = 4.95 },
            finish = 6.0 },
        body_hit("no_post", 8.0, 73, { contact = { at = 8.0, skip_damage_hook = true } }),
        body_hit("same_frame", 9.0, 74),
    },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged",
            has = { "^hit evHit_DamagePreProcess/pre set Wp00ActionParam%._GuardDegree=120",
                "^hit evHit_Damage/post set Wp00ActionParam%._GuardDegree=70",
                "^hit evHit_DamagePreProcess/pre set Wp00ActionParam%._GuardDegree=120",
                "^pre set Wp00ActionParam%._GuardDegree=70" },
            count = { ["_GuardDegree=120"] = 2, ["_AimGuardDegree=120"] = 2, [" on TECHNICAL_GUARD"] = 2, [" off TECHNICAL_GUARD"] = 2 } } },
        gcounts = { merged = { guarded = 2 } },
        final = { merged = { guard_deg = 70.0, aim_deg = 70.0, forced = 0 }, guard_ref = { guard_deg = 70.0, aim_deg = 70.0 } },
    },
}

-- 无限蓄力：开着且拿大剑时 7 个 _OverheatTime 改成 99999；换别的武器、主角消失、关开关、Reset 都还原成 3.0 / 2.5
local OVERHEAT0 = { _ChargeParam = 3.0, _ChargeParam_Strong = 3.0, _ChargeParam_Spirit = 3.0, _ChargeParam_Parry = 2.5,
    _ChargeParam_Fly = 3.0, _ChargeParam_Sliding = 3.0, _ChargeParam_BattleRide = 3.0 }
M[#M + 1] = {
    name = "guard_infinite_charge",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "无限蓄力：开着时 7 个 _OverheatTime 改成 99999；换武器、主角消失、关开关、Reset 都还原成 3.0 / 2.5（每次只在变的那一帧改）",
    duration = 9.5,
    config = gcfg({ infinite_charge = true }),
    weapon_type_at = { { 3.0, 3 }, { 4.0, 0 } },
    hunter_events = { { t = 5.0, op = "gap_char", dur = 1.0 } },
    ui = {
        { t = 7.0, kind = "checkbox", match = "##infinite_charge", value = false, script = "AutoGuardGS" },
        { t = 8.0, kind = "checkbox", match = "##infinite_charge", value = true, script = "AutoGuardGS" },
    },
    monsters = { em20 = EM20 },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", count = { ["_OverheatTime=99999"] = 28, ["_OverheatTime=3%.0"] = 24, ["_OverheatTime=2%.5"] = 4,
            ["^reset set "] = 7 } } },
        final = { merged = { overheat = OVERHEAT0 }, guard_ref = { overheat = OVERHEAT0 } },
    },
}

M[#M + 1] = {
    name = "guard_lock_health",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "锁血：开着时主玩家的 requestDamage、requestRedDamage 都跳过原函数（不扣血，已拦下 2 次），同场 NPC 的照常登记；"
        .. "不走 requestDamage 的扣血每帧补满；关掉后正常扣血",
    duration = 8,
    config = gcfg({ lock_health = true }),
    red_damage = { { t = 3.0, amount = 20.0 } },
    npc_damage = { { t = 3.5, amount = 30.0 } },
    hp_drain = { { t = 4.0, amount = 20.0 } },
    ui = { { t = 5.0, kind = "checkbox", match = "##lock_health", value = false, script = "AutoGuardGS" } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("locked", 2.0, 75), body_hit("unlocked", 6.0, 76) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", has = { "^hit requestDamage/pre skip requestDamage$", "^update requestRedDamage/pre skip requestRedDamage$",
            "set_Health" }, count = { ["skip "] = 2 } } },
        menu = { { run = "merged", seen = { "已拦下扣血 2 次" } } },
        final = { merged = { hp = 150.0 - 35.5 }, guard_ref = { hp = 150.0 - 35.5 } },
    },
}

-- ---- 配置迁移（MERGE 第 3.5 节的 10 条） ----

-- 放刀的验证世界：按住抵消蓄力，一招可接的 DANGER（提前量 28 时接住）
local MIG_WORLD = { duration = 8, player = auto(), monsters = { em20 = EM20 },
    attacks = { { id = "mig", em = "em20", at = 3.0, keep = { 0, 80 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } } } }
local function mig(t)
    local s = { merged_only = true, smoke = false, probe_ver = false }
    for k, v in pairs(MIG_WORLD) do s[k] = v end
    for k, v in pairs(t) do s[k] = v end
    return s
end
-- v1.4.2 的 8 个键（guard_angle 也写上）：合并版要原样读、迁移时原样写回
local GUARD8 = { enabled = true, guard_type = 1, guard_angle = 100, respect_armor = true, auto_tackle = true,
    infinite_charge = false, lock_health = false, debug_log = true }

M[#M + 1] = mig({
    name = "merge_migrate_v16",
    desc = "AutoGuardGS.json 是 v1.4.2 的 8 个键、旧 AutoParryGS.json {auto_parry=false, parry_lead=35, cfg_ver=3}：迁成关、35，"
        .. "加载那一刻就写回 10 个键（不带 cfg_ver），旧文件一个字节不变，一刀不放",
    config = { AutoGuardGS = GUARD8, AutoParryGS = { auto_parry = false, parry_lead = 35, cfg_ver = 3 } },
    runs = { { key = "merged", kind = "merged" } },
    mexpect = { parry_cfg = { merged = { lead = 35, auto_parry = false, fires = false, load_write = true, old_read = true } } },
})

-- 旧文件的提前量：cfg_ver 是 ≥3 的数才沿用（夹到 23~45），否则一律 28（和 v1.6 读同一个文件的结果相同：每一组另跑归档的 v1.6
-- 作对照，请求序列必须相同）
local OLD_VER = {
    { key = "v2_26", old = { parry_lead = 26, cfg_ver = 2 }, lead = 28 },
    { key = "nover_27_5", old = { parry_lead = 27.5 }, lead = 28 },
    { key = "str3", old = { cfg_ver = "3", parry_lead = 35 }, lead = 28 },
    { key = "v3_22", old = { cfg_ver = 3, parry_lead = 22 }, lead = 23 },
    { key = "v3_50", old = { cfg_ver = 3, parry_lead = 50 }, lead = 45 },
    { key = "v3_abc", old = { cfg_ver = 3, parry_lead = "abc" }, lead = 28 },
}
M[#M + 1] = (function()
    local runs, pc, same = {}, {}, {}
    for _, c in ipairs(OLD_VER) do
        runs[#runs + 1] = { key = c.key, kind = "merged", config = { AutoGuardGS = { debug_log = true }, AutoParryGS = c.old } }
        runs[#runs + 1] = { key = "a0_" .. c.key, kind = "a0", config = { AutoParryGS = c.old } }
        pc[c.key] = { lead = c.lead, auto_parry = true, load_write = true }
        same[#same + 1] = { "a0_" .. c.key, c.key }
    end
    return mig({
        name = "merge_migrate_old_ver",
        desc = "旧文件 cfg_ver=2 的 26、没有 cfg_ver 的 27.5、cfg_ver=\"3\" 的 35 → 28；cfg_ver=3 的 22 / 50 / \"abc\" → 23 / 45 / 28；"
            .. "每一组的请求序列和归档 v1.6 读同一个文件相同",
        runs = runs,
        mexpect = { parry_cfg = pc, same_req = same },
    })
end)()

M[#M + 1] = mig({
    name = "merge_migrate_none",
    desc = "没有旧文件：放刀用默认值（开、28），加载时不写 AutoGuardGS.json",
    config = { AutoGuardGS = { debug_log = true } },
    runs = { { key = "merged", kind = "merged" }, { key = "a0", kind = "a0", config = {} } },
    mexpect = { parry_cfg = { merged = { lead = 28, auto_parry = true, fires = true, load_write = false } },
        same_req = { { "a0", "merged" } } },
})

M[#M + 1] = mig({
    name = "merge_migrate_bad",
    desc = "旧文件不是 JSON：按没有旧文件处理（开、28），不报错、加载时不写；旧文件读盘抛错：ERR mod=cfg 黄恰好一行，同样按没有旧文件",
    config = { AutoGuardGS = { debug_log = true } },
    runs = {
        { key = "not_json", kind = "merged", config_raw = { AutoParryGS = "{ auto_parry = false, parry_lead: 35 " } },
        { key = "read_throw", kind = "merged", config = { AutoParryGS = { auto_parry = false, parry_lead = 35, cfg_ver = 3 } },
            faults_add = { { key = "json.load_file", mode = "throw", path = "^AutoParryGS%.json$", msg = "mock: 文件被占用" } },
            expect = { err = { { tag = "AutoParryGS", level = "yellow", mod = "cfg", min = 1, max = 1 } } } },
    },
    mexpect = { parry_cfg = { not_json = { lead = 28, auto_parry = true, fires = true, load_write = false },
        read_throw = { lead = 28, auto_parry = true, fires = true, load_write = false } } },
})

M[#M + 1] = mig({
    name = "merge_migrate_write_fail",
    desc = "迁移后写回 AutoGuardGS.json 失败（dump_file 返回 false）：ERR mod=cfg 黄恰好一行，内存里的迁移值照常生效（35）",
    config = { AutoGuardGS = { debug_log = true }, AutoParryGS = { auto_parry = true, parry_lead = 35, cfg_ver = 3 } },
    faults = { { key = "json.dump_file", mode = "false", phase = "load", path = "^AutoGuardGS%.json$", scripts = { AutoGuardGS = true } } },
    runs = { { key = "merged", kind = "merged" } },
    expect = { err = { { tag = "AutoParryGS", level = "yellow", mod = "cfg", min = 1, max = 1 } } },
    mexpect = { parry_cfg = { merged = { lead = 35, auto_parry = true, fires = true, load_write = true } } },
})

M[#M + 1] = mig({
    name = "merge_no_remigrate",
    desc = "AutoGuardGS.json 里已有 parry_lead=30（合并版写过）、旧文件 parry_lead=35 cfg_ver=3：用 30，不读旧文件、加载时不写",
    config = { AutoGuardGS = { debug_log = true, parry_lead = 30 }, AutoParryGS = { auto_parry = false, parry_lead = 35, cfg_ver = 3 } },
    runs = { { key = "merged", kind = "merged" } },
    mexpect = { parry_cfg = { merged = { lead = 30, auto_parry = true, fires = true, load_write = false, old_read = false } } },
})

-- 已有 8 个键的读法和 v1.4.2 一字不差（取值各异、也有类型不对的值）：存下的 8 个键、菜单读出来的值和 v1.4.2 读同一个文件相同
M[#M + 1] = {
    name = "merge_guard_keys",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "AutoGuardGS.json 的 v1.4.2 键取值各异（guard_angle=400 夹到 360、guard_type=3 不认、类型不对的忽略……）："
        .. "合并版读出来的值、存配置写回的 8 个键和归档 v1.4.2 读同一个文件逐个相同",
    duration = 4,
    monsters = { em20 = EM20 },
    runs = {
        { key = "guard_a", kind = "guard", config = { AutoGuardGS = { enabled = false, guard_type = 3, guard_angle = 400,
            respect_armor = "no", auto_tackle = false, infinite_charge = true, lock_health = true, debug_log = 1 } } },
        { key = "merged_a", kind = "merged", config = { AutoGuardGS = { enabled = false, guard_type = 3, guard_angle = 400,
            respect_armor = "no", auto_tackle = false, infinite_charge = true, lock_health = true, debug_log = 1 } } },
        { key = "guard_b", kind = "guard", config = { AutoGuardGS = { enabled = true, guard_type = 2, guard_angle = "90",
            respect_armor = false, auto_tackle = true, infinite_charge = false, lock_health = false, debug_log = true, cfg_ver = 3,
            scan = true } } },
        { key = "merged_b", kind = "merged", config = { AutoGuardGS = { enabled = true, guard_type = 2, guard_angle = "90",
            respect_armor = false, auto_tackle = true, infinite_charge = false, lock_health = false, debug_log = true, cfg_ver = 3,
            scan = true } } },
    },
    mexpect = { same_saved8 = { { "guard_a", "merged_a" }, { "guard_b", "merged_b" } },
        same_guard = { { "guard_a", "merged_a" }, { "guard_b", "merged_b" } } },
}

-- ---- 交互、开关、隔离 ----

-- 一个场景依次四段（MERGE 第 6.5 节 merge_interaction）：① (2,6) 普通蓄力中挨打 → 只出肩撞；② (2,21) 中有可接的 DANGER →
-- 只放刀，Q 和时刻与 v1.6 单独跑相同；③ (2,21) 中身体挨打 → 不出肩撞、不开防御标志（霸体）；④ (2,6) 中有 DANGER 进窗口 →
-- 不放刀（攻击不落下，免得出肩撞改变两边的游戏过程）。全程每帧最多一个 changeActionRequest（副作用白名单查）
M[#M + 1] = {
    name = "merge_interaction",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "交互：普通蓄力挨打只出肩撞；抵消蓄力里只放刀（和 v1.6 单独跑同一帧、同一个 Q）；抵消蓄力里挨打不肩撞不开标志；"
        .. "普通蓄力里 DANGER 进窗口不放刀；每帧最多一个动作请求",
    -- 第 2 段放刀接住后约 10.0 s 才回到拔刀待机（(2,27)→(2,28)→(2,29)），一直按着键，回来就重新进 (2,21)：第 3 段的身体
    -- 挨打放在 11.0 s；12.0 s 松手是手动上捞斩，空挥 3.6 s 后约 15.6 s 回到待机，第 4 段 16.0 s 才开始普通蓄力
    duration = 23,
    config = gcfg(),
    can_guard = true,
    player = { events = { { 1.0, "charge" }, { 3.0, "release_charge" }, { 5.0, "hold" }, { 12.0, "release" },
        { 16.0, "charge" }, { 20.0, "release_charge" } } },
    monsters = { em20 = EM20 },
    attacks = {
        body_hit("seg1_charge_hit", 1.8, 90),
        { id = "seg2_parry", em = "em20", at = 6.0, keep = { 0, 91 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        body_hit("seg3_parry_charge_hit", 11.0, 92),
        { id = "seg4_danger_in_ncharge", em = "em20", at = 17.0, keep = { 0, 93 }, entries = { D(62.0, 70.0) }, contact = false },
    },
    runs = { { key = "a0", kind = "a0", config = {} }, { key = "merged", kind = "merged" } },
    expect = { fires = 1 },
    mexpect = {
        same_req = { { "a0", "merged" } },
        same_fire = { { "a0", "merged" } },
        trace = { { run = "merged", count = { ["request %(2,15%)"] = 1, ["request %(2,17%)"] = 0, [" on "] = 0 } } },
        -- 霸体跳过 3 次：第 2 段刀上接触走两次受击前置钩子（两个刀碰撞体，(2,23) 带 SUPER_ARMOR），第 3 段身体挨打一次
        gcounts = { merged = { tackled = 1, guarded = 0, armor = 3 } },
        pcounts = { merged = { fires = 1, catch = 1 } },
    },
}

-- 调试日志 10 s 打开、20 s 关掉（toggle），和全程开着（on）、全程关着（off）比：请求序列相同；10 s 前一行 [AutoParryGS] 都没有；
-- 第一行 FIRE 前恰好一行 HDR；20 s 后没有 FIRE / RES；按时刻对齐，toggle 的 FIRE id 和 on 的相同（next_id 每刀都递增）
M[#M + 1] = {
    name = "merge_debug_toggle",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "调试日志 10 s 打开、20 s 关掉：10 s 前没有 [AutoParryGS] 行、第一行 FIRE 前恰好一行 HDR、20 s 后没有 FIRE/RES；"
        .. "请求序列和全程开、全程关相同；FIRE 的 id 和全程开着时同一刀相同",
    duration = 30,
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "d1", em = "em20", at = 3.0, keep = { 0, 94 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "d2", em = "em20", at = 8.0, keep = { 0, 95 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "d3", em = "em20", at = 13.0, keep = { 0, 96 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "d4", em = "em20", at = 18.0, keep = { 0, 97 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "d5", em = "em20", at = 24.0, keep = { 0, 98 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    runs = {
        { key = "toggle", kind = "merged", config = { AutoGuardGS = { debug_log = false } },
            ui = { { t = 10.0, kind = "checkbox", match = "##debug_log", value = true, script = "AutoGuardGS", cfg_key = "debug_log" },
                { t = 20.0, kind = "checkbox", match = "##debug_log", value = false, script = "AutoGuardGS", cfg_key = "debug_log" } } },
        { key = "on", kind = "merged", config = { AutoGuardGS = { debug_log = true } } },
        { key = "off", kind = "merged", config = { AutoGuardGS = { debug_log = false } } },
    },
    mexpect = {
        same_req = { { "on", "toggle", "off" } },
        same_fire_ids = { { "on", "toggle" } },
        log = {
            { run = "toggle", from = 0.0, to = 10.0, absent = { "%[AutoParryGS%]" } },
            { run = "toggle", from = 20.0, absent = { "%[AutoParryGS%] FIRE", "%[AutoParryGS%] RES" } },
            { run = "toggle", count = { ["%[AutoParryGS%] HDR"] = 1, ["%[AutoParryGS%] FIRE"] = 2 } },
            { run = "off", absent = { "%[AutoParryGS%]" } },
        },
        pcounts = { toggle = { fires = 5 }, off = { fires = 5 } },
    },
}

M[#M + 1] = {
    name = "merge_debug_off_silent",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "调试日志关着、没有任何错误：整个日志没有一行 [AutoParryGS]；[AutoGuardGS] 只有 loaded 那一行（可能再有一行 game guard angle）",
    duration = 12,
    config = { AutoGuardGS = { debug_log = false } },
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "s1", em = "em20", at = 3.0, keep = { 0, 99 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
        { id = "s2", em = "em20", at = 8.0, keep = { 0, 100 }, entries = { D(60.0, 68.0) }, contact = false },
    },
    runs = { { key = "merged", kind = "merged" } },
    mexpect = {
        log = { { run = "merged", only = { "^%[AutoGuardGS%] v1%.5 loaded$", "^%[AutoGuardGS%] game guard angle: " },
            count = { ["^%[AutoGuardGS%] v1%.5 loaded$"] = 1 } } },
        pcounts = { merged = { fires = 2 } },
    },
}

-- 加载隔离（MERGE 第 1.5 节）：防御初始化失败只停防御，放刀照常；放刀初始化失败只让放刀自停，防御照常
M[#M + 1] = {
    name = "merge_init_isolation_guard",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "类型 app.cHunterHealth 拿不到：防御初始化失败（菜单写明原因），受击时不开标志；放刀的请求序列和 v1.6 单独跑相同，"
        .. "放刀状态行仍是「正常」（防御出错不计入放刀的红黄）",
    duration = 10,
    config = gcfg(),
    can_guard = true,
    faults = { { key = "type:app.cHunterHealth", mode = "missing" } },
    player = { events = { { 4.0, "hold" } } },
    monsters = { em20 = EM20 },
    attacks = {
        body_hit("idle_hit", 2.0, 101),
        { id = "parry", em = "em20", at = 5.0, keep = { 0, 102 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    runs = { { key = "a0", kind = "a0", config = {} }, { key = "merged", kind = "merged" } },
    expect = { fires = 1 },
    mexpect = {
        hooks_partial = true,
        same_req = { { "a0", "merged" } },
        trace = { { run = "merged", absent = { " on " } } },
        menu = { { run = "merged", final = { "自动防御初始化失败", "状态：正常" } } },
        pcounts = { merged = { fires = 1, catch = 1 } },
    },
}

M[#M + 1] = {
    name = "merge_init_isolation_parry",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "类型 app.AttackAreaResult.RESULT_TYPE 拿不到：放刀写 RED why=init、状态「已自停」、一刀不放；防御照常"
        .. "（防御副作用轨迹、计数和 v1.4.2 单独跑相同）",
    duration = 10,
    config = gcfg(),
    can_guard = true,
    faults = { { key = "type:app.AttackAreaResult.RESULT_TYPE", mode = "missing" } },
    player = { events = { { 4.0, "hold" } } },
    monsters = { em20 = EM20 },
    attacks = {
        body_hit("idle_hit", 2.0, 103),
        { id = "danger", em = "em20", at = 5.0, keep = { 0, 104 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 } },
    },
    runs = GUARD_RUNS,
    expect = { err = { { tag = "AutoParryGS", level = "red", mod = "frame", min = 1, max = 1 } },
        red = { "AutoParryGS" }, red_why = { AutoParryGS = { "init" } } },
    mexpect = {
        hooks_partial = true,
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", has = { "^hit evHit_DamagePreProcess/pre on TECHNICAL_GUARD$" } } },
        gcounts = { merged = { guarded = 1 } },
        menu = { { run = "merged", final = { "已自停" } } },
        pcounts = { merged = { fires = 0 } },
        parry_cfg = { merged = { fires = false } },
    },
}

-- Reset 打断一次挨打的结算（前置钩子跑了、后置钩子没跑，场景在这一帧之后直接存配置、Reset），同时开着无限蓄力：
-- 角度、防御标志、7 个 _OverheatTime 都要还原
local RESET_WORLD = {
    merged_only = true,
    smoke = false,
    probe_ver = false,
    duration = 10,
    end_at = 3.0,
    config = gcfg({ guard_angle = 120, infinite_charge = true }),
    can_guard = true,
    monsters = { em20 = EM20 },
    attacks = { body_hit("cut", 3.0, 105, { contact = { at = 3.0, skip_damage_hook = true } }) },
}
M[#M + 1] = (function()
    local s = {}
    for k, v in pairs(RESET_WORLD) do s[k] = v end
    s.name = "merge_reset_restore"
    s.desc = "结算中途 Reset（前置钩子改了角度、开了标志，后置钩子没跑），无限蓄力开着：Reset 时角度、标志、7 个 _OverheatTime 全部还原"
    s.runs = GUARD_RUNS
    s.mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", has = { "^hit evHit_DamagePreProcess/pre set Wp00ActionParam%._GuardDegree=120",
            "^reset set Wp00ActionParam%._GuardDegree=70", "^reset off TECHNICAL_GUARD$", "^reset set Wp00ActionParam%.cCharge%._OverheatTime" } } },
        final = { merged = { guard_deg = 70.0, aim_deg = 70.0, forced = 0, overheat = OVERHEAT0 },
            guard_ref = { guard_deg = 70.0, aim_deg = 70.0, forced = 0, overheat = OVERHEAT0 } },
    }
    return s
end)()
M[#M + 1] = (function()
    local s = {}
    for k, v in pairs(RESET_WORLD) do s[k] = v end
    s.name = "merge_reset_restore_throw"
    s.desc = "同上，但 Reset 时 restore_hit_state 抛错（关防御标志那一步）：无限蓄力照样还原（v1.4.2 这时不会还原，本轮顺手修的缺陷）"
    s.faults = { { key = "FlagGroup.off", mode = "throw", phase = "reset", msg = "mock: off threw at reset" } }
    s.runs = { { key = "merged", kind = "merged" } }
    s.mexpect = { final = { merged = { overheat = OVERHEAT0 } } }
    return s
end)()

-- 菜单（MERGE 第 5 节）：一个树节点、控件 ID；放刀一节出错只降级它自己；防御一节出错不影响放刀一节；tree_pop 总是配对
M[#M + 1] = {
    name = "merge_menu",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "菜单：一个树节点「大剑自动防御 v1.5##AutoGuardGS」、全部控件 ID 按 5.1；放刀一节画控件抛错只降级它自己（ERR ui 黄）；"
        .. "防御一节抛错写一行 [AutoGuardGS] ui err、显示「菜单出错，见日志」，放刀一节照常，2 s 后重画、防御一节恢复（审查修订 3）",
    duration = 4,
    config = gcfg(),
    monsters = { em20 = EM20 },
    runs = {
        { key = "plain", kind = "merged" },
        { key = "parry_fault", kind = "merged", faults_add = { { key = "imgui.slider_int", mode = "throw", max = 1, from = 1.0 } },
            expect = { err = { { tag = "AutoParryGS", level = "yellow", mod = "ui", min = 1, max = 1 } } } },
        { key = "guard_fault", kind = "merged", faults_add = { { key = "imgui.combo", mode = "throw", max = 1, from = 1.0 } } },
    },
    mexpect = {
        menu = {
            { run = "plain", final = { "大剑自动防御 v1.5##AutoGuardGS", "启用自动防御（含自动肩撞）##enabled", "##guard_type",
                "##respect_armor", "##auto_tackle", "##guard_angle", "##angle_default", "自动放刀（实验）##ap_enabled",
                "提前量（真实剩余帧，1/60 秒）##ap_lead", "##infinite_charge", "##lock_health", "##reset_stats", "##debug_log",
                "状态：正常", "自动放刀：放了 0 刀" } },
            { run = "parry_fault", final = { "##enabled", "##guard_type", "状态：" }, final_absent = { "##ap_enabled", "##ap_lead" } },
            { run = "guard_fault", final = { "##ap_enabled", "##ap_lead", "##guard_type", "##guard_angle" }, seen = { "菜单出错，见日志" } },
        },
        log = { { run = "guard_fault", has = { "^%[AutoGuardGS%] ui err" } } },
    },
}

-- 否决侧读取的顺序和次数（MERGE 第 2.7 节「否决只看真假」）：同一结果里先是一条长窗口条目（触发否决），后是一条 _GuardType
-- 读取抛错的普通条目，两条同时进视野。v1.6 的否决侧对视野内每条 DANGER 条目都读攻击参数：这一条进视野的第一个求值帧就报
-- filter 黄；「见到第一个否决就不读后面的条目」的实现要等这一条进窗口、候选侧读它时才报 —— 放不放刀不变（反正否决），
-- 只有报黄的时刻变了（MERGE 第 6.7 节的变异，现有 133 个场景都抓不到它，这里补一个合并模式的场景，和 v1.6 单独跑比错误时刻）
local function of_ap(name)
    return function(o)
        local f = rawget(o, "__f")
        local ud = f and f._UserData
        local m = ud and rawget(ud, "__m")
        return m ~= nil and m.get_Name ~= nil and m.get_Name(ud) == name
    end
end
M[#M + 1] = {
    name = "merge_veto_read_order",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "否决侧对视野内每条 DANGER 条目都读攻击参数（见到否决也不停）：长窗口否决 + 后一条 _GuardType 读不出，filter 报黄的时刻"
        .. "和 v1.6 单独跑相同（读取顺序变了的话报黄会晚到这一条进窗口时）",
    duration = 8,
    config = { AutoGuardGS = { debug_log = true }, AutoParryGS = { auto_parry = true, parry_lead = 28, debug_log = true, cfg_ver = 3 } },
    player = auto(),
    monsters = { em20 = EM20 },
    faults = { { key = "app.cAttackParamEm._GuardType", mode = "throw", where = of_ap("EmAtk_em20_0_88_2"),
        scripts = { AutoParryGS = true, AutoGuardGS = true } } },
    attacks = {
        { id = "pair", em = "em20", at = 3.0, keep = { 0, 88 }, entries = { D(40.0, 150.0), D(80.0, 88.0) }, contact = false,
            finish = 7.0 },
    },
    runs = { { key = "a0", kind = "a0" }, { key = "merged", kind = "merged" } },
    expect = { fires = 0, err = { { tag = "AutoParryGS", level = "yellow", mod = "filter", min = 1, max = 1 } } },
    mexpect = { same_req = { { "a0", "merged" } }, same_err = { { "a0", "merged" } } },
}

-- 引用记账的负对照（MERGE 第 6.5 节；v16_ref_neg_probe / v16_ref_local_noaddref 的合并版）
M[#M + 1] = {
    name = "merge_ref_neg_probe",
    merged_only = true,
    smoke = false,
    probe_ver = "1.0.1",
    desc = "负对照：合并版 + 归档 APCal 1.0.1。探针停止记录（手动 release）后游戏放手：合并版下一帧访问已回收对象 → 必须出现 DEAD_OBJECT",
    duration = 10,
    drop_after = 0,
    holder = "empty",
    config = { AutoGuardGS = { debug_log = true } },
    player = auto(),
    monsters = { em20 = EM20 },
    ui = { { t = 5.0, kind = "checkbox", match = "停止记录", value = true, script = "AutoParryCalib" } },
    attacks = {
        { id = "shared", em = "em20", at = 3.0, keep = { 0, 89 }, entries = { C(300.0, 310.0) }, contact = false, finish = 6.0 },
    },
    runs = { { key = "merged", kind = "merged" } },
    expect = { dead_object = "required", probe_checks = false,
        err = { { tag = "AutoParryGS", level = "red", mod = "frame", min = 1, max = 2 } } },
}

M[#M + 1] = {
    name = "merge_ref_local_noaddref",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "负对照：结果是局部对象，被测脚本是测试生成的去掉 r:add_ref() 的合并版副本（源码里必须恰好一处）：消息钩子一结束对象就销毁，"
        .. "下一帧访问 → 必须 DEAD_OBJECT",
    duration = 10,
    config = { AutoGuardGS = { debug_log = true } },
    player = auto(),
    monsters = { em20 = EM20 },
    attacks = {
        { id = "local", em = "em20", at = 3.0, keep = { 0, 47 }, entries = { D(62.0, 70.0) }, contact = { r = 0.03 },
            local_result = true },
    },
    runs = { { key = "merged", kind = "merged", rc_transform = "strip_add_ref" } },
    expect = { dead_object = "required",
        err = { { tag = "AutoParryGS", level = "red", mod = "frame", min = 1, max = 2 } } },
}

-- ---- 合并后审查补充（2026-10-12，MERGE.md 实现记录「审查修订」）：修过的三处运行时边角 + 原来没有约束的防御 / 配置 / 隔离 ----

-- 快照读到一半抛错时，防御段照 v1.4.2 自己再读（审查修订 1）：读动作控制器抛错 2.5~3.5 s（放刀段在 1.5 s 容忍期内整帧跳过，
-- 不报错），3.0 s 关掉无限蓄力、3.2 s 有一次不走 requestDamage 的扣血。v1.4.2 平时不读动作（没有肩撞请求），照常在关开关的
-- 那一帧还原 7 个 _OverheatTime、下一帧补满血；合并版必须同一帧做同样的事（修之前要拖到故障结束的 3.5 s）
M[#M + 1] = {
    name = "guard_read_fault",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "读动作控制器抛错 2.5~3.5 s（放刀段容忍期内）：3.0 s 关无限蓄力、3.2 s 扣血，防御段照 v1.4.2 自己读，"
        .. "还原 _OverheatTime、补满血都和 v1.4.2 同一帧",
    duration = 6,
    config = gcfg({ infinite_charge = true, lock_health = true }),
    faults = { { key = "ActionController.get_CurrentActionID", mode = "throw", from = 2.5, to = 3.5 } },
    ui = { { t = 3.0, kind = "checkbox", match = "##infinite_charge", value = false, script = "AutoGuardGS" } },
    hp_drain = { { t = 3.2, amount = 20.0 } },
    monsters = { em20 = EM20 },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", has = { "_OverheatTime=99999", "_OverheatTime=3%.0", "set_Health" } } },
        final = { merged = { overheat = OVERHEAT0, hp = 150.0 }, guard_ref = { overheat = OVERHEAT0, hp = 150.0 } },
    },
}

-- 肩撞请求在等时读动作抛错（N59）：(2,6) 蓄力中 1.6 s 挨打，下一帧读动作抛错（只这一帧）。v1.4.2 的帧逻辑在 update_tackle 读动作时
-- 抛错、清掉肩撞请求，不出肩撞；合并版快照抛错后自己再读、同样抛错，由 guard_tick 清掉。不清的实现下一帧照常请求肩撞
M[#M + 1] = {
    name = "guard_tackle_read_fault",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "蓄力中挨打、肩撞请求在等时读动作抛错一帧：和 v1.4.2 一样清掉请求、不出肩撞",
    duration = 6,
    config = gcfg(),
    can_guard = true,
    player = { events = { { 1.0, "charge" } } },
    faults = { { key = "ActionController.get_CurrentActionID", mode = "throw", from = 1.605, to = 1.615 } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 1.6, 107) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", absent = { "request" } } },
        gcounts = { merged = { tackled = 0 } },
    },
}

-- 同一帧两下身体接触（D02）：两招同一时刻打中，受击前置钩子同一帧跑两次（第一下的后置钩子缺席）。防御角度的原值只能保存一次
-- （v1.4.2 的「已经改过还没还原就别再保存」），否则第二次把改过的 120 当原值存下，结算后、帧开头、Reset 都还原成 120
M[#M + 1] = {
    name = "guard_double_hit",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "两招同一时刻打中（同一帧两次受击前置钩子），防御角度 120：原值只保存一次，最后还原成 70",
    duration = 6,
    config = gcfg({ guard_angle = 120 }),
    can_guard = true,
    monsters = { em20 = EM20 },
    attacks = { body_hit("h1", 3.0, 81, { contact = { at = 3.0, skip_damage_hook = true } }), body_hit("h2", 3.0, 82) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", count = { ["_GuardDegree=120"] = 1 } } },
        final = { merged = { guard_deg = 70.0, aim_deg = 70.0, forced = 0 }, guard_ref = { guard_deg = 70.0, aim_deg = 70.0 } },
    },
}

-- 抵消动作族的上界是 (2,29)（D01）：手动放出的上捞斩接住后 (2,27)→(2,28)→(2,29)，在 (2,28)、(2,29) 里各挨一下：都不改写防御角度
-- （v1.4.1 起抵消族 (2,21)~(2,29) 不改写）。上界写成 28 的实现会在 (2,29) 里改写
M[#M + 1] = {
    name = "guard_angle_close",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "防御角度 120：手动上捞斩接住后在 (2,28)、(2,29) 里挨打，都不改写角度（抵消族到 (2,29) 为止）",
    duration = 9,
    config = gcfg({ guard_angle = 120 }),
    can_guard = true,
    player = { events = { { 3.0, "hold" }, { 4.5, "release" } } },
    monsters = { em20 = EM20 },
    attacks = {
        -- (2,23) 约 4.51 s 开始，4.95 s 的接触打在刀上 → (2,27) → 约 6.03 s (2,28) → 约 6.88 s (2,29) → 约 7.88 s 回拔刀待机
        { id = "blade", em = "em20", at = 4.3, keep = { 0, 108 }, entries = { C(100.0, 110.0) }, contact = { at = 4.95 },
            finish = 6.0 },
        body_hit("in_close_move", 6.4, 109),
        body_hit("in_close_slash", 7.3, 110),
    },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", absent = { "_GuardDegree=120" } } },
        final = { merged = { guard_deg = 70.0, aim_deg = 70.0 }, guard_ref = { guard_deg = 70.0, aim_deg = 70.0 } },
    },
}

-- 肩撞请求的超时是 0.3 s（D04）：挨打后前 22 次请求被拒（约 0.24 s，模拟挨打后的顿帧），第 23 次接受、进肩撞、「自动肩撞」+1。
-- 超时写成 0.2 s 的实现在被接受之前就放弃了
M[#M + 1] = {
    name = "guard_tackle_timeout",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "肩撞请求前 22 次被拒（约 0.24 s）：0.3 s 超时之内第 23 次被接受，照常出肩撞",
    duration = 6,
    reject_requests = 22,
    config = gcfg(),
    can_guard = true,
    player = { events = { { 1.0, "charge" } } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 1.6, 111) },
    runs = GUARD_RUNS,
    mexpect = {
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", count = { ["request %(2,15%)"] = 23 } } },
        gcounts = { merged = { tackled = 1 } },
    },
}

-- 放刀初始化失败（自停）不停防御的帧逻辑（M40）：merge_init_isolation_parry 只测了受击钩子驱动的防御；这里测帧开头驱动的三项 ——
-- 肩撞请求、无限蓄力的改写和还原、锁血每帧补满 —— 和 v1.4.2 单独跑逐项相同。「放刀自停就整段跳过帧回调」的实现三项全停
M[#M + 1] = {
    name = "merge_isolation_parry_frame",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "放刀初始化失败（自停）后，帧开头驱动的防御照常：肩撞请求、无限蓄力改写与还原、锁血补满，和 v1.4.2 单独跑相同",
    duration = 6,
    config = gcfg({ infinite_charge = true, lock_health = true }),
    can_guard = true,
    faults = { { key = "type:app.AttackAreaResult.RESULT_TYPE", mode = "missing" } },
    player = { events = { { 1.0, "charge" } } },
    monsters = { em20 = EM20 },
    attacks = { body_hit("hit", 1.6, 112) },
    hp_drain = { { t = 3.5, amount = 20.0 } },
    ui = { { t = 4.0, kind = "checkbox", match = "##infinite_charge", value = false, script = "AutoGuardGS" } },
    runs = GUARD_RUNS,
    expect = { err = { { tag = "AutoParryGS", level = "red", mod = "frame", min = 1, max = 1 } },
        red = { "AutoParryGS" }, red_why = { AutoParryGS = { "init" } } },
    mexpect = {
        hooks_partial = true,
        same_guard = { { "guard_ref", "merged" } },
        trace = { { run = "merged", has = { "_OverheatTime=99999", "request %(2,15%)", "set_Health", "_OverheatTime=3%.0" } } },
        gcounts = { merged = { tackled = 1 } },
        menu = { { run = "merged", final = { "已自停" } } },
    },
}

-- 菜单：Catalog 暂时为 nil（审查修订 3；推测是标题画面、读盘时，没直接测到）：防御一节显示「防御角度：等待读取角色数据……」，
-- 不抛错、不写 ui err；Catalog 有了以后照常显示滑块。v1.4.2 在这里索引 nil、菜单那几帧抛错（它单独跑会判失败，所以只跑合并版）
M[#M + 1] = {
    name = "merge_menu_catalog_nil",
    merged_only = true,
    smoke = false,
    probe_ver = false,
    desc = "PlayerManager.get_Catalog 0~2 s 返回 nil：防御角度一行显示「等待读取角色数据」、不报菜单错误，之后照常显示滑块",
    duration = 4,
    config = gcfg(),
    faults = { { key = "app.PlayerManager.get_Catalog", mode = "nil", to = 2.0 } },
    monsters = { em20 = EM20 },
    runs = { { key = "merged", kind = "merged" } },
    mexpect = {
        menu = { { run = "merged", seen = { "防御角度：等待读取角色数据" }, final = { "##guard_angle", "##guard_type" },
            never = { "菜单出错" } } },
        log = { { run = "merged", absent = { "%[AutoGuardGS%] ui err" } } },
    },
}

-- ---- 配置（审查修订 2 和原来没有约束的两条）----

-- AutoGuardGS.json 读盘抛错（文件被占用等）：迁移过的配置（guard_angle=360、锁血、parry_lead=33……）这次读不出来、旧 AutoParryGS.json
-- 还在。只在内存里迁（提前量 28），加载时、存配置时都不写 AutoGuardGS.json（否则拿默认值把原文件整份盖掉），菜单写明这次不保存；
-- ERR mod=cfg 黄一行。另一组：AutoGuardGS.json 不存在、旧文件在 —— 只在内存里迁，加载时不写，存配置时照常写
M[#M + 1] = mig({
    name = "merge_cfg_read_throw",
    desc = "读 AutoGuardGS.json 抛错：只在内存里迁移（28）、这次加载一个字节都不写、菜单写明不保存、ERR cfg 黄一行；"
        .. "AutoGuardGS.json 不存在：只在内存里迁移（33），加载时不写、存配置时照常写",
    runs = {
        { key = "read_throw", kind = "merged",
            config = { AutoGuardGS = { enabled = true, guard_type = 2, guard_angle = 360, respect_armor = true, auto_tackle = true,
                infinite_charge = true, lock_health = true, debug_log = true, auto_parry = true, parry_lead = 33 },
                AutoParryGS = { auto_parry = true, parry_lead = 28, cfg_ver = 3 } },
            faults_add = { { key = "json.load_file", mode = "throw", max = 1, path = "^AutoGuardGS%.json$", msg = "mock: 文件被占用" } },
            expect = { err = { { tag = "AutoParryGS", level = "yellow", mod = "cfg", min = 1, max = 1 } } } },
        { key = "no_guard_file", kind = "merged", config = { AutoParryGS = { auto_parry = true, parry_lead = 33, cfg_ver = 3 } } },
    },
    mexpect = {
        parry_cfg = { read_throw = { lead = 28, auto_parry = true, fires = true, load_write = false, old_read = true },
            no_guard_file = { lead = 33, auto_parry = true, fires = true, load_write = false, old_read = true } },
        menu = { { run = "read_throw", final = { "读不出配置文件 AutoGuardGS.json" } },
            { run = "no_guard_file", never = { "读不出配置文件" } } },
    },
})

-- 迁移条件看两个键（C01）：AutoGuardGS.json 只有 auto_parry=false（没有 parry_lead）就已经是合并版自己的配置，不迁移、不读旧文件。
-- 只看 parry_lead 的实现会再迁一次（旧文件 auto_parry=true、35），还在加载时覆盖文件
M[#M + 1] = mig({
    name = "merge_cfg_only_auto_parry",
    desc = "AutoGuardGS.json 只有 auto_parry=false：不迁移（旧文件 auto_parry=true、parry_lead=35、cfg_ver=3 不读），提前量 28、"
        .. "一刀不放、加载时不写",
    config = { AutoGuardGS = { debug_log = true, auto_parry = false }, AutoParryGS = { auto_parry = true, parry_lead = 35, cfg_ver = 3 } },
    runs = { { key = "merged", kind = "merged" } },
    mexpect = { parry_cfg = { merged = { lead = 28, auto_parry = false, fires = false, load_write = false, old_read = false } } },
})

-- AutoGuardGS.json 自己的 parry_lead 也要经 clamp_lead（N55，MERGE 第 3.2 节）：50 → 45；不是有限数值（"abc"）用默认 28。
-- 有这个键就不迁移、不读旧文件（旧文件故意写成 auto_parry=false）。45 那一组的请求序列和归档 v1.6 读到 50（cfg_ver=3）相同
M[#M + 1] = mig({
    name = "merge_cfg_lead_clamp",
    desc = "AutoGuardGS.json 的 parry_lead=50 夹到 45、\"abc\" 用默认 28（不迁移、不读旧文件）；45 那一组和归档 v1.6 读到 50 的请求序列相同",
    runs = {
        { key = "hi", kind = "merged", config = { AutoGuardGS = { debug_log = true, parry_lead = 50 },
            AutoParryGS = { auto_parry = false, parry_lead = 35, cfg_ver = 3 } } },
        { key = "abc", kind = "merged", config = { AutoGuardGS = { debug_log = true, parry_lead = "abc" },
            AutoParryGS = { auto_parry = false, parry_lead = 35, cfg_ver = 3 } } },
        { key = "a0_hi", kind = "a0", config = { AutoParryGS = { auto_parry = true, parry_lead = 50, cfg_ver = 3 } } },
    },
    mexpect = {
        parry_cfg = { hi = { lead = 45, auto_parry = true, load_write = false, old_read = false },
            abc = { lead = 28, auto_parry = true, load_write = false, old_read = false } },
        same_req = { { "a0_hi", "hi" } },
    },
})

return M
