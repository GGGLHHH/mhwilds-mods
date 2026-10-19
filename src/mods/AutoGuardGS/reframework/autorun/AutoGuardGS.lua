-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 GGG <1635656638@qq.com>
-- AutoGuardGS v1.5：大剑自动防御 + 自动放刀（实验）
--
-- 入口：配置、基础设施（日志、放刀记录、错误分级、性能计数）、把两个部件装起来，挂帧回调、Reset、存配置、菜单。
--   自动防御 → AutoGuardGS/guard.lua（原 AutoGuardGS v1.4.2）；自动放刀 → AutoGuardGS/parry.lua（原 AutoParryGS v1.6）。
--   两部分共用一个菜单、一个配置文件 reframework/data/AutoGuardGS.json、一个帧回调，互相看不见对方的状态。
--   共享库在 AutoGuardGS/lib/（源码 src/lib/，打包时复制进来，见 docs/ARCHITECTURE.md）。
-- 文档：游戏内部结构和实测结论 docs/NOTES.md；放刀规则 docs/autoparry/V16.md（规则版本 1.6）；两个脚本怎么合并、怎么验收
--   docs/autoparry/MERGE.md。
--
-- 调试日志（菜单「调试日志」，默认关，两部分共用）：防御写 [AutoGuardGS] 调试行和每 5 秒一行 PERF；放刀每次写两行
--   [AutoParryGS] FIRE（放刀）、RES（结局），本次加载第一行之前补一行 HDR。放刀出错的 ERR / RED 不看开关总写。
--   标签沿用 [AutoParryGS]，意思是「放刀记录」：tools/apcal_analyze.py 和旧日志都按它找。
local LIB = "AutoGuardGS.lib."
local util = require(LIB .. "util")
local Log = require(LIB .. "log")
local Record = require(LIB .. "record")
local Health = require(LIB .. "health")
local Prof = require(LIB .. "prof")
local Config = require(LIB .. "config")
local Ui = require(LIB .. "ui")
local Player = require(LIB .. "wilds.player")
local Weapon = require(LIB .. "wilds.weapon")
local K = require("AutoGuardGS.const")
local Guard = require("AutoGuardGS.guard")
local Parry = require("AutoGuardGS.parry")

-- ---------- §1 配置、统计、日志 ----------

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
    parry_lead = K.LEAD_DEFAULT,   -- 提前量 L（真实剩余帧）
}

-- 菜单统计，「清零统计」一次清两部分。放刀：fires 每次放刀 +1，其余四个按结局各计一次（fires 减去它们 = 还在等结局的那一刀）
local stats = { guarded = 0, skipped_armor = 0, skipped_state = 0, already_guarding = 0, tackled = 0, damage_blocked = 0,
    fires = 0, catch26 = 0, catch27 = 0, recoils = 0, nocatch = 0 }

-- 防御部分的日志：调试行受开关控制；出错写警告（每类每次加载最多 GUARD_WARN_MAX 行），不进放刀的红黄计数（两部分互不牵连）
local L = Log.new({ tag = K.TAG, debug_on = function() return config.debug_log end, warn_max = K.GUARD_WARN_MAX })

-- 性能计数：frame = 整个帧回调（两部分）；dmg_pre / dmg = 受击钩子；msg = 放刀的消息钩子。只在打开调试日志时每 5 秒写一行
local prof = Prof.new({ keys = { "frame", "dmg_pre", "dmg", "msg" }, interval = 5.0,
    on_report = function(text) L.debug("PERF " .. text) end })

-- ---------- §2 放刀记录与错误分级 ----------
-- 日志行 "[AutoParryGS] KIND k=v ..."，格式见 lib/record。留下来的字段格式和 v1.6 完全相同，分析脚本照读（MERGE 4.2）
local H     -- 错误分级（下面建）；格式化失败也要计错误
local F = util.formatter(function(msg) if H then H.note("frame", msg) end end)
local parry   -- 放刀部件（§5 建）：HDR 的 enum_skip 从它这里取
local session = os.time()
-- HDR 懒写：默认不记，调试日志关着、又没出错时一行 [AutoParryGS] 都不写；本次加载第一次写别的 [AutoParryGS] 行之前自动
-- 补一行。补写的 auto_parry、lead 是那一刻的值。加载期间写的行（初始化出错的 ERR / RED）先攒着，加载完再写（§8）
local R = Record.new({ tag = K.REC_TAG, fmt = F, header_kind = "HDR",
    spec = {
        HDR = "ver:s session:i auto_parry:b lead:i L_min:i W_long:i H_veto:i credit:f1 rule:s filter:s c_lo:f2 c_hi:f2 "
            .. "host:s enum_skip:s",
        FIRE = "id:i t:f4 L:i R0:f2 he0:f2 ent:h res:h em:s keep:s from:s C1:f3 Cf:f3 mf:f3 nchg:i dX:f2 A0:f2 Q0:f2",
        RES = "id:i t:f4 outcome:s dt:f3 to:s entered:b",
        ERR = "mod:s level:s msg:s",
        RED = "t:f4 mod:s why:s",
    },
    header = function()
        return { K.PARRY_RULE, session, config.auto_parry, config.parry_lead, K.LEAD_MIN, K.LONG_WINDOW,
            K.VETO_HORIZON, K.CREDIT, "E5c", "g1", K.C_LO, K.C_HI, K.HOST, parry and parry.enum_skip }
    end })
