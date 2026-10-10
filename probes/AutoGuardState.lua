-- AutoGuardState：验证「问游戏现在能不能举剑」（探针，验证完就删）
--
-- 主信号：cPlayerInputControllerEntity.checkContainsActionInCurrentBTable(cGuard, BASE, Invalid)
--   假设含义：从当前状态出发，行为表里有没有通往防御动作 (1,141) 的路
--   第三个参数传 ACTION_CANCEL_INDEX.Invalid 是猜的，看实验结果
-- 对照信号：拔刀状态、当前动作分类、几个 ACTION_ATTR
-- 只在「动作 + 各信号」组合变化时写一行日志

local TAG = "[AGState] "
local ACTION_ATTR = sdk.find_type_definition("app.HunterDef.ACTION_ATTR")
local CANCEL_INDEX_TD = sdk.find_type_definition("app.ACTION_CANCEL_INDEX")

local GUARD_CAT, GUARD_IDX = 1, 141
local LAYER_BASE = 0
local INVALID_CANCEL = CANCEL_INDEX_TD:get_field("Invalid"):get_data(nil)

local ATTRS = { "DODGE", "WP_OFF", "DAMAGE", "DAMAGE_DOWN", "SMASH_DAMAGE", "ITEM_USE", "IDLE", "RUN", "WALK" }
local ATTR_VALUES = {}
for _, n in ipairs(ATTRS) do ATTR_VALUES[n] = ACTION_ATTR:get_field(n):get_data(nil) end

local guard_id = ValueType.new(sdk.find_type_definition("ace.ACTION_ID"))
guard_id:set_field("_Category", GUARD_CAT)
guard_id:set_field("_Index", GUARD_IDX)

local last_line = nil
local current = "?"
local history = {}

local function sample()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local player = pm and pm:call("getMasterPlayer")
    local hunter = player and player:call("get_Character")
    if not hunter then return nil end
    local entity = player:call("get_Controller"):call("get_ControllerEntity")

    local ok_bt, can_guard = pcall(function()
        return entity:call("checkContainsActionInCurrentBTable(ace.ACTION_ID, app.AppActionDef.LAYER, app.ACTION_CANCEL_INDEX)",
            guard_id, LAYER_BASE, INVALID_CANCEL)
    end)

    local ctrl = hunter:call("get_BaseActionController")
    local id = ctrl:call("get_CurrentActionID")
    local act = ctrl:call("get_CurrentAction")
    local name = act and act:get_type_definition():get_full_name() or "?"
    name = name:gsub("app%.Wp%d%dAction%.", ""):gsub("app%.", "")

    local attrs = {}
    for _, n in ipairs(ATTRS) do
        if hunter:call("isActionAttrCurrentAction(app.HunterDef.ACTION_ATTR)", ATTR_VALUES[n]) then table.insert(attrs, n) end
    end

    return string.format("canGuard=%s wpOn=%s (%d,%d) %s attrs=[%s]",
        ok_bt and tostring(can_guard) or ("ERR " .. tostring(can_guard)),
        tostring(hunter:call("get_IsWeaponOn")),
        id:get_field("_Category"), id:get_field("_Index"), name, table.concat(attrs, ","))
end

re.on_pre_application_entry("UpdateBehavior", function()
    local ok, line = pcall(sample)
    if not ok then line = "ERR " .. tostring(line) end
    if not line then return end
    current = line
    if line ~= last_line then
        last_line = line
        log.info(TAG .. line)
        table.insert(history, 1, line)
        if #history > 15 then table.remove(history) end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("AutoGuardState (probe)") then return end
    imgui.text("Now: " .. current)
    imgui.separator()
    for _, h in ipairs(history) do imgui.text(h) end
    imgui.tree_pop()
end)

log.info(TAG .. "loaded")
