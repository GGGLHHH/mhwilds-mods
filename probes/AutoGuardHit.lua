-- AutoGuardHit：验证「受击时判定为防御」（探针）
--
-- 假设：游戏判断「玩家在防御」看的是 HunterStatus._HunterStatusFlag 里的 GUARD 标志位
-- （HitboxViewer 画防御框也是读这个标志）。如果在伤害结算前把它打开，
-- 游戏就会按自己的规则（防御角度、方向、体力）把这一下结算成防御。
--
-- 做法：
--   evHit_DamagePreProcess 前置：满足条件就打开 GUARD，记下「是我们打开的」
--   evHit_Damage 后置：把我们打开的标志关掉，记录结算结果
--   保险：下一帧开始时如果还没关，强制关掉

local TAG = "[AGHit] "
local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local STATUS_FLAG = sdk.find_type_definition("app.HunterDef.STATUS_FLAG")
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local function flag(name) return STATUS_FLAG:get_field(name):get_data(nil) end
local FLAG_GUARD = flag("GUARD")
local FLAG_TECH = flag("TECHNICAL_GUARD")
local WEAPON_GREAT_SWORD = 0

-- 挨打前记录这些标志的状态（对照：手动精确防御时游戏开的是哪个）
local WATCH_FLAGS = { "GUARD", "TECHNICAL_GUARD", "GUARD_POINT", "POWER_GUARD", "SUPER_ARMOR", "HYPER_ARMOR" }

-- 打开哪些标志：1 = 只 GUARD，2 = 只 TECHNICAL_GUARD，3 = 两个都开
local MODES = { { FLAG_GUARD }, { FLAG_TECH }, { FLAG_GUARD, FLAG_TECH } }
local MODE_NAMES = { "GUARD", "TECHNICAL_GUARD", "GUARD + TECHNICAL_GUARD" }
local mode = 3

local enabled = true
local forced = nil      -- { flags = 标志组, list = 我们打开的标志 }（等着关）

-- 防御角度：存在 app.user_data.Wp00ActionParam 里，是「全角」（70 = 正前方左右各 35°）。
-- 这份参数所有大剑共用（包括 NPC 支援猎人），所以只在「主玩家这一下的结算期间」
-- 临时改成设定值，结算完立刻还原。
local ANGLE_FIELDS = { "_GuardDegree", "_AimGuardDegree" }
local ANGLE_MIN, ANGLE_MAX = 30.0, 360.0
local guard_angle = nil       -- 滑块的值；nil = 还没读到游戏原值
local angle_defaults = nil    -- 游戏原值 { _GuardDegree = 70, ... }
local angle_restore = nil     -- 结算期间要还原的 { param = ..., values = {...} }

local function gs_action_param()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    return pm and pm:call("get_Catalog"):call("getWeaponActionParam(app.WeaponDef.TYPE)", WEAPON_GREAT_SWORD)
end

-- 第一次读到参数时记下游戏原值，作为滑块默认值
local function ensure_angle_defaults()
    if angle_defaults then return true end
    local param = gs_action_param()
    if not param then return false end
    angle_defaults = {}
    for _, f in ipairs(ANGLE_FIELDS) do angle_defaults[f] = param:get_field(f) end
    guard_angle = guard_angle or angle_defaults._GuardDegree
    log.info(string.format("%sgame guard angle: %.1f (aim %.1f)", TAG, angle_defaults._GuardDegree, angle_defaults._AimGuardDegree))
    return true
end

local function apply_angle()
    -- 已经改过还没还原（同一帧连续挨打）：别再保存一次，否则会把改过的值当成原值
    if angle_restore then return end
    if not ensure_angle_defaults() or not guard_angle then return end
    local param = gs_action_param()
    if not param then return end
    local saved = {}
    for _, f in ipairs(ANGLE_FIELDS) do
        saved[f] = param:get_field(f)
        param:set_field(f, guard_angle)
    end
    angle_restore = { param = param, values = saved }
end

local function restore_angle()
    if angle_restore then
        for f, v in pairs(angle_restore.values) do angle_restore.param:set_field(f, v) end
        angle_restore = nil
    end
end
local events = {}

local function push(text)
    table.insert(events, 1, text)
    if #events > 15 then table.remove(events) end
    log.info(TAG .. text)
end

local function flags_of(hunter)
    return hunter:call("get_HunterStatus"):get_field("_HunterStatusFlag")
end

local function is_enemy(game_object)
    if not game_object then return false end
    local chara = game_object:call("getComponent(System.Type)", T_CharacterBase)
    return chara ~= nil and chara:get_type_definition():is_a("app.EnemyCharacter")
end