-- 错误分级（CONTRACT 2.1），不许静默吞错：核心模块 10 s 内 3 次标红；可选模块第一次出错就标黄（多数同时停用那项读取，
-- items / speed / filter / filter_enum 例外，见 parry 的 SOFT_MODS）。只管放刀和配置读写；防御出错走 L.warn_err
H = Health.new({ core = { msg = true, frame = true, fire = true }, emit = R.emit,
    red_window = K.RED_WINDOW, red_count = K.RED_COUNT, log_max = K.ERR_LOG_MAX })

-- ---------- §3 配置 ----------
-- 只接受认识的键和合法的值，前 8 个键的读法和 v1.4.2 一字不差；不认识的键（旧版留下的 cfg_ver、lead_rotation、scan 等）
-- 忽略。读的时候抛错：这次加载一律不写配置（lib/config；v1.4.2 读配置不包 pcall，抛错时整个脚本加载失败，同样一个字节都不写）
local cfg = Config.new({ path = K.CONFIG_PATH, data = config,
    on_error = function(err) H.note("cfg", err) end,
    validators = {
        guard_angle = function(v) return type(v) == "number" and util.clamp(v, K.ANGLE_MIN, K.ANGLE_MAX) or nil end,
        guard_type = function(v) return (v == 1 or v == 2) and v or nil end,
        parry_lead = function(v) return util.finite(v) and K.clamp_lead(v) or nil end,
    } })

do
    -- 从旧的 AutoParryGS.json 迁移，只迁一次（MERGE 3.3）：AutoGuardGS.json 里 auto_parry、parry_lead 两个键都没有时才迁。
    -- 取值和 AutoParryGS v1.6 读同一个文件得到的完全相同：auto_parry 是布尔才收；cfg_ver 不是 ≥3 的数（缺失、1、2、
    -- 字符串 "3"）时旧提前量是名义帧口径，一律用 28。debug_log 不迁：调试日志只用本脚本自己的开关。
    -- 迁完立刻写回 AutoGuardGS.json，以后不再读旧文件。旧文件只读，不改不删：回滚到 v1.6 时它还要用。
    -- 旧文件不存在或内容坏了：用默认值、不写回（下次加载再试一次，结果相同）。
    -- 只有 AutoGuardGS.json 读出了表才在加载时写回：文件不存在、读不出来时只在内存里迁，等存配置时再写。否则迁移完以后
    -- 哪次加载读盘偶发失败，就会在加载那一刻拿默认值把用户的防御设置整份盖掉（旧文件永远在，每次都会走到这里；审查修订）
    local function migrate_parry_config(loaded)
        if loaded and (loaded.auto_parry ~= nil or loaded.parry_lead ~= nil) then return end
        local ok, old = Config.read(K.LEGACY_PARRY_CONFIG)
        if not ok then
            H.note("cfg", old)
            return
        end
        if type(old) ~= "table" then return end
        if type(old.auto_parry) == "boolean" then config.auto_parry = old.auto_parry end
        local ver = old.cfg_ver
        if type(ver) == "number" and ver >= K.LEGACY_CFG_VER and util.finite(old.parry_lead) then
            config.parry_lead = K.clamp_lead(old.parry_lead)
        end
        if loaded then cfg.save() end
    end

    local ok, err = pcall(function() migrate_parry_config(cfg.load()) end)
    if not ok then H.note("cfg", err) end
end

-- ---------- §4 帧开头的主角快照 ----------
-- 每帧开头读一次，交给防御和放刀两段共用（两段之间没有游戏更新，读到的值相同）。调用顺序和 AutoParryGS v1.6 的 read_hunter
-- 一字不差：主角 → 地址 → 武器 → 动作控制器 → 动作 ID。没有主角返回 nil；动作 ID 读不到时 cat / idx 为 nil
local function read_hunter()
    local hunter, addr, wtype, cat, idx = Player.snapshot()
    if not hunter then return nil end
    return hunter, addr, wtype == Weapon.TYPE.LONG_SWORD, cat, idx   -- 游戏内部名 LONG_SWORD = 大剑
end

-- ---------- §5 两个部件 ----------
-- 先防御后放刀（初始化、帧回调都是这个顺序），和原来两个脚本时一样（REF 按文件名字母序加载，AutoGuardGS 先跑，日志时间戳实测）。
-- 防御初始化失败只停防御（guard.ready = false），放刀照常；放刀的核心类型拿不到就自停（H.stopped），防御照常（MERGE 1.5）
local guard = Guard.new({ config = config, stats = stats, L = L, prof = prof })
parry = Parry.new({ config = config, stats = stats, F = F, R = R, H = H, prof = prof })

