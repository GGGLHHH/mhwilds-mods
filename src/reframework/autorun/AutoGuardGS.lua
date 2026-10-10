-- AutoGuardGS v1.3：大剑自动防御
--
-- 原理（每一条都在探针里验证过）：
--   被怪物打中、伤害结算之前（HunterCharacter.evHit_DamagePreProcess），
--   打开角色状态标志（cHunterStatus._HunterStatusFlag）里的防御标志：
--     TECHNICAL_GUARD → 游戏结算成精确防御（cGuardReaction_Tech）
--     GUARD           → 游戏结算成普通防御（cGuardReaction_Middle 等）
--   防御方向、体力、削伤、防御反应动作全部由游戏按自己的规则处理；
--   结算完（evHit_Damage 之后）把我们打开的标志关掉，不影响之后的操作。
--
--   为什么不用「预判举剑」：同一时刻「会打中」和「打不中」的攻击判定框
--   距离曲线一模一样，不给每只怪建模就没法区分，误触发无法消除。
--   受击时判定则只在真的打中时才触发，对任何怪、任何招式都通用。
--
-- 能不能举剑：已拔刀 + 问游戏行为表能否到达防御动作 + 动作属性黑名单（翻滚、倒地等）。
-- 霸体中（蓄力、蓄力斩等）不防御，交给霸体硬吃，不打断攻击。
--
-- 自动肩撞：蓄力中挨打（蓄力霸体照常硬吃），下一帧起向动作控制器请求切成肩撞
--   （changeActionRequest，走正常进入流程），游戏原生出肩撞，之后能接下一级蓄力。
--   经验：「改状态」可以在受击结算中途做；「改动作」必须在帧开头请求，不能中途硬切。
--
-- 防御角度：
--   存在 app.user_data.Wp00ActionParam 的 _GuardDegree / _AimGuardDegree 里（全角，
--   70 = 正前方左右各 35°）。这份参数所有大剑共用（包括 NPC 支援猎人），所以只在
--   「主玩家这一下的结算期间」临时改成设定值，结算完立刻还原。

local TAG = "[AutoGuardGS] "
local CONFIG_PATH = "AutoGuardGS.json"

local GUARD_TYPES = { "精确防御", "普通防御" }
local GUARD_FLAG_NAMES = { "TECHNICAL_GUARD", "GUARD" }

local ANGLE_MIN, ANGLE_MAX = 30.0, 360.0
local ANGLE_FIELDS = { "_GuardDegree", "_AimGuardDegree" }

local config = {
    enabled = true,
    guard_type = 1,             -- 1 = 精确防御，2 = 普通防御
    guard_angle = nil,          -- nil = 用游戏原值
    respect_armor = true,       -- 身上有霸体时不触发（保护真蓄力斩等霸体攻击）
    auto_tackle = true,         -- 蓄力中挨打后自动肩撞
    auto_parry = true,          -- 抵消蓄力中，危险攻击快到时自动放出抵消上捞斩
    parry_lead = 20,            -- 剩余多少逻辑帧（1/60 秒）时放刀
    infinite_charge = false,    -- 测试用：无限蓄力（蓄满后不会过热自动放出）
    debug_log = false,
}

local loaded = json.load_file(CONFIG_PATH)
if loaded then
    for k, v in pairs(loaded) do
        if config[k] ~= nil or k == "guard_angle" then config[k] = v end
    end
end

local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local STATUS_FLAG = sdk.find_type_definition("app.HunterDef.STATUS_FLAG")
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local function flag(name) return STATUS_FLAG:get_field(name):get_data(nil) end
local GUARD_FLAGS = { flag("TECHNICAL_GUARD"), flag("GUARD") }
-- 已经在防御（手动防御、肩撞的判定点防御等）就不用我们插手
local EXISTING_GUARD_FLAGS = { flag("GUARD"), flag("TECHNICAL_GUARD"), flag("GUARD_POINT"), flag("POWER_GUARD") }
local ARMOR_FLAGS = { flag("SUPER_ARMOR"), flag("HYPER_ARMOR") }

