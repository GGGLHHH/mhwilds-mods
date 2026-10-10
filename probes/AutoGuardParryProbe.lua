-- AutoGuardParryProbe：记录「抵消上捞斩」的完整过程（只记录，不改任何东西）
--
-- 动作（分类 2）：21 cIdleToParryCharge → 22 cParryCharge → 23 cParrySlash / 24 cParrySlashForward
--                 撞上敌人攻击后 → 25/26/27 cParrySlashHitS/M/L
-- 要回答：
--   1. 整个流程的动作顺序和每一步的帧数；子动作层（cParryChargeJust）何时出现
--   2. 撞上那一刻游戏发的消息：cMsgParrySuccess.State（NONE/WAIT/HIT/SUCCESS/RECOIL）
--   3. 怪物攻击判定激活（ATK+）到撞上，中间隔几帧
--   4. 撞上是在哪一步检测的：玩家受击（evHit_DamagePreProcess）还是玩家攻击命中（evHit_AttackPreProcess）
-- 所有事件只在「抵消相关动作中，及其后 1 秒」记录，避免刷屏。

local TAG = "[AGParry] "
local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local ColliderSwitcher = sdk.find_type_definition("app.ColliderSwitcher")
local MasterEntity = sdk.find_type_definition("app.cMasterPlayerControllerEntity")
local STATUS_FLAG = sdk.find_type_definition("app.HunterDef.STATUS_FLAG")
local PARRY_STATE = sdk.find_type_definition("app.HunterDef.PARRY_STATE")
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local PARRY_ACTIONS = { [21] = true, [22] = true, [23] = true, [24] = true, [25] = true, [26] = true, [27] = true }
local RECORD_AFTER = 1.0   -- 离开抵消动作后再记录多久（秒）

local WATCH = { "GUARD", "TECHNICAL_GUARD", "GUARD_POINT", "SUPER_ARMOR", "HYPER_ARMOR", "NO_DAMAGE_REACTION", "NO_DAMAGE" }
local FLAG = {}
for _, n in ipairs(WATCH) do FLAG[n] = STATUS_FLAG:get_field(n):get_data(nil) end

-- PARRY_STATE 数值 -> 名字
local PARRY_STATE_NAME = {}
for _, n in ipairs({ "NONE", "WAIT", "HIT", "SUCCESS", "RECOIL" }) do
    PARRY_STATE_NAME[PARRY_STATE:get_field(n):get_data(nil)] = n
end

local frame = 0
local record_until = 0
local in_parry = false
local last_base, last_sub = nil, nil
local events = {}

local function push(text)
    local line = string.format("f%d %s", frame, text)
    table.insert(events, 1, line)
    if #events > 30 then table.remove(events) end
    log.info(TAG .. line)
end

local function recording() return in_parry or os.clock() < record_until end

local function master()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    return p, p and p:call("get_Character")
end

local function action_of(ctrl)
    if not ctrl then return nil, "-" end
    local id = ctrl:call("get_CurrentActionID")
    local act = ctrl:call("get_CurrentAction")
    local name = act and act:get_type_definition():get_full_name() or "?"
    name = name:gsub("app%.Wp00Action%.", ""):gsub("app%.Wp00SubAction%.", "sub."):gsub("app%.", "")
    return id, string.format("(%d,%d)%s", id:get_field("_Category"), id:get_field("_Index"), name)
end

local function flags_text(hunter)
    local flags = hunter:call("get_HunterStatus"):get_field("_HunterStatusFlag")
    local on = {}
    for _, n in ipairs(WATCH) do
        if flags:call("check(System.UInt32)", FLAG[n]) then table.insert(on, n) end
    end
    return #on > 0 and table.concat(on, ",") or "-"
end

local function enemy_name(go)
    if not go then return nil end
    local c = go:call("getComponent(System.Type)", T_CharacterBase)
    if c and c:get_type_definition():is_a("app.EnemyCharacter") then return go:call("get_Name") end
    return nil
end

-- 1. 每帧：动作变化（主层 + 子动作层）
re.on_pre_application_entry("UpdateBehavior", function()
    frame = frame + 1
    local ok, err = pcall(function()
        local _, hunter = master()
        if not hunter then return end
        local id, base = action_of(hunter:call("get_BaseActionController"))
        local _, sub = action_of(hunter:call("get_SubActionController"))

        local now_parry = id:get_field("_Category") == 2 and PARRY_ACTIONS[id:get_field("_Index")] == true
        if in_parry and not now_parry then record_until = os.clock() + RECORD_AFTER end
        in_parry = now_parry

        if (base ~= last_base or sub ~= last_sub) and recording() then
            push(string.format("ACT base=%s sub=%s flags=%s", base, sub, flags_text(hunter)))
        end
        last_base, last_sub = base, sub
    end)
    if not ok then log.warn(TAG .. "frame err: " .. tostring(err)) end
end)

