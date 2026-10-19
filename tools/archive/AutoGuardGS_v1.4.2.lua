-- AutoGuardGS v1.4.2：大剑自动防御
--
-- 原理（每一条都在探针里验证过，详见 docs/NOTES.md）：
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
--   v1.4.1：抵消动作族 (2,21)~(2,29) 里不改写（刀上的抵消碰撞也会进受击钩子）。
--
-- 【测试】锁血（v1.4.2）：主玩家不掉血、不会倒下，方便测试。被打的反应动作照常。
--   游戏扣血分两步：受击时 app.cHunterHealth.requestDamage 登记伤害，之后 update 里结算。
--   在登记这一步拦住（跳过原函数），一下超过血量上限的攻击也打不死；
--   另外每帧把血补满兜底，覆盖不走 requestDamage 的扣血（比如持续伤害）。
--
-- 自动放刀（抵消上捞斩）是单独的脚本 AutoParryGS.lua（开发中，分支 feat/auto-offset-predict）。

local TAG = "[AutoGuardGS] "
local VERSION = "v1.4.2"
local CONFIG_PATH = "AutoGuardGS.json"

local GUARD_TYPES = { "精确防御", "普通防御" }
local GUARD_FLAG_NAMES = { "TECHNICAL_GUARD", "GUARD" }

local ANGLE_MIN, ANGLE_MAX = 30.0, 360.0
local ANGLE_FIELDS = { "_GuardDegree", "_AimGuardDegree" }

-- ---------- 配置 ----------

local config = {
    enabled = true,
    guard_type = 1,             -- 1 = 精确防御，2 = 普通防御
    guard_angle = nil,          -- nil = 用游戏原值
    respect_armor = true,       -- 身上有霸体时不触发（保护真蓄力斩等霸体攻击）
    auto_tackle = true,         -- 蓄力中挨打后自动肩撞
    infinite_charge = false,    -- 测试用：无限蓄力（蓄满后不会过热自动放出）
    lock_health = false,        -- 测试用：锁血（主玩家不掉血、不会倒下）
    debug_log = false,
}

-- 读配置：只接受认识的键和合法的值（文件被手改坏也不至于出怪事）
local function load_config()
    local loaded = json.load_file(CONFIG_PATH)
    if type(loaded) ~= "table" then return end
    for k, v in pairs(loaded) do
        if k == "guard_angle" then
            if type(v) == "number" then config.guard_angle = math.max(ANGLE_MIN, math.min(ANGLE_MAX, v)) end
        elseif k == "guard_type" then
            if v == 1 or v == 2 then config.guard_type = v end
        elseif config[k] ~= nil and type(v) == type(config[k]) then
            config[k] = v
        end
    end
end
load_config()

-- ---------- 游戏类型和常量 ----------

local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local STATUS_FLAG = sdk.find_type_definition("app.HunterDef.STATUS_FLAG")
local ACTION_ATTR = sdk.find_type_definition("app.HunterDef.ACTION_ATTR")
local ActionID = sdk.find_type_definition("ace.ACTION_ID")
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local function flag(name) return STATUS_FLAG:get_field(name):get_data(nil) end
local GUARD_FLAGS = { flag("TECHNICAL_GUARD"), flag("GUARD") }
-- 已经在防御（手动防御、肩撞的判定点防御等）就不用我们插手
local EXISTING_GUARD_FLAGS = { flag("GUARD"), flag("TECHNICAL_GUARD"), flag("GUARD_POINT"), flag("POWER_GUARD") }
local ARMOR_FLAGS = { flag("SUPER_ARMOR"), flag("HYPER_ARMOR") }

local WEAPON_GREAT_SWORD = 0
local LAYER_BASE = 0
local CANCEL_INDEX_INVALID = sdk.find_type_definition("app.ACTION_CANCEL_INDEX"):get_field("Invalid"):get_data(nil)

local function make_action_id(cat, idx)
    local id = ValueType.new(ActionID)
    id:set_field("_Category", cat)
    id:set_field("_Index", idx)
    return id
end

local GUARD_ACTION_ID = make_action_id(1, 141)   -- app.Wp00Action.cGuard

-- ---------- 状态 ----------