local WEAPON_GREAT_SWORD = 0

-- ---------- 「现在能不能举剑」 ----------
-- 第一层：问游戏。checkContainsActionInCurrentBTable 回答「当前行为表里有没有通往
--   防御动作 (1,141) 的路」。实测：收刀、受击硬直、蓄力中都是 false，判断准确；
--   但它不看时机（翻滚后半段能取消成防御，所以整个翻滚都返回 true）。
-- 第二层：动作属性黑名单，补上不看时机漏掉的情况（翻滚、倒地起身等）。
--   用属性而不是动作名：属性是游戏给动作打的标签，所有武器、所有同类动作通用。
local ACTION_ATTR = sdk.find_type_definition("app.HunterDef.ACTION_ATTR")
local CANCEL_INDEX_INVALID = sdk.find_type_definition("app.ACTION_CANCEL_INDEX"):get_field("Invalid"):get_data(nil)
local LAYER_BASE = 0

local GUARD_ACTION_ID = ValueType.new(sdk.find_type_definition("ace.ACTION_ID"))
GUARD_ACTION_ID:set_field("_Category", 1)   -- app.Wp00Action.cGuard
GUARD_ACTION_ID:set_field("_Index", 141)

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
for _, n in ipairs(BLOCKED_ATTR_NAMES) do
    local f = ACTION_ATTR:get_field(n)
    if f then
        table.insert(BLOCKED_ATTRS, { name = n, value = f:get_data(nil) })
    else
        log.warn(TAG .. "ACTION_ATTR." .. n .. " not found, skipped")
    end
end

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

-- ---------- 自动肩撞 ----------
-- 蓄力中挨打：蓄力自带霸体照常硬吃这一下，之后由我们向动作控制器「请求」切成肩撞。
--
-- 走过的弯路（都实测过）：
--   - 受击结算中途 changeActionImmediate 切成肩撞：动作对象换了，但进入流程被跳过，
--     动画和超级霸体都没跟上，表现错乱。
--   - 虚拟按住防御键（和防御用的是同一套）：按了 28 帧游戏都没反应——蓄力中出肩撞不走这个键。
-- 现在的做法：每帧开始前（主线程）调用 HunterCharacter.changeActionRequest(BASE, 肩撞ID)。
--   「请求」由动作控制器在当帧按正常流程处理，和游戏自己出招是同一条路，进入流程完整。
--   挨打后的顿帧期间请求可能被拒，所以每帧重试，直到进了肩撞或超时。
-- 肩撞 ID 跟蓄力等级走（实测）：开始蓄力 / 一段蓄力 → (2,15)，强蓄力 / 真蓄力 → (2,17)
local CHARGE_TO_TACKLE = { [5] = 15, [6] = 15, [7] = 17, [11] = 17 }   -- 分类 2 内：蓄力动作编号 -> 肩撞编号
local TACKLE_ACTIONS = { [15] = true, [17] = true }
local TACKLE_TIMEOUT = 0.3

local CHARGE_ACTIONS = {}
for k in pairs(CHARGE_TO_TACKLE) do CHARGE_ACTIONS[k] = true end