-- 2. 游戏消息：主玩家收到的每条消息（抵消中只记类型；cMsgParrySuccess 记状态）
sdk.hook(MasterEntity:get_method("receiveGameMessage(ace.cGameMessage)"), function(args)
    if not recording() then return end
    local ok, err = pcall(function()
        local msg = sdk.to_managed_object(args[3])
        if not msg then return end
        local tname = msg:get_type_definition():get_full_name()
        if tname == "app.game_message.cMsgParrySuccess" then
            local st = msg:call("get_State")
            push(string.format("MSG ParrySuccess state=%s(%s)", PARRY_STATE_NAME[st] or "?", tostring(st)))
        else
            push("MSG " .. tname)
        end
    end)
    if not ok then log.warn(TAG .. "msg err: " .. tostring(err)) end
end, nil)

-- 3. 怪物攻击判定激活（只在记录期间）
sdk.hook(ColliderSwitcher:get_method("activateAttack(System.Boolean, System.UInt32, System.UInt32, System.Nullable`1<System.Boolean>, app.Hit.HIT_ID_GROUP, System.Nullable`1<System.Single>, System.Nullable`1<System.Single>)"),
    function(args)
        if not recording() or (sdk.to_int64(args[3]) & 1) == 0 then return end
        local ok, err = pcall(function()
            local switcher = sdk.to_managed_object(args[2])
            local name = enemy_name(switcher:get_field("_HitController"):call("get_Owner"))
            if name then push(string.format("ATK+ %s req=%d", name, sdk.to_int64(args[5]) & 0xFFFFFFFF)) end
        end)
        if not ok then log.warn(TAG .. "atk err: " .. tostring(err)) end
    end, nil)

-- 4a. 玩家受击
local dmg_hunter = nil
sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    if not recording() then return end
    local ok, err = pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        local name = enemy_name(sdk.to_managed_object(args[3]):call("get_AttackOwner"))
        if not name then return end
        local _, base = action_of(hunter:call("get_BaseActionController"))
        push(string.format("DMG-pre from %s | %s flags=%s", name, base, flags_text(hunter)))
    end)
    if not ok then log.warn(TAG .. "dmg-pre err: " .. tostring(err)) end
end, nil)

sdk.hook(HunterCharacter:get_method("evHit_Damage(app.HitInfo)"), function(args)
    dmg_hunter = sdk.to_managed_object(args[2])
end, function(retval)
    local hunter = dmg_hunter
    dmg_hunter = nil
    if hunter and recording() then
        pcall(function()
            if not hunter:call("get_IsMaster") then return end
            local info = hunter:call("get_DamageInfo")
            push(string.format("DMG-post total=%.1f reaction=%s", info:get_field("_TotalDamage") or -1, tostring(info:get_field("_GuardReaction"))))
        end)
    end
    return retval
end)

-- 4b. 玩家攻击命中（看「撞在一起」是不是在这里检测的）
sdk.hook(HunterCharacter:get_method("evHit_AttackPreProcess(app.HitInfo)"), function(args)
    if not recording() then return end
    local ok, err = pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        local info = sdk.to_managed_object(args[3])
        local target = info:call("get_DamageOwner")
        local _, base = action_of(hunter:call("get_BaseActionController"))
        local dmg_data = info:call("get_DamageData")
        push(string.format("ATK-hit -> %s layer=%s dmgData=%s | %s",
            target and target:call("get_Name") or "?",
            tostring(info:call("get_CollisionLayer")),
            dmg_data and dmg_data:get_type_definition():get_full_name() or "nil",
            base))
    end)
    if not ok then log.warn(TAG .. "atk-hit err: " .. tostring(err)) end
end, nil)

re.on_draw_ui(function()
    if not imgui.tree_node("AutoGuardParryProbe") then return end
    imgui.text(recording() and "Recording..." or "Idle (start a parry charge to record)")
    if imgui.button("Clear") then events = {} end
    for _, e in ipairs(events) do imgui.text(e) end
    imgui.tree_pop()
end)

log.info(TAG .. "loaded")