local function action_name(hunter)
    local act = hunter:call("get_BaseActionController"):call("get_CurrentAction")
    local name = act and act:get_type_definition():get_full_name() or "?"
    return (name:gsub("app%.Wp%d%dAction%.", ""))
end

local function release()
    restore_angle()
    if forced then
        for _, f in ipairs(forced.list) do forced.flags:call("off(System.UInt32)", f) end
        forced = nil
    end
end

local function flags_on_text(flags)
    local on = {}
    for _, n in ipairs(WATCH_FLAGS) do
        if flags:call("check(System.UInt32)", flag(n)) then table.insert(on, n) end
    end
    return #on > 0 and table.concat(on, ",") or "-"
end

sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    local ok, err = pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        local info = sdk.to_managed_object(args[3])
        if not is_enemy(info:call("get_AttackOwner")) then return end

        -- 角度只对拿大剑的主玩家生效（不管防御是手动的还是自动的）
        if hunter:call("get_WeaponType") == WEAPON_GREAT_SWORD then apply_angle() end

        local flags = flags_of(hunter)
        local before = flags_on_text(flags)
        local already = flags:call("check(System.UInt32)", FLAG_GUARD)
        local note = "already"
        if not already then
            if enabled and hunter:call("get_WeaponType") == WEAPON_GREAT_SWORD and hunter:call("get_IsWeaponOn") then
                local list = {}
                for _, f in ipairs(MODES[mode]) do
                    if not flags:call("check(System.UInt32)", f) then
                        flags:call("on(System.UInt32)", f)
                        table.insert(list, f)
                    end
                end
                forced = { flags = flags, list = list }
                note = "FORCED[" .. MODE_NAMES[mode] .. "]"
            else
                note = "off"
            end
        end
        push(string.format("pre  flags_before=%s guard=%s action=%s", before, note, action_name(hunter)))
    end)
    if not ok then log.warn(TAG .. "pre err: " .. tostring(err)) end
end, function(retval)
    log.info(TAG .. "pre result=" .. tostring(sdk.to_int64(retval) & 0xFF))
    return retval
end)

local hit_hunter = nil
sdk.hook(HunterCharacter:get_method("evHit_Damage(app.HitInfo)"), function(args)
    hit_hunter = sdk.to_managed_object(args[2])
end, function(retval)
    local ok, err = pcall(function()
        local hunter = hit_hunter
        hit_hunter = nil
        if not hunter or not hunter:call("get_IsMaster") then return end
        local info = hunter:call("get_DamageInfo")
        push(string.format("dmg  result=%d reaction=%s lackStamina=%s total=%.1f",
            sdk.to_int64(retval) & 0xFF,
            tostring(info:get_field("_GuardReaction")),
            tostring(info:get_field("_IsLackOfGuardStamina")),
            info:get_field("_TotalDamage") or -1))
    end)
    if not ok then log.warn(TAG .. "dmg err: " .. tostring(err)) end
    release()
    return retval
end)

-- 保险：任何情况下标志和角度都不跨帧
re.on_pre_application_entry("UpdateBehavior", release)
-- 重置脚本时也还原（以防正好卡在结算中间）
re.on_script_reset(release)

-- 动作变化：结算后角色进了哪个动作（看是不是 GuardReaction）
local last_action = nil
re.on_frame(function()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    local hunter = p and p:call("get_Character")
    if not hunter then return end
    local a = action_name(hunter)
    if a ~= last_action then
        if a:find("Guard") or a:find("Damage") or a:find("Smash") then push("act  -> " .. a) end
        last_action = a
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("AutoGuardHit (probe)") then return end
    local changed, v = imgui.checkbox("Force guard on hit", enabled)
    if changed then enabled = v end
    changed, v = imgui.combo("Flags to force", mode, MODE_NAMES)
    if changed then mode = v end
    imgui.text(string.format("GUARD=%s TECHNICAL_GUARD=%s", tostring(FLAG_GUARD), tostring(FLAG_TECH)))

    imgui.separator()
    if ensure_angle_defaults() then
        changed, v = imgui.slider_float("Guard angle (deg, full)", guard_angle, ANGLE_MIN, ANGLE_MAX, "%.0f")
        if changed then guard_angle = v end
        imgui.same_line()
        if imgui.button("Default") then guard_angle = angle_defaults._GuardDegree end
        imgui.text(string.format("Game default: %.0f  (= +/-%.0f from front)  Current: +/-%.0f",
            angle_defaults._GuardDegree, angle_defaults._GuardDegree / 2, guard_angle / 2))
    else
        imgui.text("Guard angle: waiting for player data...")
    end
    imgui.separator()
    for _, e in ipairs(events) do imgui.text(e) end
    imgui.tree_pop()
end)

log.info(TAG .. "loaded, GUARD flag=" .. tostring(FLAG_GUARD))