-- ---------- 自动放刀（抵消上捞斩） ----------
-- 抵消成功的条件（实测）：我们的上捞斩和怪物攻击在同一帧互相命中。
-- 上捞斩放出后约 0.30~0.39 秒才进入有效状态，比怪物从出招到命中（约 0.15 秒）还慢，
-- 所以必须在怪物出招之前就放刀——这需要「预告」。
--
-- 预告来源：游戏给 NPC AI 用的怪物攻击预告。怪物每切换一次动作，就给猎人发一条
--   cMsgEmAttackAreaResult，里面的 app.AttackAreaResult 会随怪物动作实时更新：
--     TargetCharacter                         这一招打谁
--     ResultType                              SAFE / CAUTION / DANGER
--     getClosestDetectedData().HitStartRemainFrame   距离命中还剩多少逻辑帧（1/60 秒）
--   实测（真实怪物）：提前 1~2 秒给出，误差 < 0.1 秒。训练机关没有配置这份数据（恒为空）。
--   猎人身上的 mcHunterAttackAreaResultHolder 对玩家是未激活的（列表恒空），只能从消息里拿。
-- 规则：处于抵消蓄力，且「打我的 DANGER 预告」剩余帧 ≤ parry_lead → 请求切成上捞斩 (2,23)
-- 抵消蓄力：实测按住时一直停在 (2,21) cIdleToParryCharge，从它直接放刀到 (2,23)，并不经过 (2,22)
local PARRY_CHARGE_ACTIONS = { [21] = true, [22] = true }    -- cIdleToParryCharge / cParryCharge
local PARRY_SLASH_IDX = 23                                    -- cParrySlash
local PARRY_DONE_ACTIONS = { [23] = true, [24] = true }      -- 上捞斩（含前进版）
-- 抵消成功的判定：进入 cParrySlashHitS/M/L（游戏自己切过去的，最可靠）。
-- 不用 cMsgParrySuccess 的 State 计数：实测 HitL 时是 SUCCESS，HitM 时没收到 SUCCESS，
-- 不同档位对应的状态值不同。
local PARRY_HIT_ACTIONS = { [25] = true, [26] = true, [27] = true }
local AUTO_PARRY_CREDIT = 1.0   -- 自动放刀后多久内进入 Hit 动作，算作「自动放刀成功」（秒）
local PARRY_TIMEOUT = 0.15                                    -- 放刀请求最多重试多久（秒），过了时机就没意义了
local WARNING_MAX_AGE = 5.0                                   -- 预告最多持有多久（秒）

local ActionID = sdk.find_type_definition("ace.ACTION_ID")
local RT_DANGER = sdk.find_type_definition("app.AttackAreaResult.RESULT_TYPE"):get_field("DANGER"):get_data(nil)
local MasterEntity = sdk.find_type_definition("app.cMasterPlayerControllerEntity")

local warnings = {}   -- [对象地址] = { obj = AttackAreaResult, t = 收到的时刻 }

-- 通用「请求动作」：一次只跑一个请求（肩撞和放刀互斥：一个在普通蓄力里，一个在抵消蓄力里）
-- pending = { name, id, done = 成功动作集合, deadline, tries, still_valid = fn(hunter), stat = 统计键 }
local pending = nil

local function action_in(hunter, set)
    local id = hunter:call("get_BaseActionController"):call("get_CurrentActionID")
    return id:get_field("_Category") == 2 and set[id:get_field("_Index")] == true
end

local function is_charging(hunter) return action_in(hunter, CHARGE_ACTIONS) end

local stats = { guarded = 0, skipped_armor = 0, skipped_state = 0, already_guarding = 0, tackled = 0, parried = 0,
                parry_success = 0, auto_parry_success = 0 }
local last_auto_parry = -100   -- 最近一次自动放刀成功进入上捞斩的时刻（os.clock）
local was_parry_hit = false    -- 上一帧是否在 cParrySlashHit*（用来抓「刚进入」）
local forced = nil          -- { flags = 标志组, list = 我们打开的标志 }
local angle_defaults = nil  -- 游戏原值 { _GuardDegree = 70, _AimGuardDegree = 70 }
local angle_restore = nil   -- 结算期间要还原的 { param = ..., values = {...} }

local function debug(text)
    if config.debug_log then log.info(TAG .. text) end
end