local stats = { guarded = 0, skipped_armor = 0, skipped_state = 0, already_guarding = 0, tackled = 0, damage_blocked = 0 }
local forced = nil          -- { flags = 标志组, list = 我们打开的标志 }
local angle_defaults = nil  -- 游戏原值 { _GuardDegree = 70, _AimGuardDegree = 70 }
local angle_restore = nil   -- 结算期间要还原的 { param = ..., values = {...} }
local tackle = nil          -- 进行中的肩撞请求 { id, deadline, tries }

-- ---------- 工具 ----------

local function debug(text)
    if config.debug_log then log.info(TAG .. text) end
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

local function current_action(hunter)
    local id = hunter:call("get_BaseActionController"):call("get_CurrentActionID")
    return id:get_field("_Category"), id:get_field("_Index")
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

local function master_player()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    return pm and pm:call("getMasterPlayer")
end

-- ---------- 性能计数（诊断卡顿用） ----------
-- 一直计数（开销很小），只在打开调试日志时每 5 秒写一行日志、在菜单里显示。
-- os.clock 在 Windows 上精度约 1 毫秒，单次耗时很小时只看调用次数更可靠。
local PROF_INTERVAL = 5.0
local prof = { frame = { n = 0, t = 0 }, dmg_pre = { n = 0, t = 0 }, dmg = { n = 0, t = 0 } }
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
    for _, k in ipairs({ "frame", "dmg_pre", "dmg" }) do
        local p = prof[k]
        table.insert(parts, string.format("%s %.0f/s %.1fms/s", k, p.n / dt, p.t * 1000 / dt))
        p.n, p.t = 0, 0
    end
    prof_text = table.concat(parts, " | ")
    debug("PERF " .. prof_text)
    prof_last = now
end

-- ---------- 能不能举剑 ----------
-- 第一层：问游戏。checkContainsActionInCurrentBTable 回答「当前行为表里有没有通往
--   防御动作 (1,141) 的路」。实测：收刀、受击硬直、蓄力中都是 false，判断准确；
--   但它不看时机（翻滚后半段能取消成防御，所以整个翻滚都返回 true）。
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

-- ---------- 自动肩撞 ----------
-- 蓄力中挨打：蓄力自带霸体照常硬吃这一下，之后由我们向动作控制器「请求」切成肩撞。
--
-- 走过的弯路（都实测过）：
--   - 受击结算中途 changeActionImmediate 切成肩撞：动作对象换了，但进入流程被跳过，
--     动画和超级霸体都没跟上，表现错乱。
--   - 虚拟按住防御键：按了 28 帧游戏都没反应——蓄力中出肩撞不走这个键。
-- 现在的做法：每帧开始前（主线程）调用 HunterCharacter.changeActionRequest(BASE, 肩撞ID)。
--   「请求」由动作控制器在当帧按正常流程处理，和游戏自己出招是同一条路，进入流程完整。
--   挨打后的顿帧期间请求可能被拒，所以每帧重试，直到进了肩撞或超时（实测都是第一次就成功）。
-- 肩撞 ID 跟蓄力等级走（实测）：开始蓄力 / 一段蓄力 → (2,15)，强蓄力 / 真蓄力 → (2,17)
local CHARGE_TO_TACKLE = { [5] = 15, [6] = 15, [7] = 17, [11] = 17 }   -- 分类 2 内：蓄力动作编号 -> 肩撞编号
local TACKLE_ACTIONS = { [15] = true, [17] = true }
local TACKLE_TIMEOUT = 0.3

local function charge_index(hunter)
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

-- 每帧开始前推进：直到进了肩撞 / 超时 / 已不在蓄力
local function update_tackle(hunter)
    if not tackle then return end
    local cat, idx = current_action(hunter)

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
    if not charge_index(hunter) then
        debug("tackle CANCELLED, no longer charging | " .. action_text(hunter))
        tackle = nil
        return
    end

    local accepted = hunter:call("changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)",
        LAYER_BASE, tackle.id, false)
    tackle.tries = tackle.tries + 1
    if tackle.tries == 1 or accepted then
        debug(string.format("tackle request #%d accepted=%s | %s", tackle.tries, tostring(accepted), action_text(hunter)))
    end
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

        -- 角度对手动防御同样生效，所以先于开关判断。
        -- 例外：抵消动作族 (2,21)~(2,29) 里不改（v1.4.1）。刀上的抵消碰撞（ATTACK_PARRY_GET）
        -- 也会走进这个钩子，而且在同一帧的抵消结算之前（日志 16:12:47.045 实测）；
        -- 这时改写共用的防御角度，会混进自动放刀的测量，也可能造成 mod 导致的「全向抵消」假象。
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
        log.warn(TAG .. "pre err: " .. tostring(err))
        release()
    end
