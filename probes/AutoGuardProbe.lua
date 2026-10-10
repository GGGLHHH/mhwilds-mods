-- AutoGuardProbe v2：验证「虚拟按住防御键」能否让大剑举剑并保持（一次性探针，验证完就删）
--
-- v1 的结论：changeActionRequest 能进 cGuard，但 0.17 秒后就收剑，
-- 因为 cGuard 每帧都检查「防御键还按着吗」。
--
-- v2 的思路：不直接切动作，而是在游戏「合并完输入」之后，把合并结果里的
-- ATTACK_SP（大剑的防御键）设成按下。之后的举剑、保持、松开收剑全由游戏自己处理，
-- 和真人按键走同一条路。
--
-- 为什么改 _MergedVirtualInput 而不是 _VirtualInput：
-- 键鼠输入走 _VirtualInputPc，手柄输入走 _VirtualInput，两者每帧都会被真实设备覆盖。
-- 合并之后再改，不管玩家用哪种设备都能生效。

local CommandController = sdk.find_type_definition("app.cPlayerCommandController")
local PAD = sdk.find_type_definition("app.PlayerKey.PAD")

local function enum_value(td, name)
    local f = td:get_field(name)
    return f and f:get_data(nil) or nil
end

local KEY_ATTACK_SP = enum_value(PAD, "ATTACK_SP")

-- 加载时把几个关心的键值写进日志，和按键记录器的结果对照
for _, n in ipairs({ "ATTACK_00", "ATTACK_01", "ATTACK_SP", "ATTACK_SP_B", "UI_CANCEL", "UI_DECIDE", "DODGE" }) do
    log.info(string.format("[AutoGuardProbe] PAD.%s = %s", n, tostring(enum_value(PAD, n))))
end

local hold_until = 0       -- 虚拟按住防御键到这个时刻（os.clock 秒）
local first_frame = false  -- 按下的第一帧还要给 OnTrigger
local results = {}
local cur_ctrl = nil       -- mergeAndUpdateInput 的 this

local function push_result(text)
    table.insert(results, 1, text)
    if #results > 8 then table.remove(results) end
    log.info("[AutoGuardProbe] " .. text)
end

local function get_master_command_controller()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local player = pm and pm:call("getMasterPlayer")
    local ctrl = player and player:call("get_Controller")
    local entity = ctrl and ctrl:call("get_ControllerEntity")
    return entity and entity:call("get_CommandController")
end

local function get_hunter()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local player = pm and pm:call("getMasterPlayer")
    return player and player:call("get_Character")
end

local function current_action(hunter)
    local ctrl = hunter:call("get_BaseActionController")
    local id = ctrl:call("get_CurrentActionID")
    local act = ctrl:call("get_CurrentAction")
    local name = act and act:get_type_definition():get_full_name() or "?"
    local short = name:gsub("app%.Wp00Action%.", "")
    return string.format("(%d,%d) %s", id:get_field("_Category"), id:get_field("_Index"), short)
end

sdk.hook(CommandController:get_method("mergeAndUpdateInput"),
    function(args)
        cur_ctrl = sdk.to_managed_object(args[2])
    end,
    function(retval)
        if os.clock() < hold_until and cur_ctrl and KEY_ATTACK_SP then
            -- 只改主玩家，别的玩家（联机队友）不动
            -- 比较地址而不是 Lua 对象：同一个游戏对象每次取出来可能是不同的 Lua 包装
            local master = get_master_command_controller()
            if master and cur_ctrl:get_address() == master:get_address() then
                local merged = cur_ctrl:get_field("_MergedVirtualInput")
                local key = merged and merged:call("getKey(System.Int32)", KEY_ATTACK_SP)
                if key then
                    key:call("set_On", true)
                    if first_frame then
                        key:call("set_OnTrigger", true)
                        first_frame = false
                    end
                end
            end
        end
        cur_ctrl = nil
        return retval
    end)

re.on_draw_ui(function()
    if not imgui.tree_node("AutoGuardProbe v2") then return end

    imgui.text("PAD.ATTACK_SP = " .. tostring(KEY_ATTACK_SP))
    local hunter = get_hunter()
    imgui.text("Current action: " .. (hunter and current_action(hunter) or "no hunter"))

    for _, sec in ipairs({ 0.5, 2.0 }) do
        if imgui.button(string.format("Virtual hold ATTACK_SP %.1fs", sec)) then
            hold_until = os.clock() + sec
            first_frame = true
            push_result(string.format("hold %.1fs start | before %s", sec, hunter and current_action(hunter) or "?"))
        end
    end

    imgui.separator()
    for _, r in ipairs(results) do imgui.text(r) end
    imgui.tree_pop()
end)