-- ---------- 性能计数（诊断卡顿用） ----------
-- 统计每个钩子每秒被调用几次、花了多少时间；每 5 秒写一行日志。
-- os.clock 在 Windows 上精度约 1 毫秒，单次耗时很小时只看调用次数更可靠。
local PROF_INTERVAL = 5.0
local prof = { msg = { n = 0, t = 0 }, dmg_pre = { n = 0, t = 0 }, dmg = { n = 0, t = 0 }, frame = { n = 0, t = 0 } }
local prof_msg_types = {}
local prof_last = os.clock()
local prof_text = ""

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
    for _, k in ipairs({ "frame", "msg", "dmg_pre", "dmg" }) do
        local p = prof[k]
        table.insert(parts, string.format("%s %.0f/s %.1fms/s", k, p.n / dt, p.t * 1000 / dt))
        p.n, p.t = 0, 0
    end
    local types = {}
    for name, n in pairs(prof_msg_types) do table.insert(types, { name = name, n = n }) end
    table.sort(types, function(a, b) return a.n > b.n end)
    local top = {}
    for i = 1, math.min(4, #types) do
        table.insert(top, string.format("%s %.0f/s", types[i].name:gsub("app%.game_message%.", ""), types[i].n / dt))
    end
    prof_msg_types = {}
    prof_text = table.concat(parts, " | ") .. "\n  top msgs: " .. table.concat(top, ", ")
    log.info(TAG .. "PERF " .. prof_text:gsub("\n", ""))
    prof_last = now
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

-- 发起一个「请求动作」（分类 2 内的 idx）；已有请求在跑就忽略
local function start_request(name, idx, done, timeout, still_valid, stat, hunter)
    if pending then return end
    local id = ValueType.new(ActionID)
    id:set_field("_Category", 2)
    id:set_field("_Index", idx)
    pending = { name = name, id = id, done = done, deadline = os.clock() + timeout, tries = 0,
                still_valid = still_valid, stat = stat }
    debug(string.format("%s requested -> (2,%d) | %s", name, idx, action_text(hunter)))
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

-- ---------- 防御角度 ----------

local function gs_action_param()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    return pm and pm:call("get_Catalog"):call("getWeaponActionParam(app.WeaponDef.TYPE)", WEAPON_GREAT_SWORD)
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

-- ---------- 无限蓄力（测试用） ----------
-- 每种蓄力参数（app.user_data.Wp00ActionParam.cCharge）里有 _OverheatTime：
-- 蓄满后再按住这么久就「过热」自动放出（实测原值：普通 / 强 / 真蓄力 3 秒，抵消蓄力 2.5 秒）。
-- 打开开关时把它改成极大值。生效条件：开关打开且主玩家拿着大剑；否则还原。
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

local function restore_overheat()
    if not overheat_restore then return end
    for _, s in ipairs(overheat_restore) do
        pcall(function() s.obj:set_field("_OverheatTime", s.value) end)
    end
    overheat_restore = nil
    debug("infinite charge OFF (restored)")
end

-- ---------- 还原（标志和角度都不许跨帧） ----------

local function release()
    if angle_restore then
        for f, v in pairs(angle_restore.values) do angle_restore.param:set_field(f, v) end
        angle_restore = nil
    end
    if forced then
        for _, f in ipairs(forced.list) do forced.flags:call("off(System.UInt32)", f) end
        forced = nil
    end
end

-- ---------- 受击：结算前打开防御标志 ----------

sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), timed("dmg_pre", function(args)
    local ok, err = pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        if hunter:call("get_WeaponType") ~= WEAPON_GREAT_SWORD then return end
        if not is_enemy(sdk.to_managed_object(args[3]):call("get_AttackOwner")) then return end

        -- 角度对手动防御同样生效，所以先于开关判断
        apply_angle()

        if not config.enabled then return end

        -- 蓄力中：不防御（蓄力霸体会硬吃），改为挨打后自动肩撞
        if config.auto_tackle and is_charging(hunter) then
            local idx = hunter:call("get_BaseActionController"):call("get_CurrentActionID"):get_field("_Index")
            start_request("tackle", CHARGE_TO_TACKLE[idx], TACKLE_ACTIONS, TACKLE_TIMEOUT, is_charging, "tackled", hunter)
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

        local pm = sdk.get_managed_singleton("app.PlayerManager")
        local reason = why_cannot_guard(hunter, pm:call("getMasterPlayer"))
        if reason then
            stats.skipped_state = stats.skipped_state + 1
            debug("skip: " .. reason .. " | " .. action_text(hunter))
            return
        end

        local f = GUARD_FLAGS[config.guard_type] or GUARD_FLAGS[1]
        flags:call("on(System.UInt32)", f)
        forced = { flags = flags, list = { f } }
        stats.guarded = stats.guarded + 1
        debug("guard forced: " .. GUARD_FLAG_NAMES[config.guard_type] .. " | " .. action_text(hunter))
    end)
    if not ok then
        log.warn(TAG .. "pre err: " .. tostring(err))
        release()
    end