end), nil)

-- 结算完关掉我们打开的标志、还原角度
sdk.hook(HunterCharacter:get_method("evHit_Damage(app.HitInfo)"), nil, timed("dmg", function(retval)
    release()
    return retval
end))

-- ---------- 【测试】锁血 ----------
-- 主玩家的 cHunterHealth 地址，每帧开头更新；钩子里拿 this 的地址和它比，只拦主玩家
local master_health_addr = nil
local HunterHealth = sdk.find_type_definition("app.cHunterHealth")

local function block_master_damage(args)
    if not config.lock_health or not master_health_addr then return nil end
    local ok, hit = pcall(function() return sdk.to_int64(args[2]) == master_health_addr end)
    if ok and hit then
        stats.damage_blocked = stats.damage_blocked + 1
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
    return nil
end

-- 登记伤害（受击扣血）和红血伤害：锁血时对主玩家跳过原函数
sdk.hook(HunterHealth:get_method("requestDamage(app.HunterCharacter, System.Single, System.Single, System.Boolean, System.Boolean, System.Boolean, System.Boolean, System.Boolean, System.Boolean)"),
    block_master_damage, nil)
sdk.hook(HunterHealth:get_method("requestRedDamage(System.Single)"), block_master_damage, nil)

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

-- ---------- 每帧 ----------

-- 每帧开始时：还原标志和角度（兜底）、无限蓄力开关、推进自动肩撞
re.on_pre_application_entry("UpdateBehavior", timed("frame", function()
    prof_report()
    release()
    local ok, err = pcall(function()
        local player = master_player()
        local hunter = player and player:call("get_Character")
        if not hunter then
            tackle = nil
            master_health_addr = nil
            restore_overheat()
            return
        end
        update_lock_health(hunter)
        if config.infinite_charge and hunter:call("get_WeaponType") == WEAPON_GREAT_SWORD then
            apply_infinite_charge()
        else
            restore_overheat()
        end
        update_tackle(hunter)
    end)
    if not ok then
        log.warn(TAG .. "frame err: " .. tostring(err))
        tackle = nil
    end
end))

re.on_script_reset(function()
    release()
    restore_overheat()
end)

-- ---------- 配置与菜单 ----------

re.on_config_save(function()
    json.dump_file(CONFIG_PATH, config)
end)

re.on_draw_ui(function()
    -- "##" 后面是 imgui 的内部 ID，不显示；保证中文标签改了也不会和别的控件撞 ID
    if not imgui.tree_node("大剑自动防御 " .. VERSION .. "##AutoGuardGS") then return end
    local changed, v

    changed, v = imgui.checkbox("启用##enabled", config.enabled)
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

    imgui.separator()
    changed, v = imgui.checkbox("【测试】无限蓄力（蓄满后不会自动放出）##infinite_charge", config.infinite_charge)
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

    imgui.separator()
    imgui.text(string.format("自动防御：%d 次   自动肩撞：%d 次   本来就在防御：%d 次",
        stats.guarded, stats.tackled, stats.already_guarding))
    imgui.text(string.format("跳过：霸体 %d 次   不能举剑（翻滚、收刀、硬直等）%d 次", stats.skipped_armor, stats.skipped_state))
    if imgui.button("清零统计##reset_stats") then
        for k in pairs(stats) do stats[k] = 0 end
    end
    imgui.same_line()
    changed, v = imgui.checkbox("调试日志##debug_log", config.debug_log)
    if changed then config.debug_log = v end
    if config.debug_log then
        imgui.text("性能（每秒）：" .. (prof_text ~= "" and prof_text or "统计中……"))
    end

    imgui.tree_pop()
end)

log.info(TAG .. VERSION .. " loaded")
