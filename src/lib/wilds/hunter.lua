-- lib/wilds/hunter：猎人的状态标志、能不能举起防御。所有武器通用（防御动作的编号由调用方给）。
--
-- 状态标志（NOTES「防御」）：hunter:get_HunterStatus()._HunterStatusFlag 是 ace.cSafeContinueFlagGroup，方法
-- on/off/check(UInt32)；枚举 app.HunterDef.STATUS_FLAG。受击结算前（evHit_DamagePreProcess 前置）打开 GUARD /
-- TECHNICAL_GUARD，游戏会按自己的规则（角度、体力、削伤）结算成防御；结算完（evHit_Damage 后置）关掉。
local LIB = ((...) or error("lib 模块要用 require 载入")):gsub("wilds%.[^.]+$", "")
local ref = require(LIB .. "ref")
local action = require(LIB .. "wilds.action")

local M = {}

function M.status_flags(hunter)
    return hunter:call("get_HunterStatus"):get_field("_HunterStatusFlag")
end

function M.any_flag(flags, list)
    for _, f in ipairs(list) do
        if flags:call("check(System.UInt32)", f) then return true end
    end
    return false
end

function M.flag_on(flags, f) flags:call("on(System.UInt32)", f) end
function M.flag_off(flags, f) flags:call("off(System.UInt32)", f) end

-- STATUS_FLAG 的值。td 传 app.HunterDef.STATUS_FLAG 的类型定义；拿不到报 "STATUS_FLAG.<名字> not found"
function M.status_flag(td, name)
    return ref.need(td:get_field(name), "STATUS_FLAG." .. name):get_data(nil)
end

-- 「不能举剑」的动作属性黑名单（app.HunterDef.ACTION_ATTR）。属性是游戏给动作打的标签，所有武器、所有同类动作通用，
-- 比按动作名列举可靠。补的是行为表检查不看时机漏掉的情况（见 why_cannot_guard）
M.GUARD_BLOCKED_ATTRS = {
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

-- 把属性名读成 { name, value } 列表；读不到的名字调 on_missing(名字) 后跳过
function M.action_attrs(td, names, on_missing)
    local out = {}
    for _, n in ipairs(names) do
        local f = td:get_field(n)
        if f then
            table.insert(out, { name = n, value = f:get_data(nil) })
        else
            on_missing(n)
        end
    end
    return out
end

-- 能不能举起防御：返回 nil 表示可以，否则返回原因文字。
-- 第一层问游戏：checkContainsActionInCurrentBTable 回答「当前行为表里有没有通往防御动作 guard_id 的路」（在 controller
--   entity 上调用）。实测：收刀、受击硬直、蓄力中都是 false，判断准确；但它不看时机（翻滚后半段能取消成防御，所以整个翻滚都
--   返回 true）。
-- 第二层：动作属性黑名单 attrs（action_attrs 的结果），补上不看时机漏掉的情况。
-- player 是 cPlayerManageInfo（lib/wilds/player 的 master()），cancel_invalid 是 app.ACTION_CANCEL_INDEX.Invalid 的值
function M.why_cannot_guard(hunter, player, guard_id, cancel_invalid, attrs)
    if not hunter:call("get_IsWeaponOn") then return "weapon off" end
    local entity = player:call("get_Controller"):call("get_ControllerEntity")
    local can = entity:call("checkContainsActionInCurrentBTable(ace.ACTION_ID, app.AppActionDef.LAYER, app.ACTION_CANCEL_INDEX)",
        guard_id, action.LAYER_BASE, cancel_invalid)
    if not can then return "btable" end
    for _, a in ipairs(attrs) do
        if hunter:call("isActionAttrCurrentAction(app.HunterDef.ACTION_ATTR)", a.value) then return "attr " .. a.name end
    end
    return nil
end

return M