end), nil)

-- 结算完关掉我们打开的标志、还原角度
sdk.hook(HunterCharacter:get_method("evHit_Damage(app.HitInfo)"), nil, timed("dmg", function(retval)
    release()
    return retval
end))

-- 通用「请求动作」：每帧开始前请求一次，直到进了目标动作 / 超时 / 前提不再成立
local function update_pending(hunter)
    if not pending then return end
    local p = pending

    if action_in(hunter, p.done) then
        stats[p.stat] = stats[p.stat] + 1
        if p.name == "parry" then last_auto_parry = os.clock() end
        debug(string.format("%s OK after %d requests | %s", p.name, p.tries, action_text(hunter)))
        pending = nil
        return
    end
    if os.clock() > p.deadline then
        debug(string.format("%s TIMEOUT after %d requests | %s", p.name, p.tries, action_text(hunter)))
        pending = nil
        return
    end
    -- 前提不成立了（比如被打倒、自己放了斩击、松开了蓄力）：不再强行切换
    if not p.still_valid(hunter) then
        debug(string.format("%s CANCELLED | %s", p.name, action_text(hunter)))
        pending = nil
        return
    end

    local accepted = hunter:call("changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)",
        LAYER_BASE, p.id, false)
    p.tries = p.tries + 1
    if p.tries == 1 or accepted then
        debug(string.format("%s request #%d accepted=%s | %s", p.name, p.tries, tostring(accepted), action_text(hunter)))
    end
end

-- 预告：收到 cMsgEmAttackAreaResult 就记下里面的 AttackAreaResult。
-- 这是怪物那边的对象，要跨帧持有：add_ref 防止被回收，丢弃时 release。
-- PARRY_STATE 数值 -> 名字（调试日志用：弄清不同档位对应哪个状态）
local PARRY_STATE_NAME = {}
do
    local td = sdk.find_type_definition("app.HunterDef.PARRY_STATE")
    for _, n in ipairs({ "NONE", "WAIT", "HIT", "SUCCESS", "RECOIL" }) do
        PARRY_STATE_NAME[td:get_field(n):get_data(nil)] = n
    end
end

sdk.hook(MasterEntity:get_method("receiveGameMessage(ace.cGameMessage)"), timed("msg", function(args)
    pcall(function()
        local msg = sdk.to_managed_object(args[3])
        if not msg then return end
        local tname = msg:get_type_definition():get_full_name()
        prof_msg_types[tname] = (prof_msg_types[tname] or 0) + 1

        -- 抵消消息：只记日志，成功与否按动作统计（见 PARRY_HIT_ACTIONS）
        if tname == "app.game_message.cMsgParrySuccess" then
            local st = msg:call("get_State")
            debug("parry message: state=" .. (PARRY_STATE_NAME[st] or tostring(st)))
            return
        end

        if not config.auto_parry or tname ~= "app.game_message.cMsgEmAttackAreaResult" then return end
        local r = msg:call("get_AttackAreaResult")
        if not r then return end
        local key = r:get_address()
        if warnings[key] then return end
        r:add_ref()
        warnings[key] = { obj = r, t = os.clock() }
    end)
end), nil)

local function drop_warning(key, w)
    pcall(function() w.obj:release() end)
    warnings[key] = nil
end