-- ---------- §6 帧回调、Reset、存配置 ----------
-- 帧回调只有一个，顺序固定：PERF → 防御状态还原兜底 → 读主角快照 → 防御 → 放刀。每段各自 pcall，一段出错不影响另一段
re.on_pre_application_entry("UpdateBehavior", prof.timed("frame", function()
    local now = os.clock()
    local ok, err = pcall(prof.report)
    if not ok then L.warn_err("perf", err) end
    -- 受击钩子打开的标志、改写的角度不许跨帧（结算后的还原万一没跑到，这里兜底）
    ok, err = pcall(guard.restore_hit_state)
    if not ok then L.warn_err("restore", err) end
    if not guard.ready and H.stopped then return end   -- 两部分都不工作了：不读主角
    local rok, hunter, addr, gs, cat, idx = pcall(read_hunter)
    if guard.ready then guard.tick(rok, hunter, gs, cat, idx) end
    if not H.stopped then parry.tick(now, rok, hunter, addr, gs, cat, idx) end
end))

-- Reset 依次做三件事，各自 pcall（一件出错不耽误后面的）：还原受击状态 → 还原无限蓄力 → 丢弃预告跟踪、结算放刀
re.on_script_reset(function()
    local ok, err = pcall(guard.restore_hit_state)
    if not ok then L.warn_err("reset", err) end
    ok, err = pcall(guard.restore_overheat)
    if not ok then L.warn_err("reset", err) end
    ok, err = pcall(parry.reset, os.clock())
    if not ok then H.note("frame", err) end
end)

-- 菜单改动立刻写进内存里的配置，什么时候落盘由 REF 触发
re.on_config_save(function()
    local ok, err = pcall(cfg.save)
    if not ok then H.note("cfg", err) end
end)

-- ---------- §7 菜单 ----------
-- "##" 后面是 imgui 的内部 ID，不显示；保证中文标签改了也不会和别的控件撞 ID（沿用两个旧脚本的 ID）。
-- 防御的几块用 U.part 隔离（出错 2 秒内只画一行提示，之后再试）；放刀一节自己处理出错（parry.draw）
local U = Ui.new({ retry = 2.0, on_error = function(err) L.warn_err("ui", err) end })

local function draw_stats()
    imgui.text(string.format("自动防御：%d 次   自动肩撞：%d 次   本来就在防御：%d 次",
        stats.guarded, stats.tackled, stats.already_guarding))
    imgui.text(string.format("跳过：霸体 %d 次   不能举剑（翻滚、收刀、硬直等）%d 次", stats.skipped_armor, stats.skipped_state))
    imgui.text("自动放刀：放了 " .. F.int(stats.fires) .. " 刀   接住 " .. F.int(stats.catch26 + stats.catch27)
        .. " 刀（26：" .. F.int(stats.catch26) .. "，27：" .. F.int(stats.catch27) .. "）   被弹开 "
        .. F.int(stats.recoils) .. " 次   没接住 " .. F.int(stats.nocatch) .. " 次")
    if imgui.button("清零统计##reset_stats") then
        for k in pairs(stats) do stats[k] = 0 end
    end
    imgui.same_line()
    local changed, v = imgui.checkbox("调试日志##debug_log", config.debug_log)
    if changed then config.debug_log = v == true end
    if config.debug_log then
        imgui.text("性能（每秒）：" .. (prof.text ~= "" and prof.text or "统计中……"))
        imgui.text_colored("放刀记录写在 re2_framework_log.txt：[AutoParryGS] FIRE（放刀）、RES（结局）", Ui.COLOR.GRAY)
    end
end

local function draw_menu()
    imgui.text_colored("作者 " .. K.AUTHOR .. (K.HOMEPAGE and ("   发布地址 " .. K.HOMEPAGE) or "")
        .. "   开源许可 GPL-3.0", Ui.COLOR.GRAY)
    if cfg.unreadable then
        imgui.text_colored("读不出配置文件 AutoGuardGS.json：这次用默认设置，改动也不保存（免得盖掉原文件）。Reset Scripts 重读",
            Ui.COLOR.RED)
    end
    U.part("guard", guard.draw)
    imgui.separator()
    parry.draw()
    imgui.separator()
    U.part("tests", guard.draw_tests)
    imgui.separator()
    U.part("stats", draw_stats)
end

re.on_draw_ui(function()
    U.tree("大剑自动防御 " .. K.VERSION .. "##AutoGuardGS", draw_menu)
end)

-- ---------- §8 加载完成 ----------
L.info(K.VERSION .. " loaded")
-- 加载期间攒下的 [AutoParryGS] 行（初始化出错的 ERR / RED）现在写；调试日志开着、或者有攒下的行时先写 HDR
R.finish_loading(config.debug_log)
