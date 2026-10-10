-- AutoGuardTackleProbe：观察「手动肩撞被打中」时游戏的状态（只记录，不改任何东西）
--
-- 要回答：游戏判定「精准肩撞」看的是什么？
--   - 挨打前开着哪些状态标志（SUPER_ARMOR / HYPER_ARMOR / GUARD_POINT ...）
--   - 当前动作，以及 cTackle._IsJusted 在挨打前后的值
--   - 结算结果：伤害、伤害类型、之后切到的动作
-- 另外记录每次进入肩撞时的帧序号，算出「肩撞开始后第几帧被打中」

local TAG = "[AGTackle] "
local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local STATUS_FLAG = sdk.find_type_definition("app.HunterDef.STATUS_FLAG")
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local WATCH = { "GUARD", "TECHNICAL_GUARD", "GUARD_POINT", "POWER_GUARD", "SUPER_ARMOR", "HYPER_ARMOR", "NO_DAMAGE_REACTION" }
local FLAG = {}
for _, n in ipairs(WATCH) do FLAG[n] = STATUS_FLAG:get_field(n):get_data(nil) end

-- 实验：蓄力中挨打时，在伤害结算前立即切成肩撞，让这一下正好落在肩撞第 0 帧，
-- 看游戏会不会自己判定成精准肩撞（_IsJusted = true）。
-- 肩撞 ID 跟蓄力等级走（实测）：cCharge 出 (2,15)，cStrongCharge / cSpiritCharge 出 (2,17)
local experiment = true
local CHARGE_TO_TACKLE = { [5] = 15, [6] = 15, [7] = 17, [11] = 17 }   -- 分类 2 内：蓄力动作编号 -> 肩撞编号
local ActionID = sdk.find_type_definition("ace.ACTION_ID")

local frame = 0
local tackle_enter_frame = nil
local last_action = nil
local last_justed = "n/a"
local pending = nil   -- 挨打前记录的信息，等结算后补全
local events = {}

local function push(text)
    table.insert(events, 1, text)
    if #events > 20 then table.remove(events) end
    log.info(TAG .. text)
end

local function master_hunter()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    return p and p:call("get_Character")
end

local function is_enemy(go)
    if not go then return false end
    local c = go:call("getComponent(System.Type)", T_CharacterBase)
    return c ~= nil and c:get_type_definition():is_a("app.EnemyCharacter")
end

local function cur_action(hunter)
    local ctrl = hunter:call("get_BaseActionController")
    local act = ctrl:call("get_CurrentAction")
    local id = ctrl:call("get_CurrentActionID")
    local name = act and act:get_type_definition():get_full_name() or "?"
    return act, string.format("(%d,%d)%s", id:get_field("_Category"), id:get_field("_Index"), (name:gsub("app%.Wp00Action%.", "")))
end

local function flags_text(hunter)
    local flags = hunter:call("get_HunterStatus"):get_field("_HunterStatusFlag")
    local on = {}
    for _, n in ipairs(WATCH) do
        if flags:call("check(System.UInt32)", FLAG[n]) then table.insert(on, n) end
    end
    return #on > 0 and table.concat(on, ",") or "-"
end

local function justed(act)
    if act and act:get_type_definition():is_a("app.Wp00Action.cTackle") then
        return tostring(act:get_field("_IsJusted"))
    end
    return "n/a"
end

-- 每帧：数帧、记录动作变化（看肩撞何时开始、挨打后切到什么动作）
re.on_pre_application_entry("UpdateBehavior", function()
    frame = frame + 1
    local hunter = master_hunter()
    if not hunter then return end
    local act, text = cur_action(hunter)
    if text ~= last_action then
        if text:find("cTackle") then tackle_enter_frame = frame end
        if text:find("Tackle") or text:find("Charge") or text:find("Damage") or text:find("Slash") then
            push(string.format("f%d act -> %s  flags=%s justed=%s", frame, text, flags_text(hunter), justed(act)))
        end
        last_action = text
    end
    -- _IsJusted 可能在肩撞之后的某一帧才被设置，盯着它的变化
    local j = justed(act)
    if j ~= "n/a" and j ~= last_justed then
        push(string.format("f%d justed -> %s (tackleFrame=%d)", frame, j, tackle_enter_frame and (frame - tackle_enter_frame) or -1))
    end
    last_justed = j
end)

sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    local ok, err = pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        if not is_enemy(sdk.to_managed_object(args[3]):call("get_AttackOwner")) then return end
        local act, text = cur_action(hunter)
        local since = (text:find("cTackle") and tackle_enter_frame) and (frame - tackle_enter_frame) or -1
        push(string.format("f%d HIT pre  %s  flags=%s justed=%s tackleFrame=%d", frame, text, flags_text(hunter), justed(act), since))

        if experiment then
            local ctrl = hunter:call("get_BaseActionController")
            local id = ctrl:call("get_CurrentActionID")
            local tackle_idx = id:get_field("_Category") == 2 and CHARGE_TO_TACKLE[id:get_field("_Index")]
            if tackle_idx then
                local tid = ValueType.new(ActionID)
                tid:set_field("_Category", 2)
                tid:set_field("_Index", tackle_idx)
                local ret = ctrl:call("changeActionImmediate(ace.ACTION_ID, System.Boolean)", tid, false)
                tackle_enter_frame = frame
                act, text = cur_action(hunter)
                push(string.format("f%d EXPERIMENT changeActionImmediate(2,%d) -> %s  now %s flags=%s justed=%s",
                    frame, tackle_idx, tostring(ret), text, flags_text(hunter), justed(act)))
            end
        end
        pending = { act = act }
    end)
    if not ok then log.warn(TAG .. "pre err: " .. tostring(err)) end
end, nil)

local dmg_hunter = nil
sdk.hook(HunterCharacter:get_method("evHit_Damage(app.HitInfo)"), function(args)
    dmg_hunter = sdk.to_managed_object(args[2])
end, function(retval)
    local ok, err = pcall(function()
        local hunter = dmg_hunter
        dmg_hunter = nil
        if not hunter or not hunter:call("get_IsMaster") or not pending then return end
        local info = hunter:call("get_DamageInfo")
        local _, text = cur_action(hunter)
        push(string.format("f%d HIT post %s total=%.1f dmgType=%s reaction=%s justed=%s",
            frame, text, info:get_field("_TotalDamage") or -1, tostring(info:get_field("_DamageType")),
            tostring(info:get_field("_GuardReaction")), justed(pending.act)))
        pending = nil
    end)
    if not ok then log.warn(TAG .. "dmg err: " .. tostring(err)) end
    return retval
end)

re.on_draw_ui(function()
    if not imgui.tree_node("AutoGuardTackleProbe") then return end
    local changed, v = imgui.checkbox("Experiment: switch to tackle on hit while charging", experiment)
    if changed then experiment = v end
    for _, e in ipairs(events) do imgui.text(e) end
    imgui.tree_pop()
end)

log.info(TAG .. "loaded")