local function drop_all_warnings()
    for key, w in pairs(warnings) do drop_warning(key, w) end
end

-- 所有「打我的危险预告」里，距离命中最近的剩余逻辑帧；没有返回 nil。顺手清理过期预告。
--
-- 「粘住」危险：实测游戏会每帧重新评估，倒数到一半可能把 DANGER 降级成 CAUTION（剩余帧变 -1），
-- 但攻击照样按原时间打中（游戏对 NPC 偏保守，对我们是漏报）。所以一条预告只要曾是 DANGER，
-- 之后就按「最后一次读到的剩余帧 - 经过时间 × 60」继续估算，直到这一招结束或怪物换了动作。
local STICKY_GRACE = 10   -- 估算剩余帧低于 -10（命中时刻已过约 1/6 秒）就不再算危险

local function nearest_danger(hunter)
    local best = nil
    local now = os.clock()
    local my_addr = hunter:get_address()
    for key, w in pairs(warnings) do
        local ok, keep = pcall(function()
            local r = w.obj
            if r:call("get_IsAttackFinished") or now - w.t > WARNING_MAX_AGE then return false end
            local target = r:call("get_TargetCharacter")
            if not target or target:get_address() ~= my_addr then return true end

            -- 怪物换了动作（同一个预告对象被复用）：之前粘住的危险作废
            local keep_id = r:call("get_KeepActionID")
            local act = keep_id:get_field("_Category") * 100000 + keep_id:get_field("_Index")
            if w.act ~= act then
                w.act, w.last_s, w.last_t = act, nil, nil
            end

            local s = nil
            if r:call("get_ResultType") == RT_DANGER then
                local dd = r:call("getClosestDetectedData")
                local v = dd and dd:call("get_HitStartRemainFrame")
                if v and v >= 0 then
                    s = v
                    w.last_s, w.last_t = v, now
                end
            end
            if not s and w.last_s then
                local est = w.last_s - (now - w.last_t) * 60
                if est > -STICKY_GRACE then s = est end
            end
            if s and (not best or s < best) then best = s end
            return true
        end)
        if not ok or not keep then drop_warning(key, w) end
    end
    return best
end

local function in_parry_charge(hunter) return action_in(hunter, PARRY_CHARGE_ACTIONS) end

-- 自动放刀：抵消蓄力中，危险攻击快到了就请求上捞斩
local last_parry_bucket = nil   -- 调试：最近危险预告每减少 10 帧记一行
local function update_parry(hunter)
    if not config.auto_parry or pending then return end
    if not in_parry_charge(hunter) then
        last_parry_bucket = nil
        return
    end
    local remain = nearest_danger(hunter)
    local bucket = remain and math.floor(remain / 10) or -1
    if bucket ~= last_parry_bucket then
        debug(string.format("parry charging, nearest danger: %s | %s", remain and string.format("%.0f frames", remain) or "none", action_text(hunter)))
        last_parry_bucket = bucket
    end
    if remain and remain <= config.parry_lead then
        debug(string.format("parry trigger: danger in %.0f frames (lead %d)", remain, config.parry_lead))
        start_request("parry", PARRY_SLASH_IDX, PARRY_DONE_ACTIONS, PARRY_TIMEOUT, in_parry_charge, "parried", hunter)
    end
end

