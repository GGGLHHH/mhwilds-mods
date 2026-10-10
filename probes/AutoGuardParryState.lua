-- AutoGuardParryState：记录「手动抵消」时游戏内部的抵消流程（只记录，不改任何东西）
--
-- 抵消的核心在 cHunterWeaponHandlingBase（武器处理类）：
--   ParryState              当前抵消状态 NONE / WAIT / HIT / SUCCESS / RECOIL
--   ParryTarget             抵消对象（怪物）
--   onParryHitPreProcess(HitInfo)                受击预处理时检查「是不是抵消」
--   onParryHit(PARRY_STATE, GameObject, vec3)    判定为抵消命中
--   onParrySuccess(PARRY_STATE)                  抵消成功
-- 要回答：
--   1. ParryState 什么时候变成 WAIT（抵消窗口）？对应上捞斩的哪一段？
--   2. 撞上那一刻，这几个函数按什么顺序、带什么参数被调用？
--   3. 玩家受击（DMG）和 onParryHit 是什么先后关系？
-- 只在抵消相关动作中及其后 1.5 秒记录。

local TAG = "[AGPState] "
local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local Handling = sdk.find_type_definition("app.cHunterWeaponHandlingBase")
local PARRY_STATE = sdk.find_type_definition("app.HunterDef.PARRY_STATE")
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local PS = {}
for _, n in ipairs({ "NONE", "WAIT", "HIT", "SUCCESS", "RECOIL" }) do PS[PARRY_STATE:get_field(n):get_data(nil)] = n end
local function ps_name(v) return PS[v] or tostring(v) end

local PARRY_ACTIONS = { [21] = true, [22] = true, [23] = true, [24] = true, [25] = true, [26] = true, [27] = true }

local frame = 0
local in_parry = false
local record_until = 0
local last_line = nil
local events = {}

local function push(text)
    local line = string.format("f%d %s", frame, text)
    table.insert(events, 1, line)
    if #events > 30 then table.remove(events) end
    log.info(TAG .. line)
end
local function recording() return in_parry or os.clock() < record_until end

local function master_hunter()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    return p and p:call("get_Character")
end

local function action_text(hunter)
    local ctrl = hunter:call("get_BaseActionController")
    local id = ctrl:call("get_CurrentActionID")
    local act = ctrl:call("get_CurrentAction")
    local name = act and act:get_type_definition():get_full_name() or "?"
    return id, string.format("(%d,%d)%s", id:get_field("_Category"), id:get_field("_Index"), (name:gsub("app%.Wp00Action%.", "")))
end

local function is_master_handling(h)
    local hunter = master_hunter()
    local mh = hunter and hunter:call("get_WeaponHandling")
    return mh ~= nil and h ~= nil and mh:get_address() == h:get_address()
end

-- 每帧：动作 + ParryState + ParryTarget，组合变化时记一行
re.on_pre_application_entry("UpdateBehavior", function()
    frame = frame + 1
    local ok, err = pcall(function()
        local hunter = master_hunter()
        if not hunter then return end
        local id, act = action_text(hunter)
        local now_parry = id:get_field("_Category") == 2 and PARRY_ACTIONS[id:get_field("_Index")] == true
        if in_parry and not now_parry then record_until = os.clock() + 1.5 end
        in_parry = now_parry
        if not recording() then last_line = nil; return end

        local h = hunter:call("get_WeaponHandling")
        local target = h:call("get_ParryTarget")
        local line = string.format("STATE %s parry=%s target=%s continue=%s", act,
            ps_name(h:call("get_ParryState")), target and target:call("get_Name") or "-",
            tostring(h:call("get_IsParryInfoContinue")))
        if line ~= last_line then
            push(line)
            last_line = line
        end
    end)
    if not ok then log.warn(TAG .. "frame err: " .. tostring(err)) end
end)