-- 每帧开始时：还原标志和角度、推进自动放刀和请求动作
re.on_pre_application_entry("UpdateBehavior", timed("frame", function()
    prof_report()
    release()
    local ok, err = pcall(function()
        local pm = sdk.get_managed_singleton("app.PlayerManager")
        local player = pm and pm:call("getMasterPlayer")
        local hunter = player and player:call("get_Character")
        if not hunter then
            pending = nil
            restore_overheat()
            return
        end
        if config.infinite_charge and hunter:call("get_WeaponType") == WEAPON_GREAT_SWORD then
            apply_infinite_charge()
        else
            restore_overheat()
        end
        update_parry(hunter)
        update_pending(hunter)

        -- 抵消成功统计：刚进入 cParrySlashHit*
        local is_hit = action_in(hunter, PARRY_HIT_ACTIONS)
        if is_hit and not was_parry_hit then
            stats.parry_success = stats.parry_success + 1
            local auto = os.clock() - last_auto_parry <= AUTO_PARRY_CREDIT
            if auto then stats.auto_parry_success = stats.auto_parry_success + 1 end
            debug(string.format("PARRY SUCCESS (%s) | %s", auto and "auto" or "manual", action_text(hunter)))
        end
        was_parry_hit = is_hit
        -- 不在抵消蓄力时也要清理过期预告，免得越积越多
        if not in_parry_charge(hunter) and next(warnings) then nearest_danger(hunter) end
    end)
    if not ok then
        log.warn(TAG .. "frame err: " .. tostring(err))
        pending = nil
    end
end))
re.on_script_reset(function()
    release()
    drop_all_warnings()
    restore_overheat()
end)

-- ---------- 配置与菜单 ----------

re.on_config_save(function()
    json.dump_file(CONFIG_PATH, config)
end)

re.on_draw_ui(function()
    -- "##" 后面是 imgui 的内部 ID，不显示；保证中文标签改了也不会和别的控件撞 ID
    if not imgui.tree_node("大剑自动防御##AutoGuardGS") then return end
    local changed, v

    changed, v = imgui.checkbox("启用##enabled", config.enabled)
    if changed then config.enabled = v end

    changed, v = imgui.combo("防御类型##guard_type", config.guard_type, GUARD_TYPES)
    if changed then config.guard_type = v end

    changed, v = imgui.checkbox("霸体时不防御（保护真蓄力斩等霸体攻击）##respect_armor", config.respect_armor)
    if changed then config.respect_armor = v end

    changed, v = imgui.checkbox("蓄力中挨打后自动肩撞##auto_tackle", config.auto_tackle)
    if changed then config.auto_tackle = v end

    changed, v = imgui.checkbox("抵消蓄力中自动放刀（抵消上捞斩）##auto_parry", config.auto_parry)
    if changed then
        config.auto_parry = v
        if not v then drop_all_warnings() end
    end
    if config.auto_parry then
        changed, v = imgui.slider_int("放刀提前量（帧，1/60 秒）##parry_lead", config.parry_lead, 5, 45)
        if changed then config.parry_lead = v end
        imgui.text("太早放：刀先到、攻击后到，没撞上；太晚放：先被打中。训练机关没有预告数据，要打真怪测试。")
    end

    imgui.separator()
    changed, v = imgui.checkbox("【测试】无限蓄力（蓄满后不会自动放出）##infinite_charge", config.infinite_charge)
    if changed then config.infinite_charge = v end
    if config.infinite_charge then
        imgui.text(overheat_restore and "状态：生效中（同场 NPC 支援猎人的大剑也会受影响）" or "状态：等待（拿起大剑后生效）")
    end

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

    imgui.separator()
    imgui.text(string.format("自动防御：%d 次   自动肩撞：%d 次   本来就在防御：%d 次",
        stats.guarded, stats.tackled, stats.already_guarding))
    imgui.text(string.format("自动放刀：%d 次，其中抵消成功 %d 次   抵消成功总计：%d 次（含手动）",
        stats.parried, stats.auto_parry_success, stats.parry_success))
    imgui.text(string.format("跳过：霸体 %d 次   不能举剑（翻滚、收刀、硬直等）%d 次", stats.skipped_armor, stats.skipped_state))
    if imgui.button("清零统计##reset_stats") then
        for k in pairs(stats) do stats[k] = 0 end
    end
    imgui.same_line()
    changed, v = imgui.checkbox("调试日志##debug_log", config.debug_log)
    if changed then config.debug_log = v end
    imgui.text("性能（每秒）：" .. (prof_text ~= "" and prof_text or "统计中……"))

    imgui.tree_pop()
end)

log.info(TAG .. "v1.3 loaded")