-- 抵消相关函数调用
sdk.hook(Handling:get_method("onParryHitPreProcess(app.HitInfo)"), function(args)
    if not recording() then return end
    pcall(function()
        local h = sdk.to_managed_object(args[2])
        if not is_master_handling(h) then return end
        local info = sdk.to_managed_object(args[3])
        local owner = info:call("get_AttackOwner")
        push(string.format("CALL onParryHitPreProcess attacker=%s parry(before)=%s",
            owner and owner:call("get_Name") or "?", ps_name(h:call("get_ParryState"))))
    end)
end, nil)

sdk.hook(Handling:get_method("onParryHit(app.HunterDef.PARRY_STATE, via.GameObject, via.vec3)"), function(args)
    if not recording() then return end
    pcall(function()
        local h = sdk.to_managed_object(args[2])
        if not is_master_handling(h) then return end
        local st = sdk.to_int64(args[3]) & 0xFFFFFFFF
        local go = sdk.to_managed_object(args[4])
        push(string.format("CALL onParryHit state=%s target=%s", ps_name(st), go and go:call("get_Name") or "?"))
    end)
end, nil)

sdk.hook(Handling:get_method("onParrySuccess(app.HunterDef.PARRY_STATE)"), function(args)
    if not recording() then return end
    pcall(function()
        local h = sdk.to_managed_object(args[2])
        if not is_master_handling(h) then return end
        push("CALL onParrySuccess state=" .. ps_name(sdk.to_int64(args[3]) & 0xFFFFFFFF))
    end)
end, nil)

-- 实验：抵消蓄力中受击时，把 IsParryInfoContinue 打开，看游戏会不会自己走完抵消流程。
-- 依据（实测）：上捞斩中 continue=true，受击会调用 onParryHitPreProcess → onParryHit(WAIT) → onParrySuccess；
--             蓄力中 continue=false，受击只当普通挨打。
-- 结算完（evHit_Damage 之后）把它还原；每帧开始时也兜底还原。
local experiment = true
local CHARGE_IDX = { [21] = true, [22] = true }
local forced_handling = nil

-- 玩家受击（看和 onParryHit 的先后）
sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    if not recording() then return end
    pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        local owner = sdk.to_managed_object(args[3]):call("get_AttackOwner")
        local c = owner and owner:call("getComponent(System.Type)", T_CharacterBase)
        if not (c and c:get_type_definition():is_a("app.EnemyCharacter")) then return end
        local id, act = action_text(hunter)
        local h = hunter:call("get_WeaponHandling")
        local note = ""
        if experiment and id:get_field("_Category") == 2 and CHARGE_IDX[id:get_field("_Index")]
            and not h:call("get_IsParryInfoContinue") and not forced_handling then
            h:call("set_IsParryInfoContinue", true)
            forced_handling = h
            note = "  >>> EXPERIMENT: forced IsParryInfoContinue=true"
        end
        push(string.format("DMG-pre %s parry=%s%s", act, ps_name(h:call("get_ParryState")), note))
    end)
end, nil)

local function release_forced()
    if forced_handling then
        pcall(function() forced_handling:call("set_IsParryInfoContinue", false) end)
        forced_handling = nil
    end
end

sdk.hook(HunterCharacter:get_method("evHit_Damage(app.HitInfo)"), nil, function(retval)
    if forced_handling then
        release_forced()
        push("EXPERIMENT: restored IsParryInfoContinue=false")
    end
    return retval
end)
re.on_pre_application_entry("UpdateBehavior", release_forced)
re.on_script_reset(release_forced)

re.on_draw_ui(function()
    if not imgui.tree_node("AutoGuardParryState (probe)") then return end
    imgui.text(recording() and "Recording..." or "Idle (start a parry charge to record)")
    local changed, v = imgui.checkbox("Experiment: force IsParryInfoContinue on hit while parry-charging", experiment)
    if changed then experiment = v end
    if imgui.button("Clear") then events = {} end
    for _, e in ipairs(events) do imgui.text(e) end
    imgui.tree_pop()
end)

log.info(TAG .. "loaded")
